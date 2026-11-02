import { describe, expect, it } from "vitest";
import { flight } from "../src/flight";

const W = 1000;
const H = 600;
/** The world point at the viewport's centre, and the world width seen. */
const seen = (v: { x: number; y: number; k: number }) => ({ cx: (W / 2 - v.x) / v.k, cy: (H / 2 - v.y) / v.k, w: W / v.k });

describe("the camera's flight between slides", () => {
  it("starts and ends exactly at the two views", () => {
    const a = { k: 1, x: 0, y: 0 };
    const b = { k: 0.5, x: -2000, y: 300 };
    const f = flight(a, b, W, H);
    expect(f.at(0)).toEqual(a);
    expect(f.at(1)).toEqual(b);
    // Continuous at the end: no jump onto the last view.
    expect(seen(f.at(1 - 1e-7)).cx).toBeCloseTo(seen(b).cx, 1);
    expect(f.at(1 - 1e-7).k).toBeCloseTo(b.k, 4);
  });

  it("zooms out on the way across a long distance, and back in", () => {
    const a = { k: 1, x: 0, y: 0 };
    const b = { k: 1, x: -20000, y: 0 };
    const f = flight(a, b, W, H);
    const mid = f.at(0.5);
    expect(mid.k).toBeLessThan(0.3);
    expect(seen(mid).cx).toBeCloseTo((seen(a).cx + seen(b).cx) / 2, 0);
    // Centred on the line between them, at every step.
    for (const t of [0.1, 0.3, 0.7, 0.9]) expect(seen(f.at(t)).cy).toBeCloseTo(seen(a).cy, 6);
  });

  it("zooms in place when the centre doesn't move", () => {
    const a = { k: 1, x: 0, y: 0 };
    const b = { k: 4, x: W / 2 - (W / 2) * 4, y: H / 2 - (H / 2) * 4 };
    const f = flight(a, b, W, H);
    const mid = seen(f.at(0.5));
    expect(mid.cx).toBeCloseTo(W / 2, 6);
    expect(mid.w).toBeCloseTo(W / 2, 3);
  });

  it("takes as long as the app's (0.7 s), near or far", () => {
    expect(flight({ k: 1, x: 0, y: 0 }, { k: 1, x: -5, y: 0 }, W, H).duration).toBe(700);
    expect(flight({ k: 1, x: 0, y: 0 }, { k: 1, x: -1e7, y: 0 }, W, H).duration).toBe(700);
  });
});
