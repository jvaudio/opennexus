// The outline as an ARIA tree (WAI-ARIA tree view pattern): one tab stop, arrow keys to
// move, Right and Left to open and close, Home and End, Return to show the topic.

import type { OutlineItem } from "./bundle";

export interface Row {
  id: string;
  level: number;
  parent: string | null;
  hasChildren: boolean;
}

/** The rows a reader can reach with the arrow keys: children of closed items are skipped. */
export function visibleRows(items: readonly OutlineItem[], open: ReadonlySet<string>, level = 1, parent: string | null = null): Row[] {
  const rows: Row[] = [];
  for (const item of items) {
    rows.push({ id: item.id, level, parent, hasChildren: item.children.length > 0 });
    if (item.children.length > 0 && open.has(item.id)) rows.push(...visibleRows(item.children, open, level + 1, item.id));
  }
  return rows;
}

/** Items open at first: everything the author didn't fold. */
export function initiallyOpen(items: readonly OutlineItem[], out = new Set<string>()): Set<string> {
  for (const item of items) {
    if (item.children.length > 0 && !item.folded) out.add(item.id);
    initiallyOpen(item.children, out);
  }
  return out;
}

export type TreeKey = "ArrowDown" | "ArrowUp" | "ArrowRight" | "ArrowLeft" | "Home" | "End";

/** What a key does on row `id`: the row to move to, or an item to open or close. */
export function treeKey(
  rows: readonly Row[],
  open: ReadonlySet<string>,
  id: string,
  key: TreeKey,
): { focus?: string; toggle?: string } {
  const i = rows.findIndex((r) => r.id === id);
  const row = rows[i];
  if (row === undefined) return {};
  switch (key) {
    case "ArrowDown":
      return { focus: rows[Math.min(rows.length - 1, i + 1)]?.id ?? id };
    case "ArrowUp":
      return { focus: rows[Math.max(0, i - 1)]?.id ?? id };
    case "Home":
      return { focus: rows[0]?.id ?? id };
    case "End":
      return { focus: rows[rows.length - 1]?.id ?? id };
    case "ArrowRight":
      if (!row.hasChildren) return {};
      return open.has(id) ? { focus: rows[i + 1]?.id ?? id } : { toggle: id };
    case "ArrowLeft":
      if (row.hasChildren && open.has(id)) return { toggle: id };
      return row.parent === null ? {} : { focus: row.parent };
  }
}

/** Every ancestor of `id`, nearest last, or null when it isn't in the outline. */
export function ancestors(items: readonly OutlineItem[], id: string): string[] | null {
  for (const item of items) {
    if (item.id === id) return [];
    const below = ancestors(item.children, id);
    if (below !== null) return [item.id, ...below];
  }
  return null;
}
