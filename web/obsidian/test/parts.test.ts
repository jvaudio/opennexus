// The plugin's parts (M49): embed options, links, settings, readers, outlines and conversions.

import { describe, expect, it, vi } from "vitest";
import { App, notices, TFile, TFolder } from "./obsidian";
import { parseBundle } from "../../viewer-core/src/bundle";
import { bundleMarkdown, mapPathFor, openedMarkdown, vaultMaps } from "../src/convert";
import { parseEmbed, resolveMap } from "../src/embed";
import { hostLinks, linkTarget, topicLink, topicTarget } from "../src/links";
import { mapAt, openMap } from "../src/maps";
import * as nexus from "../src/nexus";
import { bundleLines } from "../src/notemap";
import { noteOutline } from "../src/outline";
import { findCanvas, findTopic, MapPanel } from "../src/panel";
import { DEFAULTS, readSettings } from "../src/settings";
import { bundle, nexusjson, packageFiles } from "./fixtures";

function must<T>(v: T | null | undefined): T {
  if (v === null || v === undefined) throw new Error("expected a value");
  return v;
}

describe("a ```nexus block's options", () => {
  it("reads file, canvas, topic, layout and height", () => {
    expect(parseEmbed("file: Maps/Launch.nexusjson\ncanvas: Roadmap\ntopic: Launch > Pricing\nlayout: Everything\nheight: 320px")).toEqual({
      file: "Maps/Launch.nexusjson", canvas: "Roadmap", topic: "Launch > Pricing", layout: "expanded", height: 320,
    });
    expect(parseEmbed("file: [[Launch.nexusjson|the plan]]\n\n# a comment")).toEqual({ file: "Launch.nexusjson" });
    expect(parseEmbed('file: "My map.nexusjson"\nheight: 5')).toEqual({ file: "My map.nexusjson", height: 160 });
  });

  it("says what's wrong", () => {
    expect(parseEmbed("")).toEqual({ error: "Name the map with “file: Folder/Map.nexusjson”." });
    expect(parseEmbed("file: a\nzoom: 2")).toHaveProperty("error", "There’s no “zoom”: use file, canvas, topic, layout and height.");
    expect(parseEmbed("file: a\nlayout: radial")).toHaveProperty("error");
    expect(parseEmbed("file: a\nheight: tall")).toHaveProperty("error");
    expect(parseEmbed("just words")).toHaveProperty("error");
  });

  it("finds the map: a path, a link, beside the note, or a package by name", () => {
    const app = new App({ "Maps/Launch.nexusjson": "{}", ...packageFiles("Work/Plan.nexus", true), "Notes/Side.nexusjson": "{}" });
    expect(resolveMap(app as never, "Maps/Launch.nexusjson", "Notes/a.md")).toMatchObject({ kind: "file" });
    expect(resolveMap(app as never, "Maps/Launch", "Notes/a.md")).toMatchObject({ kind: "file" });
    expect(resolveMap(app as never, "Side", "Notes/a.md")).toMatchObject({ kind: "file" });
    expect(must(resolveMap(app as never, "Plan", "Notes/a.md"))).toMatchObject({ kind: "package", folder: { path: "Work/Plan.nexus" } });
    expect(resolveMap(app as never, "Nope", "Notes/a.md")).toBeUndefined();
    expect(resolveMap(app as never, "Notes", "Notes/a.md")).toBeUndefined();
  });
});

