// Builds dist/nexus-math.js: MathJax with TeX input and SVG output as one script that
// defines globalThis.NexusMath, for the app's JavaScriptCore context (M48). The app embeds
// a copy (scripts/build-math.sh).
import { build } from "esbuild";

await build({
  entryPoints: { "nexus-math": "src/main.ts" },
  outdir: "dist",
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari17"],
  legalComments: "none",
  charset: "utf8",
  logLevel: "warning",
});
