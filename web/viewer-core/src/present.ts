// Present (M47d): the canvas's deck as the app plays it, in the browser. The map fills the
// window; each slide frames its focus topics from the index, at the deck's aspect, and dims
// the rest; the camera cuts, glides or flies between slides as the deck says.

import type { Deck, Layout, Rect, Slide } from "./bundle";
import { fit, type Camera, type View } from "./camera";
import { flight } from "./flight";
import { format } from "./format";

/** Room the caption takes at the foot of the window. */
export const CAPTION = 96;

/** What the presentation needs from the viewer. */
export interface PresentHost {
  readonly root: HTMLElement;
  readonly viewport: HTMLElement;
  readonly stage: HTMLElement;
  readonly camera: Camera;
  layout: () => Layout;
  t: (key: string) => string;
  /** Where focus goes afterwards when it was nowhere in particular (Safari doesn't focus a clicked button). */
  readonly opener?: HTMLElement;
  /** Called once the presentation has ended, however it ended. */
  ended: () => void;
}

export function union(rects: Rect[]): Rect | undefined {
  if (rects.length === 0) return undefined;
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (const r of rects) {
    x0 = Math.min(x0, r[0]);
    y0 = Math.min(y0, r[1]);
    x1 = Math.max(x1, r[0] + r[2]);
    y1 = Math.max(y1, r[1] + r[3]);
  }
  return [x0, y0, x1 - x0, y1 - y0];
}

/** Where the slide's focus is, in the layout's coordinates (the whole drawing when none is placed). */
export function focusRect(layout: Layout, slide: Slide): Rect {
  const frames = slide.focus.flatMap((id) => {
    const p = layout.topics.get(id);
    return p === undefined ? [] : [p.frame];
  });
  return union(frames) ?? layout.viewBox;
}

/** The view that frames `slide` in a `width` × `height` window: the deck's aspect, centred, above the caption. */
export function slideView(layout: Layout, slide: Slide, aspect: number, width: number, height: number): View {
  const room = Math.max(1, height - CAPTION);
  let w = width;
  let h = width / aspect;
  if (h > room) {
    h = room;
    w = room * aspect;
  }
  const v = fit(focusRect(layout, slide), w, h, Math.max(16, 0.06 * Math.min(w, h)), 2);
  return { k: v.k, x: v.x + (width - w) / 2, y: v.y + (room - h) / 2 };
}

const SVG = "http://www.w3.org/2000/svg";

/** How far the clear area reaches beyond a focus topic's frame, in the map's units. */
const MARGIN = 6;

export class Presentation {
  private index = -1;
  private ending = false;
  private readonly dim: SVGSVGElement;
  private readonly holes: SVGGElement;
  private holeFrames: Rect[] = [];
  private readonly rings: HTMLElement;
  private readonly caption: HTMLElement;
  private readonly kicker: HTMLElement;
  private readonly title: HTMLElement;
  private readonly count: HTMLElement;
  private readonly note: HTMLElement;
  private readonly live: HTMLElement;
  private readonly prev: HTMLButtonElement;
  private readonly next: HTMLButtonElement;
  private readonly exit: HTMLButtonElement;
  private readonly cleanup: (() => void)[] = [];
  private readonly returnFocus: Element | null;

