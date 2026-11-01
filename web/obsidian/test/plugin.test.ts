// A1: with Obsidian mocked, everything the plugin adds registers on load and is gone after
// unload: views, the extension, the code block, the folder menu, commands, settings, the
// protocol handler, every listener, timer and element.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App, Menu, MarkdownView, notices, TFile, TFolder, type Component } from "./obsidian";
import OpenNexusPlugin from "../src/main";
import { VIEW_NOTE } from "../src/notemap";
import { MapFileView, PackageView, VIEW_MAP, VIEW_PACKAGE } from "../src/views";
import { nexusjson, packageFiles } from "./fixtures";

function must<T>(v: T | null | undefined): T {
  if (v === null || v === undefined) throw new Error("expected a value");
  return v;
}

const manifest = { id: "opennexus", name: "OpenNexus", version: "0.1.0" };

function vault(): App {
  return new App({
    "Maps/Launch.nexusjson": nexusjson(true),
    "Maps/Plain.nexusjson": nexusjson(false),
    ...packageFiles("Maps/Plan.nexus", true),
    "Notes/Risks.md": "# Risks\n",
    "Notes/Trip.md": "# Trip\n## Packing\n- Passport\n",
  });
}

async function settle(): Promise<void> {
  for (let i = 0; i < 5; i++) await Promise.resolve();
  await vi.runOnlyPendingTimersAsync();
  for (let i = 0; i < 5; i++) await Promise.resolve();
}

