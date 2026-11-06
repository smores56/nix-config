import { decryptBlob, type DataKeys } from "./blob.ts";
import { decryptBitwardenExport, type BitwardenExport } from "./bitwarden/export.ts";
import { matchVault, plaintextExport } from "./bitwarden/dashboard.ts";
import { sanitizeFileName } from "./filenames.ts";
import { commonDirectoryPrefix, relativeSegments } from "./restore.ts";
import {
  renderManifest,
  validateManifest,
  type FamilyAccessManifest,
  type MatchedItem,
} from "./manifest.ts";
import { R2Backend, repositoryPrefix } from "./restic/r2.ts";
import {
  openRepository,
  type ResticDirEntry,
  type ResticFile,
  type ResticRepository,
  type ResticSnapshot,
} from "./restic/repository.ts";

const form = document.querySelector<HTMLFormElement>("#unlock-form");
const passwordInput = document.querySelector<HTMLInputElement>("#pwa-password");
const unlockButton = document.querySelector<HTMLButtonElement>("#unlock-button");
const lockButton = document.querySelector<HTMLButtonElement>("#lock-button");
const status = document.querySelector<HTMLDivElement>("#status");
const manifestRoot = document.querySelector<HTMLElement>("#manifest");
const restoreSection = document.querySelector<HTMLElement>("#restore");
const snapshotSelect = document.querySelector<HTMLSelectElement>("#snapshot-select");
const breadcrumbs = document.querySelector<HTMLElement>("#breadcrumbs");
const browserStatus = document.querySelector<HTMLDivElement>("#browser-status");
const browserList = document.querySelector<HTMLUListElement>("#browser");
const restoreButton = document.querySelector<HTMLButtonElement>("#restore-all");
const restoreCancelButton = document.querySelector<HTMLButtonElement>("#restore-cancel");
const restoreStatus = document.querySelector<HTMLDivElement>("#restore-status");
const restoreProgress = document.querySelector<HTMLProgressElement>("#restore-progress");
const exportForm = document.querySelector<HTMLFormElement>("#export-form");
const exportFile = document.querySelector<HTMLInputElement>("#export-file");
const exportPassword = document.querySelector<HTMLInputElement>("#export-password");
const exportButton = document.querySelector<HTMLButtonElement>("#export-button");
const exportStatus = document.querySelector<HTMLDivElement>("#export-status");

const secure = window.isSecureContext;
let dataKeys: DataKeys | null = null;
let repository: ResticRepository | null = null;
let snapshot: ResticSnapshot | null = null;
let currentPath = "";
let entriesByPath = new Map<string, ResticDirEntry>();
let manifestCache: FamilyAccessManifest | null = null;
let matches: Map<string, MatchedItem> | null = null;
let idleTimer: number | undefined;

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

function setExportStatus(
  message: string,
  tone: "info" | "error" | "ok" = "info",
): void {
  if (!exportStatus) return;
  exportStatus.textContent = message;
  exportStatus.dataset.tone = tone;
}

function clearExport(): void {
  matches = null;
  if (exportFile) exportFile.value = "";
  if (exportPassword) exportPassword.value = "";
  setExportStatus("");
  if (manifestCache && manifestRoot) {
    manifestRoot.innerHTML = renderManifest(manifestCache);
  }
}

function clearIdle(): void {
  if (idleTimer !== undefined) {
    clearTimeout(idleTimer);
    idleTimer = undefined;
  }
}

function scheduleIdle(): void {
  clearIdle();
  if (restoring) return;
  if (dataKeys || matches) idleTimer = window.setTimeout(lock, 5 * 60_000);
}

function refreshLockButton(): void {
  if (lockButton) lockButton.hidden = !(dataKeys || matches);
}

function clearRestore(): void {
  repository = null;
  snapshot = null;
  currentPath = "";
  entriesByPath = new Map();
  if (restoreSection) restoreSection.hidden = true;
  if (snapshotSelect) snapshotSelect.innerHTML = "";
  if (breadcrumbs) breadcrumbs.innerHTML = "";
  if (browserList) browserList.innerHTML = "";
  if (browserStatus) browserStatus.textContent = "";
  if (restoreStatus) restoreStatus.textContent = "";
  if (restoreProgress) {
    restoreProgress.hidden = true;
    restoreProgress.value = 0;
  }
}

