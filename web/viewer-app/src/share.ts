// The viewer site's share page (/s/): reads the link's fragment, fetches the sealed map
// without credentials, opens it in this browser and draws it with viewer-core. The key
// never leaves the page: browsers don't send the fragment, and nothing here does.

import { BundleError, parseBundle } from "../../viewer-core/src/bundle";
import { mount, type ViewerAction } from "../../viewer-core/src/viewer";
import { appLink, isFetchable, parseFragment, type ShareCode } from "./link";
import { base64, header as readHeader, importKey, openBundle, passwordKeyBytes, SealedError, type Header } from "./sealed";

export const GITHUB_API = "https://api.github.com";
/** The one file in a share gist (`GistTarget.file`). */
export const GIST_FILE = "opennexus-share.b64";

type State = "loading" | "off" | "expired" | "damaged" | "newer" | "unreachable" | "password" | "ready";

class Stop extends Error {
  constructor(readonly state: State) {
    super(state);
  }
}

declare global {
  interface Window {
    /** The opened bundle's JSON text (the share tests compare it with an export's). */
    OpenNexusShare?: { text: string };
  }
}

async function get(url: string, accept?: string): Promise<Response> {
  let r: Response;
  try {
    r = await fetch(url, {
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      ...(accept === undefined ? {} : { headers: { Accept: accept } }),
    });
  } catch {
    throw new Stop("unreachable");
  }
  // A deleted object: 404 (a server, a gist), 410 (an expired share) or 403 (a bucket that
  // doesn't let readers list what's missing).
  if (r.status === 404 || r.status === 410 || r.status === 403) throw new Stop("off");
  if (!r.ok) throw new Stop("unreachable");
  return r;
}

function property(o: unknown, k: string): unknown {
  return typeof o === "object" && o !== null && Object.prototype.hasOwnProperty.call(o, k)
    ? (o as Record<string, unknown>)[k]
    : undefined;
}

/** The sealed bytes the link points at. */
export async function fetchSealed(code: ShareCode): Promise<Uint8Array> {
  if (code.source === "u") return new Uint8Array(await (await get(code.locator)).arrayBuffer());
  const gist: unknown = await (await get(`${GITHUB_API}/gists/${code.locator}`, "application/vnd.github+json")).json().catch(() => {
    throw new Stop("damaged");
  });
  const file = property(property(gist, "files"), GIST_FILE);
  let text = property(file, "content");
  // GitHub's API cuts files over 1 MB short; the whole file is at its raw address.
  if (property(file, "truncated") === true) {
    const raw = property(file, "raw_url");
    if (typeof raw !== "string" || !isFetchable(raw) || new URL(raw).hostname !== "gist.githubusercontent.com") {
      throw new Stop("damaged");
    }
    text = await (await get(raw)).text();
  }
  if (typeof text !== "string") throw new Stop("damaged");
  try {
    return base64(text.replace(/\s+/g, ""));
  } catch {
    throw new Stop("damaged");
  }
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, cls?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls !== undefined) e.className = cls;
  return e;
}

const messages: Record<Exclude<State, "ready" | "password">, [string, string]> = {
  loading: ["Opening the map…", "It’s decrypted here, in your browser."],
  off: ["This link is turned off", "Whoever shared it has turned it off. Ask them for a new link."],
  expired: ["This link is turned off", "It has expired. Ask whoever shared it for a new link."],
  damaged: [
    "This link is damaged",
    "Part of it is missing or was changed, so the map can’t be opened. Ask whoever shared it for the link again.",
  ],
  newer: [
    "This map needs a newer viewer",
    "It was shared from a newer version of OpenNexus. Reload the page; if this stays, the viewer here hasn’t been updated yet.",
  ],
  unreachable: ["Couldn’t reach the map", "Check your connection, then try again."],
};

function card(state: State, ...children: HTMLElement[]): HTMLElement {
  document.documentElement.dataset.onxState = state;
  const main = el("main", undefined, "share");
  main.id = "share";
  main.append(...children);
  document.body.replaceChildren(main);
  return main;
}