describe("A1 · the plugin registers and unregisters cleanly", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.replaceChildren();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("registers its views, extension, code block, menu, commands, settings and links", async () => {
    const app = vault();
    const plugin = new OpenNexusPlugin(app as never, manifest as never);
    plugin.load();
    await settle();
    expect([...app.views.keys()].sort()).toEqual([VIEW_MAP, VIEW_NOTE, VIEW_PACKAGE].sort());
    expect(app.extensions.get("nexusjson")).toBe(VIEW_MAP);
    expect([...app.codeBlocks.keys()]).toEqual(["nexus"]);
    expect([...app.commands.keys()].sort()).toEqual(["convert-note", "copy-topic-link", "edit-in-app", "insert-outline", "note-as-map"]);
    expect(app.settingTabs.size).toBe(1);
    expect([...app.protocol.keys()]).toEqual(["opennexus"]);
    expect(app.workspace.listeners()).toBe(1);

    // The folder menu offers packages only.
    const menu = new Menu();
    app.workspace.trigger("file-menu", menu, new TFolder("Maps/Plan.nexus"));
    app.workspace.trigger("file-menu", menu, new TFolder("Maps"));
    app.workspace.trigger("file-menu", menu, new TFile("Maps/Launch.nexusjson"));
    expect(menu.items.map((i) => i.title)).toEqual(["Open as OpenNexus map"]);

    plugin.unload();
    expect(app.views.size + app.extensions.size + app.codeBlocks.size + app.commands.size + app.settingTabs.size + app.protocol.size).toBe(0);
    expect(app.workspace.listeners() + app.vault.listeners()).toBe(0);
  });

  it("leaves nothing behind after views, embeds and a note map have run", async () => {
    const app = vault();
    const plugin = new OpenNexusPlugin(app as never, manifest as never);
    plugin.load();
    await settle();

    // A .nexusjson opens in the map view; a package from its folder menu.
    const leaf = app.workspace.getLeaf();
    await leaf.openFile(new TFile("Maps/Launch.nexusjson"));
    const view = must(leaf.view) as unknown as MapFileView;
    expect(view).toBeInstanceOf(MapFileView);
    expect(view.contentEl.querySelector(".onx")).not.toBeNull();
    const menu = new Menu();
    app.workspace.trigger("file-menu", menu, new TFolder("Maps/Plan.nexus"));
    await must(menu.items[0]).click();
    await settle();
    const pkg = must(app.workspace.getLeavesOfType(VIEW_PACKAGE)[0]?.view) as unknown as PackageView;
    expect(pkg.getDisplayText()).toBe("Plan");
    expect(pkg.contentEl.querySelector(".onx")).not.toBeNull();

    // Two embeds in a note's section.
    const sectionEl = document.body.appendChild(document.createElement("div"));
    const children: Component[] = [];
    const ctx = { sourcePath: "Notes/Trip.md", addChild: (c: Component) => { children.push(c); c.load(); } };
    for (const source of ["file: Maps/Launch.nexusjson\ntopic: Pricing", "file: Plan.nexus"]) {
      const el = sectionEl.appendChild(document.createElement("div"));
      await must(app.codeBlocks.get("nexus"))(source, el, ctx);
    }
    await settle();
    expect(sectionEl.querySelectorAll(".onx").length).toBe(2);
    expect(plugin.embeds.size).toBe(2);

    // A note as a map (no `nexus` here: its outline).
    vi.spyOn(plugin, "nexus").mockResolvedValue(undefined);
    const md = new MarkdownView(app.workspace.getLeaf());
    md.file = new TFile("Notes/Trip.md");
    app.workspace.active = md;
    must(app.commands.get("note-as-map")?.checkCallback)(false);
    await settle();
    expect(document.body.querySelector(".opennexus-outline-topic")).not.toBeNull();

    // A change to the map redraws its view once things settle.
    expect(view.contentEl.dataset.opennexusDraws).toBe("1");
    app.vault.trigger("modify", new TFile("Maps/Launch.nexusjson"));
    app.vault.trigger("modify", new TFile("Maps/Launch.nexusjson"));
    await settle();
    expect(view.contentEl.dataset.opennexusDraws).toBe("2");

    expect(app.vault.listeners()).toBeGreaterThan(0);
    plugin.unload();
    for (const c of children) c.unload();
    expect(app.workspace.listeners() + app.vault.listeners()).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
    expect(document.body.querySelector(".onx")).toBeNull();
    expect(document.body.querySelector(".opennexus-view")).toBeNull();
    expect(plugin.embeds.size).toBe(0);
  });

  it("says so when a topic link names a map that isn't in the vault", async () => {
    const app = vault();
    const plugin = new OpenNexusPlugin(app as never, manifest as never);
    plugin.load();
    await settle();
    notices.length = 0;
    must(app.protocol.get("opennexus"))({ action: "opennexus", file: "../../etc/passwd", topic: "r" });
    await settle();
    expect(notices).toEqual(["There’s no map “../../etc/passwd” in this vault."]);
    expect(app.workspace.opened).toEqual([]);
    plugin.unload();
  });

  it("starts an embed only when it's scrolled into view", async () => {
    const watched: { el: Element; fire: () => void; off: boolean }[] = [];
    vi.stubGlobal(
      "IntersectionObserver",
      class {
        constructor(private readonly cb: (e: { isIntersecting: boolean }[]) => void) {}
        observe(el: Element): void {
          const w = { el, off: false, fire: () => { if (!w.off) this.cb([{ isIntersecting: true }]); } };
          watched.push(w);
        }
        disconnect(): void {
          for (const w of watched) w.off = true;
        }
      },
    );
    const app = vault();
    const plugin = new OpenNexusPlugin(app as never, manifest as never);
    plugin.load();
    await settle();
    const el = document.body.appendChild(document.createElement("div"));
    await must(app.codeBlocks.get("nexus"))("file: Maps/Launch.nexusjson\nheight: 250", el, {
      sourcePath: "Notes/Trip.md",
      addChild: (c: Component) => { c.load(); },
    });
    await settle();
    expect(el.querySelector(".onx")).toBeNull();
    expect(el.style.getPropertyValue("--opennexus-embed-height")).toBe("250px");
    expect(el.dataset.opennexusFile).toBe("Maps/Launch.nexusjson");
    must(watched[0]).fire();
    await settle();
    expect(el.querySelector(".onx")).not.toBeNull();
    expect(el.querySelector(".onx-embed")).not.toBeNull();
    plugin.unload();
    expect(el.querySelector(".onx")).toBeNull();
    vi.unstubAllGlobals();
  });
});
