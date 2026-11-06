import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import {
  renderManifest,
  validateManifest,
  type RecoveryManifest,
} from "./manifest.ts";

const manifest: RecoveryManifest = {
  version: 1,
  updated: "2026-11-05",
  sections: [
    {
      id: "start",
      title: "Start here",
      items: [
        {
          title: "Read this first",
          bitwardenName: "START HERE",
        },
      ],
    },
    {
      id: "accounts",
      title: "Accounts",
      items: [
        {
          title: "E-mail (Tuta)",
          bitwardenName: "Email - Tuta",
          url: "https://app.tuta.com",
          required: true,
        },
        {
          title: "Photos (Immich)",
          bitwardenName: "Immich",
          url: "https://immich.sammohr.dev",
          required: true,
        },
      ],
    },
    {
      id: "data",
      title: "Data recovery",
      items: [
        {
          title: "R2, restic, and vault keys",
          bitwardenName: "Data Recovery",
          required: true,
          recovery: true,
        },
      ],
    },
  ],
  warnings: ["Tuta free accounts are deleted after six months of inactivity."],
};

describe("family access manifest", () => {
  test("accepts the sample manifest", () => {
    expect(validateManifest(manifest)).toEqual([]);
  });

  test("rejects duplicate item titles", () => {
    const dup: RecoveryManifest = structuredClone(manifest);
    dup.sections[1].items[1].title = "E-mail (Tuta)";
    expect(validateManifest(dup).join(" ")).toContain("duplicate");
  });

  test("rejects a non-http URL", () => {
    const bad: RecoveryManifest = structuredClone(manifest);
    bad.sections[1].items[0].url = "javascript:alert(1)";
    expect(validateManifest(bad).join(" ")).toContain("http");
  });

  test("renders sections, links, and warnings", () => {
    const html = renderManifest(manifest);
    expect(html).toContain("Start here");
    expect(html).toContain("E-mail (Tuta)");
    expect(html).toContain('href="https://app.tuta.com"');
    expect(html).toContain("Data recovery");
    expect(html).toContain("Tuta free accounts");
  });

  test("escapes untrusted text", () => {
    const bad: RecoveryManifest = structuredClone(manifest);
    bad.sections[0].items[0].title = '<img src=x onerror=alert(1)>';
    const html = renderManifest(bad);
    expect(html).not.toContain("<img src=x");
    expect(html).toContain("&lt;img");
  });
});

import { readFileSync } from "node:fs";

describe("manifest hardening", () => {
  test("rejects structurally wrong sections and items", () => {
    expect(validateManifest({ ...manifest, sections: [null] } as never)).not.toEqual([]);
    const badItems = structuredClone(manifest);
    badItems.sections[1].items = [null] as never;
    expect(validateManifest(badItems)).not.toEqual([]);
  });

  test("rejects non-string warnings and malformed contacts", () => {
    expect(validateManifest({ ...manifest, warnings: [42] } as never)).not.toEqual([]);
    expect(
      validateManifest({ ...manifest, contacts: [{ role: "helper" }] } as never),
    ).not.toEqual([]);
    const badNotes = structuredClone(manifest);
    badNotes.sections[0].items[0].notes = 7 as never;
    expect(validateManifest(badNotes)).not.toEqual([]);
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
    expect(renderManifest(manifest)).toContain("2026-11-05");
  });
});
