// The recovery sentinel: a plaintext file in the vault that proves the snapshot holds the real
// documents, not just a directory tree. It sits in a folder so the store root stays tidy.

import type { ResticFile, ResticRepository, ResticSnapshot } from "./restic/repository.ts";

export const SENTINEL_DIR = "Documents";
export const SENTINEL_FILE = "sentinel.txt";
/** Path relative to the snapshot root, so it names the store without a mount. */
export const SENTINEL_PATH = `var/lib/data/vault/${SENTINEL_DIR}/${SENTINEL_FILE}`;

export async function readSentinel(
  repository: ResticRepository,
  snapshot: ResticSnapshot,
): Promise<string> {
  const files = await repository.walk(snapshot);
  const file: ResticFile | undefined = files.find((entry) => entry.path === SENTINEL_PATH);
  if (!file) throw new Error(`the snapshot has no ${SENTINEL_PATH}`);

  return new TextDecoder().decode(await repository.readFile(file)).trim();
}
