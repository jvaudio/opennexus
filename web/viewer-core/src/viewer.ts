// The viewer: canvas tabs, the drawing with its text layer, pan and zoom, the outline,
// details, search and both layouts. It draws what the app drew (the bundle's SVGs) and
// never lays a map out itself.

import type { Bundle, Canvas, Layout, Placement, Rect } from "./bundle";
import { Camera, fit, reveal, zoomAt, type View } from "./camera";
import { renderDetails } from "./details";
import { ancestors, initiallyOpen, treeKey, visibleRows, type TreeKey } from "./outline";
import { sanitizeSVG } from "./sanitize";
import { defaultOptions, find, type Match, type SearchOptions } from "./search";
import { center, next, type Direction, type Point } from "./spatial";

export type LayoutName = "saved" | "expanded";

export interface MountOptions {
  /** A URL for an asset the bundle names but doesn't carry (a document's viewer copy). */
  asset?: (name: string) => string | undefined;
}

export interface ViewerHandle {
  readonly element: HTMLElement;
  show(canvas: number, layout?: LayoutName): void;
  select(topic: string): void;
  destroy(): void;
}

/** English, for bundles that carry no strings. */
const english: Record<string, string> = {
  outline: "Outline", details: "Details", search: "Search", searchPlaceholder: "Search topics",
  matchCase: "Match case", wholeWords: "Whole words", notes: "Notes", labels: "Labels",
  allCanvases: "All canvases", noMatches: "No matches", matches: "%d of %d", asSaved: "As saved",
  everything: "Everything", layout: "Layout", fit: "Fit", zoomIn: "Zoom In", zoomOut: "Zoom Out",
  canvases: "Canvases", map: "Map", close: "Close", note: "Note", comments: "Comments", link: "Link",
  attachments: "Attachments", notIncluded: "Not included in this export", task: "Task", markers: "Markers",
  type: "Type", fields: "Fields", threats: "Threats", legend: "Legend", print: "Print",
  keys: "Arrow keys move between topics · Return opens details · / searches · Esc closes",
  showHidden: "Show %d hidden topics", previous: "Previous match", next: "Next match", topic: "Topic",
};

const rasterTypes = /^image\/(?:png|jpeg|gif|webp)$/;

export function format(s: string, ...args: (string | number)[]): string {
  let i = 0;
  return s.replace(/%(?:\d\$)?(?:lld|d|@)/g, () => String(args[i++] ?? ""));
}

