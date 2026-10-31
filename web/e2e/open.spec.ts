// M47d acceptance in Chromium and WebKit (Firefox where it starts, D326): the site's front
// page opens a .nexusjson, a .nexus folder and a Finder zip by picker and by drop, drawing
// each one's viewer copy with its assets (A1); the outline, encrypted and refused cards
// (A2); Present (A3); the PWA, offline after one visit (A4); axe and the keyboard (A7); and
// nothing requested beyond the site (A8).
//
// fixtures/open/ is made by `npm run fixtures` (OpenFixtures.swift).

import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import type { Opened } from "../viewer-app/src/document";

declare global {
  interface Window {
    /** Set by the front page once something is open (viewer-app/src/open.ts). */
    OpenNexusOpen?: { kind: Opened["kind"]; text?: string };
  }
}

interface Case {
  name: string;
  path: string;
  how: "file" | "folder";
  expect: Opened["kind"];
  bundle?: string;
  slides?: string[];
  asset?: { topic: string; name: string; bytes: string };
  outline?: string[][];
  advice?: string;
  hint?: string;
}

interface Slide {
  title: string;
  focus: string[];
  note?: string;
}

const dir = path.resolve(import.meta.dirname, "../fixtures/open");
const made = existsSync(path.join(dir, "manifest.json"));
const cases: Case[] = made ? (JSON.parse(readFileSync(path.join(dir, "manifest.json"), "utf8")) as { cases: Case[] }).cases : [];
const site = "http://127.0.0.1:4310/";

function must<T>(v: T | undefined | null, what: string): T {
  if (v === undefined || v === null) throw new Error(`missing ${what}`);
  return v;
}

/** A folder's files, by path inside it. */
function folder(root: string, prefix = ""): { path: string; data: string }[] {
  return readdirSync(path.join(root, prefix)).flatMap((name) => {
    const rel = prefix === "" ? name : `${prefix}/${name}`;
    return statSync(path.join(root, rel)).isDirectory() ? folder(root, rel) : [{ path: rel, data: readFileSync(path.join(root, rel)).toString("base64") }];
  });
}

interface Watch {
  errors: string[];
  requests: string[];
}

async function home(page: Page): Promise<Watch> {
  const w: Watch = { errors: [], requests: [] };
  page.on("pageerror", (e) => w.errors.push(e.message));
  page.on("console", (m) => {
    if (m.type() === "error") w.errors.push(m.text());
  });
  page.on("request", (r) => w.requests.push(r.url()));
  await page.goto(site);
  await expect(page.locator("html")).toHaveAttribute("data-onx-state", "home");
  return w;
}

async function state(page: Page): Promise<string> {
  await expect(page.locator("html")).not.toHaveAttribute("data-onx-state", /^(home|loading)$/, { timeout: 20_000 });
  return (await page.locator("html").getAttribute("data-onx-state")) ?? "";
}

async function pick(page: Page, c: Case): Promise<void> {
  await page.locator(c.how === "folder" ? "#open-folder" : "#open-file").setInputFiles(path.join(dir, c.path));
}

