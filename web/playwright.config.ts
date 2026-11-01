import { defineConfig, devices } from "@playwright/test";
import { release } from "node:os";

// Playwright's Firefox (157, Playwright 1.64) doesn't start on macOS 27: it exits with
// "Could not find profile folder" before reading its profile. Until a build that does,
// Firefox runs where it starts (Linux, earlier macOS), or when NEXUS_E2E_FIREFOX=1.
const firefoxStarts =
  process.env.NEXUS_E2E_FIREFOX === "1" || process.platform !== "darwin" || Number(release().split(".")[0]) < 27;

// The viewer opens from disk (file://), as a reader opens an exported .html. Share links
// (M44) open on the viewer site, served from viewer-app/dist as GitHub Pages would. The
// Obsidian plugin (M49) runs in a throwaway Obsidian, a project of its own.
export default defineConfig({
  testDir: "e2e",
  webServer: { command: "node e2e/serve.mjs", url: "http://127.0.0.1:4310/s/", reuseExistingServer: true },
  fullyParallel: true,
  forbidOnly: true,
  reporter: [["list"]],
  // Page routes don't see what a service worker answers, so only the PWA tests let the
  // viewer site's worker run (open.spec.ts).
  use: { viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1, serviceWorkers: "block" },
  testIgnore: /obsidian\.spec\.ts/,
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 } },
    { name: "webkit", use: { ...devices["Desktop Safari"], viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 } },
    ...(firefoxStarts
      ? [{ name: "firefox", use: { ...devices["Desktop Firefox"], viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 } }]
      : []),
    { name: "obsidian", testIgnore: [], testMatch: /obsidian\.spec\.ts/ },
  ],
});
