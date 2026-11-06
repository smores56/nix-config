import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { commonDirectoryPrefix, relativeSegments } from "./restore.ts";

describe("commonDirectoryPrefix", () => {
  test("strips the shared root so restored folders start at their own names", () => {
    expect(
      commonDirectoryPrefix([
        "var/lib/data/photos/2024/a.jpg",
        "var/lib/data/db/immich.dump",
        "var/lib/data/vault/d/AB/x.c9r",
      ]),
    ).toBe("var/lib/data");
  });

  test("never strips the file's own name", () => {
    expect(commonDirectoryPrefix(["var/lib/data/photos/a.jpg"])).toBe("var/lib/data/photos");
    expect(commonDirectoryPrefix(["a.jpg"])).toBe("");
  });

  test("falls back to no prefix when the roots differ", () => {
    expect(commonDirectoryPrefix(["alpha/a.txt", "beta/b.txt"])).toBe("");
    expect(commonDirectoryPrefix([])).toBe("");
  });
});

describe("relativeSegments", () => {
  test("returns the path under the prefix, sanitized per segment", () => {
    expect(relativeSegments("var/lib/data", "var/lib/data/photos/a:b.jpg")).toEqual([
      "photos",
      "a_b.jpg",
    ]);
  });

  test("rejects a path outside the prefix", () => {
    expect(() => relativeSegments("var/lib/data", "var/lib/github-mirrors/x")).toThrow(
      "not under the restore root",
    );
    expect(() => relativeSegments("var/lib/data", "var/lib/data")).toThrow(
      "empty restore path",
    );
  });

  test("rejects traversal segments", () => {
    expect(() => relativeSegments("", "../etc/passwd")).toThrow("unsafe restore segment");
    expect(() => relativeSegments("", "a/../b")).toThrow("unsafe restore segment");
  });
});
