import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { unzipSync } from "fflate";
import { streamZip, type ZipEntry } from "./zip.ts";

const encoder = new TextEncoder();

async function* zipEntries(
  entries: Array<{ path: string; chunks: string[] }>,
): AsyncGenerator<ZipEntry> {
  for (const entry of entries) {
    yield {
      path: entry.path,
      chunks: (async function* () {
        for (const chunk of entry.chunks) yield encoder.encode(chunk);
      })(),
    };
  }
}

function concatenate(chunks: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

describe("streamZip", () => {
  test("stores every file in a readable zip", async () => {
    const chunks = await streamZip(
      zipEntries([
        { path: "photos/one.txt", chunks: ["hello"] },
        { path: "photos/two.txt", chunks: ["wor", "ld"] },
        { path: "photos/empty.txt", chunks: [] },
      ]),
      { maxBytes: 1024 },
    );

    const files = unzipSync(concatenate(chunks));
    const decoder = new TextDecoder();
    expect(decoder.decode(files["photos/one.txt"])).toBe("hello");
    expect(decoder.decode(files["photos/two.txt"])).toBe("world");
    expect(files["photos/empty.txt"].length).toBe(0);
  });

  test("aborts when the decompressed total exceeds the cap", async () => {
    await expect(
      streamZip(
        zipEntries([{ path: "big.bin", chunks: ["12345", "67890"] }]),
        { maxBytes: 6 },
      ),
    ).rejects.toThrow(/limit/);
  });

  test("an empty folder still produces a valid zip", async () => {
    const chunks = await streamZip(zipEntries([]), { maxBytes: 1024 });
    expect(Object.keys(unzipSync(concatenate(chunks)))).toEqual([]);
  });
});
