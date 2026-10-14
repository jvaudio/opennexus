# 04 · Motion spec

- Source: `design/source/Motion.dc.html`
- Screenshot: `screenshots/05-Motion.png`
- Artboard size: 1440×1100 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
04 · MOTION
Springy, physical, never in front of the caret
Rule 1 · text input is live at 0 ms; layout animates after
Rule 2 · new input retargets in-flight springs, never queues
Reduce Motion · 150 ms cross-fade
snap
spring 0.28 / 0.80
Create, delete, chips
settle
spring 0.36 / 0.68
Reorder, reparent lift
glide
cubic(.65,0,.35,1)
Camera, morphs, convert
exit
cubic(.4,0,1,1)
Dismiss, shrink away
MOMENT
ANIMATION
DURATION
CURVE
REDUCE MOTION
LIVE
Create node
Grows from the parent’s connector while the branch line draws to it; siblings ease aside
180 ms
snap
Appears in place, 150 ms fade
Delete node
Shrinks into its parent; neighbours close the gap
160 ms
exit → snap
Fade out, gap closes instantly
Reorder / reparent
Lifts with shadow, travels a short arc, settles with slight overshoot
250 ms
settle
Cross-fade old → new slot
Fold / unfold
Children collapse into the fold badge, which pulses once with the count
220 ms
glide
Children fade; badge appears
Auto-layout reflow
All moved nodes spring to new positions together
300 ms
snap
Single cross-fade of the map
Structure change
Nodes morph shape and fly to new positions; lines redraw
450–600 ms
glide
Cross-fade layouts
Diagram conversion
As above, then node-type badges fade in on arrival
600 ms
glide
Cross-fade, badges static
Connect mode
Hint chips pop nearest-first in a 40 ms stagger; chosen edge draws source → target
300 ms
snap · glide
Chips appear at once; edge fades in
Focus / drill-down
Camera flies to the branch; the rest blurs 8 px and dims to 30%
400 ms
glide
Cut with 150 ms fade
Presentation step
Camera glides between branches; content builds in sequence
500 ms
glide
Cut transitions
AI suggestions
Ghosts shimmer in at 50% opacity, staggered; accept solidifies
250 ms each
snap
Static 50% ghosts, no shimmer
Rule broken
Gentle horizontal shake of the offending node plus a badge
200 ms
linear, 3 cycles
Badge only, no shake
Glow trail · new edges leave a 300 ms soft glow in the branch colour.
Depth parallax · below 40% zoom, deep levels drift 2–4% slower than the root.
Done sparkle · last to-do in a branch checked: 6 particles, 500 ms, once.
Flow dots · Present mode only: dots travel DFD edges at 120 px/s.
```
