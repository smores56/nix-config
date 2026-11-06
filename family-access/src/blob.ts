import { argon2id } from "hash-wasm";

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
  version: 2;
  kdf: "argon2id";
  iterations: number;
  memory: number;
  parallelism: number;
  salt: string;
  nonce: string;
  ciphertext: string;
};

export type Argon2Cost = {
  iterations: number;
  memory: number;
  parallelism: number;
};

export const DEFAULT_COST: Argon2Cost = {
  iterations: 3,
  memory: 64 * 1024,
  parallelism: 4,
};

// Caps keep a hostile or corrupt blob from freezing a phone. Argon2 memory is
// in KiB; the minimum is 8 KiB per lane (RFC 9106 section 3.1).
const MAX_COST: Argon2Cost = {
  iterations: 10,
  memory: 256 * 1024,
  parallelism: 16,
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

export function validateCost(cost: Argon2Cost): string[] {
  const errors: string[] = [];
  if (
    !Number.isInteger(cost.iterations) ||
    cost.iterations < 1 ||
    cost.iterations > MAX_COST.iterations
  ) {
    errors.push(`iterations must be an integer between 1 and ${MAX_COST.iterations}`);
  }
  if (
    !Number.isInteger(cost.parallelism) ||
    cost.parallelism < 1 ||
    cost.parallelism > MAX_COST.parallelism
  ) {
    errors.push(`parallelism must be an integer between 1 and ${MAX_COST.parallelism}`);
  }
  if (!Number.isInteger(cost.memory) || cost.memory < 8 || cost.memory > MAX_COST.memory) {
    errors.push(`memory must be an integer between 8 and ${MAX_COST.memory} KiB`);
  } else if (
    Number.isInteger(cost.parallelism) &&
    cost.parallelism >= 1 &&
    cost.memory < 8 * cost.parallelism
  ) {
    errors.push("memory must be at least 8 KiB per lane");
  }
  return errors;
}

function assertCost(cost: Argon2Cost): void {
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

function aadFor(
  header: Pick<DataKeysBlob, "version" | "kdf" | "iterations" | "memory" | "parallelism">,
): Uint8Array {
  return new TextEncoder().encode(
    `family-access:data-keys:v${header.version}|${header.kdf}|${header.iterations}|${header.memory}|${header.parallelism}`,
  );
}

async function deriveKey(
  password: string,
  salt: Uint8Array,
  cost: Argon2Cost,
): Promise<CryptoKey> {
  const raw = await argon2id({
    password,
    salt,
    iterations: cost.iterations,
    memorySize: cost.memory,
    parallelism: cost.parallelism,
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
  cost: Argon2Cost = DEFAULT_COST,
): Promise<DataKeysBlob> {
  const errors = validateDataKeys(payload);
  if (errors.length > 0) throw new Error(`invalid data keys: ${errors.join(", ")}`);
  if (!password) throw new Error("a PWA password is required");
  assertCost(cost);

  const header = {
    version: 2 as const,
    kdf: "argon2id" as const,
    iterations: cost.iterations,
    memory: cost.memory,
    parallelism: cost.parallelism,
  };
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
  if (!isRecord(envelope) || envelope.version !== 2 || envelope.kdf !== "argon2id") {
    throw new Error("unsupported data-keys envelope");
  }
  if (!password) throw new Error("a PWA password is required");
  assertCost({
    iterations: envelope.iterations,
    memory: envelope.memory,
    parallelism: envelope.parallelism,
  });

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
    iterations: envelope.iterations,
    memory: envelope.memory,
    parallelism: envelope.parallelism,
  });

  let plaintext: Uint8Array;
  try {
    plaintext = new Uint8Array(
      await crypto.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: nonce as BufferSource,
          additionalData: aadFor(envelope) as BufferSource,
        },
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
