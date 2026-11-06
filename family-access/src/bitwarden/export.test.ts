import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { argon2id } from "hash-wasm";
import {
  decryptBitwardenExport,
  deriveExportKey,
  hkdfExpand,
  type BitwardenExport,
} from "./export.ts";

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, data as BufferSource));
}

async function encryptString(value: string, encKey: Uint8Array, macKey: Uint8Array) {
  const iv = crypto.getRandomValues(new Uint8Array(16));
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    encKey as BufferSource,
    "AES-CBC",
    false,
    ["encrypt"],
  );
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-CBC", iv: iv as BufferSource },
      cryptoKey,
      new TextEncoder().encode(value),
    ),
  );
  const mac = await hmac(macKey, new Uint8Array([...iv, ...ciphertext]));
  return `2.${toBase64(iv)}|${toBase64(ciphertext)}|${toBase64(mac)}`;
}

type Kdf = {
  kdfType: number;
  kdfIterations: number;
  kdfMemory?: number;
  kdfParallelism?: number;
};

async function makeExport(
  vault: BitwardenExport,
  password: string,
  kdf: Kdf = { kdfType: 0, kdfIterations: 600_000 },
): Promise<string> {
  const salt = toBase64(crypto.getRandomValues(new Uint8Array(16)));
  const saltBytes = new TextEncoder().encode(salt);
  let material: Uint8Array;
  if (kdf.kdfType === 0) {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(password),
      "PBKDF2",
      false,
      ["deriveBits"],
    );
    material = new Uint8Array(
      await crypto.subtle.deriveBits(
        { name: "PBKDF2", hash: "SHA-256", salt: saltBytes as BufferSource, iterations: kdf.kdfIterations },
        key,
        256,
      ),
    );
  } else {
    material = await argon2id({
      password,
      salt: saltBytes,
      iterations: kdf.kdfIterations,
      parallelism: kdf.kdfParallelism ?? 1,
      memorySize: kdf.kdfMemory ?? 8192,
      hashLength: 32,
      outputType: "binary",
    });
  }
  const encKey = await hkdfExpand(material, "enc", 32);
  const macKey = await hkdfExpand(material, "mac", 32);
  return JSON.stringify({
    encrypted: true,
    passwordProtected: true,
    salt,
    kdfType: kdf.kdfType,
    kdfIterations: kdf.kdfIterations,
    ...(kdf.kdfMemory ? { kdfMemory: kdf.kdfMemory, kdfParallelism: kdf.kdfParallelism } : {}),
    encKeyValidation_DO_NOT_EDIT: await encryptString(crypto.randomUUID(), encKey, macKey),
    data: await encryptString(JSON.stringify(vault), encKey, macKey),
  });
}

const vault: BitwardenExport = {
  folders: [{ id: "folder-1", name: "Family Access" }],
  items: [
    {
      id: "11111111-1111-1111-1111-111111111111",
      name: "Email - Tuta",
      type: 1,
      folderId: "folder-1",
      notes: "Recovery codes in the notes",
      fields: [
        { name: "fa_id", value: "email", type: 0 },
        { name: "recovery", value: "AAAA-BBBB", type: 0 },
      ],
      login: {
        username: "owner@tuta.com",
        password: "correct horse",
        totp: "otpauth://totp/x?secret=ABC",
        uris: [{ uri: "https://app.tuta.com" }, { uri: "javascript:alert(1)" }],
      },
    },
    {
      id: "22222222-2222-2222-2222-222222222222",
      name: "Data Recovery",
      type: 2,
      folderId: "folder-1",
      fields: [{ name: "fa_id", value: "data-recovery", type: 0 }],
      secureNote: { type: 0 },
    },
  ],
};

