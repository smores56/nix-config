// Validates public/manifest.json against a Bitwarden export (protected or
// plaintext) and, optionally, checks that the restic repository is reachable.
//
//   bun run validate --export ~/bitwarden_export.json \
//     --export-password-file ~/.config/family-access/export-password
//   bun run validate --export ~/export.json --restic-dir /var/backup/restic \
//     --restic-password-file ~/.config/family-access/restic-password

import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { decryptBitwardenExport, type BitwardenExport } from "../src/bitwarden/export";
import { matchVault, plaintextExport } from "../src/bitwarden/dashboard";
import { validateManifest, type FamilyAccessManifest } from "../src/manifest";
import { LocalBackend } from "../src/restic/backend";
import { openRepository } from "../src/restic/repository";

type Args = {
  manifest: string;
  export?: string;
  exportPasswordFile?: string;
  resticDir?: string;
  resticPasswordFile?: string;
};

const USAGE =
  "usage: validate [--manifest <path>] [--export <path> [--export-password-file <path>]] " +
  "[--restic-dir <path> --restic-password-file <path>]";

function takeValue(argv: string[], index: number, flag: string): string {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("-")) throw new Error(`${flag} needs a value`);
  return value;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { manifest: "public/manifest.json" };
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    switch (value) {
      case "--manifest":
        args.manifest = takeValue(argv, index++, value);
        break;
      case "--export":
        args.export = takeValue(argv, index++, value);
        break;
      case "--export-password-file":
        args.exportPasswordFile = takeValue(argv, index++, value);
        break;
      case "--restic-dir":
        args.resticDir = takeValue(argv, index++, value);
        break;
      case "--restic-password-file":
        args.resticPasswordFile = takeValue(argv, index++, value);
        break;
      case "--help":
      case "-h":
        console.log(USAGE);
        process.exit(0);
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

async function readPassword(path: string | undefined, env: string, label: string) {
  if (!path) {
    const value = process.env[env];
    if (!value) throw new Error(`${label} not provided`);
    return value;
  }
  const value = await fs.readFile(expandHome(path), "utf8");
  const trimmed = value.replace(/\r?\n$/, "");
  if (!trimmed) throw new Error(`${label} file is empty: ${path}`);
  return trimmed;
}

async function loadExport(args: Args): Promise<BitwardenExport> {
  if (!args.export) throw new Error("--export is required");
  const json = await fs.readFile(expandHome(args.export), "utf8");
  const plain = plaintextExport(json);
  if (plain) {
    console.warn("warning: the export is not password protected");
    return plain;
  }
  const password = await readPassword(
    args.exportPasswordFile,
    "BITWARDEN_EXPORT_PASSWORD",
    "export password",
  );
  return decryptBitwardenExport(json, password);
}

async function checkRestic(args: Args): Promise<string[]> {
  const problems: string[] = [];
  if (!args.resticDir) return problems;
  try {
    const password = await readPassword(
      args.resticPasswordFile,
      "RESTIC_PASSWORD",
      "restic password",
    );
    const repository = await openRepository(new LocalBackend(args.resticDir), password);
    if (repository.snapshots.length === 0) problems.push("the restic repository has no snapshots");
    else {
      const latest = repository.snapshots[0];
      console.log(`restic: ${repository.snapshots.length} snapshot(s), latest ${latest.time}`);
    }
  } catch (error) {
    problems.push(`restic repository is not reachable: ${errorMessage(error)}`);
  }
  return problems;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const manifest = JSON.parse(
    await fs.readFile(expandHome(args.manifest), "utf8"),
  ) as FamilyAccessManifest;

  const manifestErrors = validateManifest(manifest);
  const vault = await loadExport(args);
  const result = matchVault(manifest, vault);
  const resticProblems = await checkRestic(args);

  for (const error of manifestErrors) console.error(`manifest: ${error}`);
  for (const warning of result.warnings) console.warn(`warning: ${warning}`);
  for (const error of result.errors) console.error(`error: ${error}`);
  for (const problem of resticProblems) console.error(`error: ${problem}`);

  console.log(
    `${result.matches.size} of ${manifest.sections.reduce((sum, section) => sum + section.items.length, 0)} manifest items matched`,
  );
  const failed = manifestErrors.length + result.errors.length + resticProblems.length;
  if (failed > 0) process.exit(1);
}

main().catch((error: unknown) => {
  console.error(`validate failed: ${errorMessage(error)}`);
  process.exit(1);
});
