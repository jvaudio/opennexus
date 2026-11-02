// The viewer site's join page (/join/, M46): a live session's invite. It opens the session
// in OpenNexus (`opennexus://join#…` until universal links can, D366), says where to get
// the app, and draws the host's last shared view, read-only, decrypted here with the
// invite's key. The fragment stays in the page: only the read capability goes to the
// session's server, as the request's credential, so the server can tell readers from
// strangers without seeing the map.

import { BundleError, parseBundle } from "../../viewer-core/src/bundle";
import { mount } from "../../viewer-core/src/viewer";
import { appLink, parseInvite, viewURL, type Invite } from "./invite";
import { importKey, openBundle, SealedError } from "./sealed";

export const DOWNLOAD = "https://github.com/jvaudio/opennexus/releases";

/** What the view's request found. */
export type ViewState = "none" | "refused" | "unreachable";

declare global {
  interface Window {
    /** The view's bundle JSON text once drawn (the join tests compare it with the host's). */
    OpenNexusJoin?: { text: string };
  }
}

/** The host's sealed view, or why there isn't one to show. */
export async function fetchView(i: Invite): Promise<Uint8Array | ViewState> {
  let r: Response;
  try {
    r = await fetch(viewURL(i), {
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      headers: { Authorization: `Bearer ${i.read}` },
    });
  } catch {
    return "unreachable";
  }
  // 404: no view shared yet, or the session has ended (the server deletes everything).
  if (r.status === 404) return "none";
  if (r.status === 401 || r.status === 403) return "refused";
  if (!r.ok) return "unreachable";
  return new Uint8Array(await r.arrayBuffer());
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, cls?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls !== undefined) e.className = cls;
  return e;
}

function link(text: string, href: string, cls?: string): HTMLAnchorElement {
  const a = el("a", text, cls);
  a.href = href;
  return a;
}

const notes: Record<ViewState | "damaged" | "newer", string> = {
  none: "The host hasn’t shared a view yet, or the session has ended.",
  refused: "This invite isn’t valid for the session any more. Ask whoever sent it for a new one.",
  unreachable: "Couldn’t reach the session’s server to show its view.",
  damaged: "The session’s view is damaged, so it can’t be shown here.",
  newer: "The session’s view needs a newer viewer than this site has.",
};

/** The invite: open it in the app, get the app, and (when there is one) the view below. */
function bar(i: Invite, fragment: string): HTMLElement {
  // A named region, not a banner: the viewer below brings its own header.
  const header = el("section", undefined, "join-bar");
  header.setAttribute("aria-label", "Invite");
  const text = el("div", undefined, "join-text");
  text.append(
    el("h1", "You’re invited to a live session"),
    el(
      "p",
      i.write === undefined
        ? "Watch it in OpenNexus as it changes. This invite is view only."
        : "Open it in OpenNexus to edit together, live.",
    ),
  );
  const actions = el("div", undefined, "join-actions");
  actions.append(link("Open in OpenNexus", appLink(fragment), "join-open"), link("Get OpenNexus for Mac", DOWNLOAD));
  header.append(text, actions);
  return header;
}

function invalid(): void {
  const main = el("main", undefined, "share");
  main.id = "share";
  main.append(
    el("h1", "This invite is damaged"),
    el("p", "Part of it is missing or was changed. Ask whoever sent it for the link again."),
  );
  document.body.replaceChildren(main);
  document.title = "This invite is damaged · OpenNexus";
  document.documentElement.dataset.onxState = "damaged";
}

export async function startJoin(fragment = location.hash): Promise<void> {
  const invite = parseInvite(fragment);
  if (invite === null) {
    invalid();
    return;
  }
  const layout = el("div", undefined, "join-layout");
  const header = bar(invite, fragment);
  const main = el("main", undefined, "join-main");
  const status = el("p", "Looking for the session’s view…", "join-note");
  status.setAttribute("role", "status");
  main.append(status);
  layout.append(header, main);
  document.body.replaceChildren(layout);
  document.title = "Live session · OpenNexus";
  document.documentElement.dataset.onxState = "loading";

  const view = await fetchView(invite);
  if (typeof view === "string") {
    status.textContent = notes[view];
    document.documentElement.dataset.onxState = view;
    return;
  }
  let text: string;
  try {
    text = (await openBundle(view, await importKey(invite.key))).text;
  } catch (e) {
    const state = e instanceof SealedError && e.kind === "newer" ? "newer" : "damaged";
    status.textContent = notes[state];
    document.documentElement.dataset.onxState = state;
    return;
  }
  let bundle;
  try {
    bundle = parseBundle(text);
  } catch (e) {
    const state = e instanceof BundleError && e.message.includes("version") ? "newer" : "damaged";
    status.textContent = notes[state];
    document.documentElement.dataset.onxState = state;
    return;
  }
  // The viewer brings its own main landmark: the view replaces the page's.
  const host = el("div");
  host.id = "opennexus-viewer";
  const area = el("div", undefined, "join-main");
  area.append(host);
  main.replaceWith(area);
  header.querySelector(".join-text")?.append(
    el("p", "Below is the host’s last shared view, read-only. Open it in OpenNexus to see it live."),
  );
  mount(host, bundle);
  if (bundle.title !== "") document.title = `${bundle.title} · Live session · OpenNexus`;
  window.OpenNexusJoin = { text };
  document.documentElement.dataset.onxState = "ready";
}
