import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { parseBundle, type Layout } from "../src/bundle";
import { CAPTION, focusRect, slideView, union } from "../src/present";
import { actionHref, mount } from "../src/viewer";

/** The value, which the test expects to be there. */
function must<T>(v: T | null | undefined): T {
  if (v === null || v === undefined) throw new Error("expected a value");
  return v;
}

const theme = { canvas: "#FFFFFF", ink: "#000000", ink2: "#333333", accent: "#6E56CF", dark: false };
const deck = {
  move: "fly",
  aspect: 16 / 9,
  slides: [
    { kicker: "PLAN · MIND MAP", title: "Plan", focus: [], highlight: [] },
    { kicker: "STEP 1 OF 2", title: "Alpha", focus: ["a", "a1"], highlight: ["a"], note: "Say hello" },
    { kicker: "STEP 2 OF 2", title: "Beta", focus: ["b"], highlight: [] },
  ],
};
const bundle = (more: object = {}) => ({
  format: "opennexus-viewer", version: 1, title: "Plan", assets: {},
  canvases: [{
    id: "c1", title: "Plan", type: "mindmap", typeName: "Mind map", theme,
    layouts: {
      saved: {
        svg: '<svg xmlns="http://www.w3.org/2000/svg"/>', viewBox: [0, 0, 1000, 500],
        topics: {
          r: { frame: [450, 230, 100, 40], depth: 0 },
          a: { frame: [100, 100, 80, 30], depth: 1 },
          a1: { frame: [100, 200, 80, 30], depth: 2 },
          b: { frame: [800, 300, 80, 30], depth: 1 },
        },
      },
    },
    outline: [{ id: "r", children: [{ id: "a", children: [{ id: "a1" }] }, { id: "b" }] }],
    topics: { r: { text: "Plan", label: "Plan" }, a: { text: "Alpha", label: "Alpha" }, a1: { text: "Alpha one", label: "Alpha one" }, b: { text: "Beta", label: "Beta" } },
    deck,
    ...more,
  }],
});

describe("the deck in a bundle", () => {
  it("is read when present, and checked", () => {
    const c = parseBundle(JSON.stringify(bundle())).canvases[0];
    expect(c?.deck?.move).toBe("fly");
    expect(c?.deck?.slides[1]).toEqual({ kicker: "STEP 1 OF 2", title: "Alpha", focus: ["a", "a1"], highlight: ["a"], note: "Say hello" });
    expect(() => parseBundle(JSON.stringify(bundle({ deck: { ...deck, move: "warp" } })))).toThrow(/deck\.move/);
    expect(() => parseBundle(JSON.stringify(bundle({ deck: { ...deck, aspect: 0 } })))).toThrow(/deck\.aspect/);
    expect(() => parseBundle(JSON.stringify(bundle({ deck: { ...deck, slides: [{ title: "x" }] } })))).toThrow(/slides\[0\]/);
    expect(parseBundle(JSON.stringify(bundle({ deck: undefined }))).canvases[0]?.deck).toBeUndefined();
  });
});

describe("framing a slide", () => {
  const layout: Layout = must(parseBundle(JSON.stringify(bundle())).canvases[0]).layouts.saved;

  it("frames the focus topics' frames together, or the whole map", () => {
    expect(union([])).toBeUndefined();
    expect(focusRect(layout, must(deck.slides[1]))).toEqual([100, 100, 80, 130]);
    expect(focusRect(layout, must(deck.slides[0]))).toEqual([0, 0, 1000, 500]);
    expect(focusRect(layout, { ...must(deck.slides[2]), focus: ["gone"] })).toEqual([0, 0, 1000, 500]);
  });

  it("centres the focus in the deck's aspect, above the caption", () => {
    const W = 1600;
    const H = 1000;
    const v = slideView(layout, must(deck.slides[1]), 16 / 9, W, H);
    const [x, y, w, h] = focusRect(layout, must(deck.slides[1]));
    const cx = v.x + (x + w / 2) * v.k;
    const cy = v.y + (y + h / 2) * v.k;
    expect(cx).toBeCloseTo(W / 2, 6);
    expect(cy).toBeCloseTo((H - CAPTION) / 2, 6);
    // Never more than twice the map's size.
    expect(v.k).toBeLessThanOrEqual(2);
    expect(h * v.k).toBeLessThan(H - CAPTION);
  });
});

