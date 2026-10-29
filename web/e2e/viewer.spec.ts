// M43 acceptance in Chromium, WebKit and Firefox: the exported page opens from disk with no
// requests (A1), draws what the app draws (A2), works as a reader expects (A3), stays inert
// with a crafted bundle (A4), is quick (A5) and accessible (A6).

import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { gzipSync } from "node:zlib";
import { PNG } from "pngjs";
import type { parseBundle } from "../viewer-core/src/bundle";
import type { find } from "../viewer-core/src/search";

declare global {
  interface Window {
    OpenNexusViewer: { parseBundle: typeof parseBundle; find: typeof find; readyAt: number };
  }
}

interface FindCase {
  page: string;
  canvas: number;
  query: string;
  matchCase: boolean;
  wholeWords: boolean;
  notes: boolean;
  labels: boolean;
  allCanvases: boolean;
  count: number;
}

interface Manifest {
  pages: { name: string; canvases: { id: string; topics: number; png?: string }[] }[];
  find: FindCase[];
  scopes: { branch: string[]; zone: string[] };
  rich: Record<"pricing" | "timeline" | "channels" | "risks" | "root", string>;
}

const fixtures = path.resolve(import.meta.dirname, "../fixtures");
const manifest = JSON.parse(readFileSync(path.join(fixtures, "manifest.json"), "utf8")) as Manifest;
const fileURL = (name: string): string => `file://${path.join(fixtures, `${name}.html`)}`;

interface Opened {
  errors: string[];
  requests: string[];
}

async function open(page: Page, name: string): Promise<Opened> {
  const o: Opened = { errors: [], requests: [] };
  page.on("console", (m) => {
    if (m.type() === "error" || m.type() === "warning") o.errors.push(m.text());
  });
  page.on("pageerror", (e) => o.errors.push(e.message));
  page.on("request", (r) => o.requests.push(r.url()));
  await page.goto(fileURL(name));
  await page.waitForFunction(() => document.documentElement.dataset.onxReady !== undefined);
  expect(await page.evaluate(() => document.documentElement.dataset.onxReady)).toBe("true");
  return o;
}

const transform = (page: Page): Promise<string> => page.locator(".onx-stage").evaluate((e) => (e as HTMLElement).style.transform);
const scale = async (page: Page): Promise<number> => Number(/scale\(([\d.e-]+)\)/.exec(await transform(page))?.[1] ?? "NaN");
const selected = (page: Page): Promise<string | null> => page.locator(".onx-topic.is-selected").first().getAttribute("data-id");

test.describe("A1 · offline", () => {
  for (const name of ["launchplan", "rich", "threat"]) {
    test(`${name} opens from disk with no requests and no console errors`, async ({ page }) => {
      const o = await open(page, name);
      // Use the reader's features too: they mustn't load anything either.
      await page.getByRole("radio", { name: "Everything" }).click().catch(() => undefined);
      await page.locator(".onx-topic").first().click();
      await page.getByRole("searchbox").fill("a");
      await page.waitForTimeout(300);
      expect(o.requests.filter((u) => !u.startsWith("blob:") && !u.startsWith("data:"))).toEqual([fileURL(name)]);
      expect(o.errors).toEqual([]);
    });
  }
});

test.describe("A2 · the drawing matches the app", () => {
  for (const p of manifest.pages) {
    p.canvases.forEach((c, index) => {
      const png = c.png;
      if (png === undefined) return;
      test(`${p.name} ${c.id} at 1× matches the app's PNG`, async ({ page }) => {
        await open(page, p.name);
        if (index > 0) await page.getByRole("tab").nth(index).click();
        const want = PNG.sync.read(readFileSync(path.join(fixtures, png)));
        await page.setViewportSize({ width: Math.max(want.width, 320), height: Math.max(want.height, 200) });
        // The drawing alone, at 1×, at the page's top left.
        await page.evaluate(() => {
          const svg = document.querySelector(".onx-drawing svg");
          if (!(svg instanceof SVGSVGElement)) throw new Error("no drawing");
          svg.style.position = "absolute";
          svg.style.left = "0px";
          svg.style.top = "0px";
          document.body.replaceChildren(svg);
          document.body.style.margin = "0";
        });
        const shot = PNG.sync.read(await page.screenshot({ clip: { x: 0, y: 0, width: want.width, height: want.height } }));
        expect([shot.width, shot.height]).toEqual([want.width, want.height]);
        let total = 0;
        let changed = 0;
        const n = want.width * want.height;
        for (let i = 0; i < n; i++) {
          const j = i * 4;
          const d = (Math.abs((shot.data[j] ?? 0) - (want.data[j] ?? 0)) + Math.abs((shot.data[j + 1] ?? 0) - (want.data[j + 1] ?? 0)) + Math.abs((shot.data[j + 2] ?? 0) - (want.data[j + 2] ?? 0))) / 3;
          total += d;
          if (d > 30) changed++;
        }
        const mean = total / n / 255;
        test.info().annotations.push({ type: "mean channel delta", description: mean.toFixed(4) });
        test.info().annotations.push({ type: "changed pixels", description: `${(100 * changed / n).toFixed(2)}%` });
        expect(mean).toBeLessThan(0.02);
      });
    });
  }
});

