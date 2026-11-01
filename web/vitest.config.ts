import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["viewer-core/test/**/*.test.ts", "viewer-app/test/**/*.test.ts", "obsidian/test/**/*.test.ts"],
    environment: "jsdom",
  },
  // The plugin's tests run against a stand-in for Obsidian's API (M49).
  resolve: { alias: { obsidian: fileURLToPath(new URL("obsidian/test/obsidian.ts", import.meta.url)) } },
});
