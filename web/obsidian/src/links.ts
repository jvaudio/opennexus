// Links out of a map into the vault (M49). Wikilinks in topics' notes, and hyperlinks that
// are wikilinks or `obsidian://open` links to this vault, open vault notes through the
// workspace API, and only notes that exist: a map can come from anyone, and a link mustn't
// create notes. `obsidian://opennexus` links (Copy link to topic) reopen a map at a topic.

import { Notice, type App } from "obsidian";
import type { HostLinks } from "../../viewer-core/src/viewer";

export interface TopicTarget {
  /** The map's vault path: a `.nexusjson` file or a `.nexus` folder. */
  file: string;
  canvas?: string;
  topic?: string;
}

export type Target = { kind: "note"; link: string } | ({ kind: "topic" } & TopicTarget);

export const PROTOCOL_ACTION = "opennexus";

/** What a topic's hyperlink points to in `vault`, or undefined for links the vault doesn't take. */
export function linkTarget(href: string, vault: string): Target | undefined {
  const wiki = /^\[\[([^[\]|\n]+)(?:\|[^[\]\n]*)?\]\]$/.exec(href.trim());
  if (wiki?.[1] !== undefined) return { kind: "note", link: wiki[1].trim() };
  let u: URL;
  try {
    u = new URL(href);
  } catch {
    return undefined;
  }
  if (u.protocol !== "obsidian:") return undefined;
  const v = u.searchParams.get("vault");
  if (v !== null && v !== vault) return undefined;
  const action = u.hostname === "" ? u.pathname.replace(/^\/+/, "") : u.hostname;
  const file = u.searchParams.get("file");
  if (file === null || file === "") return undefined;
  if (action === "open") return { kind: "note", link: file };
  if (action === PROTOCOL_ACTION) return { kind: "topic", ...topicTarget(Object.fromEntries(u.searchParams)) };
  return undefined;
}

/** A topic target from `obsidian://opennexus`'s parameters. */
export function topicTarget(params: Record<string, string | undefined>): TopicTarget {
  const t: TopicTarget = { file: params.file ?? "" };
  if (params.canvas !== undefined && params.canvas !== "") t.canvas = params.canvas;
  if (params.topic !== undefined && params.topic !== "") t.topic = params.topic;
  return t;
}

/** The link "Copy link to topic" gives. */
export function topicLink(vault: string, t: TopicTarget): string {
  const q = new URLSearchParams({ vault, file: t.file });
  if (t.canvas !== undefined) q.set("canvas", t.canvas);
  if (t.topic !== undefined) q.set("topic", t.topic);
  return `obsidian://${PROTOCOL_ACTION}?${q.toString().replace(/\+/g, "%20")}`;
}

/** Opens a vault note (`Note` or `Note#Heading`) if it exists; says so if it doesn't. */
export function openNote(app: App, link: string, from: string): boolean {
  const path = link.split("#")[0]?.trim() ?? "";
  const dest = path === "" ? null : app.metadataCache.getFirstLinkpathDest(path, from);
  if (dest === null) {
    new Notice(`There’s no note “${path}” in this vault.`);
    return false;
  }
  void app.workspace.openLinkText(link, from);
  return true;
}

/** The viewer's host links for a map at `from`. */
export function hostLinks(app: App, from: string, openTopic: (t: TopicTarget) => void): HostLinks {
  const vault = app.vault.getName();
  return {
    wikilinks: true,
    accepts: (href) => linkTarget(href, vault) !== undefined,
    open: (target, wikilink) => {
      const t: Target | undefined = wikilink ? { kind: "note", link: target } : linkTarget(target, vault);
      if (t?.kind === "topic") openTopic(t);
      else if (t !== undefined) openNote(app, t.link, from);
    },
  };
}