describe("links into the vault", () => {
  it("takes wikilinks and this vault's obsidian:// links only", () => {
    expect(linkTarget("[[Risks]]", "V")).toEqual({ kind: "note", link: "Risks" });
    expect(linkTarget("[[Risks#Top|risks]]", "V")).toEqual({ kind: "note", link: "Risks#Top" });
    expect(linkTarget("obsidian://open?vault=V&file=Notes%2FRisks", "V")).toEqual({ kind: "note", link: "Notes/Risks" });
    expect(linkTarget("obsidian://open?file=Risks", "V")).toEqual({ kind: "note", link: "Risks" });
    expect(linkTarget("obsidian://open?vault=Other&file=Risks", "V")).toBeUndefined();
    expect(linkTarget("obsidian://search?vault=V&query=x", "V")).toBeUndefined();
    expect(linkTarget("obsidian://open?vault=V", "V")).toBeUndefined();
    expect(linkTarget("https://example.com", "V")).toBeUndefined();
    expect(linkTarget("javascript:alert(1)", "V")).toBeUndefined();
    expect(linkTarget("[[javascript:alert(1)]]", "V")).toEqual({ kind: "note", link: "javascript:alert(1)" });
  });

  it("round-trips a topic link", () => {
    const link = topicLink("My vault", { file: "Maps/Launch plan.nexusjson", canvas: "c1", topic: "n5" });
    expect(link).toBe("obsidian://opennexus?vault=My%20vault&file=Maps%2FLaunch%20plan.nexusjson&canvas=c1&topic=n5");
    expect(linkTarget(link, "My vault")).toEqual({ kind: "topic", file: "Maps/Launch plan.nexusjson", canvas: "c1", topic: "n5" });
    expect(topicTarget({ action: "opennexus", file: "a.nexusjson", canvas: "", topic: "t" })).toEqual({ file: "a.nexusjson", topic: "t" });
  });

  it("opens only notes that exist, never creating one", () => {
    const app = new App({ "Notes/Risks.md": "# Risks" });
    const topics: unknown[] = [];
    const links = hostLinks(app as never, "Maps/a.nexusjson", (t) => topics.push(t));
    links.open("Risks", true);
    links.open("javascript:alert(1)", true);
    links.open("obsidian://open?vault=Test%20vault&file=Risks", false);
    links.open("obsidian://opennexus?vault=Test%20vault&file=Maps%2Fa.nexusjson&topic=p", false);
    expect(app.workspace.opened).toEqual(["Risks", "Risks"]);
    expect(notices.at(-1)).toBe("There’s no note “javascript:alert(1)” in this vault.");
    expect(topics).toEqual([{ kind: "topic", file: "Maps/a.nexusjson", topic: "p" }]);
    expect(links.accepts("https://example.com")).toBe(false);
  });
});

describe("settings", () => {
  it("fall back to the defaults", () => {
    expect(readSettings(undefined)).toEqual(DEFAULTS);
    expect(readSettings({ layout: "expanded", embedHeight: 9000, followTheme: false, noteStructure: "org.down", nexusPath: "/x" })).toEqual({
      layout: "expanded", embedHeight: 2000, followTheme: false, noteStructure: "org.down", nexusPath: "/x",
    });
    expect(readSettings({ layout: "radial", embedHeight: "tall", noteStructure: "spiral" })).toEqual(DEFAULTS);
  });

  it("find nexus in the app first", () => {
    expect(nexus.candidates("/Users/a")[0]).toBe("/Applications/OpenNexus.app/Contents/Helpers/nexus");
    expect(nexus.candidates("/Users/a")[1]).toBe("/Users/a/Applications/OpenNexus.app/Contents/Helpers/nexus");
  });

  it("run the tool and the app without a shell", async () => {
    const calls: { file: string; args: string[]; input?: string }[] = [];
    const load = nexus.loader.load;
    nexus.loader.load = (name: string) => {
      expect(name).toBe("child_process");
      return {
        execFile: (file: string, args: string[], _o: unknown, done: (e: null, out: string, err: string) => void) => {
          const call: { file: string; args: string[]; input?: string } = { file, args };
          calls.push(call);
          queueMicrotask(() => { done(null, "out", ""); });
          return { stdin: { end: (input: string) => { call.input = input; } } };
        },
      };
    };
    try {
      expect(await nexus.run("/bin/nexus", ["bundle", "-", "--title", "A note; rm -rf ~"], "# A")).toEqual({ code: 0, stdout: "out", stderr: "" });
      expect(await nexus.openInApp("/vault/Maps/Launch plan.nexusjson")).toEqual({ code: 0, stdout: "out", stderr: "" });
      expect(calls).toEqual([
        { file: "/bin/nexus", args: ["bundle", "-", "--title", "A note; rm -rf ~"], input: "# A" },
        { file: "/usr/bin/open", args: ["-b", "com.opennexus.OpenNexus", "/vault/Maps/Launch plan.nexusjson"] },
      ]);
    } finally {
      nexus.loader.load = load;
    }
  });
});

