// A topic's details: everything the bundle says about it, as text. Nothing from the
// bundle is ever parsed as HTML.

import type { Topic } from "./bundle";
import { safeLink } from "./sanitize";

export interface DetailsContext {
  doc: Document;
  t: (key: string) => string;
  /** A download URL for an included attachment (an octet-stream blob), or undefined. */
  attachment: (asset: string) => string | undefined;
  /** Shows the topic a topic link points to. */
  goTo: (canvas: string, topic: string) => void;
}

function el<K extends keyof HTMLElementTagNameMap>(doc: Document, tag: K, text?: string, cls?: string): HTMLElementTagNameMap[K] {
  const e = doc.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls !== undefined) e.className = cls;
  return e;
}

function section(c: DetailsContext, title: string, ...content: Node[]): HTMLElement {
  const s = el(c.doc, "section", undefined, "onx-section");
  s.append(el(c.doc, "h3", title), ...content);
  return s;
}

function chips(c: DetailsContext, items: readonly string[]): HTMLElement {
  const ul = el(c.doc, "ul", undefined, "onx-chips");
  for (const item of items) ul.append(el(c.doc, "li", item));
  return ul;
}

export function bytes(n: number): string {
  if (n < 1000) return `${String(n)} B`;
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)} KB`;
  return `${(n / 1_000_000).toFixed(1)} MB`;
}

/** Fills `into` with the details of `topic`. */
export function renderDetails(into: HTMLElement, topic: Topic, c: DetailsContext): void {
  const { doc, t } = c;
  const body: Node[] = [];
  if (topic.type !== undefined) body.push(section(c, t("type"), el(doc, "p", topic.type)));
  if (topic.task !== undefined) body.push(section(c, t("task"), el(doc, "p", topic.task)));
  if (topic.labels.length > 0) body.push(section(c, t("labels"), chips(c, topic.labels)));
  if (topic.markers.length > 0) body.push(section(c, t("markers"), chips(c, topic.markers)));
  if (topic.fields.length > 0) {
    const dl = el(doc, "dl", undefined, "onx-fields");
    for (const f of topic.fields) dl.append(el(doc, "dt", f.key), el(doc, "dd", f.value));
    body.push(section(c, t("fields"), dl));
  }
  if (topic.note !== undefined) body.push(section(c, t("note"), el(doc, "p", topic.note, "onx-note")));
  if (topic.link !== undefined) {
    const l = topic.link;
    let node: HTMLElement;
    if (l.kind === "topic" && l.canvas !== undefined && l.topic !== undefined) {
      const { canvas, topic: target } = l;
      node = el(doc, "button", l.href, "onx-linkbutton");
      node.setAttribute("type", "button");
      node.addEventListener("click", () => { c.goTo(canvas, target); });
    } else {
      const href = safeLink(l.href);
      if (href === null) {
        node = el(doc, "code", l.href);
      } else {
        const a = el(doc, "a", l.href);
        a.href = href;
        a.rel = "noopener noreferrer";
        a.target = "_blank";
        node = a;
      }
    }
    const p = el(doc, "p", undefined, "onx-link");
    p.append(node);
    body.push(section(c, t("link"), p));
  }
  if (topic.attachments.length > 0) {
    const ul = el(doc, "ul", undefined, "onx-attachments");
    for (const a of topic.attachments) {
      const li = el(doc, "li");
      const url = a.asset === undefined ? undefined : c.attachment(a.asset);
      if (url === undefined) {
        li.append(el(doc, "span", a.name), el(doc, "span", ` — ${t("notIncluded")}`, "onx-muted"));
      } else {
        const link = el(doc, "a", a.name);
        link.href = url;
        link.download = a.name;
        li.append(link);
      }
      if (a.size !== undefined) li.append(el(doc, "span", ` (${bytes(a.size)})`, "onx-muted"));
      ul.append(li);
    }
    body.push(section(c, t("attachments"), ul));
  }
  if (topic.comments.length > 0) {
    const ol = el(doc, "ol", undefined, "onx-comments");
    for (const cm of topic.comments) {
      const li = el(doc, "li");
      const by = el(doc, "p", undefined, "onx-byline");
      by.append(el(doc, "strong", cm.author));
      if (cm.date !== "") by.append(el(doc, "span", ` · ${cm.date.slice(0, 10)}`, "onx-muted"));
      li.append(by, el(doc, "p", cm.text));
      ol.append(li);
    }
    body.push(section(c, t("comments"), ol));
  }
  into.replaceChildren(...body);
}
