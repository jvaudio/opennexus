import { describe, expect, it } from "vitest";
import type { Bundle, Canvas, Topic } from "../src/bundle";
import { defaultOptions, escapeLiteral, expression, find } from "../src/search";

function topic(text: string, extra: Partial<Topic> = {}): Topic {
  return { text, label: text, comments: [], attachments: [], labels: [], markers: [], fields: [], ...extra };
}

function canvas(id: string, topics: [string, Topic][]): Canvas {
  return {
    id, title: id, type: "mindmap", typeName: "Mind map",
    theme: { canvas: "#FFFFFF", ink: "#000000", ink2: "#333333", accent: "#6E56CF", dark: false },
    layouts: { saved: { svg: "<svg/>", viewBox: [0, 0, 1, 1], topics: new Map(), zones: [] } },
    outline: topics.map(([tid]) => ({ id: tid, children: [], folded: false })),
    topics: new Map(topics),
  };
}

const bundle: Bundle = {
  title: "t", lang: "en", strings: new Map(), assets: new Map(),
  canvases: [
    canvas("c1", [
      ["a", topic("Café crème", { note: "café au lait", labels: ["Café"] })],
      ["b", topic("naïve_test über alles", { comments: [{ author: "x", date: "", text: "über" }] })],
      ["c", topic("a+b and a.b and (a)")],
      ["d", topic("Straße 42 · ÉTÉ")],
    ]),
    canvas("c2", [["e", topic("Café again")]]),
  ],
};

const count = (q: string, o: Partial<typeof defaultOptions> = {}): number => find(bundle, 0, q, { ...defaultOptions, ...o }).length;

describe("search", () => {
  it("matches literally, ignoring case unless asked", () => {
    expect(count("café")).toBe(1);
    expect(count("CAFÉ")).toBe(1);
    expect(count("CAFÉ", { matchCase: true })).toBe(0);
    expect(count("é")).toBe(3); // Café, ÉTÉ (è is another letter)
    expect(count("a.b")).toBe(1);
    expect(count("(a)")).toBe(1);
    expect(count("")).toBe(0);
  });

  it("finds whole words as ICU's \\b does", () => {
    expect(count("café", { wholeWords: true })).toBe(1);
    expect(count("naïve", { wholeWords: true })).toBe(0); // "_" is a word character
    expect(count("über", { wholeWords: true })).toBe(1);
    expect(count("42", { wholeWords: true })).toBe(1);
    expect(count("4", { wholeWords: true })).toBe(0);
    // A query that starts with a non-word character needs a word character before it.
    expect(count("+b", { wholeWords: true })).toBe(1);
    expect(count("(a)", { wholeWords: true })).toBe(0);
  });

  it("reaches notes, comments and labels only when asked", () => {
    expect(count("café", { notes: true })).toBe(2);
    expect(count("über", { notes: true })).toBe(2);
    expect(count("café", { labels: true })).toBe(2);
    expect(count("café", { allCanvases: true })).toBe(2);
  });

  it("escapes every pattern character", () => {
    expect(escapeLiteral("a.b*c?(d)[e]{f}|g^h$i\\j/k+l")).toBe("a\\.b\\*c\\?\\(d\\)\\[e\\]\\{f\\}\\|g\\^h\\$i\\\\j\\/k\\+l");
    expect(() => expression("[{(*+?", { matchCase: false, wholeWords: true })).not.toThrow();
  });
});
