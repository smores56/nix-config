// The recovery sentinel: a plaintext file in the vault that proves the snapshot holds the real
// documents, not just a directory tree. It sits in a folder so the store root stays tidy.

import type { ResticDirEntry, ResticFile, ResticRepository, ResticSnapshot } from "./restic/repository.ts";

export const SENTINEL_DIR = "var/lib/data/vault/Documents";
export const SENTINEL_FILE = "sentinel.txt";
/** Path relative to the snapshot root, so it names the store without a mount. */
export const SENTINEL_PATH = `${SENTINEL_DIR}/${SENTINEL_FILE}`;

export async function readSentinel(
  repository: ResticRepository,
  snapshot: ResticSnapshot,
): Promise<string> {
  // Descend to the folder instead of walking the snapshot: a full walk lists every directory
  // in the tree over R2, which on a library this size takes minutes for one small file.
  const entries = await repository.listDirectory(snapshot, SENTINEL_DIR);
  const entry: ResticDirEntry | undefined = entries.find(
    (candidate) => candidate.type === "file" && candidate.name === SENTINEL_FILE,
  );
  if (!entry) throw new Error(`the snapshot has no ${SENTINEL_PATH}`);

  const file: ResticFile = {
    path: entry.path,
    blobs: entry.blobs ?? [],
    ...(entry.size === undefined ? {} : { size: entry.size }),
  };
  return new TextDecoder().decode(await repository.readFile(file)).trim();
}
