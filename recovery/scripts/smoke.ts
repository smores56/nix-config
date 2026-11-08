// Serves dist/ and boots it in headless Chrome: the page must render its shell,
// run its module, unlock from a link fragment and reach the restore UI. This
// catches a broken bundle, a bad CSP, or a blob the browser cannot open — none
// of which unit tests can see.
//
// The blob served to Chrome is replaced by a fixture built here with a known
// password, so the run proves the browser derives the same key the builder does
// without needing the real recovery password.
//
//   deno task smoke [--dist dist] [--chrome /path/to/chrome]
//
// CHROME is used when --chrome is absent; otherwise the usual names are tried.

import { type DataKeys, encryptBlob } from "../src/blob.ts";

const SMOKE_PASSWORD = "smoke password";
const SMOKE_COST = { iterations: 1, memory: 8192, parallelism: 1 };

const SMOKE_KEYS: DataKeys = {
  version: 1,
  r2: {
    endpoint: "https://example.invalid",
    bucket: "restic-backup",
    accessKeyId: "smoke-access-key",
    secretAccessKey: "smoke-secret-key",
  },
  restic: {
    password: "smoke-restic-password",
    repository: "s3:https://example.invalid/restic-backup",
    photosPath: "var/lib/data/photos",
    vaultPath: "var/lib/data/vault",
  },
};

const USAGE = "usage: smoke [--dist <dir>] [--chrome <path>]";

type Args = { dist: string; chrome?: string };

function parseArgs(argv: string[]): Args {
  const args: Args = { dist: "dist" };
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    switch (value) {
      case "--dist":
        args.dist = argv[++index] ?? args.dist;
        break;
      case "--chrome":
        args.chrome = argv[++index];
        break;
      case "--help":
      case "-h":
        console.log(USAGE);
        Deno.exit(0);
        break;
      default:
        throw new Error(`unknown argument: ${value}`);
    }
  }
  return args;
}

const CONTENT_TYPES: Record<string, string> = {
  html: "text/html; charset=utf-8",
  js: "text/javascript; charset=utf-8",
  css: "text/css; charset=utf-8",
  json: "application/json",
  webmanifest: "application/manifest+json",
  png: "image/png",
  enc: "application/octet-stream",
};

function contentType(path: string): string {
  const ext = path.slice(path.lastIndexOf(".") + 1);
  return CONTENT_TYPES[ext] ?? "application/octet-stream";
}

async function findChrome(explicit?: string): Promise<string> {
  const candidates = [
    explicit,
    Deno.env.get("CHROME"),
    "chromium",
    "chromium-browser",
    "google-chrome",
    "google-chrome-stable",
  ].filter((value): value is string => !!value);
  for (const candidate of candidates) {
    try {
      const result = await new Deno.Command(candidate, {
        args: ["--version"],
        stdout: "piped",
        stderr: "piped",
      }).output();
      if (result.success) return candidate;
    } catch {
      // Try the next name.
    }
  }
  throw new Error(`no Chrome found; pass --chrome (tried ${candidates.join(", ")})`);
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);
  const chrome = await findChrome(args.chrome);
  const root = await Deno.realPath(args.dist);
  if (!(await Deno.stat(`${root}/index.html`)).isFile) {
    throw new Error(`${root}/index.html is missing; run deno task build first`);
  }

  // Everything but the password field lives behind #unlocked, so a relative who
  // opens the page before holding the letter reads nothing they should not.
  const locked = await Deno.readTextFile(`${root}/index.html`);
  if (!/<div[^>]*\bid="unlocked"[^>]*\bhidden\b/.test(locked)) {
    throw new Error("index.html must keep #unlocked hidden until the password is entered");
  }

  const envelope = JSON.stringify(await encryptBlob(SMOKE_KEYS, SMOKE_PASSWORD, SMOKE_COST));

  const server = Deno.serve({ port: 0, hostname: "127.0.0.1" }, async (request) => {
    const path = new URL(request.url).pathname;
    const relative = path === "/" ? "index.html" : decodeURIComponent(path).replace(/^\/+/, "");
    if (relative.includes("..")) return new Response("forbidden", { status: 403 });
    if (relative === "data-keys.enc") {
      return new Response(envelope, {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }
    try {
      const body = await Deno.readFile(`${root}/${relative}`);
      return new Response(body, { headers: { "content-type": contentType(relative) } });
    } catch {
      return new Response("not found", { status: 404 });
    }
  });

  try {
    const url = `http://127.0.0.1:${server.addr.port}/#${encodeURIComponent(SMOKE_PASSWORD)}`;
    const result = await new Deno.Command(chrome, {
      args: [
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--virtual-time-budget=20000",
        "--dump-dom",
        url,
      ],
      stdout: "piped",
      stderr: "piped",
    }).output();

    const dom = new TextDecoder().decode(result.stdout);
    // The account list is fetched only after the password decrypts the kit, so a
    // rendered manifest in this dump also proves the gate opened.
    const missing = [
      "<title>Recovery</title>",
      `id="manifest"`,
      `id="restore-all"`,
      `id="manifest-section-accounts"`,
      `id="snapshot-label"`,
      `id="browser"`,
    ].filter((marker) => !dom.includes(marker));

    if (missing.length > 0) {
      const stderr = new TextDecoder().decode(result.stderr).split("\n").slice(-8).join("\n");
      throw new Error(
        `the page did not boot or did not unlock: missing ${missing.join(", ")}\n` +
          `last chrome output:\n${stderr}`,
      );
    }
    const leftover = [`id="gate"`, `placeholder="Recovery password"`].filter((marker) =>
      dom.includes(marker)
    );
    if (leftover.length > 0) {
      throw new Error(`the unlock gate was not removed: still found ${leftover.join(", ")}`);
    }
    console.log(`smoke: ${url.split("#")[0]}#<password> unlocked from the fragment`);
  } finally {
    await server.shutdown();
  }
}

main().catch((error: unknown) => {
  console.error(`smoke failed: ${error instanceof Error ? error.message : String(error)}`);
  Deno.exit(1);
});
