// Builds the viewer into dist/: opennexus-viewer.js (one IIFE) and opennexus-viewer.css.
// scripts/build-viewer.sh copies both into the Swift resources.
import { build } from "esbuild";

await build({
  entryPoints: { "opennexus-viewer": "src/index.ts" },
  outdir: "dist",
  bundle: true,
  minify: true,
  format: "iife",
  target: ["chrome110", "firefox115", "safari16.4"],
  legalComments: "none",
  charset: "utf8",
  logLevel: "warning",
});