describe("Present", () => {
  let host: HTMLElement;
  beforeEach(() => {
    // Reduced motion: the camera cuts, so each step lands at once.
    vi.stubGlobal("matchMedia", () => ({ matches: true }));
    host = document.createElement("div");
    document.body.replaceChildren(host);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });
  const key = (k: string) => document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));

  it("plays the deck: P starts, the keys step and go back, N shows the note, Esc leaves", () => {
    const v = mount(host, parseBundle(JSON.stringify(bundle())));
    const root = v.element;
    const button = [...root.querySelectorAll<HTMLButtonElement>(".onx-tools .onx-button")].find((b) => b.textContent === "Present");
    expect(button?.hidden).toBe(false);
    const stage = must(root.querySelector<HTMLElement>(".onx-stage"));
    const before = stage.style.transform;
    must(root.querySelector<HTMLElement>(".onx-viewport")).dispatchEvent(new KeyboardEvent("keydown", { key: "p", bubbles: true }));
    expect(root.classList.contains("onx-presenting")).toBe(true);
    expect(root.dataset.onxSlide).toBe("0");
    expect(root.querySelector(".onx-slide-title")?.textContent).toBe("Plan");
    expect(root.querySelector(".onx-slide-count")?.textContent).toBe("1 of 3");
    // The title slide frames the whole map, dimming nothing.
    expect(root.querySelector<SVGElement>(".onx-dim")?.style.display).toBe("none");
    key("ArrowRight");
    expect(root.dataset.onxSlide).toBe("1");
    expect(root.querySelector(".onx-slide-title")?.textContent).toBe("Alpha");
    expect(root.querySelectorAll(".onx-dim rect[fill=black]")).toHaveLength(2);
    expect(root.querySelectorAll(".onx-step")).toHaveLength(1);
    expect(root.querySelector("[role=status].onx-sr")?.textContent).toBe("Alpha, 2 of 3");
    const note = must(root.querySelector<HTMLElement>(".onx-slide-note"));
    expect(note.hidden).toBe(true);
    key("n");
    expect(note.hidden).toBe(false);
    expect(note.textContent).toBe("Say hello");
    key("End");
    expect(root.dataset.onxSlide).toBe("2");
    expect(root.querySelector<HTMLButtonElement>("[aria-label='Next Slide']")?.disabled).toBe(true);
    key(" ");
    expect(root.dataset.onxSlide).toBe("2");
    key("PageUp");
    expect(root.dataset.onxSlide).toBe("1");
    key("Home");
    expect(root.dataset.onxSlide).toBe("0");
    key("Escape");
    expect(root.classList.contains("onx-presenting")).toBe(false);
    expect(root.querySelector(".onx-caption")).toBeNull();
    expect(root.querySelector(".onx-dim")).toBeNull();
    // The camera is back where it was.
    expect(stage.style.transform).toBe(before);
    // And the keys are the map's again.
    key("ArrowRight");
    expect(root.dataset.onxSlide).toBeUndefined();
    v.destroy();
  });

  it("isn't offered without a deck", () => {
    const v = mount(host, parseBundle(JSON.stringify(bundle({ deck: undefined }))));
    const button = [...v.element.querySelectorAll<HTMLButtonElement>(".onx-tools .onx-button")].find((b) => b.textContent === "Present");
    expect(button?.hidden).toBe(true);
    expect(v.present()).toBe(false);
  });
});

describe("mount options", () => {
  it("embeds the map alone, with the host's links in its corner", () => {
    const host = document.createElement("div");
    document.body.replaceChildren(host);
    const runs: string[] = [];
    const v = mount(host, parseBundle(JSON.stringify(bundle())), {
      chrome: "none",
      actions: [
        { label: "Open Full View", href: "https://viewer.example/s/#1.u.x.y", newWindow: true },
        { label: "Bad", href: "javascript:alert(1)" },
        { label: "Run", run: () => runs.push("ran") },
      ],
    });
    const root = v.element;
    expect(root.classList.contains("onx-embed")).toBe(true);
    const corner = must(root.querySelector(".onx-viewport .onx-actions"));
    const link = must(corner.querySelector("a"));
    expect(link.href).toBe("https://viewer.example/s/#1.u.x.y");
    expect(link.target).toBe("_blank");
    expect(link.rel).toBe("noopener");
    expect(corner.textContent).not.toContain("Bad");
    must(corner.querySelector("button")).click();
    expect(runs).toEqual(["ran"]);
    expect(v.present()).toBe(false);
    // Selecting a topic doesn't open details nobody can see.
    v.select("a");
    expect(root.querySelector<HTMLElement>(".onx-details")?.hidden).toBe(true);
  });

  it("puts the host's links in the bar with full chrome", () => {
    const host = document.createElement("div");
    document.body.replaceChildren(host);
    const v = mount(host, parseBundle(JSON.stringify(bundle())), { actions: [{ label: "Open in OpenNexus", href: "opennexus://view#1.u.x.y" }] });
    const link = v.element.querySelector<HTMLAnchorElement>(".onx-bar .onx-actions a");
    expect(link?.href).toBe("opennexus://view#1.u.x.y");
    expect(link?.target).toBe("");
  });

  it("allows only web, relative and opennexus: links", () => {
    const base = "https://viewer.example/s/";
    expect(actionHref("../", base)).toBe("https://viewer.example/");
    expect(actionHref("opennexus://view#x", base)).toBe("opennexus://view#x");
    expect(actionHref("javascript:alert(1)", base)).toBeNull();
    expect(actionHref("data:text/html,hi", base)).toBeNull();
    expect(actionHref("http://[", base)).toBeNull();
  });
});
