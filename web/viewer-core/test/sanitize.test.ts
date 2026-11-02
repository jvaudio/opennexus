import { describe, expect, it } from "vitest";
import { safeLink, sanitizeSVG } from "../src/sanitize";

const evil = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10" onload="x()">
<script>x()</script><style>rect{fill:red}</style>
<defs><path id="g1" d="M0 0L1 1"/><filter id="f"><feDropShadow dx="1" dy="1" stdDeviation="1"/></filter></defs>
<g data-nexus-id="n1" class="topic" filter="url(#f)">
  <rect width="5" height="5" fill="url(https://evil.example/p#g)" onclick="x()"/>
  <rect width="4" height="4" fill="#FF0000" fill-opacity="0.5" style="background:url(https://evil.example/)"/>
  <use href="#g1" x="1" y="2"/>
  <use href="https://evil.example/s.svg#a"/>
  <image href="https://evil.example/t.png"/>
  <image xlink:href="javascript:x()"/>
  <image href="data:image/png;base64,iVBORw0KGgo=" width="1" height="1"/>
  <image href="data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=" width="1" height="1"/>
  <image data-nexus-asset="pic" width="1" height="1"/>
  <foreignObject><div xmlns="http://www.w3.org/1999/xhtml">hi</div></foreignObject>
  <a href="javascript:x()"><text>a</text></a>
  <animate attributeName="href" to="javascript:x()"/>
  <set attributeName="onmouseover" to="x()"/>
  <text x="1" y="1">Hello <tspan>there</tspan></text>
  <path d="M0 0" stroke="\\75 rl(https://evil.example/)"/>
</g></svg>`;

describe("sanitizeSVG", () => {
  const svg = sanitizeSVG(evil, document, { asset: (n) => (n === "pic" ? "blob:file:///abc" : undefined) });

  it("keeps the drawing", () => {
    expect(svg).not.toBeNull();
    expect(svg?.getAttribute("viewBox")).toBe("0 0 10 10");
    expect(svg?.querySelector("[data-nexus-id=n1]")?.getAttribute("filter")).toBe("url(#f)");
    expect(svg?.querySelector("use")?.getAttribute("href")).toBe("#g1");
    expect(svg?.querySelector("feDropShadow")).not.toBeNull();
    expect(svg?.querySelector("text")?.textContent).toBe("Hello there");
    expect(svg?.querySelectorAll("rect")[1]?.getAttribute("fill-opacity")).toBe("0.5");
  });

  it("drops scripts, handlers, styles, foreign content and animation", () => {
    const html = svg?.outerHTML ?? "";
    for (const bad of ["<script", "<style", "foreignObject", "<a", "<animate", "<set", "onload", "onclick", "style=", "x()"]) {
      expect(html).not.toContain(bad);
    }
  });

  it("drops every external reference", () => {
    const html = svg?.outerHTML ?? "";
    expect(html).not.toContain("evil.example");
    expect(html).not.toContain("javascript:");
    expect(html).not.toContain("svg+xml");
    const hrefs = Array.from(svg?.querySelectorAll("image") ?? []).map((i) => i.getAttribute("href"));
    expect(hrefs.filter((h) => h !== null)).toEqual(["data:image/png;base64,iVBORw0KGgo=", "blob:file:///abc"]);
  });

  it("refuses what isn't an SVG", () => {
    expect(sanitizeSVG("<html><body/></html>", document)).toBeNull();
    expect(sanitizeSVG("<svg", document)).toBeNull();
    expect(sanitizeSVG(`<svg xmlns="http://www.w3.org/1999/xhtml"/>`, document)).toBeNull();
  });
});

describe("safeLink", () => {
  it("lets web and mail links through", () => {
    expect(safeLink("https://example.com/a?b=1")).toBe("https://example.com/a?b=1");
    expect(safeLink("http://example.com")).toBe("http://example.com/");
    expect(safeLink("mailto:ana@example.com")).toBe("mailto:ana@example.com");
  });

  it("stops everything else", () => {
    for (const bad of ["javascript:alert(1)", " JaVaScRiPt:alert(1)", "data:text/html,<script>", "file:///etc/passwd", "vbscript:x", "nexus:topic/c1/n1", "notaurl", ""]) {
      expect(safeLink(bad)).toBeNull();
    }
  });
});
