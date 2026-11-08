import { beforeAll, describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { LocalBackend } from "./backend.ts";
import {
  isSafeName,
  openRepository,
  type ResticFile,
  type ResticRepository,
} from "./repository.ts";

const fixture = new URL("../../test-fixtures/restic", import.meta.url).pathname;
const backend = new LocalBackend(fixture);
const password = "family-access-fixture";

let repo: ResticRepository;

beforeAll(async () => {
  repo = await openRepository(backend, password);
});

async function findFile(pathSuffix: string): Promise<ResticFile> {
  const files = await repo.walk(repo.snapshots[0]);
  const file = files.find((entry) => entry.path.endsWith(pathSuffix));
  if (!file) throw new Error(`fixture file not found: ${pathSuffix}`);
  return file;
}

describe("restic repository reader", () => {
  test("opens the fixture repository and lists snapshots", () => {
    expect(repo.config.version).toBeGreaterThanOrEqual(1);
    expect(repo.snapshots.length).toBeGreaterThanOrEqual(2);
    expect(repo.snapshots[0].tree).toMatch(/^[0-9a-f]{64}$/);
  });

  test("rejects the wrong password", async () => {
    await expect(openRepository(backend, "wrong-password")).rejects.toThrow();
  });

  test("walks the tree and finds the sentinel, nested file, empty file, and long name", async () => {
    const files = await repo.walk(repo.snapshots[0]);
    const names = files.map((file) => file.path);
    expect(names.some((name) => name.endsWith("family-access-sentinel.txt"))).toBe(true);
    expect(names.some((name) => name.endsWith("documents/nested/hello.txt"))).toBe(true);
    expect(names.some((name) => name.endsWith("empty.txt"))).toBe(true);
    expect(names.some((name) => name.endsWith(".txt") && name.length > 200)).toBe(true);
    expect(names.some((name) => name.endsWith("compressible.txt"))).toBe(true);
    expect(names.some((name) => name.endsWith("binary.bin"))).toBe(true);
    expect(names.some((name) => name.endsWith("large.bin"))).toBe(true);
  });

  test("walks only a selected directory", async () => {
    const all = await repo.walk(repo.snapshots[0]);
    const nested = all.find((file) => file.path.endsWith("documents/nested/hello.txt"));
    if (!nested) throw new Error("fixture documents/nested/hello.txt missing");
    const marker = "/documents/";
    const documents = nested.path.slice(
      0,
      nested.path.lastIndexOf(marker) + "/documents".length,
    );
    const scoped = await repo.walkDirectory(repo.snapshots[0], documents);
    expect(scoped.length).toBeGreaterThan(0);
    expect(scoped.every((file) => file.path.startsWith(`${documents}/`))).toBe(true);
    expect(scoped.some((file) => file.path.endsWith("documents/nested/hello.txt"))).toBe(true);
    expect(scoped.some((file) => file.path.endsWith("family-access-sentinel.txt"))).toBe(false);
  });

  test("restores the sentinel and nested text exactly", async () => {
    const sentinel = await findFile("family-access-sentinel.txt");
    expect(new TextDecoder().decode(await repo.readFile(sentinel))).toBe(
      "family-access-sentinel: 6f1c2a7e\n",
    );
    const hello = await findFile("documents/nested/hello.txt");
    expect(new TextDecoder().decode(await repo.readFile(hello))).toBe(
      "hello from a nested document\n",
    );
  });

  test("reads a compressed text blob and an empty file", async () => {
    const compressed = await findFile("compressible.txt");
    const text = new TextDecoder().decode(await repo.readFile(compressed));
    expect(text).toContain("compressible line of text");
    const empty = await findFile("empty.txt");
    expect(empty.blobs).toHaveLength(0);
    expect((await repo.readFile(empty)).length).toBe(0);
  });

  test("reads a multi-blob file in blob order", async () => {
    const large = await findFile("large.bin");
    expect(large.blobs.length).toBeGreaterThan(1);
    const content = await repo.readFile(large);
    expect(content.length).toBe(3145728);
    const chunks: Uint8Array[] = [];
    for await (const chunk of repo.readFileChunks(large)) chunks.push(chunk);
    expect(chunks.length).toBe(large.blobs.length);
    expect(chunks.reduce((sum, chunk) => sum + chunk.length, 0)).toBe(3145728);
  });

  test("rejects unsafe tree names but allows backslashes in file names", () => {
    expect(isSafeName("documents")).toBe(true);
    expect(isSafeName("family-access-sentinel.txt")).toBe(true);
    expect(isSafeName("a\\b")).toBe(true);
    expect(isSafeName("..")).toBe(false);
    expect(isSafeName("a/b")).toBe(false);
    expect(isSafeName("a\0b")).toBe(false);
  });
});
