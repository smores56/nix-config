// Cryptomator vault format 8, read-only subset.
//
// Reads file and directory names (AES-SIV), directory IDs, the encrypted
// masterkey file, the signed vault config and SIV_GCM file contents. Only the
// read path is implemented: this app never writes to the family vault.
//
// The structure follows cryptomator-ts 0.0.2 (MIT, see MIT-LICENSE.txt in this
// directory), with the content crypto and name handling corrected against the
// published vault format specification and verified against vaults created by
// cryptofs 2.8.0 / cryptolib 2.2.0.

import { aeskw, aessiv, gcm } from "@noble/ciphers/aes.js";
import { scrypt } from "hash-wasm";

export type DirID = string & { readonly __brand: "DirID" };

export const ROOT_DIR_ID = "" as DirID;

export type VaultEntry = {
  name: string;
  type: "file" | "dir";
  size?: number;
};

export interface VaultProvider {
  read(path: string): Promise<Uint8Array>;
  readText(path: string, maxBytes?: number): Promise<string>;
  list(path: string): Promise<VaultEntry[]>;
}

export type VaultSettings = {
  format: 8;
  cipherCombo: "SIV_GCM";
  shorteningThreshold: number;
};

export type Item = {
  name: string;
  kind: "file" | "dir" | "symlink" | "unknown";
  /** Absolute vault-relative ciphertext path of the file or shortened-name directory. */
  encryptedPath: string;
  /** Directory ID, set for directories. */
  dirId?: DirID;
  shortened: boolean;
  size?: number;
  /** Set when the entry cannot be classified; the rest of the listing stays usable. */
  damaged?: string;
};

/** Metadata files are tiny; refuse anything larger before buffering it. */
export const MAX_METADATA_BYTES = 64 * 1024;

const HEADER_SIZE = 68;
const HEADER_PAYLOAD_SIZE = 40;
const CHUNK_NONCE_SIZE = 12;
const CHUNK_PAYLOAD_SIZE = 32 * 1024;
const CHUNK_TAG_SIZE = 16;
const CHUNK_SIZE = CHUNK_NONCE_SIZE + CHUNK_PAYLOAD_SIZE + CHUNK_TAG_SIZE;

// 128 * N * r bytes; keep a hostile masterkey file from exhausting a phone.
const MAX_KEY_COST = { N: 1 << 18, r: 16, memory: 128 * 1024 * 1024 };

export const MAX_FILE_BYTES = 256 * 1024 * 1024;

const INTERNAL_NAMES = new Set([
  "dir.c9r",
  "dirid.c9r",
  "contents.c9r",
  "name.c9s",
  "symlink.c9r",
]);

type MasterkeyFile = {
  version: number;
  scryptSalt: string;
  scryptCostParam: number;
  scryptBlockSize: number;
  primaryMasterKey: string;
  hmacMasterKey: string;
};

export type MasterKey = {
  encKey: Uint8Array;
  macKey: Uint8Array;
};

