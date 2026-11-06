// Generates the synthetic password-protected Bitwarden export used by the
// dashboard tests and as a demo file. All credentials are fake.
//
//   deno run --allow-write --allow-read make-fixture.ts <export-password>
//
// The format matches Bitwarden's "password protected" JSON export: PBKDF2 over
// the salt string, HKDF-Expand into enc/mac keys, AES-256-CBC + HMAC.

const encoder = new TextEncoder();

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function randomString(length: number, alphabet: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

const ALNUM = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

function password(): string {
  return randomString(24, ALNUM);
}

function totpSecret(): string {
  return randomString(32, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567");
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

async function hkdfExpand(prk: Uint8Array, info: string, length: number): Promise<Uint8Array> {
  const infoBytes = encoder.encode(info);
  const blocks = Math.ceil(length / 32);
  const okm = new Uint8Array(blocks * 32);
  let previous = new Uint8Array(0);
  for (let index = 0; index < blocks; index++) {
    previous = await hmac(prk, new Uint8Array([...previous, ...infoBytes, index + 1]));
    okm.set(previous, index * 32);
  }
  return okm.subarray(0, length);
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
      encoder.encode(value),
    ),
  );
  const mac = await hmac(macKey, new Uint8Array([...iv, ...ciphertext]));
  return `2.${base64(iv)}|${base64(ciphertext)}|${base64(mac)}`;
}

const exportPassword = Deno.args[0];
if (!exportPassword) throw new Error("pass the export password as the first argument");

type FakeItem = {
  id: string;
  name: string;
  type: number;
  folderId: string;
  notes?: string;
  fields: Array<{ name: string; value: string; type: number }>;
  login?: {
    username: string;
    password: string;
    totp?: string;
    uris: Array<{ uri: string }>;
  };
};

const items: FakeItem[] = [
  {
    id: "8a1f6d1e-0000-4000-8000-000000000001",
    name: "START HERE",
    type: 2,
    folderId: "fold-0000-4000-8000-000000000001",
    notes:
      "This is a synthetic Bitwarden export for testing Family Access. " +
      "Every password in this file is fake.",
    fields: [{ name: "fa_id", value: "start", type: 0 }],
  },
  {
    id: "8a1f6d1e-0000-4000-8000-000000000002",
    name: "Email - Tuta",
    type: 1,
    folderId: "fold-0000-4000-8000-000000000001",
    notes: "Recovery code: SYNTHETIC-ONLY",
    fields: [{ name: "fa_id", value: "email", type: 0 }],
    login: {
      username: "family-test@tuta.com",
      password: password(),
      totp: `otpauth://totp/Family%20Access?secret=${totpSecret()}`,
      uris: [{ uri: "https://app.tuta.com" }],
    },
  },
  {
    id: "8a1f6d1e-0000-4000-8000-000000000003",
    name: "Immich",
    type: 1,
    folderId: "fold-0000-4000-8000-000000000001",
    fields: [{ name: "fa_id", value: "immich", type: 0 }],
    login: {
      username: "family",
      password: password(),
      uris: [{ uri: "https://immich.sammohr.dev" }],
    },
  },
  {
    id: "8a1f6d1e-0000-4000-8000-000000000004",
    name: "Data Recovery",
    type: 2,
    folderId: "fold-0000-4000-8000-000000000001",
    notes:
      "R2 read-only token: SYNTHETIC\nrestic password: SYNTHETIC\nvault password: SYNTHETIC",
    fields: [{ name: "fa_id", value: "data-recovery", type: 0 }],
  },
];

const vault = {
  folders: [{ id: "fold-0000-4000-8000-000000000001", name: "Family Access" }],
  items,
};

const salt = base64(crypto.getRandomValues(new Uint8Array(16)));
const iterations = 600_000;
const pbkdf2Key = await crypto.subtle.importKey(
  "raw",
  encoder.encode(exportPassword),
  "PBKDF2",
  false,
  ["deriveBits"],
);
const material = new Uint8Array(
  await crypto.subtle.deriveBits(
    {
      name: "PBKDF2",
      hash: "SHA-256",
      salt: encoder.encode(salt) as BufferSource,
      iterations,
    },
    pbkdf2Key,
    256,
  ),
);
const encKey = await hkdfExpand(material, "enc", 32);
const macKey = await hkdfExpand(material, "mac", 32);

const file = {
  encrypted: true,
  passwordProtected: true,
  salt,
  kdfType: 0,
  kdfIterations: iterations,
  encKeyValidation_DO_NOT_EDIT: await encryptString(crypto.randomUUID(), encKey, macKey),
  data: await encryptString(JSON.stringify(vault), encKey, macKey),
};

await Deno.writeTextFile(
  new URL("synthetic-export.json", import.meta.url),
  JSON.stringify(file, null, 2) + "\n",
);

console.log(`export password: ${exportPassword}`);
for (const item of items) {
  if (item.login) console.log(`${item.name}: ${item.login.username} / ${item.login.password}`);
}
