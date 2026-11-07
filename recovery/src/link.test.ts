import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { passwordFromHash, recoveryLink } from "./link.ts";

const page = "https://recovery.sammohr.dev/";

describe("recoveryLink", () => {
  test("puts the password in the fragment, never the query string", () => {
    const link = recoveryLink(page, "correct horse battery staple");
    expect(link).toBe(
      "https://recovery.sammohr.dev/#recovery-password=correct+horse+battery+staple",
    );
    expect(link.includes("?")).toBe(false);
  });

  test("round-trips awkward characters", () => {
    for (const password of ["a&b=c#d?e", "héllo wörld", "p@ss/word", "100% sure"]) {
      const link = recoveryLink(page, password);
      expect(passwordFromHash(new URL(link).hash)).toBe(password);
    }
  });
});

describe("passwordFromHash", () => {
  test("reads the parameter with or without the leading #", () => {
    expect(passwordFromHash("#recovery-password=abc")).toBe("abc");
    expect(passwordFromHash("recovery-password=abc")).toBe("abc");
  });

  test("ignores anything else", () => {
    expect(passwordFromHash("")).toBeNull();
    expect(passwordFromHash("#")).toBeNull();
    expect(passwordFromHash("#other=abc")).toBeNull();
    expect(passwordFromHash("#recovery-password=")).toBeNull();
  });
});
