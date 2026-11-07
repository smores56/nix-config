import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import type { ResticDirEntry, ResticFile, ResticRepository, ResticSnapshot } from "./restic/repository.ts";
import { readSentinel, SENTINEL_DIR, SENTINEL_PATH } from "./sentinel.ts";

const snapshot = { id: "abc", time: "2026-11-07T00:00:00Z", tree: "0".repeat(64), paths: [] } as
  ResticSnapshot;

function fakeRepository(entries: ResticDirEntry[], text = "sentinel: 6f1c2a7e\n") {
  const listed: string[] = [];
  const read: string[] = [];
  const repository = {
    listDirectory: async (_snapshot: ResticSnapshot, directory: string) => {
      listed.push(directory);
      return entries;
    },
    readFile: async (file: ResticFile) => {
      read.push(file.path);
      return new TextEncoder().encode(text);
    },
  } as unknown as ResticRepository;
  return { repository, listed, read };
}

describe("readSentinel", () => {
  test("lists one folder and reads the sentinel, trimming it", async () => {
    const { repository, listed, read } = fakeRepository([
      { name: "Documents", path: `${SENTINEL_DIR}/Documents`, type: "dir" },
      { name: "sentinel.txt", path: SENTINEL_PATH, type: "file", size: 19, blobs: ["b"] },
    ]);

    expect(await readSentinel(repository, snapshot)).toBe("sentinel: 6f1c2a7e");
    expect(listed).toEqual([SENTINEL_DIR]);
    expect(read).toEqual([SENTINEL_PATH]);
  });

  test("names the path it expected when the folder has no sentinel", async () => {
    const { repository } = fakeRepository([]);
    await expect(readSentinel(repository, snapshot)).rejects.toThrow(SENTINEL_PATH);
  });
});
