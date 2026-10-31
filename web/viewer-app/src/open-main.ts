// The front page's entry point (site/index.html loads the built open.js and open.css).

import "../../viewer-core/src/viewer.css";
import "./share.css";
import "./open.css";
import { startOpen } from "./open";
import { registerServiceWorker } from "./pwa";

registerServiceWorker();
startOpen();
