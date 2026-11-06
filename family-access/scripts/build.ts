import { mkdir, cp, rm } from "node:fs/promises";

const dist = new URL("../dist/", import.meta.url);

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

const result = await Bun.build({
  entrypoints: [new URL("../src/main.ts", import.meta.url).pathname],
  outdir: dist.pathname,
  target: "browser",
  minify: true,
  sourcemap: "linked",
  naming: "[name].[ext]",
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

for (const [from, to] of [
  ["index.html", "index.html"],
  ["src/style.css", "style.css"],
  ["public/manifest.json", "manifest.json"],
  ["public/manifest.webmanifest", "manifest.webmanifest"],
  ["public/sw.js", "sw.js"],
  ["public/icon-192.png", "icon-192.png"],
  ["public/icon-512.png", "icon-512.png"],
] as const) {
  await cp(new URL(`../${from}`, import.meta.url), new URL(to, dist));
}

console.log(`built ${result.outputs.length} bundle(s) into ${dist.pathname}`);