test.describe("A3 · reading", () => {
  test("canvas tabs", async ({ page }) => {
    await open(page, "launchplan");
    const tabs = page.getByRole("tab");
    await expect(tabs).toHaveCount(2);
    await expect(tabs.first()).toHaveAttribute("aria-selected", "true");
    await tabs.nth(1).click();
    await expect(tabs.nth(1)).toHaveAttribute("aria-selected", "true");
    await expect(page.locator(".onx")).toHaveAttribute("data-canvas", "c2");
    await expect(page.locator(".onx-topic")).toHaveCount(manifest.pages[0]?.canvases[1]?.topics ?? -1);
    await tabs.nth(1).press("ArrowLeft");
    await expect(page.locator(".onx")).toHaveAttribute("data-canvas", "c1");
  });

  test("pan, zoom and Fit", async ({ page }) => {
    await open(page, "rich");
    const start = await transform(page);
    const k0 = await scale(page);
    const box = await page.locator(".onx-viewport").boundingBox();
    if (box === null) throw new Error("no viewport");
    // Drag on empty canvas, near the bottom right.
    await page.mouse.move(box.x + box.width - 30, box.y + box.height - 30);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width - 130, box.y + box.height - 80, { steps: 5 });
    await page.mouse.up();
    expect(await transform(page)).not.toBe(start);
    expect(await scale(page)).toBe(k0);
    await page.getByRole("button", { name: "Zoom In" }).click();
    await expect.poll(() => scale(page)).toBeGreaterThan(k0 * 1.2);
    await page.keyboard.press("-");
    await page.getByRole("button", { name: "Fit" }).click();
    await expect.poll(() => transform(page)).toBe(start);
    // Pinch (ctrl + wheel) zooms at the pointer.
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.keyboard.down("Control");
    await page.mouse.wheel(0, -100);
    await page.keyboard.up("Control");
    await expect.poll(() => scale(page)).toBeGreaterThan(k0);
  });

  test("both layouts and the +N badge", async ({ page }) => {
    await open(page, "rich");
    const saved = await page.locator(".onx-topic").count();
    await expect(page.locator(".onx")).toHaveAttribute("data-layout", "saved");
    await page.getByRole("radio", { name: "Everything" }).click();
    await expect(page.locator(".onx")).toHaveAttribute("data-layout", "expanded");
    expect(await page.locator(".onx-topic").count()).toBe(saved + 2);
    await page.getByRole("radio", { name: "As saved" }).click();
    await expect(page.locator(".onx")).toHaveAttribute("data-layout", "saved");
    // The badge opens Everything at its topic.
    await page.getByRole("button", { name: "Show 2 hidden topics" }).click({ force: true });
    await expect(page.locator(".onx")).toHaveAttribute("data-layout", "expanded");
    await expect.poll(() => selected(page)).toBe(manifest.rich.timeline);
  });

  test("the outline flies to a topic and shows its details", async ({ page }) => {
    await open(page, "rich");
    const tree = page.getByRole("tree");
    await tree.getByRole("treeitem", { name: "Channels", exact: true }).locator(":scope > .onx-row").click();
    await expect.poll(() => selected(page)).toBe(manifest.rich.channels);
    const details = page.getByRole("complementary");
    await expect(details.getByRole("heading", { level: 2 })).toHaveText("Channels");
    const link = details.getByRole("link", { name: "https://example.com/channels" });
    await expect(link).toHaveAttribute("href", "https://example.com/channels");
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");
    // Outline keys: down to the next row, Return shows it.
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Enter");
    await expect(details.getByRole("heading", { level: 2 })).toHaveText("Product Hunt");
  });

  test("details: note, comments, attachments", async ({ page }) => {
    await open(page, "rich");
    await page.locator(`.onx-topic[data-id="${manifest.rich.pricing}"]`).click();
    const details = page.getByRole("complementary");
    await expect(details).toContainText("Secret pricing note");
    await expect(details).toContainText("Hidden remark");
    await expect(details).toContainText("Ana");
    await page.locator(`.onx-topic[data-id="${manifest.rich.risks}"]`).click();
    const att = details.getByRole("link", { name: "Brief.pdf" });
    await expect(att).toHaveAttribute("download", "Brief.pdf");
    expect(await att.getAttribute("href")).toMatch(/^blob:/);
    await page.keyboard.press("Escape");
    await expect(details).toBeHidden();
  });

  test("keyboard: arrows move between topics, Return opens details, / searches", async ({ page }) => {
    await open(page, "rich");
    await page.locator(`.onx-topic[data-id="${manifest.rich.root}"]`).click();
    await page.keyboard.press("Escape");
    await expect.poll(() => selected(page)).toBe(manifest.rich.root);
    await page.keyboard.press("ArrowRight");
    const right = await selected(page);
    expect(right).not.toBe(manifest.rich.root);
    await expect(page.locator(".onx-topic.is-selected")).toBeFocused();
    await page.keyboard.press("ArrowLeft");
    await expect.poll(() => selected(page)).toBe(manifest.rich.root);
    await page.keyboard.press("Enter");
    await expect(page.getByRole("complementary")).toBeVisible();
    await page.keyboard.press("Escape");
    await page.keyboard.press("/");
    await expect(page.getByRole("searchbox")).toBeFocused();
  });

  test("search in the page counts what the app's Find counts", async ({ page }) => {
    await open(page, "rich");
    const cases = manifest.find.filter((f) => f.page === "rich" && f.canvas === 0 && !f.notes && !f.labels);
    const box = page.getByRole("searchbox");
    const count = page.getByRole("status");
    for (const f of cases.filter((c) => ["pro", "café", "über", "4"].includes(c.query))) {
      for (const [name, on] of [["Match case", f.matchCase], ["Whole words", f.wholeWords]] as const) {
        await page.getByRole("checkbox", { name, exact: true }).setChecked(on);
      }
      await box.fill(f.query);
      await expect(count, `${f.query} ${JSON.stringify(f)}`).toHaveAttribute("data-count", String(f.count));
    }
    // Return steps through the matches.
    await page.getByRole("checkbox", { name: "Match case" }).setChecked(false);
    await page.getByRole("checkbox", { name: "Whole words" }).setChecked(false);
    await box.fill("tier");
    await box.press("Enter");
    await expect(count).toHaveText(/^1 of \d+$/);
    expect(await selected(page)).not.toBeNull();
  });

  test("every query and option matches the app's Find", async ({ page }) => {
    for (const name of [...new Set(manifest.find.map((f) => f.page))]) {
      await page.goto(fileURL(name));
      await page.waitForFunction(() => document.documentElement.dataset.onxReady === "true");
      const cases = manifest.find.filter((f) => f.page === name);
      const got = await page.evaluate((cs) => {
        const api = window.OpenNexusViewer;
        const b = api.parseBundle(document.getElementById("opennexus-bundle")?.textContent ?? "");
        return cs.map((c) => api.find(b, c.canvas, c.query, c).length);
      }, cases);
      const wrong = cases.filter((c, i) => got[i] !== c.count).map((c, i) => ({ ...c, got: got[i] }));
      expect(wrong, name).toEqual([]);
    }
  });
});

