// M49 acceptance on the desktop (A2–A5). A throwaway Obsidian, with a profile of its own so it
// runs beside one that's already open, opens a copy of web/obsidian/test-vault/ with the
// plugin installed from its release assets as a reader installs it by hand
// (scripts/release-obsidian.sh --install) and `nexus` from this checkout. Playwright reaches
// it over CDP. Maps change as OpenNexus saves them: `nexus mcp`, the app's own writer.
// Skipped where Obsidian isn't installed.

import { chromium, expect, test, type Browser, type Page } from "@playwright/test";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { inert } from "./inert";

const obsidian = "/Applications/Obsidian.app/Contents/MacOS/Obsidian";
const repo = path.resolve(import.meta.dirname, "../..");
const source = path.join(repo, "web/obsidian/test-vault");
const version = (JSON.parse(readFileSync(path.join(repo, "web/obsidian/manifest.json"), "utf8")) as { version: string }).version;

interface Editor {
  getCursor(): { line: number; ch: number };
  getValue(): string;
  setCursor(line: number, ch: number): void;
  lastLine(): number;
  getLine(line: number): string;
  focus(): void;
}

interface Leaf {
  view: { getViewType(): string; editor?: Editor; file?: { path: string } | null };
  openFile(file: unknown): Promise<void>;
  setViewState(state: { type: string; state?: Record<string, unknown>; active?: boolean }): Promise<void>;
}

declare global {
  interface Window {
    app: {
      vault: { getAbstractFileByPath(path: string): unknown };
      workspace: {
        getLeaf(how?: boolean | "tab"): Leaf;
        getActiveFile(): { path: string } | null;
        getLeavesOfType(type: string): Leaf[];
        setActiveLeaf(leaf: Leaf, o?: { focus: boolean }): void;
      };
      commands: { executeCommandById(id: string): boolean };
      plugins: { plugins: Record<string, { manifest: { version: string } } | undefined>; disablePlugin(id: string): Promise<void> };
    };
    /** Obsidian's handler for obsidian:// URLs, given the URL's parameters. */
    OBS_ACT(params: Record<string, string>): void;
    __copied?: string;
    __pwned?: unknown;
    /** Each embed's file as it starts drawing (the test's own record). */
    __started?: string[];
  }
}

interface BundleTopic {
  text: string;
}

interface Bundle {
  canvases: { id: string; title: string; topics: Record<string, BundleTopic>; layouts: { saved: { topics: Record<string, unknown> } } }[];
}

interface Session {
  child: ChildProcess;
  browser: Browser;
  page: Page;
  base: string;
  vault: string;
  nexus: string;
  dialogs: number;
  requests: string[];
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

function must<T>(v: T | undefined | null, what: string): T {
  if (v === undefined || v === null) throw new Error(`missing ${what}`);
  return v;
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const a = server.address();
      server.close(() => {
        if (typeof a === "object" && a !== null) resolve(a.port);
        else reject(new Error("no free port"));
      });
    });
  });
}

