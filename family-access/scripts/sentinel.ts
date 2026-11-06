// Opens a Cryptomator vault with the same reader the PWA uses and prints its
// sentinel file. Use it to verify the real vault without deploying anything.
//
// Passwords come from files when possible: environment variables are visible to
// any same-UID process. The env fallbacks exist for one-off runs.
//
//   deno task sentinel --local /var/lib/data/vault \
//     --vault-password-file /run/secrets/vault-password
//   deno task sentinel --repo /var/backup/restic --prefix var/lib/data/vault \
//     --restic-password-file ~/.restic-pass --vault-password-file ~/.vault-pass
//   R2_REPOSITORY=s3:https://<account>.r2.cloudflarestorage.com/restic-backup \
//   R2_ENDPOINT=... R2_BUCKET=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
//     deno task sentinel --r2 --prefix var/lib/data/vault \
//     --restic-password-file ~/.restic-pass --vault-password-file ~/.vault-pass

import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { LocalBackend } from "../src/restic/backend.ts";
import { openRepository, type ResticRepository, type ResticSnapshot } from "../src/restic/repository.ts";
import { R2Backend, repositoryPrefix } from "../src/restic/r2.ts";
import { LocalVaultProvider } from "../src/cryptomator/local-provider.ts";
import { ResticVaultProvider } from "../src/cryptomator/restic-provider.ts";
import { CryptomatorVault, ROOT_DIR_ID, type VaultProvider } from "../src/cryptomator/vault.ts";

type Args = {
  local?: string;
  repo?: string;
  r2: boolean;
  prefix?: string;
  snapshot: string;
  vaultPasswordFile?: string;
  resticPasswordFile?: string;
};

const USAGE =
  "usage: sentinel (--local <vault dir> | --repo <restic dir> | --r2) [--prefix <path>] " +
  "[--snapshot <id>] [--vault-password-file <path>] [--restic-password-file <path>]";

function takeValue(argv: string[], index: number, flag: string): string {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("-")) {
    throw new Error(`${flag} needs a value`);
  }
  return value;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { r2: false, snapshot: "latest" };
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    switch (value) {
      case "--local":
        args.local = takeValue(argv, index++, value);
        break;
      case "--repo":
        args.repo = takeValue(argv, index++, value);
        break;
      case "--r2":
        args.r2 = true;
        break;
      case "--prefix":
        args.prefix = takeValue(argv, index++, value);
        break;
      case "--snapshot":
        args.snapshot = takeValue(argv, index++, value);
        break;
      case "--vault-password-file":
        args.vaultPasswordFile = takeValue(argv, index++, value);
        break;
      case "--restic-password-file":
        args.resticPasswordFile = takeValue(argv, index++, value);
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

function expandHome(path: string): string {
  return path.startsWith("~/") ? `${homedir()}/${path.slice(2)}` : path;
}

async function readPasswordFile(path: string, label: string): Promise<string> {
  const value = await fs.readFile(expandHome(path), "utf8");
  const trimmed = value.replace(/\r?\n$/, "");
  if (!trimmed) throw new Error(`${label} file is empty: ${path}`);
  return trimmed;
}

async function password(
  file: string | undefined,
  envName: string,
  label: string,
): Promise<string> {
  if (file) return readPasswordFile(file, label);
  const value = Deno.env.get(envName);
  if (!value) throw new Error(`${label} not provided (use --${label}-file or ${envName})`);
  return value;
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function pickSnapshot(repository: ResticRepository, id: string): ResticSnapshot {
  if (id === "latest") {
    const latest = repository.snapshots[0];
    if (!latest) throw new Error("the restic repository has no snapshots");
    return latest;
  }
  const match = repository.snapshots.find((snapshot) => snapshot.id.startsWith(id));
  if (!match) throw new Error(`snapshot not found: ${id}`);
  return match;
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);
  const vaultPassword = await password(args.vaultPasswordFile, "VAULT_PASSWORD", "vault-password");

  let provider: VaultProvider;
  if (args.local) {
    provider = new LocalVaultProvider(args.local);
  } else if (args.repo) {
    const resticPassword = await password(
      args.resticPasswordFile,
      "RESTIC_PASSWORD",
      "restic-password",
    );
    const repository = await openRepository(new LocalBackend(args.repo), resticPassword);
    provider = new ResticVaultProvider(
      repository,
      pickSnapshot(repository, args.snapshot),
      args.prefix ?? "",
    );
  } else if (args.r2) {
    const resticPassword = await password(
      args.resticPasswordFile,
      "RESTIC_PASSWORD",
      "restic-password",
    );
    const endpoint = requireEnv("R2_ENDPOINT");
    const bucket = requireEnv("R2_BUCKET");
    const prefix = repositoryPrefix(requireEnv("R2_REPOSITORY"), bucket);
    const backend = new R2Backend({
      endpoint,
      bucket,
      accessKeyId: requireEnv("R2_ACCESS_KEY_ID"),
      secretAccessKey: requireEnv("R2_SECRET_ACCESS_KEY"),
      region: Deno.env.get("R2_REGION") ?? "auto",
      prefix,
    });
    const repository = await openRepository(backend, resticPassword);
    provider = new ResticVaultProvider(
      repository,
      pickSnapshot(repository, args.snapshot),
      args.prefix ?? "",
    );
  } else {
    throw new Error("choose --local, --repo or --r2");
  }

  const vault = await CryptomatorVault.open(provider, vaultPassword);
  const root = await vault.list(ROOT_DIR_ID);
  console.log(`vault format ${vault.settings.format} (${vault.settings.cipherCombo})`);
  console.log(`${root.length} entries in the root directory`);
  for (const item of root.slice(0, 20)) {
    console.log(`  ${item.kind}: ${item.name}${item.damaged ? ` (damaged: ${item.damaged})` : ""}`);
  }
  const sentinel = root.find(
    (item) => item.kind === "file" && item.name === "family-access-sentinel.txt",
  );
  if (!sentinel) throw new Error("the vault has no sentinel file");
  const text = await vault.readTextFile(sentinel);
  console.log(`sentinel: ${JSON.stringify(text.trim())}`);
}

main().catch((error: unknown) => {
  console.error(`sentinel failed: ${error instanceof Error ? error.message : String(error)}`);
  Deno.exit(1);
});
