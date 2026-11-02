// The entry point. An interactive export carries its bundle in
// <script type="application/json" id="opennexus-bundle"> and mounts itself into
// #opennexus-viewer; other hosts (share links, the web viewer, Obsidian) call
// window.OpenNexusViewer.mount themselves.

import "./page.css";
import "./viewer.css";
import { BundleError, parseBundle } from "./bundle";
import { find } from "./search";
import { mount } from "./viewer";

/** `find` is the search the page runs, for hosts and for the tests that compare it with the app's Find. */
const api = { version: 1, parseBundle, mount, find, BundleError, readyAt: -1 };

declare global {
  interface Window {
    OpenNexusViewer: typeof api;
  }
}

window.OpenNexusViewer = api;

const host = document.getElementById("opennexus-viewer");
const data = document.getElementById("opennexus-bundle");
if (host !== null && data !== null) {
  try {
    mount(host, parseBundle(data.textContent));
    api.readyAt = performance.now();
    document.documentElement.dataset.onxReady = "true";
  } catch (e) {
    const p = document.createElement("p");
    p.className = "onx-error";
    p.textContent = e instanceof BundleError ? `This file’s map is damaged (${e.message}).` : "This map couldn’t be shown.";
    host.replaceChildren(p);
    document.documentElement.dataset.onxReady = "error";
  }
}