async function launch(): Promise<Session> {
  const base = mkdtempSync(path.join(tmpdir(), "opennexus-obsidian-"));
  const vault = path.join(base, "Test vault");
  cpSync(source, vault, { recursive: true });
  execFileSync(path.join(repo, "scripts/release-obsidian.sh"), ["--install", vault], { stdio: "pipe" });
  execFileSync("swift", ["build", "--product", "nexus"], { cwd: repo, stdio: "pipe" });
  const nexus = path.join(execFileSync("swift", ["build", "--show-bin-path"], { cwd: repo, encoding: "utf8" }).trim(), "nexus");
  writeFileSync(path.join(vault, ".obsidian/plugins/opennexus/data.json"), JSON.stringify({ nexusPath: nexus }));
  // Obsidian draws menus natively on macOS, out of the page's reach; its own menus are the same menu.
  writeFileSync(path.join(vault, ".obsidian/app.json"), JSON.stringify({ nativeMenus: false }));
  const profile = path.join(base, "profile");
  mkdirSync(profile);
  writeFileSync(path.join(profile, "obsidian.json"), JSON.stringify({ vaults: { e2e0e2e0e2e0e2e0: { path: vault, ts: 1, open: true } }, updateDisabled: true }));

  const port = await freePort();
  const child = spawn(obsidian, [`--user-data-dir=${profile}`, `--remote-debugging-port=${String(port)}`], { stdio: "ignore" });
  let browser: Browser | undefined;
  for (let i = 0; i < 120 && browser === undefined; i++) {
    try {
      browser = await chromium.connectOverCDP(`http://127.0.0.1:${String(port)}`);
    } catch {
      await sleep(250);
    }
  }
  const context = must(must(browser, "Obsidian over CDP").contexts()[0], "Obsidian's window");
  const page = context.pages()[0] ?? (await context.waitForEvent("page"));
  const s: Session = { child, browser: must(browser, "browser"), page, base, vault, nexus, dialogs: 0, requests: [] };
  page.on("dialog", (d) => {
    s.dialogs++;
    void d.dismiss();
  });
  page.on("request", (r) => s.requests.push(r.url()));

  // Obsidian asks before running a vault's plugins; this vault and its plugin are ours.
  await page.getByText("Trust author and enable plugins").click({ timeout: 30_000 });
  await expect.poll(() => page.evaluate(() => window.app.plugins.plugins.opennexus !== undefined)).toBe(true);
  // It then shows the plugin settings.
  await page.keyboard.press("Escape");
  await expect(page.locator(".modal")).toHaveCount(0);
  return s;
}

async function quit(s: Session): Promise<void> {
  await s.browser.close().catch(() => undefined);
  const running = (): boolean => s.child.exitCode === null && s.child.signalCode === null;
  if (running()) {
    const gone = new Promise((r) => s.child.once("exit", r));
    s.child.kill("SIGTERM");
    await Promise.race([gone, sleep(5000)]);
    if (running()) s.child.kill("SIGKILL");
  }
  rmSync(s.base, { recursive: true, force: true });
}

/** Opens a vault file in the active tab: a map in its view, a note in Reading view or the editor. */
async function open(page: Page, file: string, mode?: "preview" | "source"): Promise<void> {
  await page.evaluate(
    async ({ file, mode }) => {
      const leaf = window.app.workspace.getLeaf(false);
      if (mode === undefined) await leaf.openFile(window.app.vault.getAbstractFileByPath(file));
      else await leaf.setViewState({ type: "markdown", state: { file, mode, source: false }, active: true });
      window.app.workspace.setActiveLeaf(leaf, { focus: true });
    },
    { file, mode },
  );
}

const command = (page: Page, id: string): Promise<boolean> => page.evaluate((id) => window.app.commands.executeCommandById(`opennexus:${id}`), id);
const activeFile = (page: Page): Promise<string | null> => page.evaluate(() => window.app.workspace.getActiveFile()?.path ?? null);
const view = (type: string): string => `.workspace-leaf.mod-active .workspace-leaf-content[data-type="${type}"]`;
const MAP = view("opennexus-map");

/** Waits until the vault has noticed a file written from outside. */
async function noticed(page: Page, file: string): Promise<void> {
  await expect.poll(() => page.evaluate((f) => window.app.vault.getAbstractFileByPath(f) !== null, file)).toBe(true);
}

/** When a topic with `text` shows under `root`, by the page's clock (the same machine's). */
function shown(page: Page, root: string, text: string): Promise<number> {
  return page.evaluate(
    ({ root, text }) =>
      new Promise<number>((resolve, reject) => {
        const hit = (): boolean => Array.from(document.querySelectorAll(`${root} .onx-topic`)).some((e) => e.textContent === text);
        if (hit()) {
          resolve(Date.now());
          return;
        }
        const watch = new MutationObserver(() => {
          if (hit()) {
            watch.disconnect();
            resolve(Date.now());
          }
        });
        watch.observe(document.body, { childList: true, subtree: true, characterData: true });
        setTimeout(() => {
          watch.disconnect();
          reject(new Error(`“${text}” never showed`));
        }, 10_000);
      }),
    { root, text },
  );
}

