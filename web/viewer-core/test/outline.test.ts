import { describe, expect, it } from "vitest";
import type { OutlineItem } from "../src/bundle";
import { ancestors, initiallyOpen, treeKey, visibleRows } from "../src/outline";

const item = (id: string, children: OutlineItem[] = [], folded = false): OutlineItem => ({ id, children, folded });
const tree = [item("root", [item("a", [item("a1"), item("a2")]), item("b", [item("b1")], true)]), item("float")];

describe("outline", () => {
  it("opens what the author left open", () => {
    expect([...initiallyOpen(tree)].sort()).toEqual(["a", "root"]);
  });

  it("lists the rows a reader can reach", () => {
    const open = initiallyOpen(tree);
    expect(visibleRows(tree, open).map((r) => `${r.id}@${String(r.level)}`)).toEqual(["root@1", "a@2", "a1@3", "a2@3", "b@2", "float@1"]);
  });

  it("moves and toggles like a tree view", () => {
    const open = initiallyOpen(tree);
    const rows = visibleRows(tree, open);
    expect(treeKey(rows, open, "root", "ArrowDown")).toEqual({ focus: "a" });
    expect(treeKey(rows, open, "a", "ArrowRight")).toEqual({ focus: "a1" });
    expect(treeKey(rows, open, "b", "ArrowRight")).toEqual({ toggle: "b" });
    expect(treeKey(rows, open, "a", "ArrowLeft")).toEqual({ toggle: "a" });
    expect(treeKey(rows, open, "a1", "ArrowLeft")).toEqual({ focus: "a" });
    expect(treeKey(rows, open, "root", "ArrowLeft")).toEqual({ toggle: "root" });
    expect(treeKey(rows, open, "float", "ArrowLeft")).toEqual({});
    expect(treeKey(rows, open, "a2", "End")).toEqual({ focus: "float" });
    expect(treeKey(rows, open, "a2", "Home")).toEqual({ focus: "root" });
  });

  it("knows each topic's ancestors", () => {
    expect(ancestors(tree, "b1")).toEqual(["root", "b"]);
    expect(ancestors(tree, "float")).toEqual([]);
    expect(ancestors(tree, "nope")).toBeNull();
  });
});
