// The camera's path between two views when presenting (M47d), as the app flies (M42):
// van Wijk and Nuij's "Smooth and efficient zooming and panning" (2003), which zooms out
// as far as the distance needs and back in, over the app's 0.7 seconds.

import type { View } from "./camera";

/** How much the path zooms out on the way (the paper's ρ; √2 is its recommendation). */
const RHO = Math.SQRT2;

/** How long a flight takes, as in the app (`Motion.fly`). */
export const FLY_MS = 700;

export interface Flight {
  /** The view at `t` in [0, 1]. */
  at: (t: number) => View;
  /** How long the flight takes, in milliseconds. */
  duration: number;
}

/** The flight from `a` to `b` in a `width` × `height` viewport. */
export function flight(a: View, b: View, width: number, height: number): Flight {
  // In world terms: the centre and the width seen.
  const x0 = (width / 2 - a.x) / a.k;
  const y0 = (height / 2 - a.y) / a.k;
  const w0 = width / a.k;
  const x1 = (width / 2 - b.x) / b.k;
  const y1 = (height / 2 - b.y) / b.k;
  const w1 = width / b.k;
  const dx = x1 - x0;
  const dy = y1 - y0;
  const d2 = dx * dx + dy * dy;
  const view = (x: number, y: number, w: number): View => {
    const k = width / w;
    return { k, x: width / 2 - x * k, y: height / 2 - y * k };
  };
  let at: (t: number) => View;
  if (d2 < 1e-12) {
    // Only zooming.
    at = (t) => view(x0, y0, w0 * Math.exp(Math.log(w1 / w0) * t));
  } else {
    const d1 = Math.sqrt(d2);
    const b0 = (w1 * w1 - w0 * w0 + RHO ** 4 * d2) / (2 * w0 * RHO * RHO * d1);
    const b1 = (w1 * w1 - w0 * w0 - RHO ** 4 * d2) / (2 * w1 * RHO * RHO * d1);
    const r0 = Math.log(Math.sqrt(b0 * b0 + 1) - b0);
    const r1 = Math.log(Math.sqrt(b1 * b1 + 1) - b1);
    const s = (r1 - r0) / RHO;
    at = (t) => {
      if (t >= 1) return b;
      const u = s * t;
      const c = Math.cosh(r0);
      const q = (w0 / (RHO * RHO * d1)) * (c * Math.tanh(RHO * u + r0) - Math.sinh(r0));
      return view(x0 + q * dx, y0 + q * dy, (w0 * c) / Math.cosh(RHO * u + r0));
    };
  }
  return { at: (t) => (t >= 1 ? b : t <= 0 ? a : at(t)), duration: FLY_MS };
}
