// Search, as the app's Find does it (`TextSearch.find`): the query is a literal, matched
// case-insensitively unless Match case is on; Whole words wraps it in ICU's `\b`. Topics
// are scanned in outline order, and each match in a field counts once.

import type { Bundle, Canvas, OutlineItem } from "./bundle";

export interface SearchOptions {
  matchCase: boolean;
  wholeWords: boolean;
  /** Notes and comments ("+ Notes" covers comments too, as in the app). */
  notes: boolean;
  labels: boolean;
  allCanvases: boolean;
}

export const defaultOptions: SearchOptions = {
  matchCase: false,
  wholeWords: false,
  notes: false,
  labels: false,
  allCanvases: false,
};

export type Field = "text" | "note" | "label" | "comment";

export interface Match {
  canvas: number;
  topic: string;
  field: Field;
  index: number;
  /** UTF-16 offset and length, like the app's NSRange. */
  start: number;
  length: number;
}

/** ICU's word characters for `\b` (UREGEX_UWORD off): letters, marks, digits, connectors, ZWJ/ZWNJ. */
const word = String.raw`[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}‌‍]`;
/** `\b`: the characters on either side differ in being word characters. */
const boundary = `(?:(?<=${word})(?!${word})|(?<!${word})(?=${word}))`;

export function escapeLiteral(s: string): string {
  return s.replace(/[\^$\\.*+?()[\]{}|/]/g, "\\$&");
}

/** The expression for a query, or null when it's empty. */
export function expression(query: string, o: Pick<SearchOptions, "matchCase" | "wholeWords">): RegExp | null {
  if (query === "") return null;
  let pattern = escapeLiteral(query);
  if (o.wholeWords) pattern = `${boundary}(?:${pattern})${boundary}`;
  return new RegExp(pattern, o.matchCase ? "gu" : "giu");
}

export function* preorder(items: readonly OutlineItem[]): Generator<string> {
  for (const item of items) {
    yield item.id;
    yield* preorder(item.children);
  }
}

function scanCanvas(c: Canvas, ci: number, re: RegExp, o: SearchOptions, out: Match[]): void {
  for (const id of preorder(c.outline)) {
    const t = c.topics.get(id);
    if (t === undefined) continue;
    const scan = (s: string, field: Field, index = 0): void => {
      re.lastIndex = 0;
      for (const m of s.matchAll(re)) {
        if (m[0].length > 0) out.push({ canvas: ci, topic: id, field, index, start: m.index, length: m[0].length });
      }
    };
    scan(t.text, "text");
    if (o.notes && t.note !== undefined) scan(t.note, "note");
    if (o.notes) t.comments.forEach((cm, i) => { scan(cm.text, "comment", i); });
    if (o.labels) t.labels.forEach((l, i) => { scan(l, "label", i); });
  }
}

/** Every match on the current canvas (or every canvas), in outline order. */
export function find(bundle: Bundle, current: number, query: string, o: SearchOptions): Match[] {
  const re = expression(query, o);
  if (re === null) return [];
  const out: Match[] = [];
  bundle.canvases.forEach((c, i) => {
    if (o.allCanvases || i === current) scanCanvas(c, i, re, o, out);
  });
  return out;
}