  constructor(
    private readonly host: PresentHost,
    private readonly deck: Deck,
  ) {
    const doc = host.root.ownerDocument;
    this.returnFocus = doc.activeElement !== null && doc.activeElement !== doc.body ? doc.activeElement : (host.opener ?? null);
    const make = <K extends keyof HTMLElementTagNameMap>(tag: K, cls: string, text?: string): HTMLElementTagNameMap[K] => {
      const e = doc.createElement(tag);
      e.className = cls;
      if (text !== undefined) e.textContent = text;
      return e;
    };
    const button = (label: string, text: string): HTMLButtonElement => {
      const b = make("button", "onx-button", text);
      b.type = "button";
      b.title = label;
      if (label !== text) b.setAttribute("aria-label", label);
      return b;
    };

    // The dimming covers the window, with a clear hole per focus topic; it follows the camera.
    this.dim = doc.createElementNS(SVG, "svg");
    this.dim.setAttribute("class", "onx-dim");
    this.dim.setAttribute("aria-hidden", "true");
    const mask = doc.createElementNS(SVG, "mask");
    mask.id = `${host.viewport.id}-dim`;
    const all = doc.createElementNS(SVG, "rect");
    this.holes = doc.createElementNS(SVG, "g");
    const shade = doc.createElementNS(SVG, "rect");
    shade.setAttribute("class", "onx-dim-shade");
    shade.setAttribute("mask", `url(#${mask.id})`);
    for (const r of [all, shade]) {
      r.setAttribute("width", "100%");
      r.setAttribute("height", "100%");
    }
    all.setAttribute("fill", "white");
    mask.append(all, this.holes);
    this.dim.append(mask, shade);
    host.stage.after(this.dim);
    // Highlight rings sit on the map, under the text layer, so topics stay readable.
    this.rings = make("div", "onx-steps");
    this.rings.setAttribute("aria-hidden", "true");
    host.stage.insertBefore(this.rings, host.stage.querySelector(".onx-text"));

    // The caption: where we are, and the way on.
    this.caption = make("section", "onx-caption");
    this.caption.setAttribute("aria-label", host.t("present"));
    const words = make("div", "onx-caption-words");
    this.kicker = make("p", "onx-kicker");
    this.title = make("h2", "onx-slide-title");
    this.note = make("p", "onx-slide-note");
    this.note.hidden = true;
    words.append(this.kicker, this.title, this.note);
    const controls = make("div", "onx-caption-controls");
    this.prev = button(host.t("previousSlide"), "‹");
    this.next = button(host.t("nextSlide"), "›");
    this.count = make("span", "onx-slide-count");
    this.exit = button(host.t("endPresentation"), host.t("endPresentation"));
    this.prev.addEventListener("click", () => { this.go(this.index - 1); });
    this.next.addEventListener("click", () => { this.go(this.index + 1); });
    this.exit.addEventListener("click", () => { this.end(); });
    controls.append(this.prev, this.count, this.next, this.exit);
    this.live = make("p", "onx-sr");
    this.live.setAttribute("role", "status");
    this.caption.append(words, controls, this.live);
    host.viewport.append(this.caption);

    host.root.classList.add("onx-presenting");
    const listen = <K extends keyof DocumentEventMap>(target: Document | Window, type: K, f: (e: DocumentEventMap[K]) => void): void => {
      target.addEventListener(type, f as EventListener);
      this.cleanup.push(() => { target.removeEventListener(type, f as EventListener); });
    };
    // On the document, so the keys work wherever focus is while the map fills the window.
    listen(doc, "keydown", (e) => { this.key(e); });
    listen(window, "resize", () => { this.place(false); });
    if (doc.fullscreenEnabled && typeof host.root.requestFullscreen === "function") {
      // Leaving full screen (the browser's own Esc) leaves the presentation too, once it
      // was entered: after a quick Esc then P, the last one's exit mustn't end this one.
      let entered = false;
      listen(doc, "fullscreenchange", () => {
        if (doc.fullscreenElement === host.root) entered = true;
        else if (entered && doc.fullscreenElement === null) this.end();
      });
      host.root.requestFullscreen().catch(() => undefined);
    }
    this.go(0, false);
    this.next.focus({ preventScroll: true });
  }

  /** The slide showing, from 0. */
  get slide(): number {
    return this.index;
  }

  private size(): { w: number; h: number } {
    return { w: this.host.viewport.clientWidth || 800, h: this.host.viewport.clientHeight || 600 };
  }

  /** Shows slide `i` (clamped), moving the camera as the deck says. */
  go(i: number, animate = true): void {
    const n = Math.max(0, Math.min(this.deck.slides.length - 1, i));
    const slide = this.deck.slides[n];
    if (slide === undefined || n === this.index) return;
    this.index = n;
    this.host.root.dataset.onxSlide = String(n);
    this.paint(slide);
    this.place(animate);
  }

  private place(animate: boolean): void {
    const slide = this.deck.slides[this.index];
    if (slide === undefined) return;
    const { w, h } = this.size();
    const to = slideView(this.host.layout(), slide, this.deck.aspect, w, h);
    const cam = this.host.camera;
    if (!animate || this.deck.move === "cut") {
      cam.set(to);
    } else if (this.deck.move === "glide") {
      cam.fly(to);
    } else {
      const f = flight(cam.view, to, w, h);
      cam.follow(f.at, f.duration);
    }
  }