describe("reading maps from the vault", () => {
  const app = new App({
    "Maps/Launch.nexusjson": nexusjson(true),
    "Maps/Plain.nexusjson": nexusjson(false),
    ...packageFiles("Maps/Plan.nexus", true),
    ...packageFiles("Maps/Bare.nexus", false),
    "Maps/notes.nexusjson": "{\"hello\": 1}",
  });

  it("reads a viewer copy, or the outline", async () => {
    const copy = await openMap(app as never, must(mapAt(app as never, "Maps/Launch.nexusjson")));
    expect(copy.kind).toBe("bundle");
    const pkg = await openMap(app as never, must(mapAt(app as never, "Maps/Plan.nexus")));
    expect(pkg.kind).toBe("bundle");
    const plain = await openMap(app as never, must(mapAt(app as never, "Maps/Plain.nexusjson")));
    expect(plain).toMatchObject({ kind: "outline", json: true, canvases: [{ title: "Plan" }] });
    const bare = await openMap(app as never, must(mapAt(app as never, "Maps/Bare.nexus")));
    expect(bare).toMatchObject({ kind: "outline", json: false });
    expect(await openMap(app as never, must(mapAt(app as never, "Maps/notes.nexusjson")))).toMatchObject({ kind: "refused" });
    expect(mapAt(app as never, "Maps")).toBeUndefined();
  });

  it("has nexus draw a map without a copy", async () => {
    const run = vi.spyOn(nexus, "run").mockResolvedValue({ code: 0, stdout: JSON.stringify(bundle), stderr: "" });
    const drawn = await openMap(app as never, must(mapAt(app as never, "Maps/Plain.nexusjson")), "/bin/nexus");
    expect(drawn.kind).toBe("bundle");
    expect(run).toHaveBeenLastCalledWith("/bin/nexus", ["bundle", "/vault/Maps/Plain.nexusjson"]);
    const pkg = await openMap(app as never, must(mapAt(app as never, "Maps/Bare.nexus")), "/bin/nexus");
    expect(pkg.kind).toBe("bundle");
    expect(run).toHaveBeenLastCalledWith("/bin/nexus", ["bundle", "/vault/Maps/Bare.nexus"]);
    // A failure leaves the outline.
    run.mockResolvedValue({ code: 1, stdout: "", stderr: "no" });
    expect((await openMap(app as never, must(mapAt(app as never, "Maps/Plain.nexusjson")), "/bin/nexus")).kind).toBe("outline");
    run.mockRestore();
  });

  it("lists every map", () => {
    expect(vaultMaps(app as never).map((m) => (m.kind === "file" ? m.file.path : m.folder.path))).toEqual([
      "Maps/Bare.nexus", "Maps/Launch.nexusjson", "Maps/notes.nexusjson", "Maps/Plain.nexusjson", "Maps/Plan.nexus",
    ]);
    expect(new TFolder("a.nexus")).toBeInstanceOf(TFolder);
    expect(new TFile("a.nexusjson").extension).toBe("nexusjson");
  });
});

