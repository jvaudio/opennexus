// One map drawn in Obsidian (M49): a view's, an embed's or a note's. It draws what the
// readers opened: the viewer copy with viewer-core, else the outline, or why it can't.

import { BundleError, parseBundle, type Bundle, type Canvas } from "../../viewer-core/src/bundle";
import { mount, type HostLinks, type MountOptions, type View, type ViewerAction, type ViewerHandle } from "../../viewer-core/src/viewer";
import { baseName, type Opened } from "../../viewer-app/src/document";
import { canvasOutlines } from "./outline";
import type { LayoutName } from "./settings";

export interface PanelOptions {
  chrome: "full" | "none";
  layout: LayoutName;
  followTheme: boolean;
  hostLinks?: HostLinks;
  actions?: ViewerAction[];
  onSelect?: (canvas: string, topic: string | null) => void;
  /** Whether `nexus` could have drawn it (so the outline says how else to see the map). */
  canDraw?: boolean;
}

/** Where to look: a canvas and a topic, each by id or title (a topic also as "A > B"). */
export interface Place {
  canvas?: string;
  topic?: string;
}

function same(a: string, b: string): boolean {
  return a.localeCompare(b, undefined, { sensitivity: "accent" }) === 0;
}

/** The canvas `ref` names (its id or title), or the first. */
export function findCanvas(b: Bundle, ref?: string): number {
  if (ref === undefined) return 0;
  const i = b.canvases.findIndex((c) => c.id === ref);
  return i >= 0 ? i : b.canvases.findIndex((c) => same(c.title, ref));
}

/** The topic `ref` names on `c`: its id, its title, or a path of titles ("Plan > Pricing"). */
export function findTopic(c: Canvas, ref: string): string | undefined {
  if (c.topics.has(ref)) return ref;
  const text = (id: string): string => c.topics.get(id)?.text ?? "";
  const parts = ref.split(">").map((p) => p.trim()).filter((p) => p !== "");
  if (parts.length > 1) {
    let level = c.outline;
    let found: string | undefined;
    for (const p of parts) {
      const next = level.find((o) => same(text(o.id), p));
      if (next === undefined) return undefined;
      found = next.id;
      level = next.children;
    }
    return found;
  }
  const walk = (items: Canvas["outline"]): string | undefined => {
    for (const o of items) {
      if (same(text(o.id), ref)) return o.id;
      const deeper = walk(o.children);
      if (deeper !== undefined) return deeper;
    }
    return undefined;
  };
  return walk(c.outline);
}

export class MapPanel {
  handle: ViewerHandle | undefined;
  bundle: Bundle | undefined;
  /** The canvas shown, by index. */
  canvas = 0;
  private release: (() => void) | undefined;

  constructor(readonly el: HTMLElement) {
    el.classList.add("opennexus-map");
  }

  /** Draws `opened`; `keep` puts the camera and canvas back after a redraw. */
  show(opened: Opened, o: PanelOptions, keep?: { view: View; canvas: number }): void {
    this.clear();
    this.el.classList.toggle("onx-obsidian", o.followTheme);
    const name = baseName(opened.name);
    switch (opened.kind) {
      case "bundle": {
        let b: Bundle;
        try {
          b = parseBundle(opened.text);
        } catch (e) {
          opened.close();
          const why = e instanceof BundleError && e.message.includes("version") ? "It was saved by a newer version of OpenNexus." : "Its viewer copy is damaged.";
          this.message(`Can’t show “${name}”`, `${why} Open it in OpenNexus and save it again.`);
          return;
        }
        this.bundle = b;
        this.release = opened.close;
        const options: MountOptions = {
          chrome: o.chrome,
          asset: (n) => opened.asset(n, b.assets.get(n)?.type),
          onSelect: (canvas, topic) => {
            this.canvas = Math.max(0, b.canvases.findIndex((c) => c.id === canvas));
            o.onSelect?.(canvas, topic);
          },
        };
        if (o.actions !== undefined) options.actions = o.actions;
        if (o.hostLinks !== undefined) options.hostLinks = o.hostLinks;
        this.handle = mount(this.el, b, options);
        const canvas = keep !== undefined && keep.canvas < b.canvases.length ? keep.canvas : 0;
        if (o.layout === "expanded" || canvas !== 0) this.handle.show(canvas, o.layout);
        if (keep !== undefined) this.handle.setView(keep.view);
        return;
      }
      case "outline": {
        const how = opened.json
          ? "To see the map, turn on Settings › Files & Backup › Save a viewer copy and Also in single-file documents in OpenNexus, then save the document again."
          : "To see the map, turn on Settings › Files & Backup › Save a viewer copy in OpenNexus, then save the document again.";
        const box = this.message(
          opened.title === "" ? name : opened.title,
          "This map has no viewer copy, so this is its outline: every canvas’s topics and notes.",
          o.canDraw === true ? `${how} Or install OpenNexus on this Mac.` : how,
        );
        box.classList.add("opennexus-outline");
        box.append(...canvasOutlines(this.el.ownerDocument, opened.canvases));
        return;
      }
      case "encrypted": {
        const box = this.message(`“${name}” is encrypted`, "An encrypted map opens only in OpenNexus, with its password.");
        if (opened.hint !== undefined) box.append(this.p(`Password hint: ${opened.hint}`));
        return;
      }
      case "refused":
        this.message(`Can’t show “${name}”`, opened.reason);
        return;
    }
  }

  /** Shows a canvas and a topic: selected (with details), or framed with its branch. */
  goTo(place: Place, how: "select" | "focus"): boolean {
    const b = this.bundle;
    const h = this.handle;
    if (b === undefined || h === undefined) return false;
    const i = findCanvas(b, place.canvas);
    const c = b.canvases[i];
    if (c === undefined) return false;
    if (i !== this.canvas) h.show(i);
    if (place.topic === undefined) return true;
    const id = findTopic(c, place.topic);
    if (id === undefined) return false;
    if (how === "select") h.select(id);
    else h.focus(id);
    return true;
  }

  /** Where the camera is, to `keep` it across a redraw. */
  keep(): { view: View; canvas: number } | undefined {
    return this.handle === undefined ? undefined : { view: this.handle.view(), canvas: this.canvas };
  }

  clear(): void {
    this.handle?.destroy();
    this.handle = undefined;
    this.bundle = undefined;
    this.canvas = 0;
    this.release?.();
    this.release = undefined;
    this.el.replaceChildren();
  }

  private p(text: string): HTMLElement {
    const p = this.el.ownerDocument.createElement("p");
    p.textContent = text;
    return p;
  }

  private message(title: string, ...lines: string[]): HTMLElement {
    const box = this.el.ownerDocument.createElement("div");
    box.className = "opennexus-message";
    const h = this.el.ownerDocument.createElement("h3");
    h.textContent = title;
    box.append(h, ...lines.map((l) => this.p(l)));
    this.el.replaceChildren(box);
    return box;
  }
}
