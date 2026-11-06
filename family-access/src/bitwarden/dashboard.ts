import type { BitwardenExport, BitwardenItem } from "./export";
import type {
  FamilyAccessItem,
  FamilyAccessManifest,
  FamilyAccessItemType,
  MatchedItem,
} from "../manifest";

const TYPE_NAMES: Record<number, FamilyAccessItemType> = {
  1: "login",
  2: "note",
  3: "card",
  4: "identity",
};

const FA_ID_FIELD = "fa_id";

export type MatchResult = {
  matches: Map<string, MatchedItem>;
  errors: string[];
  warnings: string[];
};

export function plaintextExport(json: string): BitwardenExport | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return null;
  }
  if (
    typeof parsed === "object" &&
    parsed !== null &&
    !Array.isArray(parsed) &&
    Array.isArray((parsed as { items?: unknown }).items) &&
    (parsed as { encrypted?: unknown }).encrypted !== true
  ) {
    return parsed as BitwardenExport;
  }
  return null;
}

export function itemFaId(item: BitwardenItem): string | undefined {
  const field = (item.fields ?? []).find(
    (candidate) => candidate.name?.trim().toLowerCase() === FA_ID_FIELD,
  );
  const value = field?.value?.trim();
  return value ? value : undefined;
}

export function deepLink(vaultUrl: string, itemId: string): string {
  const base = vaultUrl.replace(/\/+$/, "");
  return `${base}/#/vault?itemId=${encodeURIComponent(itemId)}`;
}

function itemType(item: BitwardenItem): FamilyAccessItemType | undefined {
  return TYPE_NAMES[item.type];
}

function folderName(vault: BitwardenExport, folderId: string | null | undefined): string | undefined {
  if (!folderId) return undefined;
  return vault.folders?.find((folder) => folder.id === folderId)?.name;
}

function httpUris(item: BitwardenItem): string[] {
  return (item.login?.uris ?? [])
    .map((entry) => entry.uri)
    .filter((uri): uri is string => {
      if (typeof uri !== "string") return false;
      try {
        const parsed = new URL(uri);
        return parsed.protocol === "http:" || parsed.protocol === "https:";
      } catch {
        return false;
      }
    });
}

function matchedItem(
  vault: BitwardenExport,
  item: BitwardenItem,
  vaultUrl: string,
): MatchedItem {
  return {
    id: item.id,
    name: item.name,
    username: item.login?.username ?? undefined,
    password: item.login?.password ?? undefined,
    totp: item.login?.totp ?? undefined,
    notes: item.notes ?? undefined,
    uris: httpUris(item),
    fields: (item.fields ?? [])
      .filter((field) => field.name?.trim().toLowerCase() !== FA_ID_FIELD)
      .map((field) => ({ name: field.name, value: field.value })),
    folder: folderName(vault, item.folderId),
    deepLink: deepLink(vaultUrl, item.id),
  };
}

export function matchVault(
  manifest: FamilyAccessManifest,
  vault: BitwardenExport,
): MatchResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  const matches = new Map<string, MatchedItem>();

  const byFaId = new Map<string, BitwardenItem[]>();
  for (const item of vault.items) {
    const faId = itemFaId(item);
    if (!faId) continue;
    byFaId.set(faId, [...(byFaId.get(faId) ?? []), item]);
  }
  for (const [faId, items] of byFaId) {
    if (items.length > 1) {
      errors.push(
        `fa_id "${faId}" is used by ${items.length} Bitwarden items: ${items
          .map((item) => item.name)
          .join(", ")}`,
      );
    }
  }

  const vaultUrl = manifest.vaultUrl ?? "https://vault.bitwarden.com";
  const manifestFaIds = new Set<string>();

  for (const section of manifest.sections) {
    for (const entry of section.items) {
      manifestFaIds.add(entry.faId);
      const byFa = byFaId.get(entry.faId)?.[0];
      const byUuid = entry.bitwardenUuid
        ? vault.items.find((item) => item.id === entry.bitwardenUuid)
        : undefined;

      if (byFa && byUuid && byFa.id !== byUuid.id) {
        errors.push(
          `"${entry.faId}": fa_id points to ${byFa.id} but the manifest UUID is ${byUuid.id}`,
        );
        continue;
      }
      const item = byUuid ?? byFa;
      if (!item) {
        if (entry.required) errors.push(`required item "${entry.faId}" is missing`);
        else warnings.push(`optional item "${entry.faId}" is missing`);
        continue;
      }

      checkItem(entry, item, vault, byFaId, errors, warnings);
      matches.set(entry.faId, matchedItem(vault, item, vaultUrl));
    }
  }

  for (const faId of byFaId.keys()) {
    if (!manifestFaIds.has(faId)) warnings.push(`Bitwarden item has unused fa_id "${faId}"`);
  }

  return { matches, errors, warnings };
}

function checkItem(
  entry: FamilyAccessItem,
  item: BitwardenItem,
  vault: BitwardenExport,
  byFaId: Map<string, BitwardenItem[]>,
  errors: string[],
  warnings: string[],
): void {
  const faId = entry.faId;
  if (entry.bitwardenUuid && item.id !== entry.bitwardenUuid) {
    errors.push(
      `"${faId}": Bitwarden UUID changed (expected ${entry.bitwardenUuid}, found ${item.id}); the item was likely deleted and recreated`,
    );
  }
  if (byFaId.get(faId)?.length === 1 && byFaId.get(faId)?.[0].id !== item.id) {
    errors.push(`"${faId}": fa_id and UUID point to different items`);
  }
  if (item.name !== entry.bitwardenName) {
    warnings.push(`"${faId}": Bitwarden name is "${item.name}", manifest says "${entry.bitwardenName}"`);
  }
  if (!itemFaId(item)) {
    warnings.push(`"${faId}": matched by UUID but the item has no fa_id field`);
  }
  if (entry.type) {
    const actual = itemType(item);
    if (actual !== entry.type) {
      errors.push(`"${faId}": expected a ${entry.type} item, found ${actual ?? "unknown"}`);
    }
  }
  if (entry.folder) {
    const actual = folderName(vault, item.folderId);
    if (actual !== entry.folder) {
      errors.push(
        `"${faId}": expected folder "${entry.folder}", found ${actual ? `"${actual}"` : "no folder"}`,
      );
    }
  }
}