describe("finding canvases and topics", () => {
  const b = parseBundle(JSON.stringify(bundle));
  const c = must(b.canvases[0]);

  it("by id, title or path", () => {
    expect(findCanvas(b)).toBe(0);
    expect(findCanvas(b, "c2")).toBe(1);
    expect(findCanvas(b, "roadmap")).toBe(1);
    expect(findCanvas(b, "Nope")).toBe(-1);
    expect(findTopic(c, "p1")).toBe("p1");
    expect(findTopic(c, "pricing")).toBe("p");
    expect(findTopic(c, "Launch > Pricing > Pro")).toBe("p1");
    expect(findTopic(c, "Launch > Pro")).toBeUndefined();
    expect(findTopic(c, "Nope")).toBeUndefined();
  });

  it("a panel goes to them, and keeps its camera across a redraw", () => {
    const host = document.body.appendChild(document.createElement("div"));
    const panel = new MapPanel(host);
    const opened = { kind: "bundle" as const, name: "Launch.nexusjson", text: JSON.stringify(bundle), asset: () => undefined, close: () => undefined };
    panel.show(opened, { chrome: "full", layout: "saved", followTheme: true });
    expect(host.classList.contains("onx-obsidian")).toBe(true);
    expect(panel.goTo({ canvas: "Roadmap", topic: "Q3" }, "select")).toBe(true);
    expect(panel.canvas).toBe(1);
    must(panel.handle).setView({ x: 5, y: 6, k: 0.75 });
    panel.show(opened, { chrome: "full", layout: "saved", followTheme: false }, panel.keep());
    expect(panel.canvas).toBe(1);
    expect(must(panel.handle).view()).toEqual({ x: 5, y: 6, k: 0.75 });
    expect(host.classList.contains("onx-obsidian")).toBe(false);
    expect(panel.goTo({ topic: "Nope" }, "focus")).toBe(false);
    panel.show({ kind: "encrypted", name: "Secret.nexus", hint: "The usual" }, { chrome: "full", layout: "saved", followTheme: true });
    expect(host.textContent).toContain("Password hint: The usual");
    panel.show({ kind: "bundle", name: "x", text: "{}", asset: () => undefined, close: () => undefined }, { chrome: "full", layout: "saved", followTheme: true });
    expect(host.textContent).toContain("Its viewer copy is damaged.");
    panel.clear();
  });
});

describe("notes and outlines", () => {
  const note = "---\ntags: [x]\n---\n# Trip\n\nIntro\n\n## Packing\n- Passport\n  - Visa\n- [ ] Charger\n```\n- not a topic\n```\n## Trains\n";

  it("reads a note's headings and bullets with their lines", () => {
    const t = noteOutline(note);
    expect(t).toEqual([
      {
        text: "Trip", line: 4, children: [
          { text: "Packing", line: 8, children: [{ text: "Passport", line: 9, children: [{ text: "Visa", line: 10, children: [] }] }, { text: "Charger", line: 11, children: [] }] },
          { text: "Trains", line: 15, children: [] },
        ],
      },
    ]);
  });

  it("reads lines from nexus bundle, refusing anything odd", () => {
    expect([...bundleLines(JSON.stringify({ canvases: [{ lines: { n1: 4, n2: 9, n3: 0, n4: "x", n5: 2.5 } }] }))]).toEqual([["n1", 4], ["n2", 9]]);
    expect(bundleLines("not json").size).toBe(0);
    expect(bundleLines("{}").size).toBe(0);
  });

  it("writes a map as Markdown", () => {
    expect(bundleMarkdown(parseBundle(JSON.stringify(bundle)))).toBe(
      "## Plan\n\n- Launch\n  See [[Risks]]\n  - Pricing\n    Ask about the discount\n    - Pro\n  - Sales\n\n## Roadmap\n\n- Q3\n",
    );
    expect(openedMarkdown({ kind: "outline", name: "x", title: "x", json: true, canvases: [{ title: "A", topics: [{ text: "Root", note: "n", children: [{ text: "Kid", children: [] }] }] }] })).toBe(
      "- Root\n  n\n  - Kid\n",
    );
    expect(openedMarkdown({ kind: "refused", name: "x", reason: "no" })).toBeUndefined();
    expect(mapPathFor("Notes/Trip.md")).toBe("Notes/Trip.nexusjson");
  });
});
