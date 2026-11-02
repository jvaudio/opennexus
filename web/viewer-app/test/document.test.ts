// @vitest-environment node
import { describe, expect, it } from "vitest";
import { baseName, folderFiles, openFile, openJSON, openPackage, openZip, outline, packageRoot } from "../src/document";
import { zip } from "./zipwriter";

/** The value, which the test expects to be there. */
function must<T>(v: T | null | undefined): T {
  if (v === null || v === undefined) throw new Error("expected a value");
  return v;
}

const manifestJSON = (more: object = {}): object => ({ format: "opennexus", canvases: ["c1", "c2"], ...more });
const manifest = (more: object = {}): string => JSON.stringify(manifestJSON(more));
const canvas = (title: string, rootText: string): object => ({
  title,
  root: "r",
  floating: ["f"],
  nodes: {
    r: { text: rootText, children: ["a", "b"] },
    a: { text: "Alpha", children: ["a1"], note: { format: "plain", text: "Alpha's note" } },
    a1: { text: "Alpha one", children: ["r"] },
    b: { text: "Beta", children: [], note: { format: "plain", text: "  " } },
    f: { text: "Floating", children: [] },
  },
});
const renderJSON = { format: "opennexus-viewer", version: 1, title: "Plan", canvases: [] };
const render = JSON.stringify(renderJSON);

function files(map: Record<string, string | Uint8Array>) {
  return folderFiles(new Map(Object.entries(map).map(([k, v]) => [k, new Blob([v as BlobPart])])));
}

describe("a document's outline", () => {
  it("walks the root then floating topics, depth first, with notes, never looping", () => {
    const o = outline(canvas("", "Launch"));
    expect(o.title).toBe("Launch");
    expect(o.topics.map((t) => t.text)).toEqual(["Launch", "Floating"]);
    const alpha = o.topics[0]?.children[0];
    expect(alpha).toMatchObject({ text: "Alpha", note: "Alpha's note" });
    // a1 lists the root as its child: the cycle stops there.
    expect(alpha?.children[0]?.children).toEqual([]);
    expect(o.topics[0]?.children[1]?.note).toBeUndefined();
  });

  it("survives junk", () => {
    expect(outline(null)).toEqual({ title: "", topics: [] });
    expect(outline({ root: "x", nodes: { x: { text: 7, children: "no" } } }).topics).toEqual([{ text: "", children: [] }]);
    expect(outline({ root: "constructor", nodes: {} }).topics).toEqual([]);
  });
});

describe("a .nexusjson", () => {
  it("opens its viewer copy, with its assets as blob URLs", async () => {
    const o = openJSON("Plan.nexusjson", JSON.stringify({ manifest: manifestJSON(), render: renderJSON, assets: { "a.png": btoa("PNG!") } }));
    expect(o.kind).toBe("bundle");
    if (o.kind !== "bundle") return;
    expect(JSON.parse(o.text)).toEqual(renderJSON);
    const url = o.asset("a.png", "image/png");
    expect(url).toMatch(/^blob:/);
    expect(o.asset("a.png")).toBe(url);
    expect(await (await fetch(must(url))).text()).toBe("PNG!");
    expect(o.asset("missing.png")).toBeUndefined();
    o.close();
  });

  it("without one, shows its canvases' outline", () => {
    const o = openJSON("Plan.nexusjson", JSON.stringify({ manifest: manifestJSON(), canvases: [canvas("First", "Launch"), canvas("", "Second")] }));
    expect(o).toMatchObject({ kind: "outline", title: "Launch", json: true });
    if (o.kind === "outline") expect(o.canvases.map((c) => c.title)).toEqual(["First", "Second"]);
  });

  it("an encrypted one says so, with its hint; anything else is refused", () => {
    expect(openJSON("S.nexusjson", JSON.stringify({ manifest: { format: "opennexus", encrypted: true, hint: "the cat" } }))).toEqual({ kind: "encrypted", name: "S.nexusjson", hint: "the cat" });
    expect(openJSON("S.nexusjson", JSON.stringify({ manifest: { format: "opennexus", encrypted: true } }))).toEqual({ kind: "encrypted", name: "S.nexusjson" });
    expect(openJSON("x.json", '{"manifest":{"format":"xmind"}}').kind).toBe("refused");
    expect(openJSON("x.json", "{not json").kind).toBe("refused");
  });
});

describe("a .nexus package", () => {
  it("finds itself in a folder and opens its viewer copy and assets", async () => {
    const f = files({
      "Plan.nexus/manifest.json": manifest(),
      "Plan.nexus/render/viewer.json": render,
      "Plan.nexus/assets/photo.png": "PNG!",
      "Other/manifest.json.bak": "x",
    });
    expect(packageRoot(f.paths())).toBe("Plan.nexus/");
    const o = await openPackage("Plan.nexus", f);
    expect(o.kind).toBe("bundle");
    if (o.kind !== "bundle") return;
    expect(o.text).toBe(render);
    expect(await (await fetch(must(o.asset("photo.png")))).text()).toBe("PNG!");
  });

  it("without a viewer copy, shows its canvases in the manifest's order, skipping odd names", async () => {
    const o = await openPackage("Plan", files({
      "manifest.json": JSON.stringify({ format: "opennexus", canvases: ["c2", "../c1", "c1", "gone"] }),
      "canvases/c1.json": JSON.stringify(canvas("One", "A")),
      "canvases/c2.json": JSON.stringify(canvas("Two", "B")),
    }));
    expect(o).toMatchObject({ kind: "outline", json: false });
    if (o.kind === "outline") expect(o.canvases.map((c) => c.title)).toEqual(["Two", "One"]);
  });

  it("an encrypted package is refused at its manifest", async () => {
    expect(await openPackage("S.nexus", files({ "manifest.json": manifest({ encrypted: true }), "encrypted.bin": "…" }))).toEqual({ kind: "encrypted", name: "S.nexus" });
  });

  it("a folder without one is refused, unless it holds a single .nexusjson", async () => {
    expect((await openPackage("Stuff", files({ "notes.txt": "hi" }))).kind).toBe("refused");
    const one = await openPackage("Stuff", files({ "Plan.nexusjson": JSON.stringify({ manifest: manifestJSON(), canvases: [] }) }));
    expect(one).toMatchObject({ kind: "outline", name: "Plan" });
  });
});

describe("a zipped package", () => {
  it("opens like the folder", async () => {
    const z = zip([
      { name: "Plan.nexus/manifest.json", data: manifest() },
      { name: "Plan.nexus/render/viewer.json", data: render, deflate: true },
    ]);
    expect((await openZip("Plan.nexus.zip", z)).kind).toBe("bundle");
  });

  it("a damaged zip is refused with the reason", async () => {
    expect(await openZip("x.zip", new Uint8Array(30))).toMatchObject({ kind: "refused", reason: expect.stringMatching(/not a zip/) as unknown });
  });
});

describe("a chosen file", () => {
  it("goes by its extension", async () => {
    const json = new File([JSON.stringify({ manifest: manifestJSON(), canvases: [] })], "Plan.nexusjson");
    expect((await openFile(json)).kind).toBe("outline");
    expect(await openFile(new File(["x"], "Plan.nexus"))).toMatchObject({ kind: "refused", reason: expect.stringMatching(/folder/) as unknown });
    expect((await openFile(new File(["x"], "photo.png"))).kind).toBe("refused");
    expect(baseName("Folder/Plan.nexus/")).toBe("Plan");
    expect(baseName("Plan.nexus.zip")).toBe("Plan");
    expect(baseName("Plan.zip")).toBe("Plan");
  });
});
