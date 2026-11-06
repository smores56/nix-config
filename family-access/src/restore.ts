// Turns a snapshot's file paths into a folder tree under the directory the
// family picks. Snapshot entries are relative to the restic tree root
// (`var/lib/data/photos/...`), so the shared root is stripped and the chosen
// folder starts at `photos/`.

import { sanitizeFileName } from "./filenames.ts";

/** Longest directory prefix shared by every path; "" when they share none. */
export function commonDirectoryPrefix(paths: string[]): string {
  const directories = paths.map((path) => path.split("/").filter(Boolean).slice(0, -1));
  const first = directories[0];
  if (!first) return "";
  let common = first;
  for (const directory of directories.slice(1)) {
    let index = 0;
    while (
      index < common.length &&
      index < directory.length &&
      common[index] === directory[index]
    ) {
      index++;
    }
    common = common.slice(0, index);
  }
  return common.join("/");
}

/** Path segments below `prefix`, one per restore directory level. */
export function relativeSegments(prefix: string, path: string): string[] {
  const segments = path.split("/").filter(Boolean);
  const root = prefix ? prefix.split("/").filter(Boolean) : [];
  for (let index = 0; index < root.length; index++) {
    if (segments[index] !== root[index]) throw new Error(`not under the restore root: ${path}`);
  }

  const rest = segments.slice(root.length);
  if (rest.length === 0) throw new Error(`empty restore path: ${path}`);

  return rest.map((segment) => {
    if (segment === "." || segment === "..") throw new Error(`unsafe restore segment: ${path}`);
    return sanitizeFileName(segment);
  });
}
