import { describe, expect, test } from "bun:test";
import type { BitwardenExport, BitwardenItem } from "./export";
import { matchVault, plaintextExport, itemFaId } from "./dashboard";
import { renderManifest, validateManifest, type FamilyAccessManifest } from "../manifest";

const manifest: FamilyAccessManifest = {
  version: 1,
  updated: "2026-11-06",
  vaultUrl: "https://vault.bitwarden.com",
  sections: [
    {
      id: "accounts",
      title: "Accounts",
      items: [
        {
          faId: "email",
          title: "E-mail",
          bitwardenName: "Email - Tuta",
          bitwardenUuid: "11111111-1111-1111-1111-111111111111",
          folder: "Family Access",
          type: "login",
          required: true,
        },
        {
          faId: "data-recovery",
          title: "Data recovery",
          bitwardenName: "Data Recovery",
          folder: "Family Access",
          type: "note",
          required: true,
          recovery: true,
        },
      ],
    },
  ],
};

function item(faId: string, extra: Partial<BitwardenItem> = {}): BitwardenItem {
  return {
    id: `${faId}-uuid`,
    name: `${faId} item`,
    type: 1,
    folderId: "folder-1",
    fields: [{ name: "fa_id", value: faId, type: 0 }],
    login: { username: "user", password: "pass", uris: [{ uri: "https://example.com" }] },
    ...extra,
  };
}

const vault: BitwardenExport = {
  folders: [{ id: "folder-1", name: "Family Access" }],
  items: [
    {
      id: "11111111-1111-1111-1111-111111111111",
      name: "Email - Tuta",
      type: 1,
      folderId: "folder-1",
      fields: [
        { name: "fa_id", value: "email", type: 0 },
        { name: "recovery", value: "AAAA-BBBB", type: 0 },
      ],
      notes: "Recovery codes",
      login: {
        username: "owner@tuta.com",
        password: "correct horse",
        totp: "otpauth://totp/x",
        uris: [{ uri: "https://app.tuta.com" }, { uri: "javascript:alert(1)" }],
      },
    },
    {
      id: "22222222-2222-2222-2222-222222222222",
      name: "Data Recovery",
      type: 2,
      folderId: "folder-1",
      fields: [{ name: "fa_id", value: "data-recovery", type: 0 }],
      secureNote: { type: 0 },
    },
  ],
};

