// Serves dist/ and boots it in headless Chrome: the page must render its shell,
// run its module, fetch the blob and reach the unlock prompt. This catches a
// broken bundle or a bad CSP that unit tests cannot see.
//
//   deno task smoke [--dist dist] [--chrome /path/to/chrome]
//
// CHROME is used when --chrome is absent; otherwise the usual names are tried.

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
  const candidates = [explicit, Deno.env.get("CHROME"), "chromium", "chromium-browser",
    "google-chrome", "google-chrome-stable"].filter((value): value is string => !!value);
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

  const server = Deno.serve({ port: 0, hostname: "127.0.0.1" }, async (request) => {
    const path = new URL(request.url).pathname;
    const relative = path === "/" ? "index.html" : decodeURIComponent(path).replace(/^\/+/, "");
    if (relative.includes("..")) return new Response("forbidden", { status: 403 });
    try {
      const body = await Deno.readFile(`${root}/${relative}`);
      return new Response(body, { headers: { "content-type": contentType(relative) } });
    } catch {
      return new Response("not found", { status: 404 });
    }
  });

  try {
    const url = `http://127.0.0.1:${server.addr.port}/`;
    const result = await new Deno.Command(chrome, {
      args: [
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--virtual-time-budget=8000",
        "--dump-dom",
        url,
      ],
      stdout: "piped",
      stderr: "piped",
    }).output();

    const dom = new TextDecoder().decode(result.stdout);
    const missing = [
      "<title>Recovery Kit</title>",
      `id="start-here"`,
      `id="restore-all"`,
      "The data-keys blob is deployed",
      `id="recovery-password"`,
    ].filter((marker) => !dom.includes(marker));

    if (missing.length > 0) {
      const stderr = new TextDecoder().decode(result.stderr).split("\n").slice(-8).join("\n");
      throw new Error(
        `the page did not boot: missing ${missing.join(", ")}\nlast chrome output:\n${stderr}`,
      );
    }
    console.log(`smoke: ${url} rendered the shell, ran main.js and found the blob`);
  } finally {
    await server.shutdown();
  }
}

main().catch((error: unknown) => {
  console.error(`smoke failed: ${error instanceof Error ? error.message : String(error)}`);
  Deno.exit(1);
});
