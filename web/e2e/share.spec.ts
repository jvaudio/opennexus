// M44 acceptance in Chromium and WebKit (Firefox where it starts, D326): share links open on
// the viewer site to the same bundle as the Interactive HTML export (A2); a wrong key or an
// altered byte reads as damaged (A3); password links (A4); Update, Revoke and expiry (A5).
//
// fixtures/share/ is made by `npm run fixtures`: Playwright answers each link's fetches with
// what the destination stored. fixtures/share-live/ is made by scripts/test-share.sh against
// MinIO and the server in Docker, so those fetches are real.

import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page, type Route } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

declare global {
  interface Window {
    /** Set by the share page once a map is open (viewer-app/src/share.ts). */
    OpenNexusShare?: { text: string };
  }
}

interface RouteCase {
  url: string;
  status: number;
  file?: string;
  json?: boolean;
}

interface Case {
  name: string;
  link: string;
  expect: string;
  bundle?: string;
  password?: string;
  routes: RouteCase[];
  after?: RouteCase[];
  then?: string;
  thenBundle?: string;
}

interface Manifest {
  viewer: string;
  cases: Case[];
}

const fixtures = path.resolve(import.meta.dirname, "../fixtures");

function load(dir: string): Manifest | undefined {
  const file = path.join(fixtures, dir, "manifest.json");
  return existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Manifest) : undefined;
}

const viewer = "http://127.0.0.1:4310";

/** Answers the case's fetches; anything else off the viewer site is a failure. */
async function serve(page: Page, dir: string, routes: RouteCase[] | undefined, stray: string[]): Promise<void> {
  await page.unroute("**/*");
  await page.route("**/*", async (route: Route) => {
    const url = route.request().url();
    if (url.startsWith(viewer)) {
      await route.continue();
      return;
    }
    const r = routes?.find((x) => x.url === url);
    if (routes === undefined) {
      await route.continue();
      return;
    }
    if (r === undefined) {
      stray.push(url);
      await route.abort();
      return;
    }
    await route.fulfill({
      status: r.status,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Content-Type": r.json === true ? "application/json" : "application/octet-stream",
      },
      body: r.file === undefined ? "" : readFileSync(path.join(fixtures, dir, r.file)),
    });
  });
}

async function state(page: Page): Promise<string> {
  await expect(page.locator("html")).not.toHaveAttribute("data-onx-state", "loading", { timeout: 20_000 });
  return (await page.locator("html").getAttribute("data-onx-state")) ?? "";
}

async function bundleMatches(page: Page, dir: string, file: string): Promise<void> {
  const shown = await page.evaluate(() => window.OpenNexusShare?.text ?? "");
  const expected = readFileSync(path.join(fixtures, dir, file), "utf8");
  expect(JSON.parse(shown)).toEqual(JSON.parse(expected));
}

function cases(dir: string): void {
  const manifest = load(dir);
  test.skip(manifest === undefined, `${dir}/ isn't made (npm run fixtures, scripts/test-share.sh)`);
  for (const c of manifest?.cases ?? []) {
    test(c.name, async ({ page }) => {
      const stray: string[] = [];
      const errors: string[] = [];
      const sent: string[] = [];
      page.on("pageerror", (e) => errors.push(e.message));
      page.on("request", (r) => {
        sent.push(r.url());
        // The key is after the #; nothing the page sends may carry it, or a referrer.
        expect(r.headers().referer ?? "").toBe("");
      });
      await serve(page, dir, dir === "share" ? c.routes : undefined, stray);
      await page.goto(c.link);
      expect(await state(page)).toBe(c.expect);
      if (c.password !== undefined) {
        await page.fill("#share-password", "not the password");
        await page.press("#share-password", "Enter");
        await expect(page.locator("html")).toHaveAttribute("data-onx-state", "wrong-password", { timeout: 20_000 });
        await expect(page.locator("#share-password-error")).toHaveText("That password doesn’t open this map.");
        expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
        await page.fill("#share-password", c.password);
        await page.press("#share-password", "Enter");
        await expect(page.locator("html")).toHaveAttribute("data-onx-state", "ready", { timeout: 20_000 });
      }
      if (c.bundle !== undefined) await bundleMatches(page, dir, c.bundle);
      if (["off", "expired", "damaged", "newer", "unreachable"].includes(c.expect)) {
        await expect(page.locator("h1")).toBeVisible();
        expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
      }
      if (c.after !== undefined) {
        await serve(page, dir, c.after, stray);
        await page.reload();
        expect(page.url()).toBe(c.link);
        expect(await state(page)).toBe(c.then);
        if (c.thenBundle !== undefined) await bundleMatches(page, dir, c.thenBundle);
        if (c.then === "off") await expect(page.locator("h1")).toHaveText("This link is turned off");
      }
      if (c.expect === "unreachable") await expect(page.getByRole("button", { name: "Try Again" })).toBeVisible();
      expect(stray).toEqual([]);
      expect(errors).toEqual([]);
      const key = c.link.split("#")[1]?.split(".")[3] ?? "";
      if (key.length > 8) expect(sent.filter((u) => u.includes(key))).toEqual([]);
    });
  }
}

