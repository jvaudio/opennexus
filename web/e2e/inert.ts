// What a crafted bundle must not leave in a page (M43 and M49, A4): elements that run or
// fetch things, event handlers, URLs that leave the page, and styles that load anything.

export interface Inert {
  bad: string[];
  handlers: string[];
  hrefs: string[];
  styles: number;
}

/** Runs in the page, on a viewer's root (`.onx`): `locator.evaluate(inert)`. */
export function inert(root: Element): Inert {
  const all = Array.from(root.querySelectorAll("*"));
  return {
    bad: all.filter((e) => ["script", "iframe", "foreignObject", "style", "animate", "set", "object", "embed", "img"].includes(e.localName) || (e.localName === "a" && e.namespaceURI !== "http://www.w3.org/1999/xhtml")).map((e) => e.localName),
    handlers: all.flatMap((e) => Array.from(e.attributes).filter((a) => a.name.startsWith("on")).map((a) => `${e.localName}[${a.name}]`)),
    hrefs: all.flatMap((e) => ["href", "src", "xlink:href"].map((n) => e.getAttribute(n) ?? "")).filter((h) => h !== "" && !h.startsWith("#") && !h.startsWith("blob:") && !h.startsWith("data:image/png")),
    styles: all.filter((e) => (e.getAttribute("style") ?? "").includes("url(")).length,
  };
}
