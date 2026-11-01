// Outlines (M49): a map without a viewer copy away from the Mac shows each canvas's topics
// as nested lists, as the viewer site does; a note away from the Mac shows its headings and
// bullets, each of which moves the cursor to its line.

import type { OutlineCanvas, OutlineTopic } from "../../viewer-app/src/document";

export interface NoteTopic {
  text: string;
  /** Its line in the note, counted from 1. */
  line: number;
  children: NoteTopic[];
}

/** A note's headings and bullets as a tree, read as OpenNexus's Markdown import reads them. */
export function noteOutline(text: string): NoteTopic[] {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  let start = 0;
  if (lines[0] === "---") {
    const end = lines.indexOf("---", 1);
    if (end > 0) start = end + 1;
  }
  const tops: NoteTopic[] = [];
  const stack: { level: number; topic: NoteTopic }[] = [];
  let fence = false;
  for (let i = start; i < lines.length; i++) {
    const raw = lines[i] ?? "";
    if (raw.trim().startsWith("```")) {
      fence = !fence;
      continue;
    }
    if (fence) continue;
    const h = /^(#{1,6})\s+(.*)$/.exec(raw.trim());
    const b = h === null ? /^(\s*)[-*+]\s+(?:\[[ xX]\]\s+)?(.*)$/.exec(raw) : null;
    if (h === null && b === null) continue;
    const level = h !== null ? (h[1]?.length ?? 1) : 100 + (b?.[1]?.replace(/\t/g, "    ").length ?? 0);
    const topic: NoteTopic = { text: ((h ?? b)?.[2] ?? "").trim(), line: i + 1, children: [] };
    while (stack.length > 0 && (stack[stack.length - 1]?.level ?? 0) >= level) stack.pop();
    const parent = stack[stack.length - 1];
    if (parent === undefined) tops.push(topic);
    else parent.topic.children.push(topic);
    stack.push({ level, topic });
  }
  return tops;
}

function list<T extends { text: string; children: T[] }>(doc: Document, items: T[], row: (li: HTMLElement, t: T) => void): HTMLElement {
  const ul = doc.createElement("ul");
  ul.className = "opennexus-outline-list";
  for (const t of items) {
    const li = doc.createElement("li");
    row(li, t);
    if (t.children.length > 0) li.append(list(doc, t.children, row));
    ul.append(li);
  }
  return ul;
}

/** A map's canvases as outlines, with notes. */
export function canvasOutlines(doc: Document, canvases: OutlineCanvas[]): HTMLElement[] {
  return canvases.map((c) => {
    const s = doc.createElement("section");
    const h = doc.createElement("h3");
    h.textContent = c.title === "" ? "Untitled canvas" : c.title;
    s.append(
      h,
      list<OutlineTopic>(doc, c.topics, (li, t) => {
        const span = doc.createElement("span");
        span.textContent = t.text;
        li.append(span);
        if (t.note !== undefined) {
          const p = doc.createElement("p");
          p.className = "opennexus-outline-note";
          p.textContent = t.note;
          li.append(p);
        }
      }),
    );
    return s;
  });
}

/** A note's outline, each topic a button that calls `go` with its line. */
export function noteOutlineList(doc: Document, topics: NoteTopic[], go: (line: number) => void): HTMLElement {
  return list(doc, topics, (li, t) => {
    const b = doc.createElement("button");
    b.type = "button";
    b.className = "opennexus-outline-topic";
    b.textContent = t.text;
    b.addEventListener("click", () => { go(t.line); });
    li.append(b);
  });
}
