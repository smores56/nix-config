import { promises as fs } from "node:fs";
import * as path from "node:path";

export interface ResticBackend {
  read(path: string, offset?: number, length?: number): Promise<Uint8Array>;
  list(prefix: string): Promise<string[]>;
}

export class LocalBackend implements ResticBackend {
  constructor(private readonly root: string) {}

  private resolve(relative: string): string {
    const root = path.resolve(this.root);
    const full = path.resolve(root, relative);
    if (full !== root && !full.startsWith(root + path.sep)) {
      throw new Error("repository path escapes the root");
    }
    return full;
  }

  async read(relative: string, offset = 0, length?: number): Promise<Uint8Array> {
    const handle = await fs.open(this.resolve(relative), "r");
    try {
      const stat = await handle.stat();
      const requested = length ?? Math.max(0, stat.size - offset);
      if (requested > 256 * 1024 * 1024) throw new Error("refusing an oversized local read");
      const buffer = new Uint8Array(requested);
      const { bytesRead } = await handle.read(buffer, 0, requested, offset);
      return buffer.subarray(0, bytesRead);
    } finally {
      await handle.close();
    }
  }

  async list(prefix: string): Promise<string[]> {
    const root = this.resolve("");
    const files: string[] = [];
    const walk = async (dir: string, relativeDir: string): Promise<void> => {
      for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
        const relative = relativeDir ? `${relativeDir}/${entry.name}` : entry.name;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) await walk(full, relative);
        else if (entry.isFile()) files.push(relative);
      }
    };
    await walk(root, "");
    return files.filter((file) => file.startsWith(prefix));
  }
}
