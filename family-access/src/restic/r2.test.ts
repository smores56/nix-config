import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { byteRange, repositoryPrefix } from "./r2.ts";

describe("R2 helpers", () => {
  test("builds the correct range header", () => {
    expect(byteRange(0, 10)).toBe("bytes=0-9");
    expect(byteRange(5, 10)).toBe("bytes=5-14");
    expect(byteRange(5)).toBe("bytes=5-");
    expect(byteRange(0)).toBeUndefined();
  });

  test("extracts a repository prefix from the restic repository URL", () => {
    expect(repositoryPrefix("s3:https://acct.r2.cloudflarestorage.com/restic-backup", "restic-backup")).toBe(
      "",
    );
    expect(
      repositoryPrefix("s3:https://acct.r2.cloudflarestorage.com/restic-backup/family", "restic-backup"),
    ).toBe("family");
    expect(repositoryPrefix("not a url", "restic-backup")).toBe("");
  });
});