/** Drops the case's file, or its folder as the browser's entry API hands one over. */
async function drop(page: Page, c: Case): Promise<void> {
  if (c.how === "file") {
    const data = readFileSync(path.join(dir, c.path)).toString("base64");
    await page.evaluate(
      ({ name, data }) => {
        const dt = new DataTransfer();
        dt.items.add(new File([Uint8Array.from(atob(data), (ch) => ch.charCodeAt(0))], name));
        document.body.dispatchEvent(new DragEvent("dragover", { dataTransfer: dt, bubbles: true, cancelable: true }));
        document.body.dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
      },
      { name: path.basename(c.path), data },
    );
    return;
  }
  // Playwright can't drag a folder in from the OS, so the drop carries entries built as
  // the browser builds them: directories that read in batches, files that hand over a File.
  await page.evaluate(
    ({ name, files }) => {
      interface Node {
        dirs: Map<string, Node>;
        files: Map<string, File>;
      }
      const tree: Node = { dirs: new Map(), files: new Map() };
      for (const f of files) {
        const parts = f.path.split("/");
        const base = must(parts.pop());
        let n = tree;
        for (const p of parts) {
          if (!n.dirs.has(p)) n.dirs.set(p, { dirs: new Map(), files: new Map() });
          n = must(n.dirs.get(p));
        }
        n.files.set(base, new File([Uint8Array.from(atob(f.data), (ch) => ch.charCodeAt(0))], base));
      }
      function must<T>(v: T | undefined): T {
        if (v === undefined) throw new Error("missing");
        return v;
      }
      function entry(entryName: string, n: Node): unknown {
        const all = [
          ...[...n.dirs].map(([k, d]) => entry(k, d)),
          ...[...n.files].map(([k, file]) => ({ name: k, isFile: true, isDirectory: false, file: (ok: (f: File) => void) => { ok(file); } })),
        ];
        return {
          name: entryName,
          isFile: false,
          isDirectory: true,
          createReader: () => {
            let at = 0;
            // Two at a time, as readEntries answers in batches until it answers with none.
            return { readEntries: (ok: (e: unknown[]) => void) => { ok(all.slice(at, (at += 2))); } };
          },
        };
      }
      const root = entry(name, tree);
      const data = {
        types: ["Files"],
        files: [],
        items: [{ kind: "file", webkitGetAsEntry: () => root, getAsFile: () => null }],
      };
      const e = new Event("drop", { bubbles: true, cancelable: true });
      Object.defineProperty(e, "dataTransfer", { value: data });
      document.body.dispatchEvent(e);
    },
    { name: path.basename(c.path), files: folder(path.join(dir, c.path)) },
  );
}

async function openedText(page: Page): Promise<unknown> {
  return JSON.parse(await page.evaluate(() => window.OpenNexusOpen?.text ?? "null")) as unknown;
}

/** The canvas's topics' text from the outline the page shows, depth first. */
function flatten(canvases: { topics: Topic[] }[]): string[][] {
  const walk = (ts: Topic[]): string[] => ts.flatMap((t) => [t.text, ...walk(t.children)]);
  return canvases.map((c) => walk(c.topics));
}

interface Topic {
  text: string;
  children: Topic[];
}

async function axe(page: Page): Promise<void> {
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
}

async function checkOpened(page: Page, c: Case): Promise<void> {
  expect(await state(page)).toBe(c.expect === "bundle" ? "ready" : c.expect);
  switch (c.expect) {
    case "bundle": {
      const expected = JSON.parse(readFileSync(path.join(dir, must(c.bundle, "bundle")), "utf8")) as unknown;
      expect(await openedText(page)).toEqual(expected);
      await expect(page.locator(".onx")).toBeVisible();
      // Its attachment comes from the document's own assets.
      const asset = must(c.asset, "asset");
      await page.getByRole("tree").getByRole("treeitem", { name: asset.topic, exact: true }).locator(":scope > .onx-row").click();
      const link = page.getByRole("complementary").getByRole("link", { name: asset.name });
      expect(await link.getAttribute("href")).toMatch(/^blob:/);
      const download = page.waitForEvent("download");
      await link.click();
      expect(readFileSync(await (await download).path(), "utf8")).toBe(asset.bytes);
      await page.keyboard.press("Escape");
      break;
    }
    case "outline": {
      expect(flatten((await openedText(page)) as { topics: Topic[] }[])).toEqual(c.outline);
      await expect(page.locator(".open-how")).toContainText(must(c.advice, "advice"));
      for (const t of must(c.outline, "outline").flat()) await expect(page.locator(".open-topic", { hasText: t }).first()).toBeVisible();
      break;
    }
    case "encrypted":
      await expect(page.locator("h1")).toHaveText(`“${path.basename(c.path, ".nexus")}” is encrypted`);
      await expect(page.locator(".open-hint")).toHaveText(`Password hint: ${must(c.hint, "hint")}`);
      break;
    case "refused":
      await expect(page.locator("h1")).toHaveText(/^Can’t open/);
      await expect(page.locator("main p").first()).not.toBeEmpty();
      break;
  }
  await axe(page);
}

