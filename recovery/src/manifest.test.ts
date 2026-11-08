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
      description:
        "The Bitwarden root password and recovery codes are in the letter/thumb drive. All accounts below use the username sam@sammohr.dev.",
      items: [
        {
          title: "Bitwarden (password manager)",
          url: "https://vault.bitwarden.com",
        },
        {
          title: "Tuta (email provider)",
          url: "https://app.tuta.com",
        },
        {
          title: "Immich (photo library)",
          url: "https://immich.sammohr.dev",
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

  test("rejects duplicate item titles", () => {
    const dup: RecoveryManifest = structuredClone(manifest);
    dup.sections[0].items[1].title = "Bitwarden (password manager)";
    expect(validateManifest(dup).join(" ")).toContain("duplicate");
  });

  test("rejects a non-http or missing URL", () => {
    const bad: RecoveryManifest = structuredClone(manifest);
    bad.sections[0].items[0].url = "javascript:alert(1)";
    expect(validateManifest(bad).join(" ")).toContain("http");
    const missing: RecoveryManifest = structuredClone(manifest);
    missing.sections[0].items[0].url = "" as never;
    expect(validateManifest(missing).join(" ")).toContain("http");
  });

  test("renders sections, visible URLs, links, and warnings", () => {
    const html = renderManifest(manifest);
    expect(html).toContain("Accounts");
    expect(html).toContain("The Bitwarden root password and recovery codes");
    expect(html).toContain("sam@sammohr.dev");
    expect(html).toContain("Tuta (email provider)");
    expect(html).toContain('href="https://app.tuta.com"');
    expect(html).toContain('class="account-url">https://app.tuta.com');
    expect(html).toContain('target="_blank"');
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

  test("rejects non-string warnings and missing update dates", () => {
    expect(validateManifest({ ...manifest, warnings: [42] } as never)).not.toEqual([]);
    expect(validateManifest({ ...manifest, updated: "" }).join(" ")).toContain("updated");
  });

  test("ships a valid, placeholder-free manifest", () => {
    const shipped = JSON.parse(
      readFileSync(new URL("../public/manifest.json", import.meta.url), "utf8"),
    );
    expect(validateManifest(shipped)).toEqual([]);
    expect(JSON.stringify(shipped)).not.toContain("Fill this in");
  });
});