function show(state: Exclude<State, "ready" | "password">, detail?: string): void {
  const [title, text] = messages[state];
  const children: HTMLElement[] = [el("h1", title), el("p", detail ?? text)];
  if (state === "unreachable") {
    const retry = el("button", "Try Again");
    retry.type = "button";
    retry.addEventListener("click", () => {
      void start();
    });
    children.push(retry);
  }
  card(state, ...children);
  document.title = `${title} · OpenNexus`;
}

function expired(h: Header, now = Date.now()): boolean {
  if (h.expires === undefined) return false;
  const t = Date.parse(h.expires);
  return Number.isNaN(t) || t <= now;
}

/** `?embed` (M47d): the map alone, for an iframe in a wiki, with a link to the full view. */
export function isEmbed(search = location.search): boolean {
  return new URLSearchParams(search).has("embed");
}

/** The share page's links: the full view when embedded, else Open in OpenNexus (D441). */
export function actions(code: ShareCode, key: Uint8Array, embed: boolean, here = location.href): ViewerAction[] {
  if (embed) {
    const full = new URL(here);
    full.searchParams.delete("embed");
    return [{ label: "Open Full View", href: full.href, newWindow: true }];
  }
  return [{ label: "Open in OpenNexus", href: appLink(code, key) }];
}

function draw(text: string, code: ShareCode, key: Uint8Array): void {
  let bundle;
  try {
    bundle = parseBundle(text);
  } catch (e) {
    throw new Stop(e instanceof BundleError && e.message.includes("version") ? "newer" : "damaged");
  }
  const host = el("div");
  host.id = "opennexus-viewer";
  document.body.replaceChildren(host);
  const embed = isEmbed();
  mount(host, bundle, { chrome: embed ? "none" : "full", actions: actions(code, key, embed) });
  document.title = bundle.title === "" ? "OpenNexus" : `${bundle.title} · OpenNexus`;
  window.OpenNexusShare = { text };
  document.documentElement.dataset.onxState = "ready";
  document.documentElement.dataset.onxReady = "true";
}

/** Asks for the password until it opens the map (each try derives the key afresh). */
function askPassword(sealed: Uint8Array, h: Header, code: ShareCode): void {
  const kdf = h.kdf;
  if (kdf === undefined) throw new Stop("damaged");
  const form = el("form");
  const label = el("label", "Password");
  const input = el("input");
  input.type = "password";
  input.id = "share-password";
  input.autocomplete = "off";
  input.required = true;
  label.htmlFor = input.id;
  const error = el("p", "", "share-error");
  error.id = "share-password-error";
  error.setAttribute("role", "alert");
  input.setAttribute("aria-describedby", error.id);
  const submit = el("button", "Open");
  submit.type = "submit";
  form.append(label, input, submit, error);
  card(
    "password",
    el("h1", "This map has a password"),
    el("p", "Whoever shared it can tell you the password. It never leaves this browser."),
    form,
  );
  document.title = "Password · OpenNexus";
  input.focus();
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    submit.disabled = true;
    error.textContent = "";
    void (async () => {
      try {
        const key = await passwordKeyBytes(input.value, kdf);
        const opened = await openBundle(sealed, await importKey(key));
        draw(opened.text, code, key);
      } catch (e) {
        if (e instanceof SealedError && e.kind === "damaged") {
          error.textContent = "That password doesn’t open this map.";
          document.documentElement.dataset.onxState = "wrong-password";
          submit.disabled = false;
          input.select();
          return;
        }
        fail(e);
      }
    })();
  });
}

function fail(e: unknown): void {
  if (e instanceof Stop && e.state !== "ready" && e.state !== "password") show(e.state);
  else if (e instanceof SealedError) show(e.kind);
  else show("damaged");
}

export async function start(fragment = location.hash): Promise<void> {
  show("loading");
  try {
    const code = parseFragment(fragment);
    if (code === null) throw new Stop("damaged");
    const sealed = await fetchSealed(code);
    const h = readHeader(sealed);
    if (expired(h)) throw new Stop("expired");
    if (code.key === undefined) {
      askPassword(sealed, h, code);
      return;
    }
    const opened = await openBundle(sealed, await importKey(code.key));
    draw(opened.text, code, code.key);
  } catch (e) {
    fail(e);
  }
}
