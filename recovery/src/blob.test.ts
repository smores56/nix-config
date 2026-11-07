import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import {
  decryptBlob,
  encryptBlob,
  validateCost,
  validateDataKeys,
  type DataKeys,
} from "./blob.ts";

const payload: DataKeys = {
  version: 1,
  r2: {
    endpoint: "https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com",
    bucket: "restic-backup",
    accessKeyId: "test-access-key",
    secretAccessKey: "test-secret-key",
    region: "auto",
  },
  restic: {
    password: "test-restic-password",
    repository:
      "s3:https://385f7d47e2e8438fbda5d6f76d760434.r2.cloudflarestorage.com/restic-backup",
    photosPath: "var/lib/data/photos",
    vaultPath: "var/lib/data/vault",
    dbPath: "var/lib/data/db/immich.dump",
  },
};

const fast = { iterations: 1, memory: 8192, parallelism: 1 };
const password = "correct horse battery staple";

function tamperCiphertext(envelope: { ciphertext: string }): void {
  const raw = Uint8Array.from(atob(envelope.ciphertext), (c) => c.charCodeAt(0));
  raw[0] ^= 1;
  envelope.ciphertext = btoa(String.fromCharCode(...raw));
}

describe("data-keys blob", () => {
  test("round-trips a valid payload", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    const out = await decryptBlob(envelope, password);
    expect(out).toEqual(payload);
    expect(envelope.version).toBe(2);
    expect(envelope.kdf).toBe("argon2id");
  });

  test("rejects the wrong password", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    await expect(decryptBlob(envelope, "wrong password")).rejects.toThrow(
      "unable to unlock the data keys",
    );
  });

  test("rejects a tampered ciphertext", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    tamperCiphertext(envelope);
    await expect(decryptBlob(envelope, password)).rejects.toThrow();
  });

  test("rejects an unknown envelope version", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    await expect(decryptBlob({ ...envelope, version: 99 } as never, password)).rejects.toThrow(
      "unsupported data-keys envelope",
    );
  });

  test("rejects the removed scrypt envelope", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    await expect(
      decryptBlob({ ...envelope, version: 1, kdf: "scrypt" } as never, password),
    ).rejects.toThrow("unsupported data-keys envelope");
  });

  test("validates required data keys", () => {
    expect(validateDataKeys(payload)).toEqual([]);
    expect(validateDataKeys({ ...payload, r2: { ...payload.r2, bucket: "" } })).not.toEqual([]);
    expect(
      validateDataKeys({ ...payload, restic: { ...payload.restic, password: "" } }),
    ).not.toEqual([]);
  });

  test("does not put the password in the envelope", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    const serialized = JSON.stringify(envelope);
    expect(serialized).not.toContain(password);
    expect(serialized).not.toContain(payload.restic.password);
  });
});

describe("blob hardening", () => {
  test("rejects unreasonable KDF parameters before deriving a key", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    await expect(
      decryptBlob({ ...envelope, iterations: 10_000 } as never, password),
    ).rejects.toThrow("invalid data-keys KDF parameters");
    await expect(
      decryptBlob({ ...envelope, memory: 4 * 1024 * 1024 } as never, password),
    ).rejects.toThrow("invalid data-keys KDF parameters");
  });

  test("rejects malformed base64", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    await expect(decryptBlob({ ...envelope, salt: "!!!" } as never, password)).rejects.toThrow(
      "invalid data-keys envelope",
    );
  });

  test("rejects a changed KDF header", async () => {
    const envelope = await encryptBlob(payload, password, fast);
    await expect(decryptBlob({ ...envelope, iterations: 2 } as never, password)).rejects.toThrow();
  });

  // The terminal that captures the password and the browser that types it can
  // disagree on the Unicode form of an accented character: a Mac keyboard gives
  // NFD, a paste from a file often gives NFC. Argon2 hashes bytes, so the same
  // password would derive two different keys.
  test("opens a blob whose password was entered in a different Unicode form", async () => {
    const composed = "café-pässword";
    const decomposed = composed.normalize("NFD");
    expect(decomposed).not.toEqual(composed);

    const envelope = await encryptBlob(payload, decomposed, fast);
    await expect(decryptBlob(envelope, composed)).resolves.toEqual(payload);
  });

  // A newline or an escape sequence pasted into the prompt must not become part
  // of the key: it is invisible on the printed letter and impossible to retype.
  test("rejects a password with a control character", async () => {
    await expect(encryptBlob(payload, "correct horse\n", fast)).rejects.toThrow(
      "password contains a control character",
    );
    const envelope = await encryptBlob(payload, password, fast);
    await expect(decryptBlob(envelope, "correct horse\n")).rejects.toThrow(
      "password contains a control character",
    );
  });

  test("validates cost ranges", async () => {
    expect(validateCost(fast)).toEqual([]);
    expect(validateCost({ iterations: 0, memory: 8192, parallelism: 1 })).not.toEqual([]);
    expect(validateCost({ iterations: 1, memory: 4, parallelism: 1 })).not.toEqual([]);
    expect(validateCost({ iterations: 1, memory: 8, parallelism: 4 })).not.toEqual([]);
    expect(validateCost({ iterations: 1, memory: 8192, parallelism: 0 })).not.toEqual([]);
    await expect(
      encryptBlob(payload, "pw", { iterations: 100, memory: 8192, parallelism: 1 }),
    ).rejects.toThrow("invalid data-keys KDF parameters");
  });
});
