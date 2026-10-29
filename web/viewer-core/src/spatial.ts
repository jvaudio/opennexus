// Arrow keys move between topics as on the app's canvas (`SpatialNavigation.next`): the
// nearest centre ahead, where sideways distance costs 2.2 times as much as distance ahead.

import type { Rect } from "./bundle";

export type Direction = "left" | "right" | "up" | "down";

export interface Point {
  x: number;
  y: number;
}

export function center(r: Rect): Point {
  return { x: r[0] + r[2] / 2, y: r[1] + r[3] / 2 };
}

export function next(current: string, direction: Direction, centers: ReadonlyMap<string, Point>): string | null {
  const cur = centers.get(current);
  if (cur === undefined) return null;
  let best: string | null = null;
  let bestScore = Infinity;
  for (const [id, p] of centers) {
    if (id === current) continue;
    const dx = p.x - cur.x;
    const dy = p.y - cur.y;
    const [main, cross] =
      direction === "right" ? [dx, dy] : direction === "left" ? [-dx, dy] : direction === "down" ? [dy, dx] : [-dy, dx];
    if (main <= 4) continue;
    const score = main + 2.2 * Math.abs(cross);
    // Ties break on id so the result is deterministic.
    if (score < bestScore || (score === bestScore && best !== null && id < best)) {
      bestScore = score;
      best = id;
    }
  }
  return best;
}
