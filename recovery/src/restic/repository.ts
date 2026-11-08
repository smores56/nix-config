import { decompress } from "fzstd";
import type { ResticBackend } from "./backend.ts";
import {
  type MasterKey,
  maybeZstd,
  openKeyFile,
  openWithMaster,
  type ResticKeyFile,
  verifySha256,
} from "./crypto.ts";

export type ResticConfig = {
  version: number;
  id: string;
  chunker_polynomial: string;
};

export type ResticSnapshot = {
  id: string;
  time: string;
  tree: string;
  paths: string[];
  hostname?: string;
  tags?: string[];
  original?: string;
};

export type ResticTree = {
  nodes?: Array<{
    name: string;
    type: "file" | "dir" | "symlink" | string;
    mode?: number;
    mtime?: string;
    size?: number;
    content?: string[];
    subtree?: string;
    linktarget?: string;
  }>;
};

export type ResticFile = {
  path: string;
  blobs: string[];
  size?: number;
};

export type ResticDirEntry = {
  name: string;
  path: string;
  type: "file" | "dir";
  size?: number;
  blobs?: string[];
};

type BlobLocation = {
  pack: string;
  offset: number;
  length: number;
  uncompressed?: number;
  type: string;
};

type IndexFile = {
  supersedes?: string[];
  packs?: Array<{
    id: string;
    blobs?: Array<{
      id: string;
      offset: number;
      length: number;
      type: string;
      uncompressed_length?: number;
    }>;
  }>;
};

function decodeJson<T>(bytes: Uint8Array): T {
  return JSON.parse(new TextDecoder().decode(bytes)) as T;
}

function treeIdOf(node: { subtree?: string }, path: string): string {
  if (!node.subtree) throw new Error(`directory ${path} has no subtree`);
  return node.subtree;
}

function isStorageId(path: string): boolean {
  return /^[0-9a-f]{64}$/.test(path.split("/").pop() ?? "");
}

export function isSafeName(name: unknown): name is string {
  return (
    typeof name === "string" &&
    name.length > 0 &&
    name !== "." &&
    name !== ".." &&
    !name.includes("/") &&
    !name.includes("\0")
  );
}

const TREE_CACHE_LIMIT = 512;

export class ResticRepository {
  private readonly treeCache = new Map<string, ResticTree>();

  constructor(
    private readonly backend: ResticBackend,
    private readonly master: MasterKey,
    readonly config: ResticConfig,
    private readonly index: Map<string, BlobLocation>,
    readonly snapshots: ResticSnapshot[],
  ) {}

  async readBlob(id: string): Promise<Uint8Array> {
    const location = this.index.get(id);
    if (!location) throw new Error(`blob is not in the index: ${id}`);
    const sealed = await this.backend.read(
      `data/${location.pack.slice(0, 2)}/${location.pack}`,
      location.offset,
      location.length,
    );
    let plain = openWithMaster(sealed, this.master);
    if (location.uncompressed !== undefined) plain = decompress(plain);
    if (!(await verifySha256(plain, id))) throw new Error(`blob hash mismatch: ${id}`);
    return plain;
  }

  async readTree(treeId: string): Promise<ResticTree> {
    const cached = this.treeCache.get(treeId);
    if (cached) {
      // Refresh insertion order so the oldest entry is evicted first.
      this.treeCache.delete(treeId);
      this.treeCache.set(treeId, cached);
      return cached;
    }
    const tree = decodeJson<ResticTree>(await this.readBlob(treeId));
    if (this.treeCache.size >= TREE_CACHE_LIMIT) {
      const oldest = this.treeCache.keys().next().value;
      if (oldest !== undefined) this.treeCache.delete(oldest);
    }
    this.treeCache.set(treeId, tree);
    return tree;
  }

  async walk(snapshot: ResticSnapshot): Promise<ResticFile[]> {
    return this.walkTree(snapshot.tree, "");
  }

  /** Walk one directory subtree instead of the whole snapshot. */
  async walkDirectory(snapshot: ResticSnapshot, directory: string): Promise<ResticFile[]> {
    const { treeId, prefix } = await this.resolveDirectory(snapshot, directory);
    return this.walkTree(treeId, prefix);
  }

  private async walkTree(rootTreeId: string, rootPrefix: string): Promise<ResticFile[]> {
    const files: ResticFile[] = [];
    const stack = new Set<string>();

    const visit = async (treeId: string, prefix: string, depth: number): Promise<void> => {
      if (depth > 128) throw new Error("restic tree is too deep");
      if (stack.has(treeId)) throw new Error("restic tree contains a cycle");
      stack.add(treeId);
      try {
        const tree = await this.readTree(treeId);
        for (const node of tree.nodes ?? []) {
          if (!isSafeName(node.name)) throw new Error(`unsafe restic name: ${String(node.name)}`);
          const path = prefix ? `${prefix}/${node.name}` : node.name;
          if (node.type === "dir") {
            await visit(treeIdOf(node, path), path, depth + 1);
          } else if (node.type === "file") {
            files.push({
              path,
              blobs: Array.isArray(node.content) ? node.content : [],
              size: typeof node.size === "number" ? node.size : 0,
            });
          }
        }
      } finally {
        stack.delete(treeId);
      }
    };

    await visit(rootTreeId, rootPrefix, 0);
    return files;
  }

