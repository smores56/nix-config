import { ctr, ecb } from "@noble/ciphers/aes.js";
import { equal, oneTimeAuth } from "@stablelib/poly1305";
import { decompress } from "fzstd";
import { scrypt } from "hash-wasm";

export type MacKey = { k: Uint8Array; r: Uint8Array };
export type MasterKey = { encrypt: Uint8Array; mac: MacKey };

export type ResticKeyFile = {
  kdf: string;
  N: number;
  r: number;
  p: number;
  salt: string;
  data: string;
};

const MAX_KEY_COST = { N: 131072, r: 8, p: 16, memory: 128 * 1024 * 1024 };

function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

export function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function poly1305Aes(mac: MacKey, nonce: Uint8Array, ciphertext: Uint8Array): Uint8Array {
  const s = ecb(mac.k).encrypt(nonce);
  return oneTimeAuth(concat(mac.r, s), ciphertext);
}

export function openSealed(
  sealed: Uint8Array,
  encKey: Uint8Array,
  mac: MacKey,
): Uint8Array {
  if (sealed.length < 32) throw new Error("restic object is too short");
  const nonce = sealed.slice(0, 16);
  const ciphertext = sealed.slice(16, sealed.length - 16);
  const tag = sealed.slice(sealed.length - 16);
  const expected = poly1305Aes(mac, nonce, ciphertext);
  if (!equal(tag, expected)) throw new Error("restic MAC mismatch");
  return ctr(encKey, nonce).decrypt(ciphertext);
}

export function maybeZstd(plaintext: Uint8Array): Uint8Array {
  return plaintext[0] === 0x02 ? decompress(plaintext.slice(1)) : plaintext;
}

function validateKeyCost(keyFile: ResticKeyFile): void {
  if (keyFile.kdf !== "scrypt") throw new Error("unsupported restic KDF");
  if (
    !Number.isInteger(keyFile.N) ||
    !Number.isInteger(keyFile.r) ||
    !Number.isInteger(keyFile.p) ||
    keyFile.N < 1024 ||
    keyFile.N > MAX_KEY_COST.N ||
    (keyFile.N & (keyFile.N - 1)) !== 0 ||
    keyFile.r < 1 ||
    keyFile.r > MAX_KEY_COST.r ||
    keyFile.p < 1 ||
    keyFile.p > MAX_KEY_COST.p ||
    128 * keyFile.N * keyFile.r > MAX_KEY_COST.memory
  ) {
    throw new Error("invalid restic KDF parameters");
  }
}

export async function openKeyFile(
  keyFile: ResticKeyFile,
  password: string,
): Promise<MasterKey> {
  validateKeyCost(keyFile);
  const salt = fromBase64(keyFile.salt);
  const derived = await scrypt({
    password,
    salt,
    costFactor: keyFile.N,
    blockSize: keyFile.r,
    parallelism: keyFile.p,
    hashLength: 64,
    outputType: "binary",
  });
  const encKey = derived.slice(0, 32);
  const mac: MacKey = { k: derived.slice(32, 48), r: derived.slice(48, 64) };
  const master = JSON.parse(
    new TextDecoder().decode(openSealed(fromBase64(keyFile.data), encKey, mac)),
  ) as { encrypt: string; mac: { k: string; r: string } };
  return {
    encrypt: fromBase64(master.encrypt),
    mac: { k: fromBase64(master.mac.k), r: fromBase64(master.mac.r) },
  };
}

export function openWithMaster(sealed: Uint8Array, master: MasterKey): Uint8Array {
  return openSealed(sealed, master.encrypt, master.mac);
}

export async function verifySha256(data: Uint8Array, expectedHex: string): Promise<boolean> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", data as BufferSource),
  );
  return bytesToHex(digest) === expectedHex.toLowerCase();
}
