import { type DataKeys, decryptBlob } from "./blob.ts";
import { sanitizeFileName } from "./filenames.ts";
import { reachHint } from "./hint.ts";
import { commonDirectoryPrefix, dataRoot, relativeSegments } from "./restore.ts";
import { passwordFromHash } from "./link.ts";
import { type RecoveryManifest, renderManifest, validateManifest } from "./manifest.ts";
import { R2Backend, repositoryPrefix } from "./restic/r2.ts";
import {
  openRepository,
  type ResticDirEntry,
  type ResticFile,
  type ResticRepository,
  type ResticSnapshot,
} from "./restic/repository.ts";

const gate = document.querySelector<HTMLElement>("#gate");
const form = document.querySelector<HTMLFormElement>("#unlock-form");
const passwordInput = document.querySelector<HTMLInputElement>("#recovery-password");
const unlockButton = document.querySelector<HTMLButtonElement>("#unlock-button");
const status = document.querySelector<HTMLDivElement>("#status");
const manifestRoot = document.querySelector<HTMLElement>("#manifest");
const restoreSection = document.querySelector<HTMLElement>("#restore");
const snapshotField = document.querySelector<HTMLElement>("#snapshot-field");
const snapshotSingle = document.querySelector<HTMLElement>("#snapshot-single");
const snapshotSelect = document.querySelector<HTMLSelectElement>("#snapshot-select");
const browserStatus = document.querySelector<HTMLDivElement>("#browser-status");
const treeList = document.querySelector<HTMLUListElement>("#browser");
const restoreButton = document.querySelector<HTMLButtonElement>("#restore-all");
const restoreCancelButton = document.querySelector<HTMLButtonElement>("#restore-cancel");
const restoreStatus = document.querySelector<HTMLDivElement>("#restore-status");
const restoreProgress = document.querySelector<HTMLProgressElement>("#restore-progress");
const restoreHint = document.querySelector<HTMLElement>("#restore-hint");
const unlockedRoot = document.querySelector<HTMLElement>("#unlocked");

const secure = window.isSecureContext;
let repository: ResticRepository | null = null;
let snapshot: ResticSnapshot | null = null;
let browseRoot = "";
let entriesByPath = new Map<string, ResticDirEntry>();
let treeGeneration = 0;

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return String(error);
}

