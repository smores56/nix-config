import { decryptBlob, type DataKeys } from "./blob";
import { sanitizeFileName } from "./filenames";
import { renderManifest, validateManifest, type FamilyAccessManifest } from "./manifest";
import { R2Backend, repositoryPrefix } from "./restic/r2";
import {
  openRepository,
  type ResticDirEntry,
  type ResticFile,
  type ResticRepository,
  type ResticSnapshot,
} from "./restic/repository";

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

const secure = window.isSecureContext;
let dataKeys: DataKeys | null = null;
let repository: ResticRepository | null = null;
let snapshot: ResticSnapshot | null = null;
let currentPath = "";
let entriesByPath = new Map<string, ResticDirEntry>();
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

function clearIdle(): void {
  if (idleTimer !== undefined) {
    clearTimeout(idleTimer);
    idleTimer = undefined;
  }
}

function scheduleIdle(): void {
  clearIdle();
  if (dataKeys) idleTimer = window.setTimeout(lock, 5 * 60_000);
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
}

function lock(): void {
  dataKeys = null;
  clearIdle();
  clearRestore();
  if (passwordInput) passwordInput.value = "";
  if (lockButton) lockButton.hidden = true;
  setStatus("Locked. The password and keys were cleared from this page.");
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
    manifestRoot.innerHTML = renderManifest(manifest);
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
  }>;
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
  if (lockButton) lockButton.hidden = false;
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
      if (lockButton) lockButton.hidden = true;
      setStatus(errorMessage(error), "error");
    })
    .finally(() => {
      if (unlockButton) unlockButton.disabled = false;
      if (passwordInput) passwordInput.value = "";
    });
});

lockButton?.addEventListener("click", lock);

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

for (const event of ["pointerdown", "keydown"] as const) {
  document.addEventListener(event, scheduleIdle, { passive: true });
}

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    clearIdle();
    if (dataKeys) idleTimer = window.setTimeout(lock, 30_000);
  } else {
    scheduleIdle();
  }
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
