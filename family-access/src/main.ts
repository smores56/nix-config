import { decryptBlob, type DataKeys } from "./blob";
import { renderManifest, validateManifest, type FamilyAccessManifest } from "./manifest";

const form = document.querySelector<HTMLFormElement>("#unlock-form");
const passwordInput = document.querySelector<HTMLInputElement>("#pwa-password");
const unlockButton = document.querySelector<HTMLButtonElement>("#unlock-button");
const lockButton = document.querySelector<HTMLButtonElement>("#lock-button");
const status = document.querySelector<HTMLDivElement>("#status");
const manifestRoot = document.querySelector<HTMLElement>("#manifest");

const secure = window.isSecureContext;
let dataKeys: DataKeys | null = null;
let idleTimer: number | undefined;

function setStatus(message: string, tone: "info" | "error" | "ok" = "info"): void {
  if (!status) return;
  status.textContent = message;
  status.dataset.tone = tone;
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

function lock(): void {
  dataKeys = null;
  clearIdle();
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
    setStatus(
      `The access manifest could not be loaded: ${error instanceof Error ? error.message : "unknown error"}`,
      "error",
    );
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
  setStatus("Unlocked.", "ok");
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
      if (lockButton) lockButton.hidden = true;
      setStatus(
        error instanceof Error ? error.message : "Unable to unlock the data keys.",
        "error",
      );
    })
    .finally(() => {
      if (unlockButton) unlockButton.disabled = false;
      if (passwordInput) passwordInput.value = "";
    });
});

lockButton?.addEventListener("click", lock);

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

window.addEventListener("pagehide", lock);

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