function escapeHtml(value: unknown): string {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatBytes(bytes: number | undefined): string {
  if (bytes === undefined) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GiB`;
}

function setStatus(message: string, tone: "info" | "error" | "ok" = "info"): void {
  if (!status) return;
  status.textContent = message;
  status.dataset.tone = tone;
}

function setBrowserStatus(message: string, tone: "info" | "error" | "ok" = "info"): void {
  if (!browserStatus) return;
  browserStatus.textContent = message;
  browserStatus.dataset.tone = tone;
}

function setRestoreStatus(message: string, tone: "info" | "error" | "ok" = "info"): void {
  if (!restoreStatus) return;
  restoreStatus.textContent = message;
  restoreStatus.dataset.tone = tone;
}

function setRestoreProgress(doneBytes: number, totalBytes: number): void {
  if (!restoreProgress) return;
  restoreProgress.hidden = totalBytes === 0;
  restoreProgress.max = Math.max(totalBytes, 1);
  restoreProgress.value = doneBytes;
}

async function loadManifest(): Promise<boolean> {
  if (!manifestRoot) return false;
  try {
    const response = await fetch(new URL("./manifest.json", document.baseURI), {
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`manifest HTTP ${response.status}`);
    const manifest = (await response.json()) as RecoveryManifest;
    const errors = validateManifest(manifest);
    if (errors.length > 0) throw new Error(errors.join(", "));
    manifestRoot.innerHTML = renderManifest(manifest);
    return true;
  } catch (error) {
    manifestRoot.innerHTML =
      `<section class="notice" role="note"><p class="notice-title">Accounts</p><p>The account list could not be loaded: ${
        escapeHtml(errorMessage(error))
      }.</p></section>`;
    return false;
  }
}

async function blobExists(): Promise<boolean> {
  try {
    const response = await fetch(new URL("./data-keys.enc", document.baseURI), {
      method: "HEAD",
      cache: "no-store",
    });
    return response.ok;
  } catch {
    return false;
  }
}

function snapshotTime(time: string): string {
  const date = new Date(time);
  if (Number.isNaN(date.getTime())) return time.slice(0, 16).replace("T", " ");
  return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function snapshotLabel(item: ResticSnapshot): string {
  const parts = [snapshotTime(item.time)];
  if (item.hostname) parts.push(item.hostname);
  if (item.tags?.length) parts.push(item.tags.join(", "));
  return parts.join(" · ");
}

function renderSnapshots(snapshots: ResticSnapshot[]): void {
  if (snapshotSelect) {
    snapshotSelect.innerHTML = snapshots
      .map((item, index) => `<option value="${index}">${escapeHtml(snapshotLabel(item))}</option>`)
      .join("");
  }
  const single = snapshots.length === 1;
  if (snapshotField) snapshotField.hidden = single;
  if (snapshotSingle) {
    snapshotSingle.hidden = !single;
    snapshotSingle.textContent = single ? snapshotLabel(snapshots[0]) : "";
  }
}

async function loadRepository(keys: DataKeys): Promise<void> {
  setBrowserStatus("Opening the backup...");
  const prefix = repositoryPrefix(keys.restic.repository, keys.r2.bucket);
  const backend = new R2Backend({ ...keys.r2, prefix });
  const repo = await openRepository(backend, keys.restic.password);
  repository = repo;
  if (repo.snapshots.length === 0) throw new Error("the backup has no snapshots");
  browseRoot = dataRoot([
    keys.restic.photosPath,
    keys.restic.vaultPath,
    // The dump is a file; the directory it lives in is what shares a parent
    // with the others.
    ...(keys.restic.dbPath ? [commonDirectoryPrefix([keys.restic.dbPath])] : []),
  ]);
  renderSnapshots(repo.snapshots);
  await selectSnapshot(repo.snapshots[0]);
  setBrowserStatus("");
}

async function selectSnapshot(next: ResticSnapshot): Promise<void> {
  snapshot = next;
  entriesByPath = new Map();
  await renderTree();
}

function treeMessage(message: string, tone: "info" | "error" = "info"): string {
  return `<li class="tree-message${tone === "error" ? " error" : ""}">${escapeHtml(message)}</li>`;
}

function sortEntries(entries: ResticDirEntry[]): ResticDirEntry[] {
  return [...entries].sort((left, right) => {
    if (left.type !== right.type) return left.type === "dir" ? -1 : 1;
    return left.name.localeCompare(right.name, undefined, {
      numeric: true,
      sensitivity: "base",
    });
  });
}

function renderEntries(entries: ResticDirEntry[]): string {
  if (entries.length === 0) return treeMessage("This folder is empty.");
  return sortEntries(entries)
    .map((entry) => {
      entriesByPath.set(entry.path, entry);
      if (entry.type === "dir") {
        return `<li class="tree-dir"><details data-path="${escapeHtml(entry.path)}">
  <summary><span class="tree-name">${escapeHtml(entry.name)}/</span></summary>
  <ul class="tree-children"></ul>
</details></li>`;
      }
      const size = formatBytes(entry.size);
      return `<li class="tree-file">
  <button type="button" class="file-button" data-file="${escapeHtml(entry.path)}" title="Download ${
        escapeHtml(entry.name)
      }">
    <span class="tree-name"><span class="sr-only">Download </span>${escapeHtml(entry.name)}</span>
    <span class="tree-size">${escapeHtml(size)}</span>
  </button>
</li>`;
    })
    .join("");
}

async function renderTree(allowFallback = true): Promise<void> {
  if (!repository || !snapshot || !treeList) return;
  const generation = ++treeGeneration;
  entriesByPath.clear();
  treeList.innerHTML = treeMessage("Reading the backup...");
  try {
    const entries = await repository.listDirectory(snapshot, browseRoot);
    if (generation !== treeGeneration) return;
    treeList.innerHTML = renderEntries(entries);
  } catch (error) {
    if (generation !== treeGeneration) return;
    if (allowFallback && browseRoot) {
      // A snapshot taken before the data moved under one parent, or one from
      // another host, has no shared root: open at the snapshot root instead of
      // dead-ending in an empty panel.
      browseRoot = "";
      await renderTree(false);
      return;
    }
    treeList.innerHTML = treeMessage(`Could not list this backup: ${errorMessage(error)}`, "error");
  }
}

async function loadDirectory(details: HTMLDetailsElement): Promise<void> {
  const path = details.dataset.path ?? "";
  if (details.dataset.loaded === "true" || details.dataset.loading === "true") return;
  const list = details.querySelector<HTMLUListElement>(":scope > ul.tree-children");
  if (!list || !repository || !snapshot) return;
  const generation = treeGeneration;
  details.dataset.loading = "true";
  list.innerHTML = treeMessage("Loading...");
  try {
    const entries = await repository.listDirectory(snapshot, path);
    if (generation !== treeGeneration || !details.isConnected) return;
    list.innerHTML = renderEntries(entries);
    details.dataset.loaded = "true";
  } catch (error) {
    if (generation !== treeGeneration || !details.isConnected) return;
    list.innerHTML = treeMessage(errorMessage(error), "error");
  } finally {
    if (generation === treeGeneration) delete details.dataset.loading;
  }
}

type FileHandle = {
  createWritable: () => Promise<{
    write: (data: Uint8Array) => Promise<void>;
    close: () => Promise<void>;
    abort?: () => Promise<void>;
  }>;
  getFile: () => Promise<File>;
};

type DirectoryHandle = {
  getDirectoryHandle: (
    name: string,
    options?: { create?: boolean },
  ) => Promise<DirectoryHandle>;
  getFileHandle: (name: string, options?: { create?: boolean }) => Promise<FileHandle>;
  removeEntry: (name: string) => Promise<void>;
};

const MAX_BUFFERED_DOWNLOAD = 256 * 1024 * 1024;

async function download(entry: ResticDirEntry): Promise<void> {
  if (!repository) return;
  const file: ResticFile = {
    path: entry.path,
    blobs: entry.blobs ?? [],
    size: entry.size ?? 0,
  };
  const name = sanitizeFileName(entry.path.split("/").pop() || "download");
  setBrowserStatus(`Downloading ${name}...`);

  const picker = (
    window as unknown as {
      showSaveFilePicker?: (options: { suggestedName: string }) => Promise<FileHandle>;
    }
  ).showSaveFilePicker;

  try {
    if (picker) {
      const handle = await picker.call(window, { suggestedName: name });
      const writable = await handle.createWritable();
      try {
        for await (const chunk of repository.readFileChunks(file)) {
          await writable.write(chunk);
        }
        await writable.close();
      } catch (error) {
        await writable.abort?.().catch(() => undefined);
        throw error;
      }
    } else {
      if (file.size !== undefined && file.size > MAX_BUFFERED_DOWNLOAD) {
        setBrowserStatus(
          `This file is ${formatBytes(file.size)}. The browser download fallback is limited to ${
            formatBytes(MAX_BUFFERED_DOWNLOAD)
          }; open this page in Chrome to save files of this size.`,
          "error",
        );
        return;
      }
      if (file.size === undefined || file.size === 0) {
        const chunks: Uint8Array[] = [];
        for await (const chunk of repository.readFileChunks(file)) chunks.push(chunk);
        const blob = new Blob(chunks as BlobPart[]);
        const url = URL.createObjectURL(blob);
        const anchor = document.createElement("a");
        anchor.href = url;
        anchor.download = name;
        anchor.click();
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
      } else {
        const buffer = new Uint8Array(file.size);
        let offset = 0;
        for await (const chunk of repository.readFileChunks(file)) {
          if (offset + chunk.length > buffer.length) {
            throw new Error("file is larger than expected");
          }
          buffer.set(chunk, offset);
          offset += chunk.length;
        }
        if (offset !== buffer.length) throw new Error("file is shorter than expected");
        const url = URL.createObjectURL(new Blob([buffer]));
        const anchor = document.createElement("a");
        anchor.href = url;
        anchor.download = name;
        anchor.click();
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
      }
    }
    setBrowserStatus(`Downloaded ${name}.`, "ok");
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      setBrowserStatus("Download cancelled.");
      return;
    }
    setBrowserStatus(`Download failed: ${errorMessage(error)}`, "error");
  }
}

// --- Restore queue -----------------------------------------------------------
// Walks the selected snapshot and writes every file into a folder the family
// picks. Each file streams through restic blob by blob, so memory stays at one
// blob regardless of total size. Needs a directory handle, which only Chromium
// on the desktop implements; Safari gets the single-file path above.

let restoring = false;
let restoreStop = false;

async function ensureDirectory(
  root: DirectoryHandle,
  segments: string[],
): Promise<DirectoryHandle> {
  let directory = root;
  for (const segment of segments) {
    directory = await directory.getDirectoryHandle(segment, { create: true });
  }
  return directory;
}

async function existingFile(directory: DirectoryHandle, name: string): Promise<File | null> {
  try {
    return await (await directory.getFileHandle(name)).getFile();
  } catch {
    return null; // Missing files are the normal case.
  }
}

async function restoreAll(): Promise<void> {
  const repo = repository;
  const current = snapshot;
  if (!repo || !current) return;
  if (restoring) return;

  const picker = (
    window as unknown as {
      showDirectoryPicker?: (options: {
        mode: string;
        id?: string;
      }) => Promise<DirectoryHandle>;
    }
  ).showDirectoryPicker;
  if (!picker) {
    setRestoreStatus(
      "This browser cannot write into a folder. Use Chrome or Edge on a computer to restore everything; you can still download files one at a time.",
      "error",
    );
    return;
  }

  setRestoreStatus("Reading the file list from R2...");
  let files: ResticFile[];
  try {
    files = await repo.walk(current);
  } catch (error) {
    setRestoreStatus(`Could not read the snapshot: ${errorMessage(error)}`, "error");
    return;
  }
  const totalBytes = files.reduce((sum, file) => sum + (file.size ?? 0), 0);
  if (
    !window.confirm(
      `Restore ${files.length} files (${formatBytes(totalBytes)}) into a folder you choose?\n\n` +
        "Files already there with the same size are skipped; any other file with the same " +
        "name is overwritten. You can stop and run it again.",
    )
  ) {
    setRestoreStatus("");
    return;
  }

  let root: DirectoryHandle;
  try {
    root = await picker.call(window, { mode: "readwrite", id: "recovery-restore" });
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      setRestoreStatus("");
      return;
    }
    setRestoreStatus(`Could not open that folder: ${errorMessage(error)}`, "error");
    return;
  }

  const prefix = commonDirectoryPrefix(files.map((file) => file.path));
  restoring = true;
  restoreStop = false;
  if (restoreButton) restoreButton.disabled = true;
  if (restoreCancelButton) restoreCancelButton.hidden = false;
  setRestoreProgress(0, totalBytes);

  let done = 0;
  let written = 0;
  let skipped = 0;
  let doneBytes = 0;
  let skippedBytes = 0;
  const problems: string[] = [];

  try {
    for (const file of files) {
      if (restoreStop) break;
      if (problems.length >= 20 && written === 0) {
        problems.push("stopping early: nothing has succeeded yet");
        break;
      }
      try {
        const segments = relativeSegments(prefix, file.path);
        const name = segments.pop() ?? "";
        const directory = await ensureDirectory(root, segments);
        const existing = await existingFile(directory, name);
        if (existing && file.size !== undefined && existing.size === file.size) {
          skipped++;
          done++;
          skippedBytes += file.size;
          setRestoreProgress(doneBytes + skippedBytes, totalBytes);
          continue;
        }

        const handle = await directory.getFileHandle(name, { create: true });
        const writable = await handle.createWritable();
        try {
          for await (const chunk of repo.readFileChunks(file)) {
            if (restoreStop) break;
            await writable.write(chunk);
          }
          if (restoreStop) {
            // abort() keeps a pre-existing file; only remove what this run made.
            await writable.abort?.().catch(() => undefined);
            if (existing === null) await directory.removeEntry(name).catch(() => undefined);
            break;
          }
          await writable.close();
        } catch (error) {
          await writable.abort?.().catch(() => undefined);
          throw error;
        }

        written++;
        done++;
        doneBytes += file.size ?? 0;
        setRestoreProgress(doneBytes + skippedBytes, totalBytes);
        setRestoreStatus(
          `${done} of ${files.length} files, ${formatBytes(doneBytes + skippedBytes)} of ${
            formatBytes(totalBytes)
          }...`,
        );
        setBrowserStatus(`Restoring ${segments.length > 0 ? segments.join("/") + "/" : ""}${name}`);
      } catch (error) {
        problems.push(`${file.path}: ${errorMessage(error)}`);
      }
    }
  } finally {
    restoring = false;
    if (restoreButton) restoreButton.disabled = false;
    if (restoreCancelButton) restoreCancelButton.hidden = true;
  }

  const summary = restoreStop
    ? `Stopped: ${written} written (${formatBytes(doneBytes)}), ${skipped} already there.`
    : `Restored ${written} files (${formatBytes(doneBytes)}), skipped ${skipped} already there.`;
  if (problems.length > 0) {
    setRestoreStatus(
      `${summary} ${problems.length} file(s) failed; first: ${problems[0]}`,
      "error",
    );
  } else {
    setRestoreStatus(summary, "ok");
  }
  setBrowserStatus("");
}

async function unlock(password: string): Promise<void> {
  if (!secure) throw new Error("Open this page over HTTPS or on localhost.");
  setStatus("Unlocking...");
  const response = await fetch(new URL("./data-keys.enc", document.baseURI), {
    cache: "no-store",
  });
  if (response.status === 404) {
    throw new Error("No recovery data has been published yet.");
  }
  if (!response.ok) throw new Error(`Could not read the recovery data (HTTP ${response.status}).`);

  const envelope = await response.json();
  const keys = await decryptBlob(envelope, password);
  setStatus("");
  if (gate) gate.hidden = true;
  if (unlockedRoot) unlockedRoot.hidden = false;
  if (restoreSection) restoreSection.hidden = false;

  // The account list and the backup are independent; start both together.
  const manifest = loadManifest();
  const repositoryLoad = loadRepository(keys).catch((error: unknown) => {
    repository = null;
    snapshot = null;
    const message = reachHint(errorMessage(error), location.origin);
    setBrowserStatus(`Could not open the backup: ${message}`, "error");
    if (treeList) treeList.innerHTML = treeMessage("The backup could not be opened.", "error");
    if (restoreButton) restoreButton.disabled = true;
  });
  await Promise.all([manifest, repositoryLoad]);
}

function supportsDirectoryPicker(): boolean {
  return (
    typeof (window as unknown as { showDirectoryPicker?: unknown }).showDirectoryPicker ===
      "function"
  );
}

function configureRestore(): void {
  const supported = supportsDirectoryPicker();
  if (restoreButton) restoreButton.hidden = !supported;
  if (restoreHint) {
    restoreHint.textContent = supported
      ? "Files with the same name and size are skipped, so a stopped restore can be run again."
      : "Folder restore needs Chrome or Edge on a computer. You can still download files one at a time.";
  }
}

form?.addEventListener("submit", (event) => {
  event.preventDefault();
  const password = passwordInput?.value ?? "";
  if (!password) return;
  if (unlockButton) {
    unlockButton.disabled = true;
    unlockButton.textContent = "Unlocking...";
  }
  setStatus("Unlocking...");
  unlock(password)
    .catch((error: unknown) => {
      setStatus(errorMessage(error), "error");
    })
    .finally(() => {
      if (unlockButton) {
        unlockButton.disabled = false;
        unlockButton.textContent = "Unlock";
      }
      if (passwordInput) passwordInput.value = "";
    });
});

snapshotSelect?.addEventListener("change", () => {
  if (!repository || !snapshotSelect) return;
  const next = repository.snapshots[Number(snapshotSelect.value)];
  if (next) void selectSnapshot(next);
});

treeList?.addEventListener(
  "toggle",
  (event) => {
    const details = event.target;
    if (!(details instanceof HTMLDetailsElement) || !details.open) return;
    void loadDirectory(details);
  },
  true,
);

treeList?.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-file]");
  if (!target?.dataset.file) return;
  const entry = entriesByPath.get(target.dataset.file);
  if (entry) void download(entry);
});

restoreButton?.addEventListener("click", () => {
  void restoreAll();
});

restoreCancelButton?.addEventListener("click", () => {
  restoreStop = true;
  setRestoreStatus("Stopping after the current file...");
});

configureRestore();

if (!secure) {
  if (unlockButton) unlockButton.disabled = true;
  setStatus("Open this page over HTTPS or on localhost. Unlock is disabled.", "error");
} else if ("serviceWorker" in navigator) {
  void navigator.serviceWorker.register(new URL("./sw.js", document.baseURI)).catch(() => {
    // The app works without the offline shell.
  });
}

void (async () => {
  if (!secure) return;
  if (!(await blobExists())) {
    if (unlockButton) unlockButton.disabled = true;
    setStatus("This page is not set up yet: no recovery data has been published.", "error");
    return;
  }
  const fromLink = passwordFromHash(location.hash);
  if (!fromLink) return;
  // Strip the password before the (slow) key derivation, so it never sits
  // in the address bar or in a history entry the next person can read.
  history.replaceState(null, "", location.pathname + location.search);
  setStatus("Opening the link from the letter...");
  try {
    await unlock(fromLink);
  } catch (error) {
    setStatus(
      `That link did not unlock the page: ${
        errorMessage(error)
      }. Type the recovery password from the letter instead.`,
      "error",
    );
  }
})();
