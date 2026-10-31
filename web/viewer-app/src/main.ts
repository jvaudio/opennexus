// The share page's entry point (site/s/index.html loads the built share.js and share.css).

import "../../viewer-core/src/viewer.css";
import "./share.css";
import { registerServiceWorker } from "./pwa";
import { start } from "./share";

registerServiceWorker("../");

// A new fragment is a new link (pasted into the same tab).
window.addEventListener("hashchange", () => {
  void start();
});
void start();
