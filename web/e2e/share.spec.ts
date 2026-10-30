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
