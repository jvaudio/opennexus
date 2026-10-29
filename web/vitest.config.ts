import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["viewer-core/test/**/*.test.ts"],
    environment: "jsdom",
  },
});
