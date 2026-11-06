// Bitwarden password-protected JSON export, decrypted in memory.
//
// Format (from bitwarden/clients, libs/tools/export-vault-core and
// libs/legacy-crypto):
//   material = PBKDF2-SHA256(password, salt-as-UTF8, iterations, 32)
//            | Argon2id(password, salt-as-UTF8, iterations, memory KiB, parallelism, 32)
//   encKey   = HKDF-Expand-SHA256(material, "enc", 32)
//   macKey   = HKDF-Expand-SHA256(material, "mac", 32)
//   data     = "2.<iv b64>|<ciphertext b64>|<mac b64>"
// AES-256-CBC/PKCS7 with encKey; MAC key over iv || ciphertext.

import { argon2id } from "hash-wasm";

export type BitwardenField = {
  name: string;
  value: string;
  type: number;
};

export type BitwardenLogin = {
  username?: string | null;
  password?: string | null;
  totp?: string | null;
  uris?: Array<{ uri: string }> | null;
};

export type BitwardenItem = {
  id: string;
  name: string;
  type: number;
  folderId?: string | null;
  notes?: string | null;
  fields?: BitwardenField[] | null;
  login?: BitwardenLogin | null;
  secureNote?: { type?: number } | null;
};

export type BitwardenExport = {
  encrypted?: false;
  folders?: Array<{ id: string; name: string }> | null;
  items: BitwardenItem[];
};

export type PasswordProtectedExport = {
  encrypted: true;
  passwordProtected: true;
  salt: string;
  kdfType: number;
  kdfIterations: number;
  kdfMemory?: number | null;
  kdfParallelism?: number | null;
  encKeyValidation_DO_NOT_EDIT: string;
  data: string;
};

const KDF_PBKDF2 = 0;
const KDF_ARGON2ID = 1;

const MAX_ITERATIONS = 2_000_000;
const MAX_ARGON_MEMORY_KIB = 256 * 1024;
const MAX_ARGON_PARALLELISM = 16;
const MAX_CIPHERTEXT_BYTES = 32 * 1024 * 1024;

type ParsedCipherString = {
  iv: Uint8Array;
  ciphertext: Uint8Array;
  mac: Uint8Array;
};

function fromBase64(value: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function fromBase64Url(value: string): Uint8Array {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  return fromBase64(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
}

function parseCipherString(value: unknown): ParsedCipherString {
  if (typeof value !== "string") throw new Error("encrypted export value is not a string");
  const match = /^2\.([A-Za-z0-9+/=_-]+)\|([A-Za-z0-9+/=_-]+)\|([A-Za-z0-9+/=_-]+)$/.exec(
    value,
  );
  if (!match) throw new Error("encrypted export uses an unsupported cipher string");
  const [, iv, ciphertext, mac] = match;
  const parsed = {
    iv: fromBase64Url(iv),
    ciphertext: fromBase64Url(ciphertext),
    mac: fromBase64Url(mac),
  };
  if (parsed.iv.length !== 16 || parsed.mac.length !== 32) {
    throw new Error("encrypted export has an invalid IV or MAC");
  }
  if (parsed.ciphertext.length === 0 || parsed.ciphertext.length % 16 !== 0) {
    throw new Error("encrypted export has invalid ciphertext");
  }
  if (parsed.ciphertext.length > MAX_CIPHERTEXT_BYTES) {
    throw new Error("encrypted export is too large");
  }
  return parsed;
}

async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, data as BufferSource));
}

function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(parts.reduce((sum, part) => sum + part.length, 0)));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/** HKDF-Expand (RFC 5869) without the extract step, as Bitwarden's stretchKey does. */
export async function hkdfExpand(
  prk: Uint8Array,
  info: string,
  length: number,
): Promise<Uint8Array> {
  if (prk.length < 32) throw new Error("HKDF PRK is too short");
  const infoBytes = new TextEncoder().encode(info);
  const blocks = Math.ceil(length / 32);
  const okm = new Uint8Array(blocks * 32);
  let previous: Uint8Array = new Uint8Array(0);
  for (let index = 0; index < blocks; index++) {
    previous = await hmacSha256(prk, concat(previous, infoBytes, new Uint8Array([index + 1])));
    okm.set(previous, index * 32);
  }
  return okm.subarray(0, length);
}