function decode(base64: string): Uint8Array | null {
  try {
    return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function inflate(r: Rect, d: number): Rect {
  return [r[0] - d, r[1] - d, r[2] + 2 * d, r[3] + 2 * d];
}

function place(e: HTMLElement, r: Rect): void {
  e.style.left = `${String(r[0])}px`;
  e.style.top = `${String(r[1])}px`;
  e.style.width = `${String(r[2])}px`;
  e.style.height = `${String(r[3])}px`;
}

let instances = 0;

class Viewer {
  private readonly doc: Document;
  private readonly uid = `onx${String(++instances)}`;
  readonly root: HTMLElement;
  private readonly tabs: HTMLElement;
  private readonly layoutGroup: HTMLElement;
  private readonly layoutButtons: Record<LayoutName, HTMLButtonElement>;
  private readonly infoButtons: HTMLElement;
  private readonly searchInput: HTMLInputElement;
  private readonly countEl: HTMLElement;
  private readonly searchChecks = new Map<keyof SearchOptions, HTMLInputElement>();
  private readonly tree: HTMLElement;
  private readonly viewport: HTMLElement;
  private readonly stage: HTMLElement;
  private readonly drawing: HTMLElement;
  private readonly textLayer: HTMLElement;
  private readonly hits: HTMLElement;
  private readonly ring: HTMLElement;
  private readonly aside: HTMLElement;
  private readonly asideTitle: HTMLElement;
  private readonly asideBody: HTMLElement;
  private readonly camera: Camera;
  private readonly reducedMotion = (): boolean =>
    typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

  private canvasIndex = -1;
  private layoutName: LayoutName = "saved";
  private selected: string | null = null;
  private open = new Set<string>();
  private treeItems = new Map<string, HTMLElement>();
  private treeBranches = new Set<string>();
  private treeFocus: string | null = null;
  private topicEls = new Map<string, HTMLElement>();
  private centers = new Map<string, Point>();
  private matches: Match[] = [];
  private matchIndex = -1;
  private options: SearchOptions = { ...defaultOptions };
  private readonly drawings = new Map<string, SVGSVGElement | null>();
  private readonly urls = new Map<string, string | undefined>();
  private readonly fitted = new Set<number>();
  private readonly cleanup: (() => void)[] = [];

  constructor(
    private readonly host: HTMLElement,
    private readonly bundle: Bundle,
    private readonly options_: MountOptions,
  ) {
    const doc = host.ownerDocument;
    this.doc = doc;
    const t = this.t.bind(this);
    const make = <K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] => {
      const e = doc.createElement(tag);
      if (cls !== undefined) e.className = cls;
      if (text !== undefined) e.textContent = text;
      return e;
    };
    const button = (label: string, text: string, cls = "onx-button"): HTMLButtonElement => {
      const b = make("button", cls, text);
      b.type = "button";
      if (label !== text) b.setAttribute("aria-label", label);
      b.title = label;
      return b;
    };

    this.root = make("div", "onx");
    this.root.lang = bundle.lang;

    // Bar: title, canvas tabs, layout, zoom, print, search.
    const bar = make("header", "onx-bar");
    const title = make("h1", "onx-title", bundle.title);
    this.tabs = make("div", "onx-tabs");
    this.tabs.setAttribute("role", "tablist");
    this.tabs.setAttribute("aria-label", t("canvases"));
    this.tabs.hidden = bundle.canvases.length < 2;
    bundle.canvases.forEach((c, i) => {
      const tab = make("button", "onx-tab", c.title === "" ? c.typeName : c.title);
      tab.type = "button";
      tab.id = `${this.uid}-tab-${String(i)}`;
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-controls", `${this.uid}-map`);
      tab.addEventListener("click", () => { this.show(i); });
      tab.addEventListener("keydown", (e) => {
        const d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
        if (d === 0) return;
        e.preventDefault();
        const n = (i + d + bundle.canvases.length) % bundle.canvases.length;
        this.show(n);
        (this.tabs.children[n] as HTMLElement | undefined)?.focus();
      });
      this.tabs.append(tab);
    });

    const tools = make("div", "onx-tools");
    this.layoutGroup = make("div", "onx-segmented");
    this.layoutGroup.setAttribute("role", "radiogroup");
    this.layoutGroup.setAttribute("aria-label", t("layout"));
    this.layoutButtons = { saved: button(t("asSaved"), t("asSaved"), "onx-seg"), expanded: button(t("everything"), t("everything"), "onx-seg") };
    for (const name of ["saved", "expanded"] as const) {
      const b = this.layoutButtons[name];
      b.setAttribute("role", "radio");
      b.addEventListener("click", () => { this.setLayout(name); });
      b.addEventListener("keydown", (e) => {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft" && e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
        e.preventDefault();
        const other = name === "saved" ? "expanded" : "saved";
        this.setLayout(other);
        this.layoutButtons[other].focus();
      });
      this.layoutGroup.append(b);
    }
    const zoomOut = button(t("zoomOut"), "−");
    const fitButton = button(t("fit"), t("fit"));
    const zoomIn = button(t("zoomIn"), "+");
    zoomOut.addEventListener("click", () => { this.zoomBy(1 / 1.25); });
    zoomIn.addEventListener("click", () => { this.zoomBy(1.25); });
    fitButton.addEventListener("click", () => { this.fitAll(true); });
    this.infoButtons = make("div", "onx-info");
    const print = button(t("print"), t("print"));
    print.addEventListener("click", () => { window.print(); });
    const outlineToggle = button(t("outline"), t("outline"), "onx-button onx-outline-toggle");
    outlineToggle.setAttribute("aria-expanded", "true");
    outlineToggle.setAttribute("aria-controls", `${this.uid}-outline`);
    outlineToggle.addEventListener("click", () => {
      const shown = !this.root.classList.toggle("onx-no-outline");
      outlineToggle.setAttribute("aria-expanded", String(shown));
    });
    // Narrow windows start with the outline closed (it covers the map there).
    if (host.clientWidth > 0 && host.clientWidth < 720) {
      this.root.classList.add("onx-no-outline");
      outlineToggle.setAttribute("aria-expanded", "false");
    }
    tools.append(outlineToggle, this.layoutGroup, zoomOut, fitButton, zoomIn, this.infoButtons, print);

    const search = make("form", "onx-search");
    search.setAttribute("role", "search");
    search.addEventListener("submit", (e) => { e.preventDefault(); });
    this.searchInput = make("input", "onx-search-input");
    this.searchInput.type = "search";
    this.searchInput.placeholder = t("searchPlaceholder");
    this.searchInput.setAttribute("aria-label", t("search"));
    this.searchInput.setAttribute("autocomplete", "off");
    this.searchInput.addEventListener("input", () => { this.runSearch(); });
    this.searchInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        this.step(e.shiftKey ? -1 : 1);
      } else if (e.key === "Escape" && this.searchInput.value !== "") {
        e.preventDefault();
        e.stopPropagation();
        this.searchInput.value = "";
        this.runSearch();
      }
    });
    const prev = button(t("previous"), "‹");
    const nextButton = button(t("next"), "›");
    prev.addEventListener("click", () => { this.step(-1); });
    nextButton.addEventListener("click", () => { this.step(1); });
    this.countEl = make("span", "onx-count");
    this.countEl.setAttribute("role", "status");
    const checks = make("div", "onx-search-options");
    const optionKeys: [keyof SearchOptions, string][] = [["matchCase", "matchCase"], ["wholeWords", "wholeWords"], ["notes", "notes"], ["labels", "labels"]];
    if (bundle.canvases.length > 1) optionKeys.push(["allCanvases", "allCanvases"]);
    for (const [key, label] of optionKeys) {
      const l = make("label", "onx-check");
      const box = make("input");
      box.type = "checkbox";
      box.name = key;
      box.addEventListener("change", () => {
        this.options = { ...this.options, [key]: box.checked };
        this.runSearch();
      });
      this.searchChecks.set(key, box);
      l.append(box, doc.createTextNode(t(label)));
      checks.append(l);
    }
    search.append(this.searchInput, prev, nextButton, this.countEl, checks);
    bar.append(title, this.tabs, tools, search);

    // Body: outline, the map, details.
    const body = make("div", "onx-body");
    const nav = make("nav", "onx-outline");
    nav.id = `${this.uid}-outline`;
    nav.setAttribute("aria-label", t("outline"));
    this.tree = make("ul", "onx-tree");
    this.tree.setAttribute("role", "tree");
    this.tree.setAttribute("aria-label", t("outline"));
    nav.append(this.tree);

    this.viewport = make("main", "onx-viewport");
    this.viewport.id = `${this.uid}-map`;
    this.viewport.setAttribute("aria-label", t("map"));
    this.stage = make("div", "onx-stage");
    this.drawing = make("div", "onx-drawing");
    this.drawing.setAttribute("aria-hidden", "true");
    this.hits = make("div", "onx-hits");
    this.hits.setAttribute("aria-hidden", "true");
    this.ring = make("div", "onx-ring");
    this.ring.setAttribute("aria-hidden", "true");
    this.ring.hidden = true;
    this.textLayer = make("div", "onx-text");
    this.textLayer.setAttribute("role", "group");
    this.textLayer.setAttribute("aria-label", t("map"));
    this.stage.append(this.drawing, this.hits, this.ring, this.textLayer);
    const keys = make("p", "onx-keys", t("keys"));
    this.viewport.append(this.stage, keys);

    this.aside = make("aside", "onx-details");
    this.aside.id = `${this.uid}-details`;
    this.aside.setAttribute("aria-labelledby", `${this.uid}-details-title`);
    this.aside.hidden = true;
    const head = make("div", "onx-details-head");
    this.asideTitle = make("h2", "onx-details-title");
    this.asideTitle.id = `${this.uid}-details-title`;
    this.asideTitle.tabIndex = -1;
    const close = button(t("close"), "×", "onx-button onx-close");
    close.addEventListener("click", () => { this.closeDetails(true); });
    head.append(this.asideTitle, close);
    this.asideBody = make("div", "onx-details-body");
    this.aside.append(head, this.asideBody);
    body.append(nav, this.viewport, this.aside);
    this.root.append(bar, body);

    this.camera = new Camera(this.stage, this.reducedMotion);
    this.wireViewport();
    this.root.addEventListener("keydown", (e) => { this.onKey(e); });
    host.replaceChildren(this.root);
    this.show(0);
  }

  t(key: string): string {
    return this.bundle.strings.get(key) ?? english[key] ?? key;
  }

  private get canvas(): Canvas {
    const c = this.bundle.canvases[this.canvasIndex];
    if (c === undefined) throw new Error("no canvas");
    return c;
  }

  private get layout(): Layout {
    return (this.layoutName === "expanded" ? this.canvas.layouts.expanded : undefined) ?? this.canvas.layouts.saved;
  }

  // MARK: Assets

  /** An image's URL: a blob of the bundle's bytes, or the host's. */
  private imageURL(name: string): string | undefined {
    if (this.urls.has(`i:${name}`)) return this.urls.get(`i:${name}`);
    const a = this.bundle.assets.get(name);
    let url: string | undefined;
    if (a?.data !== undefined && rasterTypes.test(a.type)) {
      const bytes = decode(a.data);
      if (bytes !== null) url = URL.createObjectURL(new Blob([bytes as BlobPart], { type: a.type }));
    } else if (a?.data === undefined) {
      url = this.options_.asset?.(name);
    }
    this.urls.set(`i:${name}`, url);
    return url;
  }

  /** An attachment's download URL, always as plain bytes so nothing renders in this page's origin. */
  private attachmentURL(name: string): string | undefined {
    if (this.urls.has(`a:${name}`)) return this.urls.get(`a:${name}`);
    const a = this.bundle.assets.get(name);
    let url: string | undefined;
    if (a?.data !== undefined) {
      const bytes = decode(a.data);
      if (bytes !== null) url = URL.createObjectURL(new Blob([bytes as BlobPart], { type: "application/octet-stream" }));
    } else {
      url = this.options_.asset?.(name);
    }
    this.urls.set(`a:${name}`, url);
    return url;
  }

  // MARK: Canvas and layout

  show(index: number, layout?: LayoutName): void {
    const c = this.bundle.canvases[index];
    if (c === undefined) return;
    const canvasChanged = index !== this.canvasIndex;
    if (canvasChanged) {
      this.canvasIndex = index;
      this.selected = null;
      this.open = initiallyOpen(c.outline);
      this.closeDetails(false);
      this.applyTheme(c);
      this.buildTree();
      this.buildInfo();
      Array.from(this.tabs.children).forEach((tab, i) => {
        tab.setAttribute("aria-selected", String(i === index));
        (tab as HTMLElement).tabIndex = i === index ? 0 : -1;
      });
      this.viewport.setAttribute("aria-labelledby", `${this.uid}-tab-${String(index)}`);
      if (this.bundle.canvases.length < 2) this.viewport.removeAttribute("aria-labelledby");
    }
    const name: LayoutName = layout === "expanded" && c.layouts.expanded !== undefined ? "expanded" : "saved";
    if (canvasChanged || name !== this.layoutName) {
      this.layoutName = name;
      this.drawLayout();
    }
    if (!this.fitted.has(index)) {
      this.fitted.add(index);
      this.fitAll(false);
    }
    this.runSearch();
  }

  private setLayout(name: LayoutName): void {
    if (name === this.layoutName) return;
    this.show(this.canvasIndex, name);
    if (this.selected !== null && this.layout.topics.has(this.selected)) {
      this.select(this.selected, { fly: true });
    } else {
      this.fitAll(true);
    }
  }

  private applyTheme(c: Canvas): void {
    const s = this.root.style;
    s.setProperty("--onx-canvas", c.theme.canvas);
    s.setProperty("--onx-ink", c.theme.ink);
    s.setProperty("--onx-ink2", c.theme.ink2);
    s.setProperty("--onx-accent", c.theme.accent);
    this.root.classList.toggle("onx-dark", c.theme.dark);
    this.root.dataset.canvas = c.id;
  }

  private drawLayout(): void {
    const c = this.canvas;
    const layout = this.layout;
    const key = `${String(this.canvasIndex)}:${this.layoutName}`;
    if (!this.drawings.has(key)) {
      this.drawings.set(key, sanitizeSVG(layout.svg, this.doc, { asset: (n) => this.imageURL(n) }));
    }
    const svg = this.drawings.get(key) ?? null;
    if (svg === null) {
      this.drawing.replaceChildren();
    } else {
      const [x, y, w, h] = layout.viewBox;
      svg.style.left = `${String(x)}px`;
      svg.style.top = `${String(y)}px`;
      svg.style.width = `${String(w)}px`;
      svg.style.height = `${String(h)}px`;
      this.drawing.replaceChildren(svg);
    }
    this.root.dataset.layout = this.layoutName;
    const hasExpanded = c.layouts.expanded !== undefined;
    this.layoutGroup.hidden = !hasExpanded;
    for (const n of ["saved", "expanded"] as const) {
      this.layoutButtons[n].setAttribute("aria-checked", String(n === this.layoutName));
      this.layoutButtons[n].tabIndex = n === this.layoutName ? 0 : -1;
    }

    // The text layer: one focusable element per topic, labelled as VoiceOver says it.
    this.topicEls.clear();
    this.centers.clear();
    const els: HTMLElement[] = [];
    for (const [id, p] of layout.topics) {
      const topic = c.topics.get(id);
      if (topic === undefined) continue;
      const e = this.doc.createElement("div");
      e.className = "onx-topic";
      e.dataset.id = id;
      e.setAttribute("role", "button");
      e.setAttribute("aria-label", topic.label);
      e.setAttribute("aria-controls", this.aside.id);
      e.tabIndex = -1;
      place(e, p.frame);
      const span = this.doc.createElement("span");
      span.className = "onx-t";
      span.textContent = topic.text;
      const tr = p.text ?? p.frame;
      place(span, [tr[0] - p.frame[0], tr[1] - p.frame[1], tr[2], tr[3]]);
      const lines = Math.max(topic.text.split("\n").length, Math.round(tr[3] / 22), 1);
      span.style.fontSize = `${String(Math.min(32, Math.max(6, tr[3] / lines / 1.25)))}px`;
      e.append(span);
      this.topicEls.set(id, e);
      this.centers.set(id, center(p.frame));
      els.push(e);
      // Beside its topic, not inside: a button may not hold another.
      if (p.hidden !== undefined && p.badge !== undefined && c.layouts.expanded !== undefined) {
        els.push(this.badge(id, p));
      }
    }
    this.textLayer.replaceChildren(...els);
    if (this.selected !== null && !layout.topics.has(this.selected)) this.selected = null;
    this.paintSelection();
    this.paintHits();
  }

  /** The +N badge: shows Everything and the topic's hidden branch. */
  private badge(id: string, p: Placement): HTMLElement {
    const b = this.doc.createElement("button");
    b.type = "button";
    b.className = "onx-badge";
    b.tabIndex = -1;
    b.setAttribute("aria-label", format(this.t("showHidden"), p.hidden ?? 0));
    place(b, p.badge ?? p.frame);
    b.addEventListener("click", (e) => {
      e.stopPropagation();
      this.show(this.canvasIndex, "expanded");
      this.select(id, { fly: true, focus: true });
    });
    return b;
  }

  // MARK: Camera

  private size(): { w: number; h: number } {
    return { w: this.viewport.clientWidth || 800, h: this.viewport.clientHeight || 600 };
  }

  private fitAll(animate: boolean): void {
    const { w, h } = this.size();
    const v = fit(this.layout.viewBox, w, h, 16);
    if (animate) this.camera.fly(v);
    else this.camera.set(v);
  }

  private zoomBy(f: number): void {
    const { w, h } = this.size();
    this.camera.fly(zoomAt(this.camera.view, f, w / 2, h / 2));
  }

  private wireViewport(): void {
    const vp = this.viewport;
    const pointers = new Map<number, { x: number; y: number }>();
    let start: { x: number; y: number; view: View; topic: string | null; badge: boolean } | null = null;
    let panning = false;
    let pinch: { d: number; view: View; mx: number; my: number } | null = null;
    const local = (e: PointerEvent | WheelEvent): { x: number; y: number } => {
      const r = vp.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    };
    vp.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const target = e.target as Element;
      const topicEl = target.closest(".onx-topic");
      pointers.set(e.pointerId, local(e));
      if (pointers.size === 2) {
        const [a, b] = Array.from(pointers.values());
        if (a !== undefined && b !== undefined) {
          pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), view: this.camera.view, mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
        }
        return;
      }
      start = { ...local(e), view: this.camera.view, topic: topicEl instanceof HTMLElement ? topicEl.dataset.id ?? null : null, badge: target.closest(".onx-badge") !== null };
      panning = false;
    });
    vp.addEventListener("pointermove", (e) => {
      if (!pointers.has(e.pointerId)) return;
      pointers.set(e.pointerId, local(e));
      if (pinch !== null && pointers.size === 2) {
        const [a, b] = Array.from(pointers.values());
        if (a === undefined || b === undefined) return;
        const d = Math.hypot(a.x - b.x, a.y - b.y);
        this.camera.set(zoomAt(pinch.view, d / Math.max(1, pinch.d), pinch.mx, pinch.my));
        return;
      }
      if (start === null) return;
      const p = local(e);
      const dx = p.x - start.x;
      const dy = p.y - start.y;
      if (!panning && Math.hypot(dx, dy) > 4) {
        panning = true;
        vp.setPointerCapture(e.pointerId);
        vp.classList.add("onx-panning");
      }
      if (panning) this.camera.set({ ...start.view, x: start.view.x + dx, y: start.view.y + dy });
    });
    const end = (e: PointerEvent): void => {
      pointers.delete(e.pointerId);
      if (pointers.size < 2) pinch = null;
      if (start !== null && !panning && !start.badge && e.type === "pointerup" && start.topic !== null) {
        this.select(start.topic, { details: true, focus: true });
      }
      if (pointers.size === 0) {
        start = null;
        panning = false;
        vp.classList.remove("onx-panning");
      }
    };
    vp.addEventListener("pointerup", end);
    vp.addEventListener("pointercancel", end);
    vp.addEventListener(
      "wheel",
      (e) => {
        e.preventDefault();
        const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? this.size().h : 1;
        if (e.ctrlKey || e.metaKey) {
          const p = local(e);
          this.camera.set(zoomAt(this.camera.view, Math.exp(-e.deltaY * unit * 0.01), p.x, p.y));
        } else {
          const v = this.camera.view;
          this.camera.set({ ...v, x: v.x - e.deltaX * unit, y: v.y - e.deltaY * unit });
        }
      },
      { passive: false },
    );
    this.textLayer.addEventListener("keydown", (e) => {
      const id = (e.target as HTMLElement).dataset.id;
      if (id === undefined) return;
      const dirs: Record<string, Direction> = { ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down" };
      const dir = dirs[e.key];
      if (dir !== undefined) {
        e.preventDefault();
        const to = next(id, dir, this.centers);
        if (to !== null) this.select(to, { focus: true, fly: true });
      } else if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        this.select(id, { details: true });
        this.asideTitle.focus();
      }
    });
    this.textLayer.addEventListener("focusin", (e) => {
      const id = (e.target as HTMLElement).dataset.id;
      if (id !== undefined && id !== this.selected) this.select(id, { fly: true });
    });
  }

  private onKey(e: KeyboardEvent): void {
    const target = e.target as HTMLElement;
    const typing = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target.isContentEditable;
    if (e.key === "Escape") {
      if (!this.aside.hidden) {
        e.preventDefault();
        this.closeDetails(true);
      }
      return;
    }
    if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "/") {
      e.preventDefault();
      this.searchInput.focus();
      this.searchInput.select();
    } else if (e.key === "+" || e.key === "=") {
      e.preventDefault();
      this.zoomBy(1.25);
    } else if (e.key === "-") {
      e.preventDefault();
      this.zoomBy(1 / 1.25);
    } else if (e.key === "0") {
      e.preventDefault();
      this.fitAll(true);
    }
  }

  // MARK: Selection and details

  select(id: string, how: { fly?: boolean; focus?: boolean; details?: boolean } = {}): void {
    if (!this.layout.topics.has(id)) {
      if (this.canvas.layouts.expanded?.topics.has(id) !== true) return;
      this.show(this.canvasIndex, "expanded");
    }
    this.selected = id;
    this.paintSelection();
    const p = this.layout.topics.get(id);
    if (p !== undefined && how.fly === true) {
      const { w, h } = this.size();
      this.camera.fly(reveal(this.camera.view, p.frame, w, h));
    }
    // The outline follows: open the ancestors and mark the row.
    const path = ancestors(this.canvas.outline, id);
    if (path?.some((a) => !this.open.has(a))) {
      for (const a of path) this.open.add(a);
      this.syncTree();
    }
    this.markTree(id);
    if (how.focus === true) this.topicEls.get(id)?.focus({ preventScroll: true });
    if (how.details === true || !this.aside.hidden) this.openDetails(id);
  }

  private paintSelection(): void {
    for (const [id, e] of this.topicEls) {
      const on = id === this.selected;
      e.classList.toggle("is-selected", on);
      e.tabIndex = on ? 0 : -1;
    }
    if (this.selected === null) {
      const first = this.canvas.outline[0]?.id;
      const e = (first === undefined ? undefined : this.topicEls.get(first)) ?? this.topicEls.values().next().value;
      if (e !== undefined) e.tabIndex = 0;
    }
    const p = this.selected === null ? undefined : this.layout.topics.get(this.selected);
    this.ring.hidden = p === undefined;
    if (p !== undefined) place(this.ring, inflate(p.frame, 4));
  }

  private openDetails(id: string): void {
    const topic = this.canvas.topics.get(id);
    if (topic === undefined) return;
    this.asideTitle.textContent = topic.text === "" ? this.t("topic") : topic.text;
    renderDetails(this.asideBody, topic, {
      doc: this.doc,
      t: (k) => this.t(k),
      attachment: (name) => this.attachmentURL(name),
      goTo: (canvasID, topicID) => {
        const i = this.bundle.canvases.findIndex((c) => c.id === canvasID);
        if (i < 0) return;
        this.show(i);
        this.select(topicID, { fly: true, focus: true, details: true });
      },
    });
    this.aside.hidden = false;
    this.aside.dataset.topic = id;
  }

  private closeDetails(refocus: boolean): void {
    if (this.aside.hidden) return;
    this.aside.hidden = true;
    delete this.aside.dataset.topic;
    if (refocus && this.selected !== null) this.topicEls.get(this.selected)?.focus({ preventScroll: true });
  }

  /** Legend and threat table buttons for the current canvas. */
  private buildInfo(): void {
    const c = this.canvas;
    const buttons: HTMLElement[] = [];
    const panel = (title: string, content: () => Node): void => {
      const b = this.doc.createElement("button");
      b.type = "button";
      b.className = "onx-button";
      b.textContent = title;
      b.setAttribute("aria-controls", this.aside.id);
      b.addEventListener("click", () => {
        this.asideTitle.textContent = title;
        this.asideBody.replaceChildren(content());
        this.aside.hidden = false;
        delete this.aside.dataset.topic;
        this.asideTitle.focus();
      });
      buttons.push(b);
    };
    const legend = c.legend;
    if (legend !== undefined) {
      panel(legend.title === "" ? this.t("legend") : legend.title, () => {
        const ul = this.doc.createElement("ul");
        ul.className = "onx-legend";
        for (const r of legend.rows) {
          const li = this.doc.createElement("li");
          li.textContent = r.text;
          ul.append(li);
        }
        return ul;
      });
    }
    const threats = c.threats;
    if (threats !== undefined) {
      panel(this.t("threats"), () => {
        const table = this.doc.createElement("table");
        table.className = "onx-table";
        const head = table.createTHead().insertRow();
        for (const col of threats.columns) {
          const th = this.doc.createElement("th");
          th.scope = "col";
          th.textContent = col;
          head.append(th);
        }
        const tbody = table.createTBody();
        for (const row of threats.rows) {
          const tr = tbody.insertRow();
          for (const cell of row) tr.insertCell().textContent = cell;
        }
        return table;
      });
    }
    this.infoButtons.replaceChildren(...buttons);
  }

  // MARK: Outline

  private buildTree(): void {
    const c = this.canvas;
    this.treeItems.clear();
    this.treeBranches.clear();
    // A flat tree (aria-level, -setsize, -posinset) rather than nested groups, so each
    // item's name is its own row and not the rows below it.
    const lis: HTMLElement[] = [];
    const build = (items: readonly Canvas["outline"][number][], level: number): void => {
      items.forEach((item, i) => {
        const li = this.doc.createElement("li");
        li.setAttribute("role", "treeitem");
        li.setAttribute("aria-level", String(level));
        li.setAttribute("aria-setsize", String(items.length));
        li.setAttribute("aria-posinset", String(i + 1));
        li.setAttribute("aria-selected", "false");
        li.tabIndex = -1;
        li.dataset.id = item.id;
        const row = this.doc.createElement("span");
        row.className = "onx-row";
        const text = c.topics.get(item.id)?.text ?? "";
        row.textContent = text === "" ? this.t("topic") : text;
        row.style.paddingInlineStart = `${String(0.5 + (level - 1) * 1.1)}em`;
        li.append(row);
        lis.push(li);
        this.treeItems.set(item.id, li);
        if (item.children.length > 0) {
          this.treeBranches.add(item.id);
          build(item.children, level + 1);
        }
      });
    };
    build(c.outline, 1);
    this.tree.replaceChildren(...lis);
    this.treeFocus = c.outline[0]?.id ?? null;
    this.syncTree();
    this.tree.onclick = (e): void => {
      const li = (e.target as Element).closest("[role=treeitem]");
      if (!(li instanceof HTMLElement) || li.dataset.id === undefined) return;
      const id = li.dataset.id;
      const r = li.firstElementChild?.getBoundingClientRect();
      // A click on the disclosure triangle opens or closes; anywhere else shows the topic.
      const onTwisty = r !== undefined && li.hasAttribute("aria-expanded") && (e as MouseEvent).clientX < r.left + this.twistyEdge(li);
      if (onTwisty) {
        this.toggle(id);
      } else {
        this.treeFocus = id;
        this.select(id, { fly: true, details: true });
      }
      li.focus();
      this.syncTree();
    };
    this.tree.onkeydown = (e): void => {
      const id = this.treeFocus;
      if (id === null) return;
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        this.select(id, { fly: true, details: true });
        return;
      }
      if (!["ArrowDown", "ArrowUp", "ArrowRight", "ArrowLeft", "Home", "End"].includes(e.key)) return;
      e.preventDefault();
      const rows = visibleRows(this.canvas.outline, this.open);
      const r = treeKey(rows, this.open, id, e.key as TreeKey);
      if (r.toggle !== undefined) this.toggle(r.toggle);
      if (r.focus !== undefined) {
        this.treeFocus = r.focus;
        this.syncTree();
        this.treeItems.get(r.focus)?.focus();
      }
    };
  }

  /** How far into the row the triangle reaches (its padding plus the triangle). */
  private twistyEdge(li: HTMLElement): number {
    const level = Number(li.getAttribute("aria-level") ?? "1");
    return (0.5 + (level - 1) * 1.1 + 1.2) * 13;
  }

  private toggle(id: string): void {
    if (this.open.has(id)) this.open.delete(id);
    else this.open.add(id);
    this.syncTree();
  }

  private syncTree(): void {
    const shown = new Set(visibleRows(this.canvas.outline, this.open).map((r) => r.id));
    for (const [id, li] of this.treeItems) {
      if (this.treeBranches.has(id)) li.setAttribute("aria-expanded", String(this.open.has(id)));
      li.hidden = !shown.has(id);
      li.tabIndex = id === this.treeFocus ? 0 : -1;
    }
  }

  private markTree(id: string): void {
    for (const [tid, li] of this.treeItems) li.setAttribute("aria-selected", String(tid === id));
    const li = this.treeItems.get(id);
    if (li === undefined) return;
    this.treeFocus = id;
    this.syncTree();
    // jsdom (the unit tests) has no scrollIntoView.
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
    li.firstElementChild?.scrollIntoView?.({ block: "nearest" });
  }

  // MARK: Search

  private runSearch(): void {
    this.matches = find(this.bundle, this.canvasIndex, this.searchInput.value, this.options);
    this.matchIndex = -1;
    this.paintCount();
    this.paintHits();
  }

  private step(d: number): void {
    if (this.matches.length === 0) return;
    this.matchIndex = (this.matchIndex + d + this.matches.length) % this.matches.length;
    const m = this.matches[this.matchIndex];
    if (m === undefined) return;
    if (m.canvas !== this.canvasIndex) {
      const keep = this.matchIndex;
      this.show(m.canvas);
      this.matchIndex = keep;
    }
    this.select(m.topic, { fly: true });
    this.paintCount();
    this.paintHits();
  }

  private paintCount(): void {
    const n = this.matches.length;
    this.countEl.dataset.count = String(n);
    if (this.searchInput.value === "") this.countEl.textContent = "";
    else if (n === 0) this.countEl.textContent = this.t("noMatches");
    else this.countEl.textContent = format(this.t("matches"), Math.max(1, this.matchIndex + 1), n);
  }

  private paintHits(): void {
    const current = this.matches[this.matchIndex];
    const seen = new Set<string>();
    const els: HTMLElement[] = [];
    for (const m of this.matches) {
      if (m.canvas !== this.canvasIndex || seen.has(m.topic)) continue;
      seen.add(m.topic);
      const p = this.layout.topics.get(m.topic);
      if (p === undefined) continue;
      const e = this.doc.createElement("div");
      e.className = current?.topic === m.topic && current.canvas === this.canvasIndex ? "onx-hit is-current" : "onx-hit";
      place(e, inflate(p.frame, 3));
      els.push(e);
    }
    this.hits.replaceChildren(...els);
  }

  destroy(): void {
    for (const url of this.urls.values()) if (url?.startsWith("blob:") === true) URL.revokeObjectURL(url);
    for (const f of this.cleanup) f();
    this.host.replaceChildren();
  }
}

/** Shows `bundle` in `host`. */
export function mount(host: HTMLElement, bundle: Bundle, options: MountOptions = {}): ViewerHandle {
  const v = new Viewer(host, bundle, options);
  return {
    element: v.root,
    show: (canvas, layout) => { v.show(canvas, layout); },
    select: (topic) => { v.select(topic, { fly: true, details: true }); },
    destroy: () => { v.destroy(); },
  };
}
