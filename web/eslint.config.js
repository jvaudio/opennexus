import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["**/dist/", "**/node_modules/", "fixtures/", "test-results/", "playwright-report/"] },
  js.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  ...tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: { allowDefaultProject: ["*.js", "*.ts", "viewer-core/*.mjs", "viewer-app/*.mjs", "obsidian/*.mjs"] }, tsconfigRootDir: import.meta.dirname },
    },
  },
  {
    // The viewer is offline by design: no network, no eval, no HTML from strings.
    files: ["viewer-core/src/**/*.ts"],
    rules: {
      "no-restricted-globals": ["error", "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "eval"],
      "no-restricted-properties": [
        "error",
        { property: "innerHTML", message: "Build nodes; never parse bundle text as HTML." },
        { property: "outerHTML", message: "Build nodes; never parse bundle text as HTML." },
        { property: "insertAdjacentHTML", message: "Build nodes; never parse bundle text as HTML." },
        { object: "navigator", property: "sendBeacon" },
        { object: "document", property: "write" },
      ],
      "no-implied-eval": "error",
      "no-new-func": "error",
    },
  },
  {
    // The viewer site fetches sealed maps (the network rule allows web/viewer-app), but it
    // never builds HTML from text or evaluates code either.
    files: ["viewer-app/src/**/*.ts"],
    rules: {
      "no-restricted-globals": ["error", "XMLHttpRequest", "WebSocket", "EventSource", "eval"],
      "no-restricted-properties": [
        "error",
        { property: "innerHTML", message: "Build nodes; never parse text as HTML." },
        { property: "outerHTML", message: "Build nodes; never parse text as HTML." },
        { property: "insertAdjacentHTML", message: "Build nodes; never parse text as HTML." },
        { object: "navigator", property: "sendBeacon" },
        { object: "document", property: "write" },
      ],
      "no-implied-eval": "error",
      "no-new-func": "error",
    },
  },
  {
    // The Obsidian plugin (M49) makes no network requests and inserts no HTML: maps come
    // from anyone. Obsidian's own request helpers are off limits too.
    files: ["obsidian/src/**/*.ts"],
    rules: {
      "no-restricted-globals": ["error", "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "eval"],
      "no-restricted-properties": [
        "error",
        { property: "innerHTML", message: "Build nodes; never parse map text as HTML." },
        { property: "outerHTML", message: "Build nodes; never parse map text as HTML." },
        { property: "insertAdjacentHTML", message: "Build nodes; never parse map text as HTML." },
        { object: "navigator", property: "sendBeacon" },
        { object: "document", property: "write" },
      ],
      "no-restricted-imports": [
        "error",
        {
          paths: [
            { name: "obsidian", importNames: ["request", "requestUrl", "sanitizeHTMLToDom"], message: "The plugin makes no network requests and inserts no HTML." },
            { name: "http", message: "The plugin makes no network requests." },
            { name: "https", message: "The plugin makes no network requests." },
            { name: "net", message: "The plugin makes no network requests." },
          ],
        },
      ],
      "no-implied-eval": "error",
      "no-new-func": "error",
    },
  },
  { files: ["**/*.mjs", "**/*.js"], ...tseslint.configs.disableTypeChecked },
  // MathJax for JavaScriptCore (M48) is glue around MathJax's own classes, whose typings
  // don't hold under the strict base config, so it's linted without type information.
  { files: ["math/src/**/*.ts"], ...tseslint.configs.disableTypeChecked },
  {
    // The site's service worker runs in the worker's scope, not a page's.
    files: ["viewer-app/site/sw.js"],
    languageOptions: { globals: { self: "readonly", caches: "readonly", fetch: "readonly", URL: "readonly" } },
  },
);
