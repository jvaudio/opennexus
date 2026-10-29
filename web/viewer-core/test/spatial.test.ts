import { describe, expect, it } from "vitest";
import { center, next, type Point } from "../src/spatial";

describe("spatial navigation", () => {
  // A central topic with children right and left, as a mind map lays them out.
  const centers = new Map<string, Point>([
    ["root", { x: 0, y: 0 }],
    ["r1", { x: 200, y: -60 }],
    ["r2", { x: 200, y: 60 }],
    ["l1", { x: -200, y: 0 }],
    ["r1a", { x: 380, y: -80 }],
  ]);

  it("goes to the nearest topic ahead, sideways distance costing more", () => {
    expect(next("root", "right", centers)).toBe("r1");
    expect(next("root", "left", centers)).toBe("l1");
    expect(next("r1", "down", centers)).toBe("r2");
    expect(next("r2", "up", centers)).toBe("r1");
    expect(next("r1", "right", centers)).toBe("r1a");
    expect(next("l1", "left", centers)).toBeNull();
  });

  it("breaks ties on id", () => {
    const tie = new Map<string, Point>([["a", { x: 0, y: 0 }], ["c", { x: 100, y: 10 }], ["b", { x: 100, y: -10 }]]);
    expect(next("a", "right", tie)).toBe("b");
  });

  it("finds a rectangle's centre", () => {
    expect(center([10, 20, 100, 40])).toEqual({ x: 60, y: 40 });
  });
});
