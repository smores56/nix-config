import { describe, it as test } from "jsr:@std/testing/bdd";
import { expect } from "jsr:@std/expect";
import { reachHint } from "./hint.ts";

const origin = "https://recovery.sammohr.dev";

describe("reachHint", () => {
  test("explains a blocked or failed cross-origin fetch", () => {
    expect(reachHint("Failed to fetch", origin)).toContain(`not configured for ${origin}`);
    expect(reachHint("TypeError: Load failed", origin)).toContain(
      "could not reach Cloudflare Storage",
    );
  });

  test("leaves every other error alone", () => {
    expect(reachHint("s3: 403 Forbidden", origin)).toEqual("s3: 403 Forbidden");
    expect(reachHint("unable to unlock the data keys", origin)).toEqual(
      "unable to unlock the data keys",
    );
  });
});