/** Adds a topic to a map with `nexus mcp`, which saves as OpenNexus does; when the request went and when it was saved. */
async function save(s: Session, file: string, parent: string, text: string): Promise<{ sent: number; saved: number }> {
  const config = path.join(s.base, "agent.json");
  writeFileSync(config, JSON.stringify({ enabled: true, folders: [s.vault], read: "allow", edit: "allow", files: "allow" }));
  const agent = spawn(s.nexus, ["mcp", "--config", config], { stdio: ["pipe", "pipe", "ignore"] });
  const replies = new Map<number, (m: { result?: { isError?: boolean } }) => void>();
  let buffer = "";
  agent.stdout.on("data", (d: Buffer) => {
    buffer += d.toString("utf8");
    for (let i = buffer.indexOf("\n"); i >= 0; i = buffer.indexOf("\n")) {
      const m = JSON.parse(buffer.slice(0, i)) as { id?: number; result?: { isError?: boolean } };
      buffer = buffer.slice(i + 1);
      if (m.id !== undefined) replies.get(m.id)?.(m);
    }
  });
  const call = (id: number, method: string, params: unknown): Promise<{ result?: { isError?: boolean } }> =>
    new Promise((resolve) => {
      replies.set(id, resolve);
      agent.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  await call(1, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "1" } });
  agent.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
  const sent = Date.now();
  const reply = await call(2, "tools/call", { name: "add_topic", arguments: { path: path.join(s.vault, file), parent, text } });
  const saved = Date.now();
  agent.stdin.end();
  expect(reply.result?.isError).toBe(false);
  return { sent, saved };
}

function bundleOf(file: string): Bundle {
  const json = JSON.parse(readFileSync(file, "utf8")) as { render?: Bundle } & Bundle;
  return json.render ?? json;
}

function topicId(b: Bundle, text: string): string {
  const c = must(b.canvases[0], "a canvas");
  return must(Object.entries(c.topics).find(([, t]) => t.text === text)?.[0], `topic ${text}`);
}

/** A viewer's drawing: its topics and the SVG, without the ids that number each viewer on the page. */
function drawing(root: Element): { topics: string[]; svg: string } {
  const stage = root.querySelector(".onx-stage");
  const strip = (s: string): string => s.replace(/onx\d+-/g, "onx-");
  return {
    topics: Array.from(stage?.querySelectorAll(".onx-topic") ?? []).map((e) => strip(`${(e as HTMLElement).dataset.id ?? ""}|${e.textContent}|${(e as HTMLElement).style.cssText}`)),
    svg: strip(stage?.querySelector("svg")?.outerHTML ?? ""),
  };
}

