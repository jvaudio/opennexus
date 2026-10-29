// An allow-list for the drawings and links a bundle carries. The SVG is parsed as XML and
// rebuilt element by element into the page, so nothing the list doesn't name survives:
// no scripts, event handlers, foreignObject, styles, animation or external references.

export const SVG_NS = "http://www.w3.org/2000/svg";
const XLINK_NS = "http://www.w3.org/1999/xlink";

const elements = new Set([
  "svg", "g", "defs", "symbol", "use", "title", "desc",
  "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
  "text", "tspan", "image", "clipPath", "mask", "marker", "pattern",
  "linearGradient", "radialGradient", "stop",
  "filter", "feDropShadow", "feGaussianBlur", "feOffset", "feFlood", "feComposite", "feMerge", "feMergeNode",
  "feColorMatrix", "feBlend",
]);

/** Elements whose text content is kept. */
const textual = new Set(["text", "tspan", "title", "desc"]);

const attributes = new Set([
  "id", "class", "viewBox", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry",
  "d", "points", "transform", "preserveAspectRatio", "version",
  "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-dasharray",
  "stroke-dashoffset", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "clip-rule",
  "clip-path", "mask", "filter", "marker-start", "marker-mid", "marker-end",
  "font-family", "font-size", "font-style", "font-weight", "letter-spacing", "text-anchor", "text-decoration",
  "dominant-baseline", "dx", "dy",
  "offset", "stop-color", "stop-opacity", "gradientUnits", "gradientTransform", "spreadMethod", "fx", "fy",
  "stdDeviation", "flood-color", "flood-opacity", "in", "in2", "result", "operator", "mode", "values", "type",
  "k1", "k2", "k3", "k4", "clipPathUnits", "maskUnits", "maskContentUnits", "patternUnits", "patternContentUnits",
  "filterUnits", "primitiveUnits", "markerWidth", "markerHeight", "refX", "refY", "orient", "markerUnits",
]);

/** `url(#id)` only: a paint, clip or filter in the same drawing. */
const localURL = /^\s*url\(\s*#[A-Za-z_][\w.-]*\s*\)\s*$/;
const idPattern = /^[A-Za-z_][\w.-]*$/;
/** Raster images inline, the only kind an `<image>` may show. */
export const imageData = /^data:image\/(?:png|jpeg|gif|webp);base64,[A-Za-z0-9+/]+={0,2}$/;

function safeValue(name: string, value: string): boolean {
  const v = value.trim().toLowerCase();
  // Backslashes could spell `url(` in CSS escapes; the app never writes one.
  if (v.includes("\\") || v.includes("javascript:") || v.includes("expression(") || v.includes("@import")) return false;
  if (v.includes("url(")) return localURL.test(value);
  if (name === "id") return idPattern.test(value);
  return true;
}

export interface SanitizeOptions {
  /** A URL for an asset an `<image data-nexus-asset>` names (a blob: or data: URL), or undefined. */
  asset?: (name: string) => string | undefined;
}

/** The drawing as a clean element of `doc`, or null when it isn't an SVG. */
export function sanitizeSVG(source: string, doc: Document, options: SanitizeOptions = {}): SVGSVGElement | null {
  const parsed = new DOMParser().parseFromString(source, "image/svg+xml");
  const root = parsed.documentElement;
  if (root.namespaceURI !== SVG_NS || root.localName !== "svg") return null;
  if (parsed.getElementsByTagName("parsererror").length > 0) return null;
  const out = copy(root, doc, options);
  return out instanceof SVGSVGElement ? out : null;
}

function copy(src: Element, doc: Document, options: SanitizeOptions): Element | null {
  if (src.namespaceURI !== SVG_NS || !elements.has(src.localName)) return null;
  const el = doc.createElementNS(SVG_NS, src.localName);
  for (const attr of Array.from(src.attributes)) {
    const name = attr.localName;
    const value = attr.value;
    if (attr.namespaceURI === null && name.startsWith("data-nexus-")) {
      if (/^data-nexus-[a-z-]+$/.test(name)) el.setAttribute(name, value);
      continue;
    }
    if (name === "href" && (attr.namespaceURI === null || attr.namespaceURI === XLINK_NS)) {
      const href = safeHref(src.localName, value);
      if (href !== null) el.setAttribute("href", href);
      continue;
    }
    if (attr.namespaceURI !== null || !attributes.has(name) || !safeValue(name, value)) continue;
    el.setAttribute(name, value);
  }
  if (src.localName === "image" && !el.hasAttribute("href")) {
    const name = src.getAttribute("data-nexus-asset");
    const url = name === null ? undefined : options.asset?.(name);
    if (url !== undefined && (url.startsWith("blob:") || imageData.test(url))) el.setAttribute("href", url);
  }
  for (const child of Array.from(src.childNodes)) {
    if (child.nodeType === 1) {
      const c = copy(child as Element, doc, options);
      if (c !== null) el.appendChild(c);
    } else if (child.nodeType === 3 && textual.has(src.localName)) {
      el.appendChild(doc.createTextNode(child.nodeValue ?? ""));
    }
  }
  return el;
}

function safeHref(element: string, value: string): string | null {
  if (element === "use") return /^#[A-Za-z_][\w.-]*$/.test(value) ? value : null;
  if (element === "image") return imageData.test(value) ? value : null;
  return null;
}

/** A link the reader may follow: http, https and mailto only. Null for anything else. */
export function safeLink(href: string): string | null {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  return ["http:", "https:", "mailto:"].includes(url.protocol) ? url.href : null;
}
