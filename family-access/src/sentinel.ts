// The recovery sentinel the family PWA looks for: a plaintext file inside the
// vault that proves the reader, the restic snapshot and the Cryptomator key all
// work. It lives in a folder so the vault root stays the Cryptomator layout.

import { type CryptomatorVault, ROOT_DIR_ID } from "./cryptomator/vault.ts";

export const SENTINEL_DIR = "Documents";
export const SENTINEL_FILE = "sentinel.txt";
export const SENTINEL_PATH = `${SENTINEL_DIR}/${SENTINEL_FILE}`;

type VaultReader = Pick<CryptomatorVault, "list" | "readTextFile">;

export async function readSentinel(vault: VaultReader): Promise<string> {
  const root = await vault.list(ROOT_DIR_ID);
  const folder = root.find((item) => item.kind === "dir" && item.name === SENTINEL_DIR);
  if (!folder?.dirId) throw new Error(`the vault has no ${SENTINEL_DIR}/ folder at its root`);

  const entries = await vault.list(folder.dirId);
  const file = entries.find((item) => item.kind === "file" && item.name === SENTINEL_FILE);
  if (!file) throw new Error(`the vault has no ${SENTINEL_PATH}`);

  return (await vault.readTextFile(file)).trim();
}
