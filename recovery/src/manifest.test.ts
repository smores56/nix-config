import { readFileSync } from "node:fs";
import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { type RecoveryManifest, renderManifest, validateManifest } from "./manifest.ts";

const manifest: RecoveryManifest = {
  version: 1,
  updated: "2026-11-08",
  sections: [
    {
      id: "accounts",
      title: "Accounts",
      description: "Passwords and recovery codes are in Bitwarden, in the Family Access folder.",
      items: [
        {
          title: "Bitwarden",
          url: "https://vault.bitwarden.com",
          notes: "Master password and two-step recovery code are on the sealed letter.",
        },
        {
          title: "Tuta",
          bitwardenName: "Email - Tuta",
          url: "https://app.tuta.com",
          notes: "Email · sam@sammohr.dev",
        },
        {
          title: "Immich",
          bitwardenName: "Immich",
          url: "https://immich.sammohr.dev",
          notes: "Photos and images.",
        },
      ],
    },
  ],
  warnings: ["A warning from the manifest."],
};

describe("recovery manifest", () => {
  test("accepts the sample manifest", () => {
    expect(validateManifest(manifest)).toEqual([]);
  });

  test("allows an item without a Bitwarden item name", () => {
    expect(manifest.sections[0].items[0].bitwardenName).toBeUndefined();
    expect(validateManifest(manifest)).toEqual([]);
  });

  test("rejects duplicate item titles", () => {
    const dup: RecoveryManifest = structuredClone(manifest);
    dup.sections[0].items[1].title = "Bitwarden";
    expect(validateManifest(dup).join(" ")).toContain("duplicate");
  });

  test("rejects a non-http URL", () => {
    const bad: RecoveryManifest = structuredClone(manifest);
    bad.sections[0].items[0].url = "javascript:alert(1)";
    expect(validateManifest(bad).join(" ")).toContain("http");
  });

  test("renders sections, links, item names, and warnings", () => {
    const html = renderManifest(manifest);
    expect(html).toContain("Accounts");
    expect(html).toContain("Passwords and recovery codes");
    expect(html).toContain("Tuta");
    expect(html).toContain("sam@sammohr.dev");
    expect(html).toContain('href="https://app.tuta.com"');
    expect(html).toContain('target="_blank"');
    expect(html).toContain("Email - Tuta");
    expect(html).toContain("A warning from the manifest.");
    expect(html).not.toContain("Contacts");
  });

  test("escapes untrusted text", () => {
    const bad: RecoveryManifest = structuredClone(manifest);
    bad.sections[0].items[0].title = "<img src=x onerror=alert(1)>";
    const html = renderManifest(bad);
    expect(html).not.toContain("<img src=x");
    expect(html).toContain("&lt;img");
  });
});

describe("manifest hardening", () => {
  test("rejects structurally wrong sections and items", () => {
    expect(validateManifest({ ...manifest, sections: [null] } as never)).not.toEqual([]);
    const badItems = structuredClone(manifest);
    badItems.sections[0].items = [null] as never;
    expect(validateManifest(badItems)).not.toEqual([]);
    const emptyItems = structuredClone(manifest);
    emptyItems.sections[0].items = [];
    expect(validateManifest(emptyItems)).not.toEqual([]);
  });

  test("rejects non-string warnings and malformed item text", () => {
    expect(validateManifest({ ...manifest, warnings: [42] } as never)).not.toEqual([]);
    const badNotes = structuredClone(manifest);
    badNotes.sections[0].items[0].notes = 7 as never;
    expect(validateManifest(badNotes)).not.toEqual([]);
    const badName = structuredClone(manifest);
    badName.sections[0].items[1].bitwardenName = " ";
    expect(validateManifest(badName)).not.toEqual([]);
  });

  test("ships a valid, placeholder-free manifest", () => {
    const shipped = JSON.parse(
      readFileSync(new URL("../public/manifest.json", import.meta.url), "utf8"),
    );
    expect(validateManifest(shipped)).toEqual([]);
    expect(JSON.stringify(shipped)).not.toContain("Fill this in");
  });

  test("renders the updated date", () => {
    expect(renderManifest(manifest)).toContain("Updated");
    expect(renderManifest(manifest)).toContain("2026-11-08");
  });
});
