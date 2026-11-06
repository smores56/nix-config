import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import {
  decryptBlob,
  encryptBlob,
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
    photosPath: "/var/lib/data/photos",
    vaultPath: "/var/lib/data/vault",
    dbPath: "/var/lib/data/db/immich.dump",
  },
  vault: {
    password: "test-vault-password",
    path: "/var/lib/data/vault",
  },
};

const fast = { N: 1024, r: 8, p: 1 };

function tamperCiphertext(envelope: { ciphertext: string }): void {
  const raw = Uint8Array.from(atob(envelope.ciphertext), (c) => c.charCodeAt(0));
  raw[0] ^= 1;
  envelope.ciphertext = btoa(String.fromCharCode(...raw));
}

describe("data-keys blob", () => {
  test("round-trips a valid payload", async () => {
    const envelope = await encryptBlob(payload, "correct horse battery staple", fast);
    const out = await decryptBlob(envelope, "correct horse battery staple");
    expect(out).toEqual(payload);
    expect(envelope.version).toBe(1);
    expect(envelope.kdf).toBe("scrypt");
  });

  test("rejects the wrong password", async () => {
    const envelope = await encryptBlob(payload, "correct horse battery staple", fast);
    await expect(decryptBlob(envelope, "wrong password")).rejects.toThrow();
  });

  test("rejects a tampered ciphertext", async () => {
    const envelope = await encryptBlob(payload, "correct horse battery staple", fast);
    tamperCiphertext(envelope);
    await expect(decryptBlob(envelope, "correct horse battery staple")).rejects.toThrow();
  });

  test("rejects an unknown envelope version", async () => {
    const envelope = await encryptBlob(payload, "correct horse battery staple", fast);
    await expect(
      decryptBlob({ ...envelope, version: 99 } as never, "correct horse battery staple"),
    ).rejects.toThrow();
  });

  test("validates required data keys", () => {
    expect(validateDataKeys(payload)).toEqual([]);
    expect(validateDataKeys({ ...payload, r2: { ...payload.r2, bucket: "" } })).not.toEqual([]);
    expect(validateDataKeys({ ...payload, restic: { ...payload.restic, password: "" } })).not.toEqual([]);
    expect(validateDataKeys({ ...payload, vault: { ...payload.vault, password: "" } })).not.toEqual([]);
  });

  test("does not put the password in the envelope", async () => {
    const envelope = await encryptBlob(payload, "correct horse battery staple", fast);
    const serialized = JSON.stringify(envelope);
    expect(serialized).not.toContain("correct horse battery staple");
    expect(serialized).not.toContain(payload.restic.password);
    expect(serialized).not.toContain(payload.vault.password);
  });
});

describe("blob hardening", () => {
  test("rejects unreasonable KDF parameters before deriving a key", async () => {
    const envelope = await encryptBlob(payload, "correct horse battery staple", fast);
    await expect(decryptBlob({ ...envelope, N: 1 << 30 } as never, "pw")).rejects.toThrow(
      "invalid data-keys KDF parameters",
    );
  });

  test("rejects malformed base64", async () => {
    const envelope = await encryptBlob(payload, "correct horse battery staple", fast);
    await expect(decryptBlob({ ...envelope, salt: "!!!" } as never, "pw")).rejects.toThrow(
      "invalid data-keys envelope",
    );
  });
});

describe("blob cost hardening", () => {
  test("rejects a non-power-of-two KDF cost", async () => {
    await expect(
      encryptBlob(payload, "pw", { N: 12345, r: 8, p: 1 }),
    ).rejects.toThrow("invalid data-keys KDF parameters");
  });

  test("rejects an oversized KDF cost", async () => {
    await expect(
      encryptBlob(payload, "pw", { N: 131072, r: 8, p: 1 }),
    ).rejects.toThrow("invalid data-keys KDF parameters");
  });

  test("rejects a changed KDF header", async () => {
    const envelope = await encryptBlob(payload, "pw", fast);
    await expect(decryptBlob({ ...envelope, r: 4 } as never, "pw")).rejects.toThrow();
  });
});
