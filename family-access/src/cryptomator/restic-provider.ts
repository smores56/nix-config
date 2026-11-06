import type { ResticDirEntry, ResticRepository, ResticSnapshot } from "../restic/repository";
import {
  MAX_FILE_BYTES,
  MAX_METADATA_BYTES,
  type VaultEntry,
  type VaultProvider,
} from "./vault";

function assertRelativePath(relative: string): void {
  if (relative.startsWith("/") || relative.includes("\0")) {
    throw new Error("invalid vault path");
  }
  for (const segment of relative.split("/")) {
    if (segment === ".." || segment === ".") throw new Error("invalid vault path");
  }
}

function parentOf(path: string): string {
  const index = path.lastIndexOf("/");
  return index === -1 ? "" : path.slice(0, index);
}

function nameOf(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}

/** Maps the vault's relative ciphertext paths onto a restic snapshot. */
export class ResticVaultProvider implements VaultProvider {
  private readonly listings = new Map<string, ResticDirEntry[]>();

  constructor(
    private readonly repository: ResticRepository,
    private readonly snapshot: ResticSnapshot,
    private readonly prefix: string,
  ) {
    if (prefix.startsWith("/") || prefix.includes("\0")) {
      throw new Error("invalid vault prefix");
    }
  }

  private full(relative: string): string {
    assertRelativePath(relative);
    return relative ? `${this.prefix}/${relative}` : this.prefix;
  }

  private async entries(relative: string): Promise<ResticDirEntry[]> {
    const cached = this.listings.get(relative);
    if (cached) return cached;
    const entries = await this.repository.listDirectory(this.snapshot, this.full(relative));
    if (this.listings.size >= 256) {
      const oldest = this.listings.keys().next().value;
      if (oldest !== undefined) this.listings.delete(oldest);
    }
    this.listings.set(relative, entries);
    return entries;
  }

  async list(relative: string): Promise<VaultEntry[]> {
    return (await this.entries(relative)).map((entry) => ({
      name: entry.name,
      type: entry.type,
      size: entry.type === "file" ? entry.size : undefined,
    }));
  }

  async read(relative: string): Promise<Uint8Array> {
    const parent = parentOf(relative);
    const entry = (await this.entries(parent)).find(
      (candidate) => candidate.name === nameOf(relative) && candidate.type === "file",
    );
    if (!entry) throw new Error(`vault file not found: ${relative}`);
    const size = entry.size ?? 0;
    if (size > MAX_FILE_BYTES + 1024 * 1024) {
      throw new Error(`vault file is too large: ${relative}`);
    }
    return this.repository.readFile({
      path: this.full(relative),
      blobs: entry.blobs ?? [],
      size,
    });
  }

  async readText(relative: string, maxBytes = MAX_METADATA_BYTES): Promise<string> {
    const parent = parentOf(relative);
    const entry = (await this.entries(parent)).find(
      (candidate) => candidate.name === nameOf(relative) && candidate.type === "file",
    );
    if (!entry) throw new Error(`vault file not found: ${relative}`);
    if ((entry.size ?? 0) > maxBytes) throw new Error(`vault metadata is too large: ${relative}`);
    return new TextDecoder().decode(await this.read(relative));
  }
}