test.describe("open", () => {
  test.skip(!made, "fixtures/open/ isn't made (npm run fixtures)");

  test("the front page", async ({ page, browserName }) => {
    const w = await home(page);
    await expect(page.locator("h1")).toHaveText("OpenNexus Viewer");
    await expect(page.getByRole("button", { name: "Open File…" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Open Folder…" })).toBeVisible();
    await axe(page);
    // From the keyboard: the first stop is Open File…, which opens the file chooser. (Safari
    // tabs to buttons with Option-Tab unless "Press Tab to highlight each item" is on.)
    await page.keyboard.press(browserName === "webkit" ? "Alt+Tab" : "Tab");
    await expect(page.getByRole("button", { name: "Open File…" })).toBeFocused();
    const chooser = page.waitForEvent("filechooser");
    await page.keyboard.press("Enter");
    await (await chooser).setFiles(path.join(dir, "Plan.nexusjson"));
    expect(await state(page)).toBe("ready");
    expect(w.errors).toEqual([]);
  });

  for (const c of cases) {
    test(`${c.name} by picker`, async ({ page, browserName }) => {
      // Playwright's folder upload to WebKit now and then takes over ten seconds by itself.
      test.slow(browserName === "webkit" && c.how === "folder");
      const w = await home(page);
      await pick(page, c);
      await checkOpened(page, c);
      // Open Another… goes back to the front page.
      await page.getByRole("button", { name: "Open Another…" }).click();
      await expect(page.locator("html")).toHaveAttribute("data-onx-state", "home");
      expect(w.errors).toEqual([]);
      // Nothing beyond the site's own files: the document never leaves the browser (A8).
      expect(w.requests.filter((u) => !u.startsWith(site) && !u.startsWith("blob:"))).toEqual([]);
    });

    test(`${c.name} by drop`, async ({ page }) => {
      const w = await home(page);
      await drop(page, c);
      await checkOpened(page, c);
      expect(w.errors).toEqual([]);
    });
  }

  test("a drop over an open map opens the new one", async ({ page }) => {
    await home(page);
    await pick(page, must(cases.find((c) => c.name === "json"), "json"));
    expect(await state(page)).toBe("ready");
    const outline = must(cases.find((c) => c.name === "json-outline"), "json-outline");
    await drop(page, outline);
    await checkOpened(page, outline);
  });

  test("Present plays the deck in its saved order", async ({ page }) => {
    const c = must(cases.find((x) => x.name === "json"), "json");
    const bundle = JSON.parse(readFileSync(path.join(dir, must(c.bundle, "bundle")), "utf8")) as { canvases: { deck: { slides: Slide[] } }[] };
    const slides = must(bundle.canvases[0], "canvas").deck.slides;
    expect(slides.map((s) => s.title)).toEqual(c.slides);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await home(page);
    await pick(page, c);
    expect(await state(page)).toBe("ready");
    await page.getByRole("button", { name: "Present", exact: true }).click();
    const root = page.locator(".onx");
    await expect(root).toHaveClass(/onx-presenting/);
    const caption = page.getByRole("region", { name: "Present" });
    const title = caption.getByRole("heading", { level: 2 });
    const next = caption.getByRole("button", { name: "Next Slide" });
    await expect(next).toBeFocused();
    await axe(page);
    const stage = page.locator(".onx-stage");
    const view = page.viewportSize() ?? { width: 1280, height: 800 };
    for (const [i, s] of slides.entries()) {
      if (i > 0) {
        const before = await stage.evaluate((e) => e.style.transform);
        await page.keyboard.press(i % 2 === 0 ? "ArrowRight" : "Space");
        // With reduced motion the camera cuts: the transform is final at once.
        const after = await stage.evaluate((e) => e.style.transform);
        expect(after).not.toBe(before);
        await page.waitForTimeout(100);
        expect(await stage.evaluate((e) => e.style.transform)).toBe(after);
      }
      await expect(title).toHaveText(s.title);
      await expect(caption.locator(".onx-slide-count")).toHaveText(`${String(i + 1)} of ${String(slides.length)}`);
      await expect(root).toHaveAttribute("data-onx-slide", String(i));
      // The camera frames the slide's focus topics above the caption.
      const top = must(await caption.boundingBox(), "caption").y;
      for (const id of s.focus) {
        const box = must(await page.locator(`.onx-topic[data-id="${id}"]`).boundingBox(), id);
        expect(box.x).toBeGreaterThanOrEqual(0);
        expect(box.y).toBeGreaterThanOrEqual(0);
        expect(box.x + box.width).toBeLessThanOrEqual(view.width);
        expect(box.y + box.height).toBeLessThanOrEqual(top);
      }
      if (s.note !== undefined) {
        const note = caption.locator(".onx-slide-note");
        await expect(note).toBeHidden();
        await page.keyboard.press("n");
        await expect(note).toHaveText(s.note);
        await page.keyboard.press("n");
        await expect(note).toBeHidden();
      }
    }
    // The last slide stays; ← goes back; Home and End jump.
    await page.keyboard.press("ArrowRight");
    await expect(title).toHaveText(must(slides.at(-1), "last").title);
    await page.keyboard.press("ArrowLeft");
    await expect(title).toHaveText(must(slides.at(-2), "second last").title);
    await page.keyboard.press("Home");
    await expect(title).toHaveText(must(slides[0], "first").title);
    await page.keyboard.press("End");
    await expect(title).toHaveText(must(slides.at(-1), "last").title);
    // Esc leaves, back to the map as it was, with focus on Present.
    await page.keyboard.press("Escape");
    await expect(root).not.toHaveClass(/onx-presenting/);
    await expect(caption).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Present", exact: true })).toBeFocused();
    // P presents from the keyboard too.
    await page.keyboard.press("p");
    await expect(root).toHaveClass(/onx-presenting/);
    await caption.getByRole("button", { name: "End Presentation" }).click();
    await expect(root).not.toHaveClass(/onx-presenting/);
  });

  test("Present flies between slides", async ({ page }) => {
    await home(page);
    await pick(page, must(cases.find((x) => x.name === "json"), "json"));
    expect(await state(page)).toBe("ready");
    await page.getByRole("button", { name: "Present", exact: true }).click();
    const stage = page.locator(".onx-stage");
    const caption = page.getByRole("region", { name: "Present" });
    await expect(caption).toBeVisible();
    await page.waitForTimeout(800);
    const start = await stage.evaluate((e) => e.style.transform);
    await page.keyboard.press("ArrowRight");
    // Partway through the flight the camera is between the two views.
    await page.waitForTimeout(250);
    const mid = await stage.evaluate((e) => e.style.transform);
    await page.waitForTimeout(700);
    const end = await stage.evaluate((e) => e.style.transform);
    expect(mid).not.toBe(start);
    expect(mid).not.toBe(end);
  });
});

test.describe("the installed site", () => {
  test.skip(!made, "fixtures/open/ isn't made (npm run fixtures)");
  test.use({ serviceWorkers: "allow" });

  test("is an installable PWA", async ({ page, browserName }) => {
    test.skip(browserName !== "chromium", "installability is Chromium's to report");
    await home(page);
    await page.evaluate(() => navigator.serviceWorker.ready.then(() => undefined));
    const cdp = await page.context().newCDPSession(page);
    const manifest = (await cdp.send("Page.getAppManifest")) as { errors: unknown[]; url: string };
    expect(manifest.url).toBe(`${site}manifest.webmanifest`);
    expect(manifest.errors).toEqual([]);
    const install = (await cdp.send("Page.getInstallabilityErrors")) as { installabilityErrors: unknown[] };
    expect(install.installabilityErrors).toEqual([]);
  });

  test("works offline after one visit", async ({ page, context }) => {
    await home(page);
    // The worker precaches the site, then takes the page.
    await page.waitForFunction(() => navigator.serviceWorker.controller !== null, undefined, { timeout: 20_000 });
    await context.setOffline(true);
    try {
      await page.reload();
      await expect(page.locator("html")).toHaveAttribute("data-onx-state", "home");
      await pick(page, must(cases.find((c) => c.name === "zip"), "zip"));
      expect(await state(page)).toBe("ready");
      // The share and join pages come from the cache too.
      await page.goto(`${site}s/`);
      await expect(page.locator("h1")).toBeVisible();
    } finally {
      await context.setOffline(false);
    }
  });
});
