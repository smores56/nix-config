import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { sanitizeFileName, uniqueFileName } from "./filenames.ts";

describe("sanitizeFileName", () => {
  test("keeps ordinary names", () => {
    expect(sanitizeFileName("family-access-sentinel.txt")).toBe("family-access-sentinel.txt");
    expect(sanitizeFileName("documents")).toBe("documents");
  });

  test("replaces path and control characters", () => {
    expect(sanitizeFileName('a/b\\c:d*e?f"g<h>i|j.txt')).toBe("a_b_c_d_e_f_g_h_i_j.txt");
    expect(sanitizeFileName("a\u0000b\u001fc")).toBe("a_b_c");
  });

  test("handles Windows reserved names", () => {
    expect(sanitizeFileName("CON")).toBe("_CON");
    expect(sanitizeFileName("aux.txt")).toBe("_aux.txt");
    expect(sanitizeFileName("com1.log")).toBe("_com1.log");
  });

  test("handles empty and trailing-dot names", () => {
    expect(sanitizeFileName("...")).toBe("download");
    expect(sanitizeFileName("name. ")).toBe("name");
  });
});

describe("uniqueFileName", () => {
  test("keeps the first name and numbers later collisions", () => {
    const taken = new Set<string>();
    expect(uniqueFileName(taken, "a.jpg")).toBe("a.jpg");
    expect(uniqueFileName(taken, "a.jpg")).toBe("a (2).jpg");
    expect(uniqueFileName(taken, "a.jpg")).toBe("a (3).jpg");
  });

  test("sanitizes before claiming a name", () => {
    const taken = new Set<string>();
    expect(uniqueFileName(taken, "a:b.jpg")).toBe("a_b.jpg");
    expect(uniqueFileName(taken, "a:b.jpg")).toBe("a_b (2).jpg");
    expect(uniqueFileName(taken, "a_b (2).jpg")).toBe("a_b (2) (2).jpg");
  });

  test("keeps numbered names inside the length cap", () => {
    const taken = new Set<string>();
    const long = `${"x".repeat(200)}.txt`;
    const first = uniqueFileName(taken, long);
    const second = uniqueFileName(taken, long);
    expect(second.length).toBeLessThanOrEqual(200);
    expect(second).not.toBe(first);
  });
});
