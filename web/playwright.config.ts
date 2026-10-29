import { defineConfig, devices } from "@playwright/test";
import { release } from "node:os";

// Playwright's Firefox (157, Playwright 1.64) doesn't start on macOS 27: it exits with
// "Could not find profile folder" before reading its profile. Until a build that does,
// Firefox runs where it starts (Linux, earlier macOS), or when NEXUS_E2E_FIREFOX=1.
const firefoxStarts =
  process.env.NEXUS_E2E_FIREFOX === "1" || process.platform !== "darwin" || Number(release().split(".")[0]) < 27;

// The viewer opens from disk (file://), as a reader opens an exported .html. Share links
// (M44) open on the viewer site, served from viewer-app/dist as GitHub Pages would.
export default defineConfig({
  testDir: "e2e",
  webServer: { command: "node e2e/serve.mjs", url: "http://127.0.0.1:4310/s/", reuseExistingServer: true },
  fullyParallel: true,
  forbidOnly: true,
  reporter: [["list"]],
  use: { viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 } },
    { name: "webkit", use: { ...devices["Desktop Safari"], viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 } },
    ...(firefoxStarts
      ? [{ name: "firefox", use: { ...devices["Desktop Firefox"], viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 } }]
      : []),
  ],
});
