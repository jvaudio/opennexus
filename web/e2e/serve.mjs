// The viewer site (viewer-app/dist) on http://127.0.0.1:4310, as GitHub Pages serves it,
// for the share-link tests. No dependencies: node:http and the files.
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { URL } from "node:url";

const root = path.resolve(import.meta.dirname, "../viewer-app/dist");
const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css" };

createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://127.0.0.1");
  let file = path.normalize(path.join(root, decodeURIComponent(url.pathname)));
  if (!file.startsWith(root)) {
    res.writeHead(403).end();
    return;
  }
  if (url.pathname.endsWith("/")) file = path.join(file, "index.html");
  readFile(file).then(
    (data) => {
      res.writeHead(200, { "Content-Type": types[path.extname(file)] ?? "application/octet-stream" }).end(data);
    },
    () => {
      res.writeHead(404).end("not found");
    },
  );
}).listen(4310, "127.0.0.1");
