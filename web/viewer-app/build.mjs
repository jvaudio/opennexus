// Builds the static site into dist/: site/ as it is, plus the front page's open.js and
// open.css (M47d), s/share.js and s/share.css (viewer-core and the share page), and
// join/join.js and join/join.css (the join page, M46); the brand's icons for the web app
// manifest; and sw.js with the list of every file it precaches and a hash of them all as its
// version (M47d). GitHub Pages serves dist/ (.github/workflows/pages.yml).
import { createHash } from "node:crypto";
import { copyFile, cp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { build } from "esbuild";

await rm("dist", { recursive: true, force: true });
await cp("site", "dist", { recursive: true });
for (const icon of ["icon-192.png", "icon-512.png", "apple-touch-icon.png"]) {
  await copyFile(path.join("../../brand/web", icon), path.join("dist", icon));
}
await build({
  entryPoints: { open: "src/open-main.ts", "s/share": "src/main.ts", "join/join": "src/join-main.ts" },
  outdir: "dist",
  bundle: true,
  minify: true,
  format: "iife",
  target: ["chrome110", "firefox115", "safari16.4"],
  legalComments: "none",
  charset: "utf8",
  logLevel: "warning",
});

// The precache: every file but the worker itself and dotfiles (.nojekyll, .well-known),
// and each folder's index as its folder.
const files = (await readdir("dist", { recursive: true, withFileTypes: true }))
  .filter((e) => e.isFile())
  .map((e) => path.relative("dist", path.join(e.parentPath, e.name)).split(path.sep).join("/"))
  .filter((f) => f !== "sw.js" && !f.split("/").some((part) => part.startsWith(".")))
  .sort();
const hash = createHash("sha256");
for (const f of files) hash.update(f).update("\0").update(await readFile(path.join("dist", f)));
const list = files.flatMap((f) => (f === "index.html" ? ["./", f] : f.endsWith("/index.html") ? [f.slice(0, -"index.html".length), f] : [f]));
const sw = await readFile("dist/sw.js", "utf8");
await writeFile(
  "dist/sw.js",
  sw.replace('"__VERSION__"', JSON.stringify(hash.digest("hex").slice(0, 16))).replace('["__FILES__"]', JSON.stringify(list)),
);
