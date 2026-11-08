// Zip fallback for browsers without a directory picker. Streaming (store-only)
// keeps memory at roughly the archive size instead of holding every decompressed
// file and then a second full copy, and the cap counts the bytes actually read.
import { Zip, ZipPassThrough } from "fflate";

export type ZipEntry = {
  /** Path inside the archive, already sanitized by the caller. */
  path: string;
  chunks: AsyncIterable<Uint8Array>;
};

export type ZipOptions = {
  /** Decompressed byte budget; the archive is abandoned once it is exceeded. */
  maxBytes: number;
};

export async function streamZip(
  entries: AsyncIterable<ZipEntry>,
  { maxBytes }: ZipOptions,
): Promise<Uint8Array[]> {
  const output: Uint8Array[] = [];
  let failure: Error | undefined;
  const archive = new Zip((error, chunk) => {
    if (error) {
      failure ??= error;
      return;
    }
    if (chunk.length > 0) output.push(chunk);
  });

  let total = 0;
  for await (const entry of entries) {
    const writer = new ZipPassThrough(entry.path);
    archive.add(writer);
    for await (const chunk of entry.chunks) {
      total += chunk.length;
      if (total > maxBytes) {
        throw new Error(`folder is larger than the ${maxBytes}-byte zip limit`);
      }
      writer.push(chunk, false);
      if (failure) throw failure;
    }
    writer.push(new Uint8Array(0), true);
    if (failure) throw failure;
  }

  archive.end();
  if (failure) throw failure;
  return output;
}
