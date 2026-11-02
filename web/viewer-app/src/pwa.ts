// The site works offline once visited (M47d): every page registers the service worker at
// the site's root, which serves the site's own files from its cache. Share fetches and
// everything else go to the network untouched (site/sw.js).

/** Registers `sw.js`, which sits `up` folders above this page. */
export function registerServiceWorker(up = ""): void {
  if (!("serviceWorker" in navigator) || !window.isSecureContext) return;
  navigator.serviceWorker.register(new URL(`${up}sw.js`, location.href)).catch(() => undefined);
}