function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(parts.reduce((sum, part) => sum + part.length, 0)));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function fromBase64(value: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function fromBase64Url(value: string): Uint8Array<ArrayBuffer> {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  return fromBase64(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
}

const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

function uint64be(value: number): Uint8Array {
  const out = new Uint8Array(8);
  new DataView(out.buffer).setBigUint64(0, BigInt(value), false);
  return out;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireInteger(value: unknown, label: string, min = 0): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min) {
    throw new Error(`invalid ${label}`);
  }
  return value;
}

export async function deriveKek(
  masterkey: MasterkeyFile,
  password: string,
): Promise<Uint8Array> {
  const cost = requireInteger(masterkey.scryptCostParam, "scrypt cost", 2);
  const blockSize = requireInteger(masterkey.scryptBlockSize, "scrypt block size", 1);
  if ((cost & (cost - 1)) !== 0) throw new Error("scrypt cost must be a power of two");
  if (cost > MAX_KEY_COST.N || blockSize > MAX_KEY_COST.r) {
    throw new Error("scrypt parameters exceed the supported limits");
  }
  if (128 * cost * blockSize > MAX_KEY_COST.memory) {
    throw new Error("scrypt parameters exceed the supported memory");
  }
  const salt = fromBase64(masterkey.scryptSalt);
  if (salt.length < 8 || salt.length > 64) throw new Error("invalid scrypt salt");
  const raw = await scrypt({
    password,
    salt,
    costFactor: cost,
    blockSize,
    parallelism: 1,
    hashLength: 32,
    outputType: "binary",
  });
  return raw as Uint8Array;
}

export async function openMasterKey(
  masterkeyJson: string,
  password: string,
): Promise<MasterKey> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(masterkeyJson);
  } catch {
    throw new Error("masterkey.cryptomator is not valid JSON");
  }
  if (!isRecord(parsed)) throw new Error("masterkey.cryptomator has an unexpected shape");
  const masterkey = parsed as MasterkeyFile;
  if (requireInteger(masterkey.version, "masterkey version", 1) !== 999) {
    throw new Error("unsupported Cryptomator masterkey version");
  }
  if (typeof masterkey.primaryMasterKey !== "string" || typeof masterkey.hmacMasterKey !== "string") {
    throw new Error("masterkey.cryptomator is missing its keys");
  }

  const kek = await deriveKek(masterkey, password);
  let encKey: Uint8Array;
  let macKey: Uint8Array;
  try {
    const unwrap = aeskw(kek);
    encKey = unwrap.decrypt(fromBase64(masterkey.primaryMasterKey));
    macKey = unwrap.decrypt(fromBase64(masterkey.hmacMasterKey));
  } catch {
    throw new Error("the vault password is wrong");
  } finally {
    kek.fill(0);
  }
  if (encKey.length !== 32 || macKey.length !== 32) {
    throw new Error("masterkey.cryptomator contains unexpected key lengths");
  }
  return { encKey, macKey };
}

