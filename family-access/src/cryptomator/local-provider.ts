import { promises as fs } from "node:fs";
import * as path from "node:path";
import { MAX_FILE_BYTES, MAX_METADATA_BYTES, type VaultEntry, type VaultProvider } from "./vault";

/** Read-only provider over a Cryptomator vault directory (tests and the Mac CLI). */
export class LocalVaultProvider implements VaultProvider {
  private readonly root: string;

  constructor(root: string) {
    this.root = path.resolve(root);
  }

  private resolve(relative: string): string {
    const full = path.resolve(this.root, relative);
    if (full !== this.root && !full.startsWith(this.root + path.sep)) {
      throw new Error("vault path escapes the root");
    }
    return full;
  }

  private async assertRegular(full: string, maxBytes: number): Promise<number> {
    const stat = await fs.lstat(full);
    if (stat.isSymbolicLink()) throw new Error("the vault contains a filesystem symlink");
    if (!stat.isFile()) throw new Error("the vault path is not a regular file");
    if (stat.size > maxBytes) throw new Error("the vault file is too large");
    return stat.size;
  }

  async read(relative: string): Promise<Uint8Array> {
    const full = this.resolve(relative);
    await this.assertRegular(full, MAX_FILE_BYTES + 1024 * 1024);
    return new Uint8Array(await fs.readFile(full));
  }

  async readText(relative: string, maxBytes = MAX_METADATA_BYTES): Promise<string> {
    const full = this.resolve(relative);
    await this.assertRegular(full, maxBytes);
    return fs.readFile(full, "utf8");
  }

  async list(relative: string): Promise<VaultEntry[]> {
    const directory = this.resolve(relative);
    const entries = await fs.readdir(directory, { withFileTypes: true });
    const out: VaultEntry[] = [];
    for (const entry of entries) {
      if (entry.isSymbolicLink()) {
        throw new Error("the vault contains a filesystem symlink");
      }
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        out.push({ name: entry.name, type: "dir" });
      } else if (entry.isFile()) {
        const stat = await fs.lstat(full);
        out.push({ name: entry.name, type: "file", size: stat.size });
      }
    }
    return out;
  }
}
