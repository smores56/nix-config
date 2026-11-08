import { zip } from "fflate";
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
const footerBackup = document.querySelector<HTMLTimeElement>("#footer-backup");
const footerUpdated = document.querySelector<HTMLTimeElement>("#footer-updated");
const browserStatus = document.querySelector<HTMLDivElement>("#browser-status");
const treeList = document.querySelector<HTMLUListElement>("#browser");
const treeWrap = document.querySelector<HTMLElement>(".tree-wrap");
const restoreButton = document.querySelector<HTMLButtonElement>("#restore-all");
const restoreCancelButton = document.querySelector<HTMLButtonElement>("#restore-cancel");
const restoreStatus = document.querySelector<HTMLDivElement>("#restore-status");
const restoreProgress = document.querySelector<HTMLProgressElement>("#restore-progress");
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

function setRestoreIndeterminate(): void {
  if (!restoreProgress) return;
  restoreProgress.hidden = false;
  restoreProgress.removeAttribute("value");
}

async function loadManifest(): Promise<RecoveryManifest | null> {
  if (!manifestRoot) return null;
  try {
    const response = await fetch(new URL("./manifest.json", document.baseURI), {
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`manifest HTTP ${response.status}`);
    const manifest = (await response.json()) as RecoveryManifest;
    const errors = validateManifest(manifest);
    if (errors.length > 0) throw new Error(errors.join(", "));
    manifestRoot.innerHTML = renderManifest(manifest);
    return manifest;
  } catch (error) {
    manifestRoot.innerHTML =
      `<section class="notice" role="note"><p class="notice-title">Accounts</p><p>The account list could not be loaded: ${
        escapeHtml(errorMessage(error))
      }.</p></section>`;
    return null;
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
  const latest = repo.snapshots[0];
  snapshot = latest;
  if (footerBackup) {
    footerBackup.textContent = snapshotTime(latest.time);
    footerBackup.dateTime = latest.time;
  }
  entriesByPath = new Map();
  await renderTree();
  setBrowserStatus("");
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
        const download = `<button type="button" class="folder-download" data-dir-download="${
          escapeHtml(entry.path)
        }" aria-label="Download ${escapeHtml(entry.name)} folder">Download</button>`;
        return `<li class="tree-dir"><details data-path="${escapeHtml(entry.path)}">
  <summary><span class="tree-name">${escapeHtml(entry.name)}/</span>${download}</summary>
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
const MAX_ZIP_BYTES = 256 * 1024 * 1024;

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
// Walks the latest snapshot (or just one folder of it) and writes the files
// into a folder the family picks. Each file streams through restic blob by blob,
// so memory stays at one blob regardless of total size. Needs a directory
// handle, which only Chromium on the desktop implements; Safari gets the
// single-file path above.

let restoring = false;
let restoreBusy = false;
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

async function pickRestoreRoot(): Promise<DirectoryHandle | null> {
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
      "This browser cannot write into a folder. Use Chrome or Edge on a computer to restore folders; you can still download files one at a time.",
      "error",
    );
    return null;
  }
  try {
    return await picker.call(window, { mode: "readwrite", id: "recovery-restore" });
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      setRestoreStatus("");
      return null;
    }
    setRestoreStatus(`Could not open that folder: ${errorMessage(error)}`, "error");
    return null;
  }
}

async function restoreInto(
  root: DirectoryHandle,
  files: AsyncIterable<ResticFile>,
  prefix: string,
): Promise<void> {
  const repo = repository;
  if (!repo) return;
  restoring = true;
  restoreStop = false;
  if (restoreButton) restoreButton.disabled = true;
  if (restoreCancelButton) restoreCancelButton.hidden = false;
  setRestoreIndeterminate();
  setRestoreStatus("Starting download...");

  let done = 0;
  let written = 0;
  let skipped = 0;
  let doneBytes = 0;
  const problems: string[] = [];

  try {
    for await (const file of files) {
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
          setRestoreStatus(`${done} files checked, ${skipped} already there...`);
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
        setRestoreStatus(
          `${written} files downloaded (${formatBytes(doneBytes)}), ${skipped} already there...`,
        );
        setBrowserStatus(
          `Downloading ${segments.length > 0 ? segments.join("/") + "/" : ""}${name}`,
        );
      } catch (error) {
        problems.push(`${file.path}: ${errorMessage(error)}`);
      }
    }
  } catch (error) {
    problems.push(`could not read the backup: ${errorMessage(error)}`);
  } finally {
    restoring = false;
    if (restoreButton) restoreButton.disabled = false;
    if (restoreCancelButton) restoreCancelButton.hidden = true;
    if (restoreProgress) {
      restoreProgress.hidden = true;
      restoreProgress.value = 0;
    }
  }

  const summaryBytes = formatBytes(doneBytes);
  const summary = restoreStop
    ? `Stopped: ${written} files downloaded (${summaryBytes}), ${skipped} already there.`
    : `Downloaded ${written} files (${summaryBytes}), skipped ${skipped} already there.`;
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

async function restoreAll(): Promise<void> {
  const repo = repository;
  const current = snapshot;
  if (!repo || !current || restoreBusy || restoring) return;
  if (!supportsDirectoryPicker()) {
    setRestoreStatus(
      "Saving to a folder needs Chrome or Edge. This browser can download one folder as a zip.",
      "error",
    );
    return;
  }
  restoreBusy = true;
  try {
    if (
      !window.confirm(
        "Download all backup files into a folder you choose?\n\n" +
          "Files already there with the same size are skipped; any other file with the same " +
          "name is overwritten. You can stop and run it again.",
      )
    ) {
      setRestoreStatus("");
      return;
    }
    const root = await pickRestoreRoot();
    if (!root) return;
    await restoreInto(root, repo.walkFiles(current, browseRoot), browseRoot);
  } finally {
    restoreBusy = false;
  }
}

async function restoreFolder(folderPath: string): Promise<void> {
  const repo = repository;
  const current = snapshot;
  if (!repo || !current || restoreBusy || restoring) return;
  if (!supportsDirectoryPicker()) {
    setRestoreStatus(
      "Saving to a folder needs Chrome or Edge. This browser can download this folder as a zip.",
      "error",
    );
    return;
  }
  const name = folderPath.split("/").pop() || folderPath;
  restoreBusy = true;
  try {
    if (
      !window.confirm(
        `Download the ${name}/ folder into a folder you choose?\n\n` +
          "Files already there with the same size are skipped; any other file with the same " +
          "name is overwritten. You can stop and run it again.",
      )
    ) {
      setRestoreStatus("");
      return;
    }
    const root = await pickRestoreRoot();
    if (!root) return;
    const parent = folderPath.split("/").slice(0, -1).join("/");
    await restoreInto(root, repo.walkFiles(current, folderPath), parent);
  } finally {
    restoreBusy = false;
  }
}
function concatenateChunks(chunks: Uint8Array[]): Uint8Array {
  const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const data = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    data.set(chunk, offset);
    offset += chunk.length;
  }
  return data;
}

function zipFiles(entries: Record<string, Uint8Array>): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    zip(entries, { level: 0 }, (error, data) => {
      if (error) reject(error);
      else resolve(data);
    });
  });
}

async function downloadFolderZip(folderPath: string): Promise<void> {
  const repo = repository;
  const current = snapshot;
  if (!repo || !current || restoreBusy || restoring) return;
  restoreBusy = true;
  const name = folderPath.split("/").pop() || folderPath;
  try {
    const prefix = folderPath.split("/").slice(0, -1).join("/");
    const entries: Record<string, Uint8Array> = {};
    let done = 0;
    let totalBytes = 0;
    for await (const file of repo.walkFiles(current, folderPath)) {
      if (file.size !== undefined) {
        totalBytes += file.size;
        if (totalBytes > MAX_ZIP_BYTES) {
          setRestoreStatus(
            `This folder is over ${
              formatBytes(MAX_ZIP_BYTES)
            }. The browser zip download is capped; use Chrome or Edge to save it directly.`,
            "error",
          );
          return;
        }
      }
      const path = relativeSegments(prefix, file.path).join("/");
      const chunks: Uint8Array[] = [];
      for await (const chunk of repo.readFileChunks(file)) chunks.push(chunk);
      entries[path] = concatenateChunks(chunks);
      done++;
      if (done === 1 || done % 10 === 0) {
        setRestoreStatus(
          `Building ${name}.zip... ${done} files, ${formatBytes(totalBytes)}`,
        );
      }
    }
    if (done === 0) {
      setRestoreStatus(`There are no files in ${name}/.`, "error");
      return;
    }
    setRestoreStatus(`Compressing ${name}.zip...`);
    const zipped = await zipFiles(entries);
    for (const key of Object.keys(entries)) delete entries[key];
    const url = URL.createObjectURL(
      new Blob([zipped.buffer as ArrayBuffer], { type: "application/zip" }),
    );
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `${sanitizeFileName(name)}.zip`;
    anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
    setRestoreStatus(`Downloaded ${name}.zip.`, "ok");
  } catch (error) {
    setRestoreStatus(`Folder download failed: ${errorMessage(error)}`, "error");
  } finally {
    restoreBusy = false;
  }
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
  gate?.remove();
  if (unlockedRoot) unlockedRoot.hidden = false;
  if (restoreSection) restoreSection.hidden = false;

  // The account list and the backup are independent; start both together.
  const manifestLoad = loadManifest().then((manifest) => {
    if (!footerUpdated) return;
    footerUpdated.textContent = manifest?.updated ?? "unknown";
    if (manifest) footerUpdated.dateTime = manifest.updated;
  });
  const repositoryLoad = loadRepository(keys).catch((error: unknown) => {
    repository = null;
    snapshot = null;
    const message = reachHint(errorMessage(error), location.origin);
    setBrowserStatus(`Could not open the backup: ${message}`, "error");
    if (treeList) treeList.innerHTML = treeMessage("The backup could not be opened.", "error");
    if (footerBackup) footerBackup.textContent = "unavailable";
    if (restoreButton) restoreButton.disabled = true;
  });
  await Promise.all([manifestLoad, repositoryLoad]);
}

function supportsDirectoryPicker(): boolean {
  return (
    typeof (window as unknown as { showDirectoryPicker?: unknown }).showDirectoryPicker ===
      "function"
  );
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

treeList?.addEventListener(
  "toggle",
  (event) => {
    const details = event.target;
    if (!(details instanceof HTMLDetailsElement)) return;
    if (!details.open) return;
    void loadDirectory(details);
  },
  true,
);

treeList?.addEventListener("click", (event) => {
  const target = event.target as HTMLElement;
  const folder = target.closest<HTMLElement>("[data-dir-download]");
  if (folder?.dataset.dirDownload) {
    event.preventDefault();
    event.stopPropagation();
    const path = folder.dataset.dirDownload;
    if (supportsDirectoryPicker()) void restoreFolder(path);
    else void downloadFolderZip(path);
    return;
  }
  const file = target.closest<HTMLElement>("[data-file]");
  if (!file?.dataset.file) return;
  const entry = entriesByPath.get(file.dataset.file);
  if (entry) void download(entry);
});

restoreButton?.addEventListener("click", () => {
  void restoreAll();
});

restoreCancelButton?.addEventListener("click", () => {
  restoreStop = true;
  setRestoreStatus("Stopping after the current file...");
});

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