describe("bitwarden dashboard matching", () => {
  test("matches every manifest item by fa_id", () => {
    const result = matchVault(manifest, vault);
    expect(result.errors).toEqual([]);
    expect(result.matches.size).toBe(2);
    const email = result.matches.get("email")!;
    expect(email.username).toBe("owner@tuta.com");
    expect(email.password).toBe("correct horse");
    expect(email.fields).toEqual([{ name: "recovery", value: "AAAA-BBBB" }]);
    expect(email.uris).toEqual(["https://app.tuta.com"]);
    expect(email.deepLink).toContain("itemId=11111111-1111-1111-1111-111111111111");
  });

  test("reports a missing required item", () => {
    const result = matchVault(manifest, {
      folders: vault.folders,
      items: [vault.items[1]],
    });
    expect(result.errors.join(" ")).toContain('required item "email" is missing');
  });

  test("reports a deleted and recreated UUID", () => {
    const recreated = structuredClone(vault);
    recreated.items[0].id = "33333333-3333-3333-3333-333333333333";
    const result = matchVault(manifest, recreated);
    expect(result.errors.join(" ")).toContain("UUID changed");
  });

  test("reports a folder mismatch", () => {
    const moved = structuredClone(vault);
    moved.items[0].folderId = null;
    const movedManifest = structuredClone(manifest);
    movedManifest.sections[0].items[0].bitwardenUuid = undefined;
    const result = matchVault(movedManifest, moved);
    expect(result.errors.join(" ")).toContain('expected folder "Family Access"');
  });

  test("reports a type mismatch", () => {
    const wrong = structuredClone(vault);
    wrong.items[1].type = 1;
    const result = matchVault(manifest, wrong);
    expect(result.errors.join(" ")).toContain("expected a note item, found login");
  });

  test("reports duplicate fa_id fields", () => {
    const duplicate = structuredClone(vault);
    duplicate.items.push(item("email", { id: "other" }));
    const result = matchVault(manifest, duplicate);
    expect(result.errors.join(" ")).toContain("fa_id \"email\" is used by 2 Bitwarden items");
  });

  test("warns about a renamed item", () => {
    const renamed = structuredClone(vault);
    renamed.items[0].name = "Email (new name)";
    const result = matchVault(manifest, renamed);
    expect(result.errors).toEqual([]);
    expect(result.warnings.join(" ")).toContain("manifest says");
  });

  test("warns about stale fa_id values", () => {
    const stale = structuredClone(vault);
    stale.items.push(item("old-account", { id: "old" }));
    const result = matchVault(manifest, stale);
    expect(result.warnings.join(" ")).toContain('unused fa_id "old-account"');
  });

  test("matches by UUID when the fa_id field is missing", () => {
    const noField = structuredClone(vault);
    noField.items[0].fields = [];
    const result = matchVault(manifest, noField);
    expect(result.errors).toEqual([]);
    expect(result.warnings.join(" ")).toContain("no fa_id field");
    expect(result.matches.get("email")?.id).toBe("11111111-1111-1111-1111-111111111111");
  });

  test("rejects a fa_id and UUID that point to different items", () => {
    const disagree = structuredClone(vault) as BitwardenExport;
    disagree.items[0].fields = [];
    disagree.items.push({
      id: "11111111-1111-1111-1111-111111111111",
      name: "Email - Tuta",
      type: 1,
      fields: [],
    });
    disagree.items[2].fields = [{ name: "fa_id", value: "email", type: 0 }];
    disagree.items[2].id = "22222222-2222-2222-2222-222222222222-b";
    const result = matchVault(manifest, disagree);
    expect(result.errors.join(" ")).toContain("fa_id points to");
  });

  test("only accepts plaintext exports without an encrypted flag", () => {
    expect(plaintextExport('{"items":[]}')?.items).toEqual([]);
    expect(plaintextExport('{"encrypted":true,"items":[]}')).toBeNull();
    expect(plaintextExport("not json")).toBeNull();
  });

  test("reads fa_id case-insensitively and trims it", () => {
    expect(itemFaId(item("email", { fields: [{ name: " FA_ID ", value: " email ", type: 0 }] }))).toBe(
      "email",
    );
    expect(itemFaId({ id: "x", name: "x", type: 1 })).toBeUndefined();
  });
});

describe("dashboard rendering", () => {
  test("renders credentials and a deep link for matched items", () => {
    const result = matchVault(manifest, vault);
    const html = renderManifest(manifest, result.matches);
    expect(html).toContain("owner@tuta.com");
    expect(html).toContain("correct horse");
    expect(html).toContain("AAAA-BBBB");
    expect(html).toContain("itemId=11111111-1111-1111-1111-111111111111");
    expect(html).not.toContain("javascript:alert");
    expect(html).toContain('data-bitwarden-id="11111111-1111-1111-1111-111111111111"');
  });

  test("renders the manifest without matches", () => {
    const html = renderManifest(manifest);
    expect(html).not.toContain("credentials");
    expect(html).toContain("Email - Tuta");
  });

  test("escapes credentials from the vault", () => {
    const hostile = structuredClone(vault);
    hostile.items[0].name = "<img src=x onerror=alert(1)>";
    hostile.items[0].login!.username = "<script>alert(1)</script>";
    const result = matchVault(manifest, hostile);
    const html = renderManifest(manifest, result.matches);
    expect(html).not.toContain("<script>");
    expect(html).not.toContain("<img src=x");
  });

  test("validates the new manifest fields", () => {
    expect(validateManifest(manifest)).toEqual([]);
    const badType = structuredClone(manifest);
    badType.sections[0].items[0].type = "database" as never;
    expect(validateManifest(badType).join(" ")).toContain("unknown type");
    const badUrl = structuredClone(manifest);
    badUrl.vaultUrl = "javascript:alert(1)";
    expect(validateManifest(badUrl).join(" ")).toContain("vaultUrl");
    const badFolder = structuredClone(manifest);
    badFolder.sections[0].items[0].folder = "";
    expect(validateManifest(badFolder).join(" ")).toContain("empty folder");
  });
});
