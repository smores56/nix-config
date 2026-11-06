import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { LocalBackend } from "../restic/backend.ts";
import { openRepository } from "../restic/repository.ts";
import { LocalVaultProvider } from "./local-provider.ts";
import { ResticVaultProvider } from "./restic-provider.ts";
import { CryptomatorVault, ROOT_DIR_ID } from "./vault.ts";

const fixture = new URL("../../test-fixtures/cryptomator-vault", import.meta.url).pathname;
const password = "family-access-vault-fixture";
const resticPassword = "family-access-fixture";

const vault = await CryptomatorVault.open(new LocalVaultProvider(fixture), password);
const root = await vault.list(ROOT_DIR_ID);

const LONG_FILE = "long-file-" + "abcdefghij".repeat(18) + ".txt";

function item(name: string, items = root) {
  const found = items.find((candidate) => candidate.name === name);
  if (!found) throw new Error(`fixture item not found: ${name}`);
  return found;
}

describe("cryptomator vault reader", () => {
  test("opens the reference vault and verifies its config", () => {
    expect(vault.settings).toEqual({
      format: 8,
      cipherCombo: "SIV_GCM",
      shorteningThreshold: 220,
    });
  });

  test("derives the documented root directory path", async () => {
    expect(await vault.ciphertextPath(ROOT_DIR_ID)).toBe(
      "d/ED/5AD542HXVAJNAAOWAF4BFRUYW5ISBG",
    );
  });

  test("lists root entries, skipping internal files", () => {
    expect(root.map((entry) => `${entry.kind}:${entry.name}`).sort()).toEqual(
      [
        "dir:documents",
        "dir:" + "long-dir-" + "klmnopqrst".repeat(18),
        "file:café.txt",
        "file:chunk-plus-one.bin",
        "file:empty.txt",
        "file:exact-chunk.bin",
        "file:family-access-sentinel.txt",
        "file:one-byte.bin",
        "symlink:link-to-hello.txt",
      ].sort(),
    );
    expect(root.some((entry) => entry.name === "dir.c9r" || entry.name === "dirid.c9r")).toBe(
      false,
    );
  });

  test("decrypts the sentinel from the root directory", async () => {
    expect(await vault.readTextFile(item("family-access-sentinel.txt"))).toBe(
      "vault-sentinel: 6f1c2a7e",
    );
  });

  test("handles every chunk boundary", async () => {
    const cases: Array<[string, number]> = [
      ["empty.txt", 0],
      ["one-byte.bin", 1],
      ["exact-chunk.bin", 32 * 1024],
      ["chunk-plus-one.bin", 32 * 1024 + 1],
    ];
    for (const [name, length] of cases) {
      expect((await vault.readFile(item(name))).length).toBe(length);
    }
    const documents = await vault.list(item("documents").dirId!);
    expect((await vault.readFile(item("binary.bin", documents))).length).toBe(100_000);
  });
});

describe("cryptomator nested and shortened entries", () => {
  test("walks nested directories", async () => {
    const documents = await vault.list(item("documents").dirId!);
    expect(documents.map((entry) => entry.name).sort()).toEqual(
      ["binary.bin", "hello.txt", LONG_FILE, "nested"].sort(),
    );
    expect(await vault.readTextFile(item("hello.txt", documents))).toBe(
      "hello from inside the vault\n",
    );
    const nested = await vault.list(item("nested", documents).dirId!);
    expect(await vault.readTextFile(item("report.txt", nested))).toBe("nested report\n");
  });

  test("reads a shortened file name", async () => {
    const documents = await vault.list(item("documents").dirId!);
    const shortened = item(LONG_FILE, documents);
    expect(shortened.shortened).toBe(true);
    expect(await vault.readTextFile(shortened)).toBe("shortened file name body\n");
  });

  test("reads a shortened directory", async () => {
    const longDir = root.find((entry) => entry.name.startsWith("long-dir-"));
    expect(longDir?.shortened).toBe(true);
    const inside = await vault.list(longDir!.dirId!);
    expect(await vault.readTextFile(item("inside.txt", inside))).toBe(
      "inside a shortened directory\n",
    );
  });

  test("applies NFC normalization as Cryptomator does", () => {
    expect(root.filter((entry) => entry.name.normalize("NFC") === "café.txt")).toHaveLength(1);
    expect(item("café.txt").name).toBe("café.txt");
  });

  test("refuses symlink contents", async () => {
    expect(item("link-to-hello.txt").kind).toBe("symlink");
    await expect(vault.readFile(item("link-to-hello.txt"))).rejects.toThrow(
      "is not a regular file",
    );
  });
});

