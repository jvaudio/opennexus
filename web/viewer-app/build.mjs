// Builds the static site into dist/: site/ as it is, plus s/share.js and s/share.css
// (viewer-core and the share page). GitHub Pages serves dist/ (.github/workflows/pages.yml).
import { cp, rm } from "node:fs/promises";
import { build } from "esbuild";

await rm("dist", { recursive: true, force: true });
await cp("site", "dist", { recursive: true });
await build({
  entryPoints: { "s/share": "src/main.ts" },
  outdir: "dist",
  bundle: true,
  minify: true,
  format: "iife",
  target: ["chrome110", "firefox115", "safari16.4"],
  legalComments: "none",
  charset: "utf8",
  logLevel: "warning",
});
