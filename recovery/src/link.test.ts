import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { passwordFromHash, recoveryLink } from "./link.ts";

const page = "https://recovery.sammohr.dev/";

describe("recoveryLink", () => {
  test("puts the password in the fragment as-is, with no parameter name", () => {
    expect(recoveryLink(page, "correct-horse")).toBe("https://recovery.sammohr.dev/#correct-horse");
    expect(recoveryLink(page, "correct horse")).toBe(
      "https://recovery.sammohr.dev/#correct%20horse",
    );
    expect(recoveryLink(page, "correct-horse").includes("?")).toBe(false);
  });

  test("replaces an existing fragment", () => {
    expect(recoveryLink("https://recovery.sammohr.dev/#stale", "pw")).toBe(
      "https://recovery.sammohr.dev/#pw",
    );
  });

  test("round-trips awkward characters", () => {
    for (const password of ["a&b=c#d?e", "héllo wörld", "p@ss/word", "100% sure", "a+b"]) {
      expect(passwordFromHash(new URL(recoveryLink(page, password)).hash)).toBe(password);
    }
  });
});

describe("passwordFromHash", () => {
  test("takes the whole fragment", () => {
    expect(passwordFromHash("#abc")).toBe("abc");
    expect(passwordFromHash("abc")).toBe("abc");
    expect(passwordFromHash("#with spaces")).toBe("with spaces");
  });

  test("decodes percent escapes, and keeps a malformed one literally", () => {
    expect(passwordFromHash("#a%20b")).toBe("a b");
    expect(passwordFromHash("#100%")).toBe("100%");
  });

  test("treats an empty fragment as no password", () => {
    expect(passwordFromHash("")).toBeNull();
    expect(passwordFromHash("#")).toBeNull();
  });
});
