import { scrypt } from "hash-wasm";

export type DataKeys = {
  version: 1;
  r2: {
    endpoint: string;
    bucket: string;
    accessKeyId: string;
    secretAccessKey: string;
    region?: string;
  };
  restic: {
    password: string;
    repository: string;
    photosPath: string;
    vaultPath: string;
    dbPath?: string;
  };
  vault: {
    password: string;
    path: string;
  };
};

export type DataKeysBlob = {
  version: 1;
  kdf: "scrypt";
  N: number;
  r: number;
  p: number;
  salt: string;
  nonce: string;
  ciphertext: string;
};

export type ScryptCost = {
  N: number;
  r: number;
  p: number;
};

export const DEFAULT_COST: ScryptCost = { N: 65536, r: 8, p: 1 };

// 128 * N * r bytes; cap at 64 MiB so a hostile or corrupt blob cannot OOM a
// phone. N must be a power of two for scrypt.
const MAX_COST: ScryptCost & { memory: number } = {
  N: 65536,
  r: 8,
  p: 2,
  memory: 64 * 1024 * 1024,
};

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function validateCost(cost: ScryptCost): string[] {
  const errors: string[] = [];
  if (!Number.isInteger(cost.N) || cost.N < 1024 || cost.N > MAX_COST.N) {
    errors.push(`N must be an integer between 1024 and ${MAX_COST.N}`);
  } else if ((cost.N & (cost.N - 1)) !== 0) {
    errors.push("N must be a power of two");
  }
  if (!Number.isInteger(cost.r) || cost.r < 1 || cost.r > MAX_COST.r) {
    errors.push(`r must be an integer between 1 and ${MAX_COST.r}`);
  }
  if (!Number.isInteger(cost.p) || cost.p < 1 || cost.p > MAX_COST.p) {
    errors.push(`p must be an integer between 1 and ${MAX_COST.p}`);
  }
  if (128 * cost.N * cost.r > MAX_COST.memory) {
    errors.push("scrypt memory cost is too high");
  }
  return errors;
}

function assertCost(cost: ScryptCost): void {
  const errors = validateCost(cost);
  if (errors.length > 0) throw new Error("invalid data-keys KDF parameters");
}

export function validateDataKeys(value: unknown): string[] {
  const errors: string[] = [];
  if (!isRecord(value)) return ["data keys must be an object"];
  if (value.version !== 1) errors.push("unsupported data-keys version");

  const r2 = value.r2;
  if (!isRecord(r2)) errors.push("r2 is missing");
  else {
    for (const field of ["endpoint", "bucket", "accessKeyId", "secretAccessKey"] as const) {
      if (!isNonEmptyString(r2[field])) errors.push(`r2.${field} is missing`);
    }
  }

  const restic = value.restic;
  if (!isRecord(restic)) errors.push("restic is missing");
  else {
    for (const field of ["password", "repository", "photosPath", "vaultPath"] as const) {
      if (!isNonEmptyString(restic[field])) errors.push(`restic.${field} is missing`);
    }
  }

  const vault = value.vault;
  if (!isRecord(vault)) errors.push("vault is missing");
  else {
    for (const field of ["password", "path"] as const) {
      if (!isNonEmptyString(vault[field])) errors.push(`vault.${field} is missing`);
    }
  }

  return errors;
}

function aadFor(header: Pick<DataKeysBlob, "version" | "kdf" | "N" | "r" | "p">): Uint8Array {
  return new TextEncoder().encode(
    `family-access:data-keys:v${header.version}|${header.kdf}|${header.N}|${header.r}|${header.p}`,
  );
}

async function deriveKey(
  password: string,
  salt: Uint8Array,
  cost: ScryptCost,
): Promise<CryptoKey> {
  const raw = await scrypt({
    password,
    salt,
    costFactor: cost.N,
    blockSize: cost.r,
    parallelism: cost.p,
    hashLength: 32,
    outputType: "binary",
  });
  return crypto.subtle.importKey("raw", raw as BufferSource, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
}

export async function encryptBlob(
  payload: DataKeys,
  password: string,
  cost: ScryptCost = DEFAULT_COST,
): Promise<DataKeysBlob> {
  const errors = validateDataKeys(payload);
  if (errors.length > 0) throw new Error(`invalid data keys: ${errors.join(", ")}`);
  if (!password) throw new Error("a PWA password is required");
  assertCost(cost);

  const header = { version: 1 as const, kdf: "scrypt" as const, N: cost.N, r: cost.r, p: cost.p };
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveKey(password, salt, cost);
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce as BufferSource, additionalData: aadFor(header) as BufferSource },
      key,
      plaintext as BufferSource,
    ),
  );

  return {
    ...header,
    salt: toBase64(salt),
    nonce: toBase64(nonce),
    ciphertext: toBase64(ciphertext),
  };
}

export async function decryptBlob(
  envelope: DataKeysBlob,
  password: string,
): Promise<DataKeys> {
  if (!isRecord(envelope) || envelope.version !== 1 || envelope.kdf !== "scrypt") {
    throw new Error("unsupported data-keys envelope");
  }
  if (!password) throw new Error("a PWA password is required");
  assertCost({ N: envelope.N, r: envelope.r, p: envelope.p });

  let salt: Uint8Array;
  let nonce: Uint8Array;
  let ciphertext: Uint8Array;
  try {
    salt = fromBase64(envelope.salt);
    nonce = fromBase64(envelope.nonce);
    ciphertext = fromBase64(envelope.ciphertext);
  } catch {
    throw new Error("invalid data-keys envelope");
  }
  if (salt.length !== 16 || nonce.length !== 12 || ciphertext.length <= 16) {
    throw new Error("invalid data-keys envelope");
  }

  const key = await deriveKey(password, salt, {
    N: envelope.N,
    r: envelope.r,
    p: envelope.p,
  });

  let plaintext: Uint8Array;
  try {
    plaintext = new Uint8Array(
      await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: nonce as BufferSource, additionalData: aadFor(envelope) as BufferSource },
        key,
        ciphertext as BufferSource,
      ),
    );
  } catch {
    throw new Error("unable to unlock the data keys");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(plaintext));
  } catch {
    throw new Error("the data-keys payload is not valid JSON");
  }

  const errors = validateDataKeys(parsed);
  if (errors.length > 0) throw new Error(`invalid data keys: ${errors.join(", ")}`);
  return parsed as DataKeys;
}
