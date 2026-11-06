import { describe, expect, test } from "bun:test";
import { sanitizeFileName } from "./filenames";

describe("sanitizeFileName", () => {
  test("keeps ordinary names", () => {
    expect(sanitizeFileName("family-access-sentinel.txt")).toBe("family-access-sentinel.txt");
    expect(sanitizeFileName("documents")).toBe("documents");
  });

  test("replaces path and control characters", () => {
    expect(sanitizeFileName("a/b\\c:d*e?f\"g<h>i|j.txt")).toBe("a_b_c_d_e_f_g_h_i_j.txt");
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
