// M46: the join page in Chromium and WebKit (Firefox where it starts, D326). Invites come
// from a real session in Swift (`JoinFixtures`, made by `npm run fixtures`): the page offers
// the app with the same invite, asks the session's server for the view with the read
// capability only, and draws the host's view read-only, byte for byte the bundle the app
// sealed.

import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Route } from "@playwright/test";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

declare global {
  interface Window {
    /** Set by the join page once the view is drawn (viewer-app/src/join.ts). */
    OpenNexusJoin?: { text: string };
  }
}

interface RouteCase {
  url: string;
  status: number;
  file?: string;
}

interface Case {
  name: string;
  link: string;
  expect: string;
  bundle?: string;
  routes: RouteCase[];
}

const dir = path.resolve(import.meta.dirname, "../fixtures/join");
const manifestFile = path.join(dir, "manifest.json");
const manifest = existsSync(manifestFile)
  ? (JSON.parse(readFileSync(manifestFile, "utf8")) as { viewer: string; cases: Case[] })
  : undefined;
const viewer = "http://127.0.0.1:4310";

test.skip(manifest === undefined, "fixtures/join/ isn't made (npm run fixtures)");

for (const c of manifest?.cases ?? []) {
  test(c.name, async ({ page }) => {
    const fragment = c.link.split("#")[1] ?? "";
    const parts = fragment.split(".");
    const [read, write] = [parts[4] ?? "", parts[5]];
    const stray: string[] = [];
    const errors: string[] = [];
    const sent: { url: string; auth: string | undefined }[] = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("request", (r) => {
      sent.push({ url: r.url(), auth: r.headers().authorization });
      expect(r.headers().referer ?? "").toBe("");
    });
    await page.route("**/*", async (route: Route) => {
      const url = route.request().url();
      if (url.startsWith(viewer)) {
        await route.continue();
        return;
      }
      if (route.request().method() === "OPTIONS") {
        await route.fulfill({
          status: 204,
          headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "Authorization" },
        });
        return;
      }
      const r = c.routes.find((x) => x.url === url);
      if (r === undefined) {
        stray.push(url);
        await route.abort();
        return;
      }
      await route.fulfill({
        status: r.status,
        headers: { "Access-Control-Allow-Origin": "*", "Content-Type": "application/octet-stream" },
        body: r.file === undefined ? "" : readFileSync(path.join(dir, r.file)),
      });
    });
    await page.goto(c.link);
    await expect(page.locator("html")).not.toHaveAttribute("data-onx-state", "loading", { timeout: 20_000 });
    await expect(page.locator("html")).toHaveAttribute("data-onx-state", c.expect, { timeout: 20_000 });
    if (c.expect === "damaged") {
      await expect(page.locator("h1")).toHaveText("This invite is damaged");
    } else {
      await expect(page.getByRole("link", { name: "Open in OpenNexus" })).toHaveAttribute(
        "href",
        `opennexus://join#${fragment}`,
      );
      await expect(page.getByRole("link", { name: "Get OpenNexus for Mac" })).toBeVisible();
      // The server is asked for the view with the read capability, and nothing else of the invite.
      const asked = sent.filter((s) => !s.url.startsWith(viewer));
      expect(asked.length).toBeGreaterThan(0);
      for (const s of asked) {
        if (s.auth !== undefined) expect(s.auth).toBe(`Bearer ${read}`);
        expect(s.url).not.toContain(parts[3] ?? "-");
        if (write !== undefined) expect(s.url + (s.auth ?? "")).not.toContain(write);
      }
    }
    if (c.bundle !== undefined) {
      const shown = await page.evaluate(() => window.OpenNexusJoin?.text ?? "");
      expect(JSON.parse(shown)).toEqual(JSON.parse(readFileSync(path.join(dir, c.bundle), "utf8")));
      await expect(page.locator("#opennexus-viewer")).toBeVisible();
    }
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    expect(stray).toEqual([]);
    expect(errors).toEqual([]);
  });
}
