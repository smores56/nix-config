// Builds the encrypted data-keys blob that ships with the PWA.
//
// Reads the R2 read-only token and restic password from sops, prompts for the
// recovery password (twice) and the Cryptomator password, encrypts the payload with
// Argon2id + AES-256-GCM, writes public/data-keys.enc, then decrypts it again
// and walks the real data path (R2 -> restic -> Cryptomator sentinel).
//
//   deno task blob [--out public/data-keys.enc] [--secrets ../secrets/smortress.yaml]
//                  [--account-id <id>] [--no-check] [--check-only]
//
// `--check-only` re-runs the data-path check against an existing blob: it needs
// the recovery password but not the Cryptomator password, which the blob already
// carries.
//
// Passwords are only read from the terminal: there is no password-file option.

import { type DataKeys, type DataKeysBlob, decryptBlob, encryptBlob } from "../src/blob.ts";
import { R2Backend, repositoryPrefix } from "../src/restic/r2.ts";
import { openRepository } from "../src/restic/repository.ts";
import { ResticVaultProvider } from "../src/cryptomator/restic-provider.ts";
import { CryptomatorVault } from "../src/cryptomator/vault.ts";
import { promptHidden, promptNewPassword } from "./prompt.ts";
import { readSentinel, SENTINEL_PATH } from "../src/sentinel.ts";

const DEFAULT_ACCOUNT_ID = "385f7d47e2e8438fbda5d6f76d760434";
const BUCKET = "restic-backup";

type Args = {
  out: string;
  secrets: string;
  accountId: string;
  check: boolean;
  checkOnly: boolean;
};

const USAGE = "usage: blob [--out public/data-keys.enc] [--secrets ../secrets/smortress.yaml] " +
  "[--account-id <id>] [--no-check] [--check-only]";

function takeValue(argv: string[], index: number, flag: string): string {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("-")) throw new Error(`${flag} needs a value`);
  return value;
}

function parseArgs(argv: string[]): Args {
  const args: Args = {
    out: "public/data-keys.enc",
    secrets: "../secrets/smortress.yaml",
    accountId: DEFAULT_ACCOUNT_ID,
    check: true,
    checkOnly: false,
  };
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    switch (value) {
      case "--out":
        args.out = takeValue(argv, index++, value);
        break;
      case "--secrets":
        args.secrets = takeValue(argv, index++, value);
        break;
      case "--account-id":
        args.accountId = takeValue(argv, index++, value);
        break;
      case "--no-check":
        args.check = false;
        break;
      case "--check-only":
        args.checkOnly = true;
        break;
      case "--help":
      case "-h":
        console.log(USAGE);
        Deno.exit(0);
        break;
      default:
        throw new Error(`unknown argument: ${value}`);
    }
  }
  return args;
}

async function readSecrets(path: string): Promise<Record<string, string>> {
  const output = await new Deno.Command("sops", {
    args: ["-d", path],
    stdout: "piped",
    stderr: "inherit",
    stdin: "inherit",
  }).output();
  if (!output.success) throw new Error(`sops failed to decrypt ${path}`);

  const secrets: Record<string, string> = {};
  for (const line of new TextDecoder().decode(output.stdout).split("\n")) {
    const match = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/.exec(line);
    if (!match) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (value) secrets[match[1]] = value;
  }
  return secrets;
}

function requireSecret(secrets: Record<string, string>, name: string): string {
  const value = secrets[name];
  if (!value) throw new Error(`sops is missing ${name}`);
  return value;
}

async function selfTest(keys: DataKeys): Promise<void> {
  const prefix = repositoryPrefix(keys.restic.repository, keys.r2.bucket);
  const backend = new R2Backend({ ...keys.r2, prefix });
  const repository = await openRepository(backend, keys.restic.password);
  if (repository.snapshots.length === 0) throw new Error("the restic repository has no snapshots");
  const snapshot = repository.snapshots[0];
  console.log(`restic: ${repository.snapshots.length} snapshot(s), latest ${snapshot.time}`);

  const provider = new ResticVaultProvider(repository, snapshot, keys.restic.vaultPath);
  const vault = await CryptomatorVault.open(provider, keys.vault.password);
  let text: string;
  try {
    text = await readSentinel(vault);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    throw new Error(
      `snapshot ${snapshot.id} (${snapshot.time}): ${reason}; if you just created it, ` +
        "run a backup first",
    );
  }
  console.log(`vault: ${SENTINEL_PATH} in snapshot ${snapshot.id}, ${JSON.stringify(text)}`);
}

async function checkExisting(args: Args): Promise<void> {
  let text: string;
  try {
    text = await Deno.readTextFile(args.out);
  } catch {
    throw new Error(`${args.out} is missing; build it first`);
  }
  const envelope = JSON.parse(text) as DataKeysBlob;
  console.log("The recovery password is written on the media; it is not stored anywhere.");
  const keys = await decryptBlob(envelope, await promptHidden("recovery password: "));
  console.log(`${args.out}: decrypts with the recovery password; checking the data path`);
  await selfTest(keys);
  console.log("done");
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);
  if (args.checkOnly) {
    await checkExisting(args);
    return;
  }
  console.log("The recovery password is written on the media; it is not stored anywhere.");
  const recoveryPassword = await promptNewPassword("recovery password: ");
  console.log("The Cryptomator password is used to open the vault during the self-test.");
  const vaultPassword = await promptNewPassword("Cryptomator password: ");

  const secrets = await readSecrets(args.secrets);
  const endpoint = `https://${args.accountId}.r2.cloudflarestorage.com`;
  const repository = `s3:${endpoint}/${BUCKET}`;
  const keys: DataKeys = {
    version: 1,
    r2: {
      endpoint,
      bucket: BUCKET,
      accessKeyId: requireSecret(secrets, "r2-access-key-id-readonly"),
      secretAccessKey: requireSecret(secrets, "r2-secret-access-key-readonly"),
      region: "auto",
    },
    restic: {
      password: requireSecret(secrets, "restic-password"),
      repository,
      photosPath: "var/lib/data/photos",
      vaultPath: "var/lib/data/vault",
      dbPath: "var/lib/data/db/immich.dump",
    },
    vault: {
      password: vaultPassword,
      path: "var/lib/data/vault",
    },
  };

  console.log("Deriving the key with Argon2id...");
  const envelope = await encryptBlob(keys, recoveryPassword);
  await Deno.writeTextFile(args.out, JSON.stringify(envelope, null, 2) + "\n");
  console.log(`wrote ${args.out}`);

  const check = await decryptBlob(envelope, recoveryPassword);
  if (JSON.stringify(check) !== JSON.stringify(keys)) {
    throw new Error("the self-test decrypted different data");
  }
  console.log("self-test: the blob decrypts with the recovery password");

  if (args.check) await selfTest(keys);
  console.log("done");
}

main().catch((error: unknown) => {
  console.error(`blob failed: ${error instanceof Error ? error.message : String(error)}`);
  Deno.exit(1);
});
