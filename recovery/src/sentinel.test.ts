import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import type { ResticFile, ResticRepository, ResticSnapshot } from "./restic/repository.ts";
import { readSentinel, SENTINEL_PATH } from "./sentinel.ts";

const snapshot = { id: "abc", time: "2026-11-07T00:00:00Z", tree: "0".repeat(64), paths: [] } as
  ResticSnapshot;

function fakeRepository(files: ResticFile[], text = "sentinel: 6f1c2a7e\n") {
  const read: string[] = [];
  const repository = {
    walk: async () => files,
    readFile: async (file: ResticFile) => {
      read.push(file.path);
      return new TextEncoder().encode(text);
    },
  } as unknown as ResticRepository;
  return { repository, read };
}

describe("readSentinel", () => {
  test("reads the sentinel from the store and trims it", async () => {
    const { repository, read } = fakeRepository([
      { path: "var/lib/data/photos/2024/a.jpg", blobs: [] },
      { path: SENTINEL_PATH, blobs: [] },
    ]);

    expect(await readSentinel(repository, snapshot)).toBe("sentinel: 6f1c2a7e");
    expect(read).toEqual([SENTINEL_PATH]);
  });

  test("names the path it expected when the snapshot has no sentinel", async () => {
    const { repository } = fakeRepository([{ path: "var/lib/data/photos/a.jpg", blobs: [] }]);
    await expect(readSentinel(repository, snapshot)).rejects.toThrow(SENTINEL_PATH);
  });
});
