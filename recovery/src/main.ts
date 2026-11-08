import { type DataKeys, decryptBlob } from "./blob.ts";
import { sanitizeFileName, uniqueFileName } from "./filenames.ts";
import { reachHint } from "./hint.ts";
import { commonDirectoryPrefix, dataRoot, relativeSegments } from "./restore.ts";
import { passwordFromHash } from "./link.ts";
import { escapeHtml, type RecoveryManifest, renderManifest, validateManifest } from "./manifest.ts";
import { R2Backend, repositoryPrefix } from "./restic/r2.ts";
import {
  openRepository,
  type ResticDirEntry,
  type ResticFile,
  type ResticRepository,
  type ResticSnapshot,
} from "./restic/repository.ts";
import { streamZip } from "./zip.ts";

const gate = document.querySelector<HTMLElement>("#gate");
const form = document.querySelector<HTMLFormElement>("#unlock-form");
const passwordInput = document.querySelector<HTMLInputElement>("#recovery-password");
const unlockButton = document.querySelector<HTMLButtonElement>("#unlock-button");
const status = document.querySelector<HTMLDivElement>("#status");
const manifestRoot = document.querySelector<HTMLElement>("#manifest");
const restoreSection = document.querySelector<HTMLElement>("#restore");
const footerBackup = document.querySelector<HTMLElement>("#footer-backup");
const footerUpdated = document.querySelector<HTMLTimeElement>("#footer-updated");
const treeList = document.querySelector<HTMLUListElement>("#browser");
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

