import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { kitSlug, type KitValues, renderLabel, renderLetter, renderStartHere } from "./kit.ts";

const values: KitValues = {
  recipient: "Alex",
  operatorName: "Sam",
  bitwardenEmail: "sam@example.com",
  bitwardenPassword: "master-pw",
  recoveryCode: "ABCDE-FGHIJ",
  recoveryPassword: "pwa-pw",
  pageUrl: "https://recovery.sammohr.dev/",
  fallbackUrl: "https://recovery.pages.dev/",
};

describe("kitSlug", () => {
  test("makes a filesystem-safe name", () => {
    expect(kitSlug("Mary Jane O'Neil")).toBe("mary-jane-o-neil");
    expect(kitSlug("  ")).toBe("family");
  });
});

describe("renderStartHere", () => {
  test("carries every value the family needs and no more", () => {
    const text = renderStartHere(values);
    for (
      const value of [
        "Alex",
        "sam@example.com",
        "master-pw",
        "ABCDE-FGHIJ",
        "pwa-pw",
        "https://recovery.sammohr.dev/",
        "https://recovery.pages.dev/",
      ]
    ) {
      expect(text).toContain(value);
    }
    expect(text).not.toContain("r2-access-key");
    expect(text).not.toContain("restic");
  });
});

describe("renderLetter", () => {
  test("is a printable page with the instructions and the secrets", () => {
    const html = renderLetter(values);
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("@media print");
    expect(html).toContain("Alex");
    expect(html).toContain("sam@example.com");
    expect(html).toContain("master-pw");
    expect(html).toContain("ABCDE-FGHIJ");
    expect(html).toContain("pwa-pw");
    expect(html).toContain("Chrome");
    expect(html).toContain("six months");
  });

  test("escapes values so a password with markup cannot break the page", () => {
    const html = renderLetter({ ...values, bitwardenPassword: "a<b&c>d" });
    expect(html).toContain("a&lt;b&amp;c&gt;d");
    expect(html).not.toContain("a<b&c>d");
  });
});

describe("renderLabel", () => {
  test("names the recipient and the drive", () => {
    const html = renderLabel(values);
    expect(html).toContain("Alex");
    expect(html).toContain("Do not open");
  });
});