test.describe("M49 · OpenNexus in Obsidian", () => {
  test.skip(!existsSync(obsidian), "Obsidian isn't installed");
  test.describe.configure({ mode: "default", timeout: 60_000 });

  let s: Session;
  test.beforeAll(async () => {
    test.setTimeout(600_000);
    s = await launch();
  });
  test.afterAll(async () => {
    await quit(s);
  });

  test("A5 · the release assets install by hand and load", async () => {
    const loaded = await s.page.evaluate(() => window.app.plugins.plugins.opennexus?.manifest.version);
    expect(loaded).toBe(version);
    for (const f of ["main.js", "manifest.json", "styles.css"]) {
      const released = readFileSync(path.join(repo, "dist/obsidian", version, f));
      expect(readFileSync(path.join(s.vault, ".obsidian/plugins/opennexus", f)).equals(released)).toBe(true);
    }
  });

  test("A2 · a .nexusjson opens as its viewer copy", async () => {
    const { page } = s;
    await open(page, "Maps/Launch plan.nexusjson");
    const b = bundleOf(path.join(s.vault, "Maps/Launch plan.nexusjson"));
    await expect(page.locator(`${MAP} .onx-topic`)).toHaveCount(Object.keys(must(b.canvases[0], "c1").layouts.saved.topics).length);
    await expect(page.locator(".workspace-leaf.mod-active .view-header-title")).toHaveText("Launch plan");
    // Its second canvas, from the bar.
    await page.locator(MAP).getByRole("tab", { name: "Roadmap", exact: true }).click();
    await expect(page.locator(`${MAP} .onx-topic`, { hasText: "Pricing page" })).toBeVisible();
  });

  test("A2 · a package opens from its folder menu", async () => {
    const { page } = s;
    const maps = page.locator('.nav-folder-title[data-path="Maps"]');
    if ((await page.locator('.nav-folder-title[data-path="Maps/Plan.nexus"]').count()) === 0) await maps.click();
    await page.locator('.nav-folder-title[data-path="Maps/Plan.nexus"]').click({ button: "right" });
    await page.locator(".menu-item", { hasText: "Open as OpenNexus map" }).click();
    const b = bundleOf(path.join(s.vault, "Maps/Plan.nexus/render/viewer.json"));
    const pkg = view("opennexus-package");
    await expect(page.locator(`${pkg} .onx-topic`)).toHaveCount(Object.keys(must(b.canvases[0], "c1").layouts.saved.topics).length);
    await expect(page.locator(".workspace-leaf.mod-active .view-header-title")).toHaveText("Plan");
  });

  test("A2 · a map without a viewer copy is drawn by nexus", async () => {
    const { page } = s;
    await open(page, "Maps/Plain.nexusjson");
    const b = JSON.parse(execFileSync(s.nexus, ["bundle", path.join(s.vault, "Maps/Plain.nexusjson")], { encoding: "utf8" })) as Bundle;
    await expect(page.locator(`${MAP} .onx-topic`)).toHaveCount(Object.keys(must(b.canvases[0], "c1").layouts.saved.topics).length);
    await expect(page.locator(`${MAP} .opennexus-outline`)).toHaveCount(0);
  });

  test("A2 · embeds draw in Reading view and Live Preview; broken ones say why", async () => {
    const { page } = s;
    const b = bundleOf(path.join(s.vault, "Maps/Launch plan.nexusjson"));
    const pricing = topicId(b, "Pricing");
    for (const mode of ["preview", "source"] as const) {
      // Obsidian keeps only the sections near the screen, so the page records each start.
      const surface = mode === "preview" ? ".markdown-preview-view" : ".markdown-source-view";
      await page.evaluate((surface) => {
        const seen = new WeakSet<Element>();
        const started: string[] = [];
        window.__started = started;
        new MutationObserver(() => {
          for (const e of Array.from(document.querySelectorAll<HTMLElement>(`.workspace-leaf.mod-active ${surface} .opennexus-embed[data-opennexus-ready="true"]`))) {
            if (seen.has(e)) continue;
            seen.add(e);
            started.push(e.dataset.opennexusFile ?? "");
          }
        }).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-opennexus-ready"] });
      }, surface);
      await open(page, "Embeds.md", mode);
      // A note's tab keeps its other mode's page too, hidden.
      const note = page.locator(`.workspace-leaf.mod-active .workspace-leaf-content[data-type=markdown] ${surface}`);
      const scroller = mode === "preview" ? note : note.locator(".cm-scroller");
      // Obsidian carries the scroll position across modes; start from the top.
      await scroller.evaluate((e) => {
        e.scrollTo(0, 0);
      });
      await expect(note.locator(".opennexus-embed .onx").first()).toBeVisible();
      // Down the note a little at a time: each embed starts as it comes into view.
      for (let i = 0; i < 40; i++) {
        const atEnd = await scroller.evaluate((e) => e.scrollTop + e.clientHeight >= e.scrollHeight - 2);
        if (atEnd) break;
        await scroller.evaluate((e) => {
          e.scrollBy(0, 250);
        });
        await sleep(120);
      }
      await expect(note.getByText("OpenNexus embed: height is a number of pixels, not “tall”.")).toBeVisible();
      await expect(note.getByText("OpenNexus embed: Name the map with “file: Folder/Map.nexusjson”.")).toBeVisible();
      await expect(note.getByText("OpenNexus embed: there’s no map “Maps/Nowhere.nexusjson” in this vault.")).toBeVisible();
      const started = (await page.evaluate(() => window.__started)) ?? [];
      expect(new Set(started)).toEqual(new Set(["Maps/Launch plan.nexusjson", "Launch plan.nexusjson", "Plan.nexus"]));
      expect(started.filter((f) => f === "Maps/Launch plan.nexusjson").length).toBeGreaterThanOrEqual(2);
      if (mode === "preview") {
        // The Roadmap canvas, and Pricing framed with its branch.
        await scroller.evaluate((e) => {
          e.scrollTo(0, 0);
        });
        await expect(note.locator('.opennexus-embed[data-opennexus-file="Launch plan.nexusjson"] .onx-topic', { hasText: "Pricing page" })).toBeVisible();
        // The branch's embed (260 px tall); Obsidian draws its section once it's near the screen.
        const framed = note.locator('.opennexus-embed[data-opennexus-file="Maps/Launch plan.nexusjson"][data-opennexus-ready="true"][style*="260px"]');
        for (let i = 0; i < 30 && (await framed.count()) === 0; i++) {
          await scroller.evaluate((e) => {
            e.scrollBy(0, 200);
          });
          await sleep(150);
        }
        await expect(async () => {
          await framed.scrollIntoViewIfNeeded({ timeout: 1000 });
          await expect(framed.locator(`.onx-topic[data-id="${pricing}"]`)).toBeVisible({ timeout: 1000 });
          const box = must(await framed.locator(".onx").boundingBox({ timeout: 1000 }), "the embed");
          for (const id of [pricing, topicId(b, "Free tier"), topicId(b, "Annual discount")]) {
            const t = must(await framed.locator(`.onx-topic[data-id="${id}"]`).boundingBox({ timeout: 1000 }), id);
            expect(t.x).toBeGreaterThanOrEqual(box.x);
            expect(t.x + t.width).toBeLessThanOrEqual(box.x + box.width);
            expect(t.y).toBeGreaterThanOrEqual(box.y);
            expect(t.y + t.height).toBeLessThanOrEqual(box.y + box.height);
          }
        }).toPass({ timeout: 15_000 });
      }
    }
  });

  test("A2 · an embed far down a note starts only when it's scrolled into view", async () => {
    const { page } = s;
    await open(page, "Long note.md", "preview");
    const note = page.locator(".workspace-leaf.mod-active .workspace-leaf-content[data-type=markdown]");
    await expect(note.locator(".markdown-preview-view").getByText("Paragraph 1.", { exact: false }).first()).toBeVisible();
    await sleep(1000);
    await expect(note.locator(".onx")).toHaveCount(0);
    for (let i = 0; i < 60 && (await note.locator(".onx").count()) === 0; i++) {
      await note.locator(".markdown-preview-view").evaluate((e) => {
        e.scrollBy(0, 400);
      });
      await sleep(100);
    }
    await expect(note.locator(".opennexus-embed .onx")).toBeVisible();
  });

  test("A2 · links in a map open notes in the vault", async () => {
    const { page } = s;
    const b = bundleOf(path.join(s.vault, "Maps/Launch plan.nexusjson"));
    const select = async (text: string): Promise<void> => {
      await page.locator(`${MAP} .onx-topic[data-id="${topicId(b, text)}"]`).click();
    };
    await open(page, "Maps/Launch plan.nexusjson");
    await select("Launch plan");
    await page.locator(`${MAP} .onx-details`).getByRole("button", { name: "Risks", exact: true }).click();
    await expect.poll(() => activeFile(page)).toBe("Notes/Risks.md");

    await open(page, "Maps/Launch plan.nexusjson");
    await select("Launch plan");
    await page.locator(`${MAP} .onx-details`).getByRole("button", { name: "the budget" }).click();
    await expect(page.locator(".notice", { hasText: "There’s no note “Budget” in this vault." })).toBeVisible();
    expect(await activeFile(page)).toBe("Maps/Launch plan.nexusjson");

    // An obsidian://open link opens the note; a web link stays a link.
    await select("Positioning");
    await expect(page.locator(`${MAP} .onx-details a[href="https://example.com/positioning"]`)).toBeVisible();
    await select("Channels");
    await page.locator(`${MAP} .onx-details`).getByRole("button", { name: "obsidian://open?file=Notes%2FRisks" }).click();
    await expect.poll(() => activeFile(page)).toBe("Notes/Risks.md");
  });

  test("A2 · Copy link to topic reopens the map at the topic", async () => {
    const { page } = s;
    const b = bundleOf(path.join(s.vault, "Maps/Launch plan.nexusjson"));
    const pricing = topicId(b, "Pricing");
    await open(page, "Maps/Launch plan.nexusjson");
    // The system clipboard is the user's: the link goes to the page instead.
    await page.evaluate(() => {
      navigator.clipboard.writeText = (t: string) => {
        window.__copied = t;
        return Promise.resolve();
      };
    });
    await page.locator(`${MAP} .onx-topic[data-id="${pricing}"]`).click();
    await command(page, "copy-topic-link");
    const link = must(await page.evaluate(() => window.__copied), "the copied link");
    expect(link).toBe(`obsidian://opennexus?vault=Test%20vault&file=Maps%2FLaunch%20plan.nexusjson&canvas=c1&topic=${pricing}`);

    // Elsewhere, with the map closed, Obsidian hands the link to the plugin.
    await open(page, "Notes/Risks.md", "preview");
    await page.evaluate((link) => {
      for (const leaf of window.app.workspace.getLeavesOfType("opennexus-map")) (leaf as unknown as { detach(): void }).detach();
      const u = new URL(link);
      const params: Record<string, string> = { action: u.hostname };
      u.searchParams.forEach((v, k) => (params[k] = v));
      window.OBS_ACT(params);
    }, link);
    await expect.poll(() => activeFile(page)).toBe("Maps/Launch plan.nexusjson");
    await expect(page.locator(`${MAP} .onx-topic.is-selected`)).toHaveAttribute("data-id", pricing);
  });

  test("A2 · an open map redraws within 1 s of a save", async () => {
    const { page } = s;
    cpSync(path.join(s.vault, "Maps/Launch plan.nexusjson"), path.join(s.vault, "Maps/Live.nexusjson"));
    cpSync(path.join(s.vault, "Maps/Plan.nexus"), path.join(s.vault, "Maps/Live.nexus"), { recursive: true });
    await noticed(page, "Maps/Live.nexusjson");
    await noticed(page, "Maps/Live.nexus/render/viewer.json");

    // A single file: the app's save leaves out `render` (as single-file documents do by
    // default), so the plugin draws it with nexus.
    await open(page, "Maps/Live.nexusjson");
    await expect(page.locator(`${MAP} .onx-topic`).first()).toBeVisible();
    let at = shown(page, MAP, "Saved by OpenNexus");
    await sleep(200);
    let t = await save(s, "Maps/Live.nexusjson", "Launch plan", "Saved by OpenNexus");
    let ms = (await at) - t.sent;
    test.info().annotations.push({ type: ".nexusjson", description: `${String(ms)} ms from the save's request (${String(t.saved - t.sent)} ms to save)` });
    expect(ms).toBeLessThan(1000);

    // A package, replaced whole on save.
    await page.evaluate(async () => {
      await window.app.workspace.getLeaf(false).setViewState({ type: "opennexus-package", state: { path: "Maps/Live.nexus" }, active: true });
    });
    const pkg = view("opennexus-package");
    await expect(page.locator(`${pkg} .onx-topic`).first()).toBeVisible();
    at = shown(page, pkg, "Saved by OpenNexus");
    await sleep(200);
    t = await save(s, "Maps/Live.nexus", "Launch plan", "Saved by OpenNexus");
    ms = (await at) - t.sent;
    test.info().annotations.push({ type: ".nexus", description: `${String(ms)} ms from the save's request (${String(t.saved - t.sent)} ms to save)` });
    expect(ms).toBeLessThan(1000);
  });

  test("A3 · a note as a map equals nexus import, follows the cursor and keeps up with typing", async () => {
    const { page } = s;
    const NOTE = '.workspace-leaf-content[data-type="opennexus-note-map"]';
    await open(page, "Trip.md", "source");
    await command(page, "note-as-map");
    await expect(page.locator(`${NOTE} .onx-topic`, { hasText: "Sintra" })).toBeVisible();
    const fromNote = await page.locator(`${NOTE} .onx`).evaluate(drawing);

    // The same note through Convert note (nexus import --viewer-copy), and by hand.
    await page.evaluate(() => {
      const leaf = window.app.workspace.getLeavesOfType("markdown").find((l) => l.view.file?.path === "Trip.md");
      if (leaf !== undefined) window.app.workspace.setActiveLeaf(leaf, { focus: true });
    });
    await command(page, "convert-note");
    await expect.poll(() => activeFile(page)).toBe("Trip.nexusjson");
    await expect(page.locator(`${MAP} .onx-topic`, { hasText: "Sintra" })).toBeVisible();
    expect(await page.locator(`${MAP} .onx`).evaluate(drawing)).toEqual(fromNote);
    const imported = path.join(s.base, "Trip.nexusjson");
    execFileSync(s.nexus, ["import", path.join(s.vault, "Trip.md"), "--out", imported, "--viewer-copy"]);
    expect(bundleOf(imported)).toEqual(bundleOf(path.join(s.vault, "Trip.nexusjson")));

    // Clicking a topic puts the editor's cursor on its line.
    const lines = readFileSync(path.join(s.vault, "Trip.md"), "utf8").split("\n");
    await page.locator(`${NOTE} .onx-topic`, { hasText: "Passport" }).click();
    const cursor = (): Promise<number> =>
      page.evaluate(() => window.app.workspace.getLeavesOfType("markdown").find((l) => l.view.file?.path === "Trip.md")?.view.editor?.getCursor().line ?? -1);
    await expect.poll(cursor).toBe(lines.indexOf("- Passport"));
    await page.locator(`${NOTE} .onx-topic`, { hasText: "Day 2" }).click();
    await expect.poll(cursor).toBe(lines.indexOf("### Day 2"));

    // Typing: the map catches up within 1 s of the pause.
    // The note ends with a newline, so the cursor goes to an empty last line.
    const empty = await page.evaluate(() => {
      const leaf = window.app.workspace.getLeavesOfType("markdown").find((l) => l.view.file?.path === "Trip.md");
      const editor = leaf?.view.editor;
      if (leaf === undefined || editor === undefined) return false;
      window.app.workspace.setActiveLeaf(leaf, { focus: true });
      const last = editor.lastLine();
      editor.setCursor(last, 0);
      editor.focus();
      return editor.getLine(last) === "";
    });
    expect(empty).toBe(true);
    const at = shown(page, NOTE, "Tram 28");
    await page.keyboard.type("- Tram 28", { delay: 30 });
    const paused = Date.now();
    const ms = (await at) - paused;
    test.info().annotations.push({ type: "typing", description: `${String(ms)} ms after typing stopped` });
    expect(ms).toBeLessThan(1000);
  });

  test("A2 · Insert map as outline writes the map into the note", async () => {
    const { page } = s;
    writeFileSync(path.join(s.vault, "Outline.md"), "# Outline\n\n");
    await noticed(page, "Outline.md");
    await open(page, "Outline.md", "source");
    await page.evaluate(() => {
      const editor = window.app.workspace.getLeavesOfType("markdown").find((l) => l.view.editor?.getValue().startsWith("# Outline"))?.view.editor;
      editor?.setCursor(2, 0);
    });
    await command(page, "insert-outline");
    await page.locator(".prompt-input").fill("Launch plan.nexusjson");
    await page.keyboard.press("Enter");
    const text = (): Promise<string> => page.evaluate(() => window.app.workspace.getLeavesOfType("markdown").map((l) => l.view.editor?.getValue() ?? "").find((t) => t.startsWith("# Outline")) ?? "");
    await expect.poll(text).toContain("Annual discount");
    expect(await text()).toContain("Pricing");
  });

  test("A4 · a crafted map is inert in its view and in an embed", async () => {
    const { page } = s;
    const from = s.requests.length;
    const dialogs = s.dialogs;
    await open(page, "Maps/Crafted.nexusjson");
    const map = page.locator(`${MAP} .onx`);
    await page.locator(`${MAP} .onx-topic[data-id="t1"]`).click();
    await page.mouse.move(60, 200);
    await sleep(300);
    expect(await map.evaluate(inert)).toEqual({ bad: [], handlers: [], hrefs: [], styles: 0 });
    await expect(page.locator(`${MAP} .onx-details code`)).toHaveText("javascript:window.__pwned=10");

    // Hostile wikilinks are text on buttons; one names no note, one names a real note.
    const details = page.locator(`${MAP} .onx-details`);
    await details.getByRole("button", { name: '<img src=x onerror="window.__pwned=16">' }).click();
    await expect(page.locator(".notice", { hasText: 'There’s no note “<img src=x onerror="window.__pwned=16">” in this vault.' })).toBeVisible();
    expect(await page.locator(".notice-container img").count()).toBe(0);
    await details.getByRole("button", { name: '<b onmouseover="window.__pwned=17">Risks</b>' }).click();
    await expect.poll(() => activeFile(page)).toBe("Notes/Risks.md");

    // A link into another vault stays text; a topic link out of this one opens nothing.
    await open(page, "Maps/Crafted.nexusjson");
    await page.locator(`${MAP} .onx-topic[data-id="t2"]`).click();
    await expect(page.locator(`${MAP} .onx-details code`)).toHaveText("obsidian://open?vault=Elsewhere&file=Secrets");
    await page.locator(`${MAP} .onx-topic[data-id="t3"]`).click();
    await page.locator(`${MAP} .onx-details`).getByRole("button", { name: /^obsidian:\/\/opennexus/ }).click();
    await expect(page.locator(".notice", { hasText: "There’s no map “../../../etc/passwd” in this vault." })).toBeVisible();
    expect(await activeFile(page)).toBe("Maps/Crafted.nexusjson");

    await open(page, "Crafted.md", "preview");
    const embed = page.locator(".workspace-leaf.mod-active .opennexus-embed .onx");
    await expect(embed).toBeVisible();
    await embed.locator(".onx-topic").first().hover();
    expect(await embed.evaluate(inert)).toEqual({ bad: [], handlers: [], hrefs: [], styles: 0 });

    await sleep(300);
    expect(s.dialogs).toBe(dialogs);
    expect(await page.evaluate(() => window.__pwned)).toBeUndefined();
    expect(s.requests.slice(from).filter((u) => /^(https?|wss?):/.test(u))).toEqual([]);
  });

  test("A1 · turning the plugin off leaves nothing behind, and on again redraws", async () => {
    const { page } = s;
    await open(page, "Maps/Launch plan.nexusjson");
    await expect(page.locator(`${MAP} .onx-topic`).first()).toBeVisible();
    await page.evaluate(async () => {
      const leaf = window.app.workspace.getLeaf("tab");
      await leaf.setViewState({ type: "markdown", state: { file: "Embeds.md", mode: "preview" }, active: true });
    });
    await expect(page.locator(".workspace-leaf.mod-active .opennexus-embed .onx").first()).toBeVisible();
    await page.evaluate(() => window.app.plugins.disablePlugin("opennexus"));
    // Obsidian keeps the plugin's tabs as placeholders, to bring back if it's turned on again.
    const left = await page.evaluate(() => ({
      viewers: document.querySelectorAll(".onx, .opennexus-view, .opennexus-embed").length,
      placeholders: window.app.workspace.getLeavesOfType("opennexus-map").map((l) => (l as unknown as { view: { containerEl: HTMLElement } }).view.containerEl.innerText.includes("Plugin no longer active")),
    }));
    expect(left.viewers).toBe(0);
    expect(left.placeholders.length).toBeGreaterThan(0);
    expect(left.placeholders.every(Boolean)).toBe(true);
    // On again, the map's tab draws when it's shown.
    await page.evaluate(async () => {
      await (window.app.plugins as unknown as { enablePlugin(id: string): Promise<void> }).enablePlugin("opennexus");
      const leaf = window.app.workspace.getLeavesOfType("opennexus-map")[0];
      if (leaf !== undefined) window.app.workspace.setActiveLeaf(leaf, { focus: true });
    });
    await expect(page.locator(`${MAP} .onx-topic`).first()).toBeVisible();
  });
});
