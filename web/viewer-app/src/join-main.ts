// The join page's entry point (site/join/index.html loads the built join.js and join.css).

import "../../viewer-core/src/viewer.css";
import "./share.css";
import "./join.css";
import { startJoin } from "./join";

// A new fragment is a new invite (pasted into the same tab).
window.addEventListener("hashchange", () => {
  void startJoin();
});
void startJoin();
