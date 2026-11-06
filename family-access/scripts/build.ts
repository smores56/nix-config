import { cp, mkdir, rm } from "node:fs/promises";
import * as esbuild from "esbuild";

const dist = new URL("../dist/", import.meta.url);

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

await esbuild.build({
  entryPoints: [new URL("../src/main.ts", import.meta.url).pathname],
  outfile: new URL("main.js", dist).pathname,
  bundle: true,
  minify: true,
  sourcemap: "linked",
  platform: "browser",
  format: "esm",
  target: ["es2022"],
  logLevel: "info",
});

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

console.log(`built ${dist.pathname}`);