describe("bitwarden export decryptor", () => {
  test("decrypts a PBKDF2 export", async () => {
    const json = await makeExport(vault, "export-password", {
      kdfType: 0,
      kdfIterations: 100_000,
    });
    const decrypted = await decryptBitwardenExport(json, "export-password");
    expect(decrypted.items).toHaveLength(2);
    expect(decrypted.items[0].login?.password).toBe("correct horse");
    expect(decrypted.items[0].fields?.[0]).toEqual({ name: "fa_id", value: "email", type: 0 });
  });

  test("decrypts an Argon2id export", async () => {
    const json = await makeExport(vault, "export-password", {
      kdfType: 1,
      kdfIterations: 3,
      kdfMemory: 8192,
      kdfParallelism: 1,
    });
    const decrypted = await decryptBitwardenExport(json, "export-password");
    expect(decrypted.items[1].name).toBe("Data Recovery");
  });

  test("a wrong password fails at the validation cipher", async () => {
    const json = await makeExport(vault, "export-password", {
      kdfType: 0,
      kdfIterations: 100_000,
    });
    await expect(decryptBitwardenExport(json, "wrong-password")).rejects.toThrow(
      "the export password is wrong",
    );
  });

  test("rejects a tampered MAC", async () => {
    const json = await makeExport(vault, "export-password", {
      kdfType: 0,
      kdfIterations: 100_000,
    });
    const wrapper = JSON.parse(json);
    const [type, rest] = wrapper.data.split(".");
    const [iv, ciphertext, mac] = rest.split("|");
    wrapper.data = `${type}.${iv}|${ciphertext}|${mac[0] === "A" ? "B" : "A"}${mac.slice(1)}`;
    await expect(decryptBitwardenExport(JSON.stringify(wrapper), "export-password")).rejects.toThrow(
      "the export password is wrong",
    );
  });

  test("rejects non-protected JSON", async () => {
    await expect(decryptBitwardenExport('{"items":[]}', "x")).rejects.toThrow(
      "not a password-protected Bitwarden export",
    );
  });

  test("rejects absurd KDF parameters before deriving", async () => {
    const wrapper = JSON.parse(
      await makeExport(vault, "export-password", { kdfType: 0, kdfIterations: 100_000 }),
    );
    wrapper.kdfIterations = 1_000_000_000;
    await expect(decryptBitwardenExport(JSON.stringify(wrapper), "export-password")).rejects.toThrow(
      "out of range",
    );
  });

  test("rejects an unsupported cipher string", async () => {
    const wrapper = JSON.parse(
      await makeExport(vault, "export-password", { kdfType: 0, kdfIterations: 100_000 }),
    );
    wrapper.data = "0.abc|def";
    await expect(decryptBitwardenExport(JSON.stringify(wrapper), "export-password")).rejects.toThrow(
      "unsupported cipher string",
    );
  });

  test("decrypts the committed synthetic export", async () => {
    const json = await Deno.readTextFile(
      new URL("../../test-fixtures/bitwarden/synthetic-export.json", import.meta.url),
    );
    const vault = await decryptBitwardenExport(json, "synthetic-export-fixture-4f9c1a");
    expect(vault.items.find((item) => item.name === "Email - Tuta")?.login?.password).toBe(
      "okMfeBD8ush7HHMLbszsV5Bw",
    );
    expect(vault.items.find((item) => item.name === "Immich")?.login?.username).toBe("family");
  });

  test("caps Argon2 time and memory separately", async () => {
    const wrapper = JSON.parse(
      await makeExport(vault, "export-password", { kdfType: 0, kdfIterations: 100_000 }),
    );
    wrapper.kdfType = 1;
    wrapper.kdfIterations = 100;
    wrapper.kdfMemory = 8192;
    wrapper.kdfParallelism = 1;
    await expect(decryptBitwardenExport(JSON.stringify(wrapper), "export-password")).rejects.toThrow(
      "Argon2 iterations",
    );
    wrapper.kdfIterations = 3;
    wrapper.kdfMemory = 8;
    wrapper.kdfParallelism = 4;
    await expect(decryptBitwardenExport(JSON.stringify(wrapper), "export-password")).rejects.toThrow(
      "Argon2 parameters",
    );
  });

  test("derives separate enc and mac keys", async () => {
    const key = await deriveExportKey("pw", "salt", 0, 100_000);
    expect(key.encKey).toHaveLength(32);
    expect(key.macKey).toHaveLength(32);
    expect(toBase64(key.encKey)).not.toBe(toBase64(key.macKey));
  });
});