test.describe("A4 · scopes and a crafted bundle", () => {
  for (const scope of ["branch", "zone"] as const) {
    test(`a ${scope} export holds only its topics`, async ({ page }) => {
      await open(page, scope);
      const ids = await page.locator(".onx-topic").evaluateAll((els) => els.map((e) => (e as HTMLElement).dataset.id));
      expect(new Set(ids)).toEqual(new Set(manifest.scopes[scope]));
      const rows = await page.getByRole("treeitem").count();
      expect(rows).toBe(manifest.scopes[scope].length);
    });
  }

  test("a crafted bundle renders inert", async ({ page }) => {
    let dialogs = 0;
    page.on("dialog", (d) => {
      dialogs++;
      void d.dismiss();
    });
    const o = await open(page, "malicious");
    await page.locator(".onx-topic").first().click();
    await page.mouse.move(60, 200);
    await page.waitForTimeout(300);
    expect(dialogs).toBe(0);
    expect(await page.evaluate(() => (window as unknown as { __pwned?: unknown }).__pwned)).toBeUndefined();
    expect(o.requests.filter((u) => !u.startsWith("blob:") && !u.startsWith("data:"))).toEqual([fileURL("malicious")]);
    const report = await page.evaluate(() => {
      const root = document.querySelector(".onx");
      const all = Array.from(root?.querySelectorAll("*") ?? []);
      return {
        bad: all.filter((e) => ["script", "iframe", "foreignObject", "style", "animate", "set", "object", "embed", "img"].includes(e.localName) || (e.localName === "a" && e.namespaceURI !== "http://www.w3.org/1999/xhtml")).map((e) => e.localName),
        handlers: all.flatMap((e) => Array.from(e.attributes).filter((a) => a.name.startsWith("on")).map((a) => `${e.localName}[${a.name}]`)),
        hrefs: all.flatMap((e) => ["href", "src", "xlink:href"].map((n) => e.getAttribute(n) ?? "")).filter((h) => h !== "" && !h.startsWith("#") && !h.startsWith("blob:") && !h.startsWith("data:image/png")),
        styles: all.filter((e) => (e.getAttribute("style") ?? "").includes("url(")).length,
      };
    });
    expect(report).toEqual({ bad: [], handlers: [], hrefs: [], styles: 0 });
    // The javascript: link is shown as text, never as a link.
    await expect(page.getByRole("complementary").locator("code")).toHaveText("javascript:window.__pwned=10");
  });
});

