import { afterEach, describe, expect, it } from "vitest";
import { entryFiles, handleFiles, home, inputFiles, MAX_FILES, show } from "../src/open";

/** The value, which the test expects to be there. */
function must<T>(v: T | null | undefined): T {
  if (v === null || v === undefined) throw new Error("expected a value");
  return v;
}

afterEach(() => {
  document.body.replaceChildren();
});

describe("reading a folder", () => {
  it("from the directory picker, by path inside it", async () => {
    const file = (name: string) => ({ kind: "file" as const, name, getFile: () => Promise.resolve(new File([name], name)) });
    const dir = (name: string, items: unknown[]) => ({
      kind: "directory" as const,
      name,
      values: async function* () { yield* await Promise.resolve(items); },
    });
    const files = await handleFiles(dir("Plan.nexus", [file("manifest.json"), dir("render", [file("viewer.json")])]) as never);
    expect([...files.keys()].sort()).toEqual(["manifest.json", "render/viewer.json"]);
  });

  it("from a drop, reading each folder's batches until there are none", async () => {
    const fileEntry = (name: string) => ({ isFile: true, isDirectory: false, name, file: (ok: (f: File) => void) => { ok(new File([name], name)); } });
    const dirEntry = (name: string, batches: unknown[][]) => ({
      isFile: false, isDirectory: true, name,
      createReader: () => {
        let i = 0;
        return { readEntries: (ok: (e: unknown[]) => void) => { ok(batches[i++] ?? []); } };
      },
    });
    const root = dirEntry("Plan.nexus", [[fileEntry("manifest.json")], [dirEntry("canvases", [[fileEntry("c1.json"), fileEntry("c2.json")]])]]);
    const files = await entryFiles(root as never);
    expect([...files.keys()].sort()).toEqual(["canvases/c1.json", "canvases/c2.json", "manifest.json"]);
  });

  it("from a folder input, without the folder's own name", () => {
    const f = (path: string) => Object.defineProperty(new File(["x"], must(path.split("/").pop())), "webkitRelativePath", { value: path });
    const list = [f("Plan.nexus/manifest.json"), f("Plan.nexus/render/viewer.json")] as unknown as FileList;
    const { name, files } = inputFiles(list);
    expect(name).toBe("Plan.nexus");
    expect([...files.keys()]).toEqual(["manifest.json", "render/viewer.json"]);
  });

  it("not a whole disk", () => {
    const many = Array.from({ length: MAX_FILES + 1 }, (_, i) => Object.defineProperty(new File(["x"], "f"), "webkitRelativePath", { value: `Home/f${String(i)}` }));
    expect(() => inputFiles(many as unknown as FileList)).toThrow();
  });
});

describe("what the page shows", () => {
  it("the front page: both pickers and what the site is", () => {
    home();
    expect(document.documentElement.dataset.onxState).toBe("home");
    expect([...document.querySelectorAll("button")].map((b) => b.textContent)).toEqual(["Open File…", "Open Folder…"]);
    expect(document.querySelector<HTMLInputElement>("#open-folder")?.webkitdirectory).toBe(true);
    expect(document.body.textContent).toContain("never uploaded");
  });

  it("an outline, with how to add a viewer copy", () => {
    show({ kind: "outline", name: "Plan.nexusjson", title: "Launch", json: true, canvases: [{ title: "Plan", topics: [{ text: "Launch", note: "Why", children: [{ text: "", children: [] }] }] }] });
    expect(document.documentElement.dataset.onxState).toBe("outline");
    expect(document.querySelector("h1")?.textContent).toBe("Launch");
    expect(document.querySelector(".open-how")?.textContent).toContain("Also in single-file documents");
    expect(document.querySelector(".open-canvas h2")?.textContent).toBe("Plan");
    expect(document.querySelector(".open-note")?.textContent).toBe("Why");
    expect([...document.querySelectorAll(".open-topic")].map((e) => e.textContent)).toEqual(["Launch", "Untitled topic"]);
    show({ kind: "outline", name: "Plan.nexus", title: "", json: false, canvases: [] });
    expect(document.querySelector("h1")?.textContent).toBe("Plan");
    expect(document.querySelector(".open-how")?.textContent).not.toContain("single-file");
  });

  it("an encrypted document, with its hint, and a refusal, with its reason", () => {
    show({ kind: "encrypted", name: "Secret.nexus", hint: "the cat" });
    expect(document.querySelector("h1")?.textContent).toBe("“Secret” is encrypted");
    expect(document.querySelector(".open-hint")?.textContent).toBe("Password hint: the cat");
    show({ kind: "refused", name: "photo.png", reason: "It isn’t an OpenNexus document." });
    expect(document.documentElement.dataset.onxState).toBe("refused");
    expect(document.body.textContent).toContain("It isn’t an OpenNexus document.");
  });

  it("a damaged viewer copy is refused, and lets go of its assets", () => {
    let closed = false;
    show({ kind: "bundle", name: "Plan.nexus", text: "{", asset: () => undefined, close: () => { closed = true; } });
    expect(closed).toBe(true);
    expect(document.documentElement.dataset.onxState).toBe("refused");
    expect(document.body.textContent).toContain("viewer copy is damaged");
  });
});