async function deriveMaterial(
  password: string,
  salt: string,
  kdfType: number,
  iterations: number,
  memory?: number | null,
  parallelism?: number | null,
): Promise<Uint8Array> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > MAX_ITERATIONS) {
    throw new Error("export KDF iterations are out of range");
  }
  // Bitwarden encodes the salt string as UTF-8; it is already base64 text.
  const saltBytes = new TextEncoder().encode(salt);
  if (kdfType === KDF_PBKDF2) {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(password),
      "PBKDF2",
      false,
      ["deriveBits"],
    );
    const bits = await crypto.subtle.deriveBits(
      { name: "PBKDF2", hash: "SHA-256", salt: saltBytes as BufferSource, iterations },
      key,
      256,
    );
    return new Uint8Array(bits);
  }
  if (kdfType === KDF_ARGON2ID) {
    const memoryKib = memory ?? 64 * 1024;
    const lanes = parallelism ?? 4;
    if (
      !Number.isInteger(memoryKib) ||
      memoryKib < 8 ||
      memoryKib > MAX_ARGON_MEMORY_KIB ||
      !Number.isInteger(lanes) ||
      lanes < 1 ||
      lanes > MAX_ARGON_PARALLELISM
    ) {
      throw new Error("export Argon2 parameters are out of range");
    }
    return argon2id({
      password,
      salt: saltBytes,
      iterations,
      parallelism: lanes,
      memorySize: memoryKib,
      hashLength: 32,
      outputType: "binary",
    });
  }
  throw new Error(`unsupported export KDF type: ${kdfType}`);
}

export type ExportKey = { encKey: Uint8Array; macKey: Uint8Array };

export async function deriveExportKey(
  password: string,
  salt: string,
  kdfType: number,
  iterations: number,
  memory?: number | null,
  parallelism?: number | null,
): Promise<ExportKey> {
  const material = await deriveMaterial(
    password,
    salt,
    kdfType,
    iterations,
    memory,
    parallelism,
  );
  try {
    return {
      encKey: await hkdfExpand(material, "enc", 32),
      macKey: await hkdfExpand(material, "mac", 32),
    };
  } finally {
    material.fill(0);
  }
}

export async function decryptCipherString(value: unknown, key: ExportKey): Promise<string> {
  const parsed = parseCipherString(value);
  const expected = await hmacSha256(key.macKey, concat(parsed.iv, parsed.ciphertext));
  if (!timingSafeEqual(expected, parsed.mac)) {
    throw new Error("the export password is wrong");
  }
  const cryptoKey = await crypto.subtle.importKey("raw", key.encKey as BufferSource, "AES-CBC", false, [
    "decrypt",
  ]);
  let plain: ArrayBuffer;
  try {
    plain = await crypto.subtle.decrypt(
      { name: "AES-CBC", iv: parsed.iv as BufferSource },
      cryptoKey,
      parsed.ciphertext as BufferSource,
    );
  } catch {
    throw new Error("the export could not be decrypted");
  }
  return new TextDecoder().decode(plain);
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let index = 0; index < a.length; index++) diff |= a[index] ^ b[index];
  return diff === 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isProtectedExport(value: unknown): value is PasswordProtectedExport {
  return (
    isRecord(value) &&
    value.encrypted === true &&
    value.passwordProtected === true &&
    typeof value.salt === "string" &&
    typeof value.kdfType === "number" &&
    typeof value.kdfIterations === "number" &&
    typeof value.data === "string" &&
    typeof value.encKeyValidation_DO_NOT_EDIT === "string"
  );
}

export async function decryptBitwardenExport(
  json: string,
  password: string,
  limits: { maxIterations?: number } = {},
): Promise<BitwardenExport> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new Error("the Bitwarden export is not valid JSON");
  }
  if (!isProtectedExport(parsed)) {
    throw new Error("this is not a password-protected Bitwarden export");
  }
  if (limits.maxIterations !== undefined && parsed.kdfIterations > limits.maxIterations) {
    throw new Error("export KDF iterations are above the configured limit");
  }

  const key = await deriveExportKey(
    password,
    parsed.salt,
    parsed.kdfType,
    parsed.kdfIterations,
    parsed.kdfMemory,
    parsed.kdfParallelism,
  );
  // A random GUID encrypted with the same key; a wrong password fails the MAC.
  await decryptCipherString(parsed.encKeyValidation_DO_NOT_EDIT, key);
  const plaintext = await decryptCipherString(parsed.data, key);

  let vault: unknown;
  try {
    vault = JSON.parse(plaintext);
  } catch {
    throw new Error("the decrypted export is not valid JSON");
  }
  if (!isRecord(vault) || !Array.isArray(vault.items)) {
    throw new Error("the decrypted export has no items");
  }
  return vault as BitwardenExport;
}