function formatBytes(bytes: number | undefined): string {
  if (bytes === undefined) return "";
  if (bytes < 1000) return `${bytes} B`;
  if (bytes < 1_000_000) return `${(bytes / 1000).toFixed(1)} KB`;
  if (bytes < 1_000_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  return `${(bytes / 1_000_000_000).toFixed(1)} GB`;
}

function setStatus(message: string, tone: "info" | "error" | "ok" = "info"): void {
  if (!status) return;
  status.textContent = message;
  status.dataset.tone = tone;
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

function isBusy(): boolean {
  if (restoreBusy || restoring || downloading) {
    setRestoreStatus("Another download is already running; wait for it to finish.", "error");
    return true;
  }
  return false;
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

function parseDateTime(value: string): Date {
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (dateOnly) {
    return new Date(Number(dateOnly[1]), Number(dateOnly[2]) - 1, Number(dateOnly[3]));
  }
  return new Date(value);
}

function formatDateTime(value: string): string {
  const date = parseDateTime(value);
  if (Number.isNaN(date.getTime())) return value.slice(0, 16).replace("T", " ");
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return date.toLocaleDateString(undefined, { dateStyle: "medium" });
  }
  return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

async function loadRepository(keys: DataKeys): Promise<void> {
  setRestoreStatus("Opening the backup...");
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
    footerBackup.textContent = formatDateTime(latest.time);
  }
  const estimate = latest.summary?.total_bytes_processed;
  if (restoreButton) {
    restoreButton.textContent = estimate !== undefined && estimate > 0
      ? `Download all (${formatBytes(estimate)})`
      : "Download all";
    restoreButton.disabled = !supportsDirectoryPicker();
  }
  entriesByPath = new Map();
  await renderTree();
  setRestoreStatus("");
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
const FOLDER_PICKER_HELP =
  "Saving to a folder needs Chrome, Edge, or Brave with File System Access enabled (brave://flags/#file-system-access-api).";
const SKIP_EXISTING_NOTE =
  "Files already there with the same size are skipped; any other file with the same " +
  "name is overwritten. You can stop and run it again.";

async function download(entry: ResticDirEntry): Promise<void> {
  if (!repository || isBusy()) return;
  downloading = true;
  const file: ResticFile = {
    path: entry.path,
    blobs: entry.blobs ?? [],
    size: entry.size ?? 0,
  };
  const name = sanitizeFileName(entry.path.split("/").pop() || "download");

  const picker = (
    window as unknown as {
      showSaveFilePicker?: (options: { suggestedName: string }) => Promise<FileHandle>;
    }
  ).showSaveFilePicker;

  setRestoreStatus(picker ? `Choose where to save ${name}...` : `Downloading ${name}...`);

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
        setRestoreStatus(
          `This file is ${formatBytes(file.size)}. The browser download fallback is limited to ${
            formatBytes(MAX_BUFFERED_DOWNLOAD)
          }; open this page in Chrome to save files of this size.`,
          "error",
        );
        return;
      }
      if (file.size === undefined || file.size === 0) {
        const chunks: Uint8Array[] = [];
        let buffered = 0;
        for await (const chunk of repository.readFileChunks(file)) {
          buffered += chunk.length;
          if (buffered > MAX_BUFFERED_DOWNLOAD) {
            throw new Error(
              `file is larger than the ${
                formatBytes(MAX_BUFFERED_DOWNLOAD)
              } browser download limit; open this page in Chrome to save it`,
            );
          }
          chunks.push(chunk);
        }
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
    setRestoreStatus(`Downloaded ${name}.`, "ok");
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      setRestoreStatus("Download cancelled.");
      return;
    }
    setRestoreStatus(`Download failed: ${errorMessage(error)}`, "error");
  } finally {
    downloading = false;
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
let downloading = false;
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
  } catch (error) {
    // Only a genuinely missing file means this run creates it; any other error
    // must not make Stop delete a file that was already there.
    if (error instanceof Error && error.name === "NotFoundError") return null;
    throw error;
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
      `${FOLDER_PICKER_HELP} You can still download files one at a time.`,
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

  const MAX_CONSECUTIVE_FAILURES = 20;
  let done = 0;
  let written = 0;
  let skipped = 0;
  let doneBytes = 0;
  let failures = 0;
  let consecutiveFailures = 0;
  let lastStatusAt = 0;
  const problems: string[] = [];
  // Sanitized names can collide (a:b and a_b, or two names sharing the first
  // 200 bytes). Claim one output name per directory so a later file is never
  // mistaken for an earlier one by the size-only skip check.
  const claimedByDirectory = new Map<string, Set<string>>();

  const recordFailure = (message: string): void => {
    failures++;
    if (problems.length < 10) problems.push(message);
  };

  const statusThrottled = (message: string): void => {
    const now = performance.now();
    if (now - lastStatusAt < 500) return;
    lastStatusAt = now;
    setRestoreStatus(message);
  };

  try {
    for await (const file of files) {
      if (restoreStop) break;
      try {
        const segments = relativeSegments(prefix, file.path);
        const directoryKey = segments.join("/");
        let claimed = claimedByDirectory.get(directoryKey);
        if (!claimed) {
          claimed = new Set();
          claimedByDirectory.set(directoryKey, claimed);
        }
        const name = uniqueFileName(claimed, segments.pop() ?? "");
        const displayPath = `${segments.length > 0 ? segments.join("/") + "/" : ""}${name}`;
        const directory = await ensureDirectory(root, segments);
        const existing = await existingFile(directory, name);
        // existingFile returns null only for NotFoundError, so only a file this
        // run creates may be removed on stop or failure.
        const created = existing === null;
        if (existing && file.size !== undefined && existing.size === file.size) {
          skipped++;
          done++;
          consecutiveFailures = 0;
          statusThrottled(
            `Checking ${displayPath} — ${done} files checked, ${skipped} already there...`,
          );
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
            if (created) await directory.removeEntry(name).catch(() => undefined);
            break;
          }
          await writable.close();
        } catch (error) {
          await writable.abort?.().catch(() => undefined);
          if (created) await directory.removeEntry(name).catch(() => undefined);
          throw error;
        }

        written++;
        done++;
        doneBytes += file.size ?? 0;
        consecutiveFailures = 0;
        statusThrottled(
          `Downloading ${displayPath} — ${written} files downloaded (${
            formatBytes(doneBytes)
          }), ${skipped} already there...`,
        );
      } catch (error) {
        recordFailure(`${file.path}: ${errorMessage(error)}`);
        consecutiveFailures++;
        if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
          recordFailure(`stopping early: ${MAX_CONSECUTIVE_FAILURES} failures in a row`);
          break;
        }
      }
    }
  } catch (error) {
    recordFailure(`could not read the backup: ${errorMessage(error)}`);
  } finally {
    restoring = false;
    if (restoreButton) restoreButton.disabled = !supportsDirectoryPicker();
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
  if (failures > 0) {
    setRestoreStatus(`${summary} ${failures} file(s) failed; first: ${problems[0]}`, "error");
  } else {
    setRestoreStatus(summary, "ok");
  }
}

async function startStreamingRestore(
  files: AsyncIterable<ResticFile>,
  prefix: string,
  confirmMessage: string,
): Promise<void> {
  const repo = repository;
  if (!repo || isBusy()) return;
  if (!supportsDirectoryPicker()) {
    setRestoreStatus(
      `${FOLDER_PICKER_HELP} Use a folder Download button for a zip instead.`,
      "error",
    );
    return;
  }
  restoreBusy = true;
  try {
    if (!window.confirm(confirmMessage)) {
      setRestoreStatus("");
      return;
    }
    const root = await pickRestoreRoot();
    if (!root) return;
    await restoreInto(root, files, prefix);
  } finally {
    restoreBusy = false;
  }
}

async function restoreAll(): Promise<void> {
  const repo = repository;
  const current = snapshot;
  if (!repo || !current) return;
  await startStreamingRestore(
    repo.walkFiles(current, browseRoot),
    browseRoot,
    "Download all backup files into a folder you choose?\n\n" + SKIP_EXISTING_NOTE,
  );
}

async function restoreFolder(folderPath: string): Promise<void> {
  const repo = repository;
  const current = snapshot;
  if (!repo || !current) return;
  const name = folderPath.split("/").pop() || folderPath;
  const parent = folderPath.split("/").slice(0, -1).join("/");
  await startStreamingRestore(
    repo.walkFiles(current, folderPath),
    parent,
    `Download the ${name}/ folder into a folder you choose?\n\n` + SKIP_EXISTING_NOTE,
  );
}

async function downloadFolderZip(folderPath: string): Promise<void> {
  const repo = repository;
  const current = snapshot;
  if (!repo || !current || isBusy()) return;
  restoreBusy = true;
  const name = folderPath.split("/").pop() || folderPath;
  try {
    const prefix = folderPath.split("/").slice(0, -1).join("/");
    // Same name claim as a direct restore: two restic names that sanitize alike
    // must not overwrite each other inside the archive.
    const claimed = new Set<string>();
    let done = 0;
    let declaredBytes = 0;
    const files = (async function* () {
      for await (const file of repo.walkFiles(current, folderPath)) {
        declaredBytes += file.size ?? 0;
        if (declaredBytes > MAX_ZIP_BYTES) {
          throw new Error(
            `This folder is over ${
              formatBytes(MAX_ZIP_BYTES)
            }; the browser zip fallback is capped. Use Chrome, Edge, or Brave with File System Access enabled to save it directly.`,
          );
        }
        const segments = relativeSegments(prefix, file.path);
        const leaf = uniqueFileName(claimed, segments.pop() ?? "");
        const path = [...segments, leaf].join("/");
        done++;
        if (done === 1 || done % 10 === 0) {
          setRestoreStatus(
            `Building ${name}.zip... ${done} files, ${formatBytes(declaredBytes)}`,
          );
        }
        yield { path, chunks: repo.readFileChunks(file) };
      }
    })();
    const chunks = await streamZip(files, { maxBytes: MAX_ZIP_BYTES });
    if (done === 0) {
      setRestoreStatus(`There are no files in ${name}/.`, "error");
      return;
    }
    const url = URL.createObjectURL(
      new Blob(chunks as BlobPart[], { type: "application/zip" }),
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

  // Start both reads, but render the account header and footer date before revealing
  // the unlocked view so the header does not pop in afterwards.
  const manifestLoad = loadManifest().then((manifest) => {
    if (!footerUpdated) return;
    footerUpdated.textContent = manifest ? formatDateTime(manifest.updated) : "unknown";
    if (manifest) footerUpdated.dateTime = manifest.updated;
  });
  const repositoryLoad = loadRepository(keys).catch((error: unknown) => {
    repository = null;
    snapshot = null;
    const message = reachHint(errorMessage(error), location.origin);
    setRestoreStatus(`Could not open the backup: ${message}`, "error");
    if (treeList) treeList.innerHTML = treeMessage("The backup could not be opened.", "error");
    if (footerBackup) footerBackup.textContent = "unavailable";
    if (restoreButton) {
      restoreButton.textContent = "Download all";
      restoreButton.disabled = true;
    }
  });

  await manifestLoad;
  gate?.remove();
  if (unlockedRoot) unlockedRoot.hidden = false;
  if (restoreSection) restoreSection.hidden = false;
  // The gate held the only live region, so announce the change by moving focus
  // to the account header a keyboard or screen-reader user lands on.
  const heading = manifestRoot?.querySelector<HTMLElement>("h2");
  if (heading) {
    heading.tabIndex = -1;
    heading.focus();
  }
  await repositoryLoad;
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

if (restoreButton) restoreButton.disabled = !supportsDirectoryPicker();

if (!secure) {
  if (unlockButton) unlockButton.disabled = true;
  setStatus("Open this page over HTTPS or on localhost. Unlock is disabled.", "error");
} else if ("serviceWorker" in navigator) {
  void navigator.serviceWorker.register(new URL("./sw.js", document.baseURI)).catch(() => {
    // The app works without the offline shell.
  });
}

void (async () => {
  // Strip the password before anything else, including a network probe or an
  // early return, so it never sits in the address bar or a history entry.
  const fromLink = passwordFromHash(location.hash);
  if (fromLink) history.replaceState(null, "", location.pathname + location.search);
  if (!secure) return;
  if (!(await blobExists())) {
    if (unlockButton) unlockButton.disabled = true;
    setStatus("This page is not set up yet: no recovery data has been published.", "error");
    return;
  }
  if (!fromLink) return;
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