export async function verifyVaultConfig(
  token: string,
  masterkey: MasterKey,
): Promise<VaultSettings> {
  const parts = token.trim().split(".");
  if (parts.length !== 3) throw new Error("vault.cryptomator is not a signed JWT");
  const [headerPart, payloadPart, signaturePart] = parts;
  const key = await crypto.subtle.importKey(
    "raw",
    concat(masterkey.encKey, masterkey.macKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const signed = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
  const valid = await crypto.subtle.verify("HMAC", key, fromBase64Url(signaturePart), signed);
  if (!valid) throw new Error("vault.cryptomator signature is invalid");

  const header = JSON.parse(new TextDecoder().decode(fromBase64Url(headerPart))) as {
    alg?: string;
  };
  if (header.alg !== "HS256") throw new Error("vault.cryptomator uses an unsupported signature");

  const claims = JSON.parse(new TextDecoder().decode(fromBase64Url(payloadPart))) as {
    format?: number;
    cipherCombo?: string;
    shorteningThreshold?: number;
  };
  if (claims.format !== 8) throw new Error(`unsupported vault format: ${String(claims.format)}`);
  if (claims.cipherCombo !== "SIV_GCM") {
    throw new Error(`unsupported cipher combo: ${String(claims.cipherCombo)}`);
  }
  const threshold = claims.shorteningThreshold;
  if (typeof threshold !== "number" || !Number.isInteger(threshold) || threshold < 32) {
    throw new Error("vault.cryptomator has an invalid shortening threshold");
  }
  return { format: 8, cipherCombo: "SIV_GCM", shorteningThreshold: threshold };
}

export class CryptomatorVault {
  private readonly sivKey: Uint8Array;

  private constructor(
    private readonly provider: VaultProvider,
    readonly settings: VaultSettings,
    private readonly masterkey: MasterKey,
  ) {
    // RFC 5297 splits the 64-byte key into K1 (S2V) and K2 (CTR); Cryptomator
    // stores the masterkey as enc || mac.
    this.sivKey = concat(masterkey.macKey, masterkey.encKey);
  }

  static async open(provider: VaultProvider, password: string): Promise<CryptomatorVault> {
    const [configToken, masterkeyJson] = await Promise.all([
      provider.readText("vault.cryptomator", MAX_METADATA_BYTES),
      provider.readText("masterkey.cryptomator", MAX_METADATA_BYTES),
    ]);
    const masterkey = await openMasterKey(masterkeyJson, password);
    const settings = await verifyVaultConfig(configToken, masterkey);
    return new CryptomatorVault(provider, settings, masterkey);
  }

  /** Ciphertext directory for a directory ID. */
  async ciphertextPath(dirId: DirID): Promise<string> {
    const sealed = aessiv(this.sivKey).encrypt(new TextEncoder().encode(dirId));
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-1", sealed));
    const hash = base32(digest);
    return `d/${hash.slice(0, 2)}/${hash.slice(2)}`;
  }

  decryptName(ciphertextName: string, parentId: DirID): string {
    const stripped = ciphertextName.endsWith(".c9r")
      ? ciphertextName.slice(0, -4)
      : ciphertextName;
    const associated = new TextEncoder().encode(parentId);
    let plain: Uint8Array;
    try {
      plain = aessiv(this.sivKey, associated).decrypt(fromBase64Url(stripped));
    } catch {
      throw new Error("a vault file name could not be decrypted");
    }
    // Cryptomator writes NFC; normalise anyway so a name restored from a
    // case-insensitive or decomposing filesystem still matches.
    return new TextDecoder().decode(plain).normalize("NFC");
  }

  async list(dirId: DirID): Promise<Item[]> {
    const directory = await this.ciphertextPath(dirId);
    const entries = await this.provider.list(directory);
    const items: Item[] = [];

    const childKind = async (path: string): Promise<Item["kind"]> => {
      const names = new Set((await this.provider.list(path)).map((entry) => entry.name));
      if (names.has("contents.c9r")) return "file";
      if (names.has("dir.c9r")) return "dir";
      if (names.has("symlink.c9r")) return "symlink";
      return "unknown";
    };

    const childIdOf = async (path: string): Promise<DirID> =>
      (await this.provider.readText(`${path}/dir.c9r`, MAX_METADATA_BYTES)).trim() as DirID;

    for (const entry of entries) {
      if (INTERNAL_NAMES.has(entry.name)) continue;
      const path = `${directory}/${entry.name}`;
      if (entry.name.endsWith(".c9s")) {
        if (entry.type !== "dir") {
          items.push({
            name: entry.name,
            kind: "unknown",
            encryptedPath: path,
            shortened: true,
            damaged: "shortened entry is not a directory",
          });
          continue;
        }
        const inflated = (
          await this.provider.readText(`${path}/name.c9s`, MAX_METADATA_BYTES)
        ).trim();
        const name = this.decryptName(inflated, dirId);
        const kind = await childKind(path);
        if (kind === "dir") {
          const childId = await childIdOf(path);
          items.push({ name, kind, encryptedPath: path, dirId: childId, shortened: true });
        } else if (kind === "unknown") {
          items.push({
            name,
            kind,
            encryptedPath: path,
            shortened: true,
            damaged: "no file, directory or symlink marker",
          });
        } else {
          items.push({ name, kind, encryptedPath: path, shortened: true });
        }
      } else if (entry.name.endsWith(".c9r")) {
        const name = this.decryptName(entry.name, dirId);
        if (entry.type === "file") {
          items.push({ name, kind: "file", encryptedPath: path, shortened: false, size: entry.size });
        } else {
          const kind = await childKind(path);
          if (kind === "dir") {
            const childId = await childIdOf(path);
            items.push({ name, kind, encryptedPath: path, dirId: childId, shortened: false });
          } else if (kind === "unknown") {
            items.push({
              name,
              kind,
              encryptedPath: path,
              shortened: false,
              damaged: "no file, directory or symlink marker",
            });
          } else {
            items.push({ name, kind, encryptedPath: path, shortened: false });
          }
        }
      }
    }

    return items;
  }

  async readFile(item: Item): Promise<Uint8Array> {
    if (item.kind !== "file") throw new Error(`${item.name} is not a regular file`);
    const path = item.shortened ? `${item.encryptedPath}/contents.c9r` : item.encryptedPath;
    const ciphertext = await this.provider.read(path);
    // A provider that reports a size must return exactly that many bytes; a
    // short read means the file changed mid-restore.
    if (item.size !== undefined && !item.shortened && ciphertext.length !== item.size) {
      throw new Error(`${item.name} is shorter than the vault index reports`);
    }
    return this.decryptFile(ciphertext);
  }

  async readTextFile(item: Item): Promise<string> {
    return new TextDecoder().decode(await this.readFile(item));
  }

  private async decryptFile(ciphertext: Uint8Array): Promise<Uint8Array> {
    if (ciphertext.length < HEADER_SIZE) throw new Error("ciphertext file is truncated");
    if (ciphertext.length > MAX_FILE_BYTES + 1024 * 1024) {
      throw new Error("file exceeds the safe decrypt size");
    }

    const headerNonce = ciphertext.subarray(0, CHUNK_NONCE_SIZE);
    let header: Uint8Array;
    try {
      header = gcm(this.masterkey.encKey, headerNonce).decrypt(
        ciphertext.subarray(CHUNK_NONCE_SIZE, HEADER_SIZE),
      );
    } catch {
      throw new Error("the vault file header failed authentication");
    }
    if (header.length !== HEADER_PAYLOAD_SIZE) throw new Error("invalid vault file header");
    const contentKey = header.subarray(8, 40);

    const encryptedLength = ciphertext.length - HEADER_SIZE;
    const chunks = encryptedLength === 0 ? 0 : Math.ceil(encryptedLength / CHUNK_SIZE);
    const lastChunkLength = chunks === 0 ? 0 : encryptedLength - (chunks - 1) * CHUNK_SIZE;
    const plaintextLength =
      chunks === 0 ? 0 : (chunks - 1) * CHUNK_PAYLOAD_SIZE + lastChunkLength - CHUNK_NONCE_SIZE - CHUNK_TAG_SIZE;
    if (plaintextLength > MAX_FILE_BYTES) throw new Error("file is too large");
    const out = new Uint8Array(plaintextLength);

    let written = 0;
    for (let index = 0; index < chunks; index++) {
      const start = HEADER_SIZE + index * CHUNK_SIZE;
      const chunk = ciphertext.subarray(start, Math.min(start + CHUNK_SIZE, ciphertext.length));
      if (chunk.length < CHUNK_NONCE_SIZE + CHUNK_TAG_SIZE) {
        throw new Error("ciphertext chunk is truncated");
      }
      const nonce = chunk.subarray(0, CHUNK_NONCE_SIZE);
      const aad = concat(uint64be(index), headerNonce);
      let plain: Uint8Array;
      try {
        plain = gcm(contentKey, nonce, aad).decrypt(chunk.subarray(CHUNK_NONCE_SIZE));
      } catch {
        throw new Error(`a vault file chunk failed authentication (chunk ${index})`);
      }
      out.set(plain, written);
      written += plain.length;
      plain.fill(0);
      // A 256 MiB document would otherwise block a phone's main thread for
      // seconds; yield every 2 MiB so the page stays responsive.
      if (index % 64 === 63) await new Promise((resolve) => setTimeout(resolve, 0));
    }
    header.fill(0);
    return out;
  }
}
