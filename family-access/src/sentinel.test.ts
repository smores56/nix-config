import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { type CryptomatorVault, type DirID, type Item, ROOT_DIR_ID } from "./cryptomator/vault.ts";
import { readSentinel } from "./sentinel.ts";

const DOCS = "docs" as DirID;
const OTHER = "other" as DirID;

function file(name: string): Item {
  return { name, kind: "file", encryptedPath: `d/f/${name}`, shortened: false };
}

function dir(name: string, dirId: DirID): Item {
  return { name, kind: "dir", encryptedPath: `d/d/${name}`, dirId, shortened: false };
}

function fakeVault(trees: Record<string, Item[]>, text = "sentinel: 6f1c2a7e\n") {
  const reads: Item[] = [];
  const vault = {
    list: async (dirId: DirID) => trees[String(dirId)] ?? [],
    readTextFile: async (item: Item) => {
      reads.push(item);
      return text;
    },
  } as Pick<CryptomatorVault, "list" | "readTextFile">;
  return { vault, reads };
}

describe("readSentinel", () => {
  test("reads Documents/sentinel.txt and trims it", async () => {
    const { vault, reads } = fakeVault({
      [String(ROOT_DIR_ID)]: [file("IMPORTANT.rtf"), dir("Documents", DOCS)],
      [String(DOCS)]: [file("sentinel.txt"), dir("Taxes", OTHER)],
    });

    expect(await readSentinel(vault)).toBe("sentinel: 6f1c2a7e");
    expect(reads.map((item) => item.name)).toEqual(["sentinel.txt"]);
  });

  test("rejects a sentinel left at the vault root", async () => {
    const { vault } = fakeVault({
      [String(ROOT_DIR_ID)]: [file("sentinel.txt"), dir("Documents", DOCS)],
      [String(DOCS)]: [],
    });

    await expect(readSentinel(vault)).rejects.toThrow("Documents/sentinel.txt");
  });

  test("names the missing folder", async () => {
    const { vault } = fakeVault({ [String(ROOT_DIR_ID)]: [file("IMPORTANT.rtf")] });

    await expect(readSentinel(vault)).rejects.toThrow("Documents/");
  });

  test("names the missing file", async () => {
    const { vault } = fakeVault({
      [String(ROOT_DIR_ID)]: [dir("Documents", DOCS)],
      [String(DOCS)]: [file("budget.txt")],
    });

    await expect(readSentinel(vault)).rejects.toThrow("Documents/sentinel.txt");
  });
});
