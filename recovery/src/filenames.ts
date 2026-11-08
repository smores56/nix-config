export function sanitizeFileName(name: string): string {
  const cleaned = name
    .replace(/[\\/:*?"<>|\x00-\x1f]/g, "_")
    .trim()
    .replace(/[. ]+$/g, "")
    .slice(0, 200);
  if (!cleaned) return "download";
  return /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i.test(cleaned) ? `_${cleaned}` : cleaned;
}

/**
 * Claim a name for a directory inside one restore or zip run. Two different
 * restic names can sanitize to the same file name (or the same 200-byte
 * prefix); numbering the later ones prevents a silent overwrite that the
 * size-only skip check would otherwise report as already there.
 */
export function uniqueFileName(taken: Set<string>, name: string): string {
  const base = sanitizeFileName(name);
  if (!taken.has(base)) {
    taken.add(base);
    return base;
  }
  const dot = base.lastIndexOf(".");
  const stem = dot > 0 ? base.slice(0, dot) : base;
  const extension = dot > 0 ? base.slice(dot) : "";
  for (let index = 2;; index++) {
    const suffix = ` (${index})`;
    const room = Math.max(1, 200 - suffix.length - extension.length);
    const candidate = `${stem.slice(0, room)}${suffix}${extension}`;
    if (!taken.has(candidate)) {
      taken.add(candidate);
      return candidate;
    }
  }
}