function lock(): void {
  dataKeys = null;
  clearIdle();
  clearRestore();
  clearExport();
  if (passwordInput) passwordInput.value = "";
  refreshLockButton();
  setStatus("Locked. The password, keys, and export were cleared from this page.");
}

async function loadManifest(): Promise<boolean> {
  if (!manifestRoot) return false;
  try {
    const response = await fetch(new URL("./manifest.json", document.baseURI), {
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`manifest HTTP ${response.status}`);
    const manifest = (await response.json()) as FamilyAccessManifest;
    const errors = validateManifest(manifest);
    if (errors.length > 0) throw new Error(errors.join(", "));
    manifestCache = manifest;
    manifestRoot.innerHTML = renderManifest(manifest, matches ?? undefined);
    return true;
  } catch (error) {
    manifestRoot.innerHTML = "";
    setStatus(`The access manifest could not be loaded: ${errorMessage(error)}`, "error");
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

function renderSnapshots(snapshots: ResticSnapshot[]): void {
  if (!snapshotSelect) return;
  snapshotSelect.innerHTML = snapshots
    .map((item, index) => {
      const context = [item.hostname, item.tags?.join(", "), item.paths.join(", ")]
        .filter(Boolean)
        .join(" | ");
      const label = `${item.time} - ${item.id.slice(0, 8)}${context ? ` - ${context}` : ""}`;
      return `<option value="${index}">${escapeHtml(label)}</option>`;
    })
    .join("");
}

async function loadRepository(keys: DataKeys): Promise<void> {
  setBrowserStatus("Opening the restic repository...");
  const prefix = repositoryPrefix(keys.restic.repository, keys.r2.bucket);
  const backend = new R2Backend({ ...keys.r2, prefix });
  const repo = await openRepository(backend, keys.restic.password);
  repository = repo;
  if (repo.snapshots.length === 0) throw new Error("the restic repository has no snapshots");
  renderSnapshots(repo.snapshots);
  if (restoreSection) restoreSection.hidden = false;
  await selectSnapshot(repo.snapshots[0]);
}

async function selectSnapshot(next: ResticSnapshot): Promise<void> {
  snapshot = next;
  currentPath = "";
  await renderBrowser();
}

function renderBreadcrumbs(): void {
  if (!breadcrumbs) return;
  const segments = currentPath.split("/").filter(Boolean);
  const parts = [
    `<button type="button" class="crumb" data-browse="">root</button>`,
    ...segments.map((segment, index) => {
      const path = segments.slice(0, index + 1).join("/");
      return `<button type="button" class="crumb" data-browse="${escapeHtml(path)}">${escapeHtml(segment)}</button>`;
    }),
  ];
  breadcrumbs.innerHTML = parts.join('<span class="crumb-sep">/</span>');
}

async function renderBrowser(): Promise<void> {
  if (!repository || !snapshot || !browserList) return;
  try {
    const entries = await repository.listDirectory(snapshot, currentPath);
    entriesByPath = new Map(entries.map((entry) => [entry.path, entry]));
    renderBreadcrumbs();
    browserList.innerHTML = entries
      .map((entry) => {
        if (entry.type === "dir") {
          return `<li class="item"><div class="item-row"><button type="button" class="link-button" data-dir="${escapeHtml(entry.path)}">${escapeHtml(entry.name)}/</button></div></li>`;
        }
        return `<li class="item"><div class="item-row"><span>${escapeHtml(entry.name)}</span><span class="item-meta">${formatBytes(entry.size)}</span><button type="button" data-file="${escapeHtml(entry.path)}">Download</button></div></li>`;
      })
      .join("");
    setBrowserStatus(`${entries.length} entries in ${currentPath || "the snapshot root"}.`);
  } catch (error) {
    entriesByPath.clear();
    browserList.innerHTML = "";
    setBrowserStatus(`Could not list this folder: ${errorMessage(error)}`, "error");
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
      for await (const chunk of repository.readFileChunks(file)) {
        await writable.write(chunk);
      }
      await writable.close();
    } else {
      if (file.size !== undefined && file.size > MAX_BUFFERED_DOWNLOAD) {
        setBrowserStatus(
          `This file is ${formatBytes(file.size)}. The browser download fallback is limited to ${formatBytes(MAX_BUFFERED_DOWNLOAD)}; use Chrome with the save picker or the Mac CLI.`,
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
          if (offset + chunk.length > buffer.length) throw new Error("file is larger than expected");
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
      "This browser cannot write into a folder. Open this page in Chrome or Edge on the Mac to restore everything; Safari can still download single files.",
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
        "Files already there with the same size are skipped, so you can stop and run it again.",
    )
  ) {
    setRestoreStatus("");
    return;
  }

  let root: DirectoryHandle;
  try {
    root = await picker.call(window, { mode: "readwrite", id: "family-access-restore" });
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
  clearIdle();
  if (restoreButton) restoreButton.disabled = true;
  if (restoreCancelButton) restoreCancelButton.hidden = false;
  setRestoreProgress(0, totalBytes);

  let done = 0;
  let written = 0;
  let skipped = 0;
  let doneBytes = 0;
  const problems: string[] = [];

  try {
    for (const file of files) {
      if (restoreStop) break;
      const segments = relativeSegments(prefix, file.path);
      const name = segments.pop() ?? "";
      try {
        const directory = await ensureDirectory(root, segments);
        const existing = await existingFile(directory, name);
        if (existing && file.size !== undefined && existing.size === file.size) {
          skipped++;
          done++;
          doneBytes += file.size;
          setRestoreProgress(doneBytes, totalBytes);
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
            await writable.abort?.();
            await directory.removeEntry(name).catch(() => undefined);
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
        setRestoreProgress(doneBytes, totalBytes);
        setRestoreStatus(
          `${done} of ${files.length} files, ${formatBytes(doneBytes)} of ${formatBytes(totalBytes)}...`,
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
    scheduleIdle();
  }

  const summary = restoreStop
    ? `Stopped: ${written} written, ${skipped} already there.`
    : `Restored ${written} files, skipped ${skipped} already there, ${formatBytes(doneBytes)} total.`;
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
  setStatus("Fetching the encrypted data-keys blob...");
  const response = await fetch(new URL("./data-keys.enc", document.baseURI), {
    cache: "no-store",
  });
  if (response.status === 404) {
    throw new Error(
      "No data-keys blob is deployed yet. Run the family-access blob builder and push the result.",
    );
  }
  if (!response.ok) throw new Error(`data-keys HTTP ${response.status}`);

  const envelope = await response.json();
  setStatus("Deriving the key and decrypting in this browser...");
  const keys = await decryptBlob(envelope, password);
  dataKeys = keys;
  refreshLockButton();
  scheduleIdle();
  setStatus("Unlocked. Opening the restic repository...", "ok");
  try {
    await loadRepository(keys);
    setStatus("Unlocked.", "ok");
  } catch (error) {
    const message = errorMessage(error);
    setStatus(`Unlocked, but the restic repository could not be opened: ${message}`, "error");
    setBrowserStatus(`Restic repository error: ${message}`, "error");
  }
}

form?.addEventListener("submit", (event) => {
  event.preventDefault();
  const password = passwordInput?.value ?? "";
  if (!password) return;
  if (unlockButton) unlockButton.disabled = true;
  setStatus("Unlocking...");
  unlock(password)
    .catch((error: unknown) => {
      dataKeys = null;
      clearIdle();
      clearRestore();
      refreshLockButton();
      setStatus(errorMessage(error), "error");
    })
    .finally(() => {
      if (unlockButton) unlockButton.disabled = false;
      if (passwordInput) passwordInput.value = "";
    });
});

lockButton?.addEventListener("click", lock);

const MAX_EXPORT_BYTES = 32 * 1024 * 1024;

exportForm?.addEventListener("submit", (event) => {
  event.preventDefault();
  if (exportButton) exportButton.disabled = true;
  void loadExport().finally(() => {
    if (exportButton) exportButton.disabled = false;
  });
});

async function loadExport(): Promise<void> {
  if (!manifestCache) {
    setExportStatus("The access manifest is not loaded yet.", "error");
    return;
  }
  const file = exportFile?.files?.[0];
  if (!file) {
    setExportStatus("Choose a Bitwarden export file first.", "error");
    return;
  }
  if (file.size > MAX_EXPORT_BYTES) {
    setExportStatus("That export file is too large.", "error");
    return;
  }
  const password = exportPassword?.value ?? "";
  setExportStatus("Reading the export...");
  try {
    const json = await file.text();
    const plain = plaintextExport(json);
    let vault: BitwardenExport;
    if (plain) {
      vault = plain;
    } else {
      if (!password) throw new Error("Enter the export password.");
      setExportStatus("Deriving the export key in this browser...");
      vault = await decryptBitwardenExport(json, password);
    }
    const result = matchVault(manifestCache, vault);
    const issues = [
      ...result.errors.map((issue) => `Error: ${issue}`),
      ...result.warnings.map((issue) => `Warning: ${issue}`),
    ];
    const plaintextNote = plain
      ? ["This export is not password protected; treat the file as the secret."]
      : [];
    if (result.errors.length > 0) {
      // Do not show credentials next to an item the manifest check rejected.
      matches = null;
      if (manifestRoot) manifestRoot.innerHTML = renderManifest(manifestCache);
      setExportStatus(
        `${result.errors.length} problem(s); credentials are hidden until they are fixed. ${issues.join(" ")}`,
        "error",
      );
    } else {
      matches = result.matches;
      if (manifestRoot) manifestRoot.innerHTML = renderManifest(manifestCache, matches);
      const notes = [...plaintextNote, ...result.warnings];
      if (notes.length > 0) setExportStatus(`Export loaded. ${notes.join(" ")}`, "info");
      else setExportStatus(`Export loaded. ${matches.size} item(s) matched.`, "ok");
    }
    refreshLockButton();
    scheduleIdle();
  } catch (error) {
    matches = null;
    if (manifestRoot) manifestRoot.innerHTML = renderManifest(manifestCache);
    setExportStatus(`Could not read the export: ${errorMessage(error)}`, "error");
  } finally {
    if (exportPassword) exportPassword.value = "";
  }
}

snapshotSelect?.addEventListener("change", () => {
  if (!repository || !snapshotSelect) return;
  const next = repository.snapshots[Number(snapshotSelect.value)];
  if (next) void selectSnapshot(next);
});

breadcrumbs?.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-browse]");
  if (!target) return;
  currentPath = target.dataset.browse ?? "";
  void renderBrowser();
});

browserList?.addEventListener("click", (event) => {
  const target = event.target as HTMLElement;
  const directory = target.closest<HTMLElement>("[data-dir]");
  if (directory) {
    currentPath = directory.dataset.dir ?? "";
    void renderBrowser();
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

for (const event of ["pointerdown", "keydown"] as const) {
  document.addEventListener(event, scheduleIdle, { passive: true });
}

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    clearIdle();
    // A running restore keeps its keys: it writes plaintext the user asked for,
    // and a two-hour job must not die because the tab was backgrounded.
    if (!restoring && (dataKeys || matches)) idleTimer = window.setTimeout(lock, 30_000);
  } else {
    scheduleIdle();
  }
});

window.addEventListener("pagehide", () => {
  if (dataKeys || matches) lock();
});

if (!secure) {
  if (unlockButton) unlockButton.disabled = true;
  if (exportButton) exportButton.disabled = true;
  setStatus("Open this page over HTTPS or on localhost. Unlock is disabled.", "error");
  setExportStatus("Open this page over HTTPS or on localhost to load an export.", "error");
} else if ("serviceWorker" in navigator) {
  void navigator.serviceWorker.register(new URL("./sw.js", document.baseURI)).catch(() => {
    // The app works without the offline shell.
  });
}

void (async () => {
  const manifestOk = await loadManifest();
  if (!manifestOk || !secure) return;
  if (await blobExists()) {
    setStatus("The data-keys blob is deployed. Enter the PWA password to unlock.");
  } else {
    setStatus(
      "No data-keys blob is deployed yet. The access manifest is still available; data restore will work after the blob is generated.",
    );
  }
})();