test.describe("share links", () => {
  cases("share");
});

test.describe("share links against MinIO and the server", () => {
  cases("share-live");
});

// fixtures/share-ipad/ is made by scripts/test-ipad.sh: a link the iPad simulator made.
test.describe("share links made on the iPad", () => {
  cases("share-ipad");
});

// M47d: `?embed` on a share link, in a wiki's iframe (A5), and the bar's Open in OpenNexus,
// which hands the app the link with its key (A6).
test.describe("embed and Open in OpenNexus", () => {
  const manifest = load("share");
  test.skip(manifest === undefined, "share/ isn't made (npm run fixtures)");
  const named = (name: string): Case => {
    const c = manifest?.cases.find((x) => x.name === name);
    if (c === undefined) throw new Error(`no ${name} case`);
    return c;
  };

  test("?embed shows the map alone, with pan, zoom and a link to the full view", async ({ page }) => {
    const c = named("bucket");
    const stray: string[] = [];
    await serve(page, "share", c.routes, stray);
    const [base, fragment] = c.link.split("#");
    // A wiki page framing the link. (On the site's own origin: Chromium refuses a routed page
    // framing 127.0.0.1, and the frame needs a secure context for Web Crypto.)
    const wiki =
      `<!doctype html><html lang="en"><head><title>Team wiki</title></head><body><main><h1>Plans</h1>` +
      `<iframe title="Launch plan" src="${base ?? ""}?embed#${fragment ?? ""}" style="width:800px;height:500px;border:0"></iframe></main></body></html>`;
    await page.route(`${viewer}/wiki/**`, (r) => r.fulfill({ contentType: "text/html", body: wiki }));
    await page.goto(`${viewer}/wiki/plans`);
    const frame = page.frameLocator("iframe");
    await expect(frame.locator("html")).toHaveAttribute("data-onx-state", "ready", { timeout: 20_000 });
    await expect(frame.locator(".onx")).toHaveClass(/onx-embed/);
    for (const part of [".onx-bar", ".onx-outline", ".onx-details", ".onx-keys"]) await expect(frame.locator(part)).toBeHidden();
    const full = frame.getByRole("link", { name: "Open Full View" });
    await expect(full).toHaveAttribute("href", c.link);
    await expect(full).toHaveAttribute("target", "_blank");
    await expect(full).toHaveAttribute("rel", /noopener/);
    await expect(frame.getByRole("link", { name: "Open in OpenNexus" })).toHaveCount(0);
    // Pan by dragging, zoom with the wheel.
    const stage = frame.locator(".onx-stage");
    const box = await frame.locator(".onx-viewport").boundingBox();
    if (box === null) throw new Error("no viewport");
    const at = (): Promise<string> => stage.evaluate((e) => e.style.transform);
    const start = await at();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + 80, box.y + box.height / 2 + 40, { steps: 5 });
    await page.mouse.up();
    await expect.poll(at).not.toBe(start);
    const panned = await at();
    await page.keyboard.down("Control");
    await page.mouse.wheel(0, -200);
    await page.keyboard.up("Control");
    await expect.poll(at).not.toBe(panned);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    expect(stray).toEqual([]);
  });

  test("Open in OpenNexus hands the app the link with its key", async ({ page }) => {
    const c = named("bucket");
    const stray: string[] = [];
    await serve(page, "share", c.routes, stray);
    await page.goto(c.link);
    expect(await state(page)).toBe("ready");
    const open = page.getByRole("link", { name: "Open in OpenNexus" });
    await expect(open).toHaveAttribute("href", `opennexus://view#${c.link.split("#")[1] ?? ""}`);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    expect(stray).toEqual([]);
  });

  test("a password link hands the app the key the password made", async ({ page }) => {
    const c = named("password");
    const stray: string[] = [];
    await serve(page, "share", c.routes, stray);
    await page.goto(c.link);
    expect(await state(page)).toBe("password");
    await page.fill("#share-password", c.password ?? "");
    await page.press("#share-password", "Enter");
    await expect(page.locator("html")).toHaveAttribute("data-onx-state", "ready", { timeout: 20_000 });
    const href = (await page.getByRole("link", { name: "Open in OpenNexus" }).getAttribute("href")) ?? "";
    const parts = (c.link.split("#")[1] ?? "").split(".");
    const sent = href.replace(/^opennexus:\/\/view#/, "").split(".");
    expect(href.startsWith("opennexus://view#")).toBe(true);
    expect(sent.slice(0, 3)).toEqual(parts.slice(0, 3));
    // 32 bytes of key, in base64url: never the password or its salt.
    expect(sent[3]).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(sent[3]).not.toBe(parts[3]);
    expect(href).not.toContain(c.password ?? "");
    expect(stray).toEqual([]);
  });
});