test.describe("A5 · speed and size", () => {
  test("a 1,000-topic map is interactive in under 1.5 s", async ({ page, browserName }) => {
    test.skip(browserName !== "chromium", "measured in Chromium");
    await open(page, "large");
    const ready = await page.evaluate(() => window.OpenNexusViewer.readyAt);
    test.info().annotations.push({ type: "ready", description: `${ready.toFixed(0)} ms` });
    expect(ready).toBeGreaterThan(0);
    expect(ready).toBeLessThan(1500);
    await expect(page.locator(".onx-topic")).toHaveCount(1000);
  });

  test("the viewer is at most 150 KB gzipped", ({ browserName }) => {
    test.skip(browserName !== "chromium", "once");
    const dir = path.resolve(import.meta.dirname, "../../Sources/NexusCanvas/Viewer");
    const bytes = ["opennexus-viewer.js", "opennexus-viewer.css"].reduce((n, f) => n + gzipSync(readFileSync(path.join(dir, f))).length, 0);
    test.info().annotations.push({ type: "gzipped", description: `${String(bytes)} bytes` });
    expect(bytes).toBeLessThanOrEqual(150 * 1024);
  });
});

test.describe("A6 · accessibility", () => {
  for (const name of ["launchplan", "rich", "threat"]) {
    test(`${name}: axe finds nothing serious`, async ({ page }) => {
      await open(page, name);
      await page.locator(".onx-topic").nth(1).click();
      const results = await new AxeBuilder({ page }).analyze();
      const bad = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(" ")).slice(0, 3).join(", ")}`);
      expect(bad).toEqual([]);
    });
  }

  test("the outline is an ARIA tree and every topic speaks as in the app", async ({ page }) => {
    await open(page, "rich");
    const tree = page.getByRole("tree");
    await expect(tree).toHaveCount(1);
    expect(await tree.getByRole("treeitem").count()).toBeGreaterThan(10);
    const mismatches = await page.evaluate(() => {
      const raw = JSON.parse(document.getElementById("opennexus-bundle")?.textContent ?? "{}") as { canvases: { topics: Record<string, { label: string }> }[] };
      const topics = raw.canvases[0]?.topics ?? {};
      return Array.from(document.querySelectorAll<HTMLElement>(".onx-topic")).filter((e) => e.getAttribute("aria-label") !== topics[e.dataset.id ?? ""]?.label).length;
    });
    expect(mismatches).toBe(0);
    // Exactly one topic is in the tab order, and every one can take focus.
    expect(await page.locator('.onx-topic[tabindex="0"]').count()).toBe(1);
    expect(await page.locator('.onx-topic:not([tabindex])').count()).toBe(0);
  });
});
