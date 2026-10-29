import { describe, expect, it } from "vitest";
import { BundleError, parseBundle } from "../src/bundle";

const minimal = {
  format: "opennexus-viewer", version: 1, title: "T", assets: {},
  canvases: [{
    id: "c1", title: "C", type: "mindmap", typeName: "Mind map",
    theme: { canvas: "#FFFFFF", ink: "#000000", ink2: "#333333", accent: "#6E56CF", dark: false },
    layouts: { saved: { svg: "<svg/>", viewBox: [0, 0, 10, 10], topics: { constructor: { frame: [0, 0, 1, 1], depth: 0 } } } },
    outline: [{ id: "constructor" }],
    topics: { constructor: { text: "Hi", label: "Hi. Central topic." } },
  }],
};

describe("parseBundle", () => {
  it("reads a minimal bundle, ids like constructor included", () => {
    const b = parseBundle(JSON.stringify(minimal));
    const c = b.canvases[0];
    expect(c?.topics.get("constructor")?.text).toBe("Hi");
    expect(c?.topics.get("toString")).toBeUndefined();
    expect(b.lang).toBe("en");
  });

  it("names the first bad field", () => {
    const bad = (edit: (o: typeof minimal) => unknown): string => {
      const o = structuredClone(minimal);
      edit(o);
      try {
        parseBundle(JSON.stringify(o));
        return "";
      } catch (e) {
        expect(e).toBeInstanceOf(BundleError);
        return (e as Error).message;
      }
    };
    expect(bad((o) => { (o as { version: number }).version = 2; })).toMatch(/version/);
    expect(bad((o) => { o.canvases = []; })).toMatch(/no canvases/);
    expect(bad((o) => { (o.canvases[0] as { theme: { ink: string } }).theme.ink = "red"; })).toMatch(/theme\.ink/);
    expect(bad((o) => { (o.canvases[0] as { layouts: { saved: { viewBox: number[] } } }).layouts.saved.viewBox = [0, 0]; })).toMatch(/viewBox/);
    expect(() => parseBundle("{")).toThrow(BundleError);
    expect(() => parseBundle("[]")).toThrow(BundleError);
  });
});
