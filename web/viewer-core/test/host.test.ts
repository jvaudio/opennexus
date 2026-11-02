import { describe, expect, it } from "vitest";
import { parseBundle } from "../src/bundle";
import { mount, type HostLinks } from "../src/viewer";

/** The value, which the test expects to be there. */
function must<T>(v: T | null | undefined): T {
  if (v === null || v === undefined) throw new Error("expected a value");
  return v;
}

const theme = { canvas: "#FFFFFF", ink: "#000000", ink2: "#333333", accent: "#6E56CF", dark: false };
const canvas = (id: string, topics: Record<string, object>, frames: Record<string, object>) => ({
  id, title: id, type: "mindmap", typeName: "Mind map", theme,
  layouts: { saved: { svg: '<svg xmlns="http://www.w3.org/2000/svg"/>', viewBox: [0, 0, 1000, 500], topics: frames } },
  outline: [{ id: "r", children: Object.keys(topics).filter((k) => k !== "r").map((k) => ({ id: k })) }],
  topics,
});
const bundle = () => ({
  format: "opennexus-viewer", version: 1, title: "Plan", assets: {},
  canvases: [
    canvas(
      "c1",
      {
        r: { text: "Plan", label: "Plan", note: "See [[Risks]] and [[Budget#Q3|the budget]]; [[not closed" },
        a: { text: "Alpha", label: "Alpha", link: { href: "obsidian://open?vault=V&file=Risks", kind: "other" } },
        b: { text: "Beta", label: "Beta", link: { href: "javascript:alert(1)", kind: "other" } },
        c: { text: "Gamma", label: "Gamma", link: { href: "https://example.com/", kind: "web" } },
      },
      {
        r: { frame: [450, 230, 100, 40], depth: 0 },
        a: { frame: [100, 100, 80, 30], depth: 1, parent: "r" },
        a1: { frame: [60, 160, 80, 30], depth: 2, parent: "a" },
        b: { frame: [800, 300, 80, 30], depth: 1, parent: "r" },
        // A loop a crafted bundle could hold.
        x: { frame: [0, 0, 10, 10], depth: 3, parent: "y" },
        y: { frame: [0, 0, 10, 10], depth: 3, parent: "x" },
        c: { frame: [900, 450, 80, 30], depth: 1, parent: "r" },
      },
    ),
    canvas("c2", { r: { text: "Two", label: "Two" } }, { r: { frame: [0, 0, 100, 40], depth: 0 } }),
  ],
});

function host(): HTMLElement {
  const h = document.createElement("div");
  Object.defineProperty(h, "clientWidth", { value: 800 });
  document.body.replaceChildren(h);
  return h;
}

describe("links the host opens (M49)", () => {
  const opened: [string, boolean][] = [];
  const links: HostLinks = {
    accepts: (href) => href.startsWith("obsidian:") || href.startsWith("javascript:"),
    open: (target, wikilink) => opened.push([target, wikilink]),
    wikilinks: true,
  };

  it("turns wikilinks in notes into buttons, and leaves the rest as text", () => {
    opened.length = 0;
    const v = mount(host(), parseBundle(JSON.stringify(bundle())), { hostLinks: links });
    v.select("r");
    const note = must(v.element.querySelector(".onx-note"));
    const buttons = Array.from(note.querySelectorAll("button"));
    expect(buttons.map((b) => b.textContent)).toEqual(["Risks", "the budget"]);
    expect(note.textContent).toBe("See Risks and the budget; [[not closed");
    expect(note.querySelector("a")).toBeNull();
    for (const b of buttons) b.click();
    expect(opened).toEqual([["Risks", true], ["Budget#Q3", true]]);
  });

  it("opens the hyperlinks it accepts, never as links", () => {
    opened.length = 0;
    const v = mount(host(), parseBundle(JSON.stringify(bundle())), { hostLinks: links });
    v.select("a");
    must(v.element.querySelector<HTMLButtonElement>(".onx-link button")).click();
    expect(opened).toEqual([["obsidian://open?vault=V&file=Risks", false]]);
    // The host decides: whatever it takes, the viewer never makes an <a> of it.
    v.select("b");
    expect(v.element.querySelector(".onx-link a")).toBeNull();
    v.select("c");
    expect(must(v.element.querySelector<HTMLAnchorElement>(".onx-link a")).href).toBe("https://example.com/");
  });

  it("without a host, wikilinks are text and obsidian: links aren't followed", () => {
    const v = mount(host(), parseBundle(JSON.stringify(bundle())));
    v.select("r");
    expect(must(v.element.querySelector(".onx-note")).querySelector("button")).toBeNull();
    v.select("a");
    expect(v.element.querySelector(".onx-link a")).toBeNull();
    expect(v.element.querySelector(".onx-link code")?.textContent).toBe("obsidian://open?vault=V&file=Risks");
  });
});

describe("selection, branches and the camera (M49)", () => {
  it("tells the host what's selected, once per change", () => {
    const seen: string[] = [];
    const v = mount(host(), parseBundle(JSON.stringify(bundle())), {
      onSelect: (c, t) => seen.push(`${c}:${t ?? "-"}`),
    });
    v.select("a");
    v.select("a");
    v.select("b");
    v.show(1);
    expect(seen).toEqual(["c1:-", "c1:a", "c1:b", "c2:-"]);
  });

  it("frames a branch: the topic and everything under it", () => {
    const v = mount(host(), parseBundle(JSON.stringify(bundle())));
    expect(v.focus("gone")).toBe(false);
    expect(v.focus("a")).toBe(true);
    const branch = v.view();
    // a (100,100)–(180,130) and a1 (60,160)–(140,190): centred in the 800 × 600 viewport.
    expect((60 + 180) / 2 * branch.k + branch.x).toBeCloseTo(400, 6);
    expect((100 + 190) / 2 * branch.k + branch.y).toBeCloseTo(300, 6);
    expect(v.focus("x")).toBe(true);
  });

  it("gives and takes the camera", () => {
    const v = mount(host(), parseBundle(JSON.stringify(bundle())));
    v.setView({ x: 12, y: -40, k: 0.5 });
    expect(v.view()).toEqual({ x: 12, y: -40, k: 0.5 });
  });
});
