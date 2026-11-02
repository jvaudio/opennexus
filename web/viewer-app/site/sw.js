// The viewer site's service worker (M47d): the site's own files, precached when it
// installs and served from the cache first, so the site opens and reads files offline.
// Every other request (a share link's sealed map, anything off this site) goes to the
// network untouched. build.mjs fills in the files and the version, a hash of their bytes.

const VERSION = "__VERSION__";
const FILES = ["__FILES__"];
const CACHE = `opennexus-viewer-${VERSION}`;
const scope = new URL(self.registration.scope);
const urls = FILES.map((f) => new URL(f, scope).href);
const paths = new Set(urls.map((u) => new URL(u).pathname));

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(urls)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith("opennexus-viewer-") && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== scope.origin || !paths.has(url.pathname)) return;
  // `s/?embed#…` is `s/`: the query only changes what the page does, not what it is.
  event.respondWith(
    caches
      .open(CACHE)
      .then((cache) => cache.match(url.origin + url.pathname))
      .then((hit) => hit ?? fetch(request)),
  );
});
