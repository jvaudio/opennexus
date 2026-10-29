// Pan and zoom: the stage (drawing plus text layer) sits in world coordinates and one CSS
// transform maps it to the viewport. Fly-to animates unless the reader asks for reduced
// motion.

import type { Rect } from "./bundle";

export interface View {
  x: number;
  y: number;
  k: number;
}

export const minZoom = 0.05;
export const maxZoom = 8;

export function clampZoom(k: number): number {
  return Math.min(maxZoom, Math.max(minZoom, k));
}

/** The view that fits `r` into a `width` × `height` viewport with `pad` around it (never above 1×, as the app's Fit). */
export function fit(r: Rect, width: number, height: number, pad = 24, maxK = 1): View {
  const k = clampZoom(Math.min(maxK, (width - 2 * pad) / Math.max(1, r[2]), (height - 2 * pad) / Math.max(1, r[3])));
  return { k, x: (width - r[2] * k) / 2 - r[0] * k, y: (height - r[3] * k) / 2 - r[1] * k };
}

/** Zooms by `factor` keeping the viewport point (px, py) still. */
export function zoomAt(v: View, factor: number, px: number, py: number): View {
  const k = clampZoom(v.k * factor);
  const f = k / v.k;
  return { k, x: px - (px - v.x) * f, y: py - (py - v.y) * f };
}

/** The view that centres `r` without changing zoom, unless it doesn't fit. */
export function reveal(v: View, r: Rect, width: number, height: number, pad = 48): View {
  const k = Math.min(v.k, fit(r, width, height, pad, v.k).k);
  return { k, x: width / 2 - (r[0] + r[2] / 2) * k, y: height / 2 - (r[1] + r[3] / 2) * k };
}

export class Camera {
  view: View = { x: 0, y: 0, k: 1 };
  private frame = 0;

  constructor(
    private readonly stage: HTMLElement,
    private readonly reducedMotion: () => boolean,
    private readonly onChange: (v: View) => void = () => undefined,
  ) {}

  set(v: View): void {
    cancelAnimationFrame(this.frame);
    this.apply(v);
  }

  /** Moves to `v`, animated over 280 ms (or at once with reduced motion). */
  fly(v: View): void {
    cancelAnimationFrame(this.frame);
    if (this.reducedMotion()) {
      this.apply(v);
      return;
    }
    const from = this.view;
    const start = performance.now();
    const step = (now: number): void => {
      const t = Math.min(1, (now - start) / 280);
      const e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
      // Interpolate zoom geometrically so the motion feels even.
      const k = from.k * (v.k / from.k) ** e;
      this.apply({ k, x: from.x + (v.x - from.x) * e, y: from.y + (v.y - from.y) * e });
      if (t < 1) this.frame = requestAnimationFrame(step);
    };
    this.frame = requestAnimationFrame(step);
  }

  private apply(v: View): void {
    this.view = v;
    this.stage.style.transform = `translate(${String(v.x)}px, ${String(v.y)}px) scale(${String(v.k)})`;
    this.onChange(v);
  }
}
