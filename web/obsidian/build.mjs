// Builds the plugin into dist/: main.js (CommonJS, as Obsidian loads plugins), styles.css
// (viewer-core's chrome and the plugin's own) and a copy of manifest.json, the three files a
// release carries (scripts/release-obsidian.sh).
import { builtinModules } from "node:module";
import { copyFile, mkdir, rm } from "node:fs/promises";
import { build } from "esbuild";

await rm("dist", { recursive: true, force: true });
await mkdir("dist");
const common = { bundle: true, minify: true, legalComments: "none", charset: "utf8", logLevel: "warning" };
await build({
  ...common,
  entryPoints: { main: "src/main.ts" },
  outdir: "dist",
  format: "cjs",
  platform: "browser",
  target: ["chrome110", "safari16.4"],
  external: ["obsidian", "electron", "@codemirror/*", "@lezer/*", ...builtinModules, ...builtinModules.map((m) => `node:${m}`)],
});
await build({ ...common, entryPoints: { styles: "src/styles.css" }, outdir: "dist" });
await copyFile("manifest.json", "dist/manifest.json");