describe("cryptomator failure modes", () => {
  test("rejects a wrong password", async () => {
    await expect(
      CryptomatorVault.open(new LocalVaultProvider(fixture), "wrong-password"),
    ).rejects.toThrow("the vault password is wrong");
  });

  test("rejects a tampered vault config signature", async () => {
    const provider = new LocalVaultProvider(fixture);
    const token = await provider.readText("vault.cryptomator");
    const tampered = token.slice(0, -1) + (token.endsWith("A") ? "B" : "A");
    const patched = {
      read: provider.read.bind(provider),
      list: provider.list.bind(provider),
      async readText(path: string) {
        return path === "vault.cryptomator" ? tampered : provider.readText(path);
      },
    };
    await expect(CryptomatorVault.open(patched, password)).rejects.toThrow(
      "vault.cryptomator signature is invalid",
    );
  });

  test("rejects a tampered file header", async () => {
    const provider = new LocalVaultProvider(fixture);
    const path = item("family-access-sentinel.txt").encryptedPath;
    const patched = {
      list: provider.list.bind(provider),
      readText: provider.readText.bind(provider),
      async read(candidate: string) {
        const bytes = await provider.read(candidate);
        if (candidate !== path) return bytes;
        const copy = new Uint8Array(bytes);
        copy[0] ^= 0xff;
        return copy;
      },
    };
    const opened = await CryptomatorVault.open(patched, password);
    const entries = await opened.list(ROOT_DIR_ID);
    await expect(opened.readFile(item("family-access-sentinel.txt", entries))).rejects.toThrow();
  });

  test("rejects a ciphertext truncated at a chunk boundary", async () => {
    const provider = new LocalVaultProvider(fixture);
    const path = item("binary.bin", await vault.list(item("documents").dirId!)).encryptedPath;
    const patched = {
      list: provider.list.bind(provider),
      readText: provider.readText.bind(provider),
      async read(candidate: string) {
        const bytes = await provider.read(candidate);
        return candidate === path ? bytes.subarray(0, 68 + 32796) : bytes;
      },
    };
    const opened = await CryptomatorVault.open(patched, password);
    const entries = await opened.list(item("documents").dirId!);
    await expect(opened.readFile(item("binary.bin", entries))).rejects.toThrow(
      "is shorter than the vault index reports",
    );
  });

  test("keeps listing when one entry has no marker file", async () => {
    const provider = new LocalVaultProvider(fixture);
    const documentsPath = item("documents").encryptedPath;
    const patched = {
      read: provider.read.bind(provider),
      readText: provider.readText.bind(provider),
      async list(path: string) {
        return path === documentsPath ? [] : provider.list(path);
      },
    };
    const opened = await CryptomatorVault.open(patched, password);
    const entries = await opened.list(ROOT_DIR_ID);
    const documents = entries.find((entry) => entry.name === "documents")!;
    expect(documents.kind).toBe("unknown");
    expect(documents.damaged).toBeDefined();
    expect(entries.find((entry) => entry.name === "family-access-sentinel.txt")?.kind).toBe(
      "file",
    );
  });

  test("caps metadata reads", async () => {
    const provider = new LocalVaultProvider(fixture);
    const longDir = root.find((entry) => entry.shortened && entry.kind === "dir")!;
    await expect(provider.readText(`${longDir.encryptedPath}/name.c9s`, 8)).rejects.toThrow(
      "too large",
    );
  });
});

describe("restic-backed vault provider", () => {
  const repositoryFixture = new URL(
    "../../test-fixtures/restic-cryptomator",
    import.meta.url,
  ).pathname;

  test("lists and decrypts the vault from a restic snapshot", async () => {
    const repository = await openRepository(new LocalBackend(repositoryFixture), resticPassword);
    const snapshot = repository.snapshots[0];
    const provider = new ResticVaultProvider(
      repository,
      snapshot,
      "var/lib/data/vault",
    );
    const resticVault = await CryptomatorVault.open(provider, password);
    const entries = await resticVault.list(ROOT_DIR_ID);
    const sentinel = entries.find((entry) => entry.name === "family-access-sentinel.txt")!;
    expect(await resticVault.readTextFile(sentinel)).toBe("vault-sentinel: 6f1c2a7e");
    const documents = await resticVault.list(
      entries.find((entry) => entry.name === "documents")!.dirId!,
    );
    expect(
      await resticVault.readFile(documents.find((entry) => entry.name === "binary.bin")!),
    ).toHaveLength(100_000);
  });

  test("rejects a missing vault file", async () => {
    const repository = await openRepository(new LocalBackend(repositoryFixture), resticPassword);
    const provider = new ResticVaultProvider(
      repository,
      repository.snapshots[0],
      "var/lib/data/vault",
    );
    await expect(provider.read("missing.c9r")).rejects.toThrow("vault file not found");
  });
});