  private async resolveDirectory(
    snapshot: ResticSnapshot,
    directory: string,
  ): Promise<{ treeId: string; prefix: string }> {
    const segments = directory.split("/").filter(Boolean);
    let treeId = snapshot.tree;
    let prefix = "";
    for (const segment of segments) {
      if (!isSafeName(segment)) throw new Error("unsafe directory name");
      const tree = await this.readTree(treeId);
      const node = (tree.nodes ?? []).find(
        (child) => child.name === segment && child.type === "dir",
      );
      if (!node) throw new Error(`directory not found: ${directory}`);
      treeId = treeIdOf(node, prefix ? `${prefix}/${segment}` : segment);
      prefix = prefix ? `${prefix}/${segment}` : segment;
    }
    return { treeId, prefix };
  }

  async listDirectory(
    snapshot: ResticSnapshot,
    directory: string,
  ): Promise<ResticDirEntry[]> {
    const { treeId, prefix } = await this.resolveDirectory(snapshot, directory);

    const tree = await this.readTree(treeId);
    return (tree.nodes ?? [])
      .filter((node) => node.type === "file" || node.type === "dir")
      .filter((node) => isSafeName(node.name))
      .map((node) => ({
        name: node.name,
        path: prefix ? `${prefix}/${node.name}` : node.name,
        type: node.type as "file" | "dir",
        size: typeof node.size === "number" ? node.size : 0,
        ...(node.type === "file" ? { blobs: Array.isArray(node.content) ? node.content : [] } : {}),
      }));
  }

  async *readFileChunks(file: ResticFile): AsyncGenerator<Uint8Array> {
    let total = 0;
    for (const blob of file.blobs) {
      const chunk = await this.readBlob(blob);
      total += chunk.length;
      yield chunk;
    }
    if (file.size !== undefined && total !== file.size) {
      throw new Error(`file size mismatch for ${file.path}: ${total} != ${file.size}`);
    }
  }

  async readFile(file: ResticFile): Promise<Uint8Array> {
    const chunks: Uint8Array[] = [];
    for await (const chunk of this.readFileChunks(file)) chunks.push(chunk);
    const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    const out = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      out.set(chunk, offset);
      offset += chunk.length;
    }
    return out;
  }
}

export async function openRepository(
  backend: ResticBackend,
  password: string,
): Promise<ResticRepository> {
  const keyPaths = (await backend.list("keys/")).filter(isStorageId);
  let master: MasterKey | undefined;
  let lastKeyError: unknown;
  for (const keyPath of keyPaths) {
    try {
      const keyFile = decodeJson<ResticKeyFile>(await backend.read(keyPath));
      master = await openKeyFile(keyFile, password);
      break;
    } catch (error) {
      lastKeyError = error;
    }
  }
  if (!master) {
    const detail = keyPaths.length === 1 && lastKeyError instanceof Error
      ? `: ${lastKeyError.message}`
      : "";
    throw new Error(`unable to open restic repository${detail}`);
  }

  const config = decodeJson<ResticConfig>(
    openWithMaster(await backend.read("config"), master),
  );
  if (config.version !== 1 && config.version !== 2) {
    throw new Error(`unsupported restic repository version: ${config.version}`);
  }

  const indexFiles: Array<{ id: string; body: IndexFile }> = [];
  for (const indexPath of (await backend.list("index/")).filter(isStorageId)) {
    const plain = maybeZstd(openWithMaster(await backend.read(indexPath), master));
    indexFiles.push({
      id: indexPath.split("/").pop() ?? indexPath,
      body: decodeJson<IndexFile>(plain),
    });
  }
  const superseded = new Set(indexFiles.flatMap(({ body }) => body.supersedes ?? []));
  const index = new Map<string, BlobLocation>();
  for (const { id, body } of indexFiles) {
    if (superseded.has(id)) continue;
    for (const pack of body.packs ?? []) {
      for (const blob of pack.blobs ?? []) {
        index.set(blob.id, {
          pack: pack.id,
          offset: blob.offset,
          length: blob.length,
          uncompressed: blob.uncompressed_length,
          type: blob.type,
        });
      }
    }
  }

  const snapshots: ResticSnapshot[] = [];
  for (const snapshotPath of (await backend.list("snapshots/")).filter(isStorageId)) {
    try {
      const plain = maybeZstd(openWithMaster(await backend.read(snapshotPath), master));
      const snapshot = decodeJson<Omit<ResticSnapshot, "id">>(plain);
      if (typeof snapshot.tree !== "string" || typeof snapshot.time !== "string") {
        continue;
      }
      snapshots.push({
        id: snapshotPath.split("/").pop() ?? snapshotPath,
        ...snapshot,
        paths: Array.isArray(snapshot.paths) ? snapshot.paths : [],
      });
    } catch {
      // Skip an unreadable snapshot; the remaining ones are still usable.
    }
  }
  snapshots.sort((a, b) => b.time.localeCompare(a.time));

  return new ResticRepository(backend, master, config, index, snapshots);
}