  /** Keeps the dimming's holes on their topics as the camera moves. */
  moved(v: View): void {
    Array.from(this.holes.children).forEach((r, i) => {
      const f = this.holeFrames[i];
      if (f === undefined) return;
      r.setAttribute("x", String(v.x + (f[0] - MARGIN) * v.k));
      r.setAttribute("y", String(v.y + (f[1] - MARGIN) * v.k));
      r.setAttribute("width", String((f[2] + 2 * MARGIN) * v.k));
      r.setAttribute("height", String((f[3] + 2 * MARGIN) * v.k));
      r.setAttribute("rx", String(10 * v.k));
    });
  }

  private paint(slide: Slide): void {
    const layout = this.host.layout();
    const doc = this.host.root.ownerDocument;
    this.holeFrames = slide.focus.flatMap((id) => {
      const p = layout.topics.get(id);
      return p === undefined ? [] : [p.frame];
    });
    this.holes.replaceChildren(
      ...this.holeFrames.map(() => {
        const r = doc.createElementNS(SVG, "rect");
        r.setAttribute("fill", "black");
        return r;
      }),
    );
    this.moved(this.host.camera.view);
    // A slide of the whole map dims nothing.
    this.dim.style.display = this.holeFrames.length === 0 ? "none" : "";
    this.rings.replaceChildren(
      ...slide.highlight.flatMap((id) => {
        const p = layout.topics.get(id);
        if (p === undefined) return [];
        const ring = doc.createElement("div");
        ring.className = "onx-step";
        const [x, y, w, h] = p.frame;
        ring.style.left = `${String(x - 5)}px`;
        ring.style.top = `${String(y - 5)}px`;
        ring.style.width = `${String(w + 10)}px`;
        ring.style.height = `${String(h + 10)}px`;
        return [ring];
      }),
    );
    const total = this.deck.slides.length;
    const count = format(this.host.t("slideCount"), this.index + 1, total);
    this.kicker.textContent = slide.kicker;
    this.kicker.hidden = slide.kicker === "";
    this.title.textContent = slide.title;
    this.count.textContent = count;
    this.note.textContent = slide.note ?? "";
    if (slide.note === undefined) this.note.hidden = true;
    // A button that goes dim mustn't take the keyboard's place with it.
    const focused = doc.activeElement;
    this.prev.disabled = this.index === 0;
    this.next.disabled = this.index === total - 1;
    if ((focused === this.prev || focused === this.next) && (focused as HTMLButtonElement).disabled) {
      (this.next.disabled ? this.prev.disabled ? this.exit : this.prev : this.next).focus();
    }
    this.live.textContent = `${slide.title}, ${count}`;
  }

  /** Present's keys; true when the key was one of them. */
  key(e: KeyboardEvent): boolean {
    if (this.ending || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return false;
    // Space and Return on a button press the button.
    if ((e.key === " " || e.key === "Enter") && e.target instanceof HTMLButtonElement) return false;
    switch (e.key) {
      case "ArrowRight":
      case "ArrowDown":
      case "PageDown":
      case " ":
      case "Enter":
        this.go(this.index + 1);
        break;
      case "ArrowLeft":
      case "ArrowUp":
      case "PageUp":
      case "Backspace":
        this.go(this.index - 1);
        break;
      case "Home":
        this.go(0);
        break;
      case "End":
        this.go(this.deck.slides.length - 1);
        break;
      case "n":
      case "N":
        if (this.deck.slides[this.index]?.note !== undefined) this.note.hidden = !this.note.hidden;
        break;
      case "Escape":
        this.end();
        break;
      default:
        return false;
    }
    e.preventDefault();
    return true;
  }

  end(): void {
    if (this.ending) return;
    this.ending = true;
    for (const f of this.cleanup) f();
    const doc = this.host.root.ownerDocument;
    if (doc.fullscreenElement === this.host.root) void doc.exitFullscreen().catch(() => undefined);
    this.dim.remove();
    this.rings.remove();
    this.caption.remove();
    this.host.root.classList.remove("onx-presenting");
    delete this.host.root.dataset.onxSlide;
    this.host.ended();
    if (this.returnFocus instanceof HTMLElement && this.returnFocus.isConnected) this.returnFocus.focus({ preventScroll: true });
  }
}
