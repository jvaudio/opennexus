# 01 · Brand: Aperture

- Source: `design/source/Brand.dc.html` (shows `brand/reference/brand-board.png`)
- Screenshot: `screenshots/02-Brand.png`
- Artboard size: 1440×1100 pt

> The brand kit in `brand/` replaces this artboard's earlier logo directions. `brand/BRAND.md`
> is the numeric spec (geometry, optical sizes, colours, lockups, surfaces, don'ts) and
> `brand/reference/brand-board.png` the visual one. Take values from BRAND.md, not from the
> screenshot.

The board's sections, top to bottom:

- **Aperture: a node left open.** A ring with an opening on the right, and two branches
  leaving through the gap. The three colours are the canvas states: Iris for Select and Edit,
  Amber for Connect, Aurora for on-device AI.
- **Primary lockup**, light and dark: the mark, then "Open" (Geist 500) and "Nexus" (Geist
  700). In the app the lockup is the `BrandLockup` asset, never live text.
- **Clear space and minimum size:** clear space is the ring radius (14 of 64 units) on every
  side. Minimum: mark 16 px, horizontal lockup 96 px wide. Below 32 px use the optical size.
- **Geometry on a 64-unit grid:** BRAND.md §1. The gap always faces right.
- **App icon, macOS 27 appearances:** Default (Iris), Dark (graphite), Tinted and Clear, from
  the Icon Composer layers: background, ring, branches, root node.
- **Colour, every element and context:** BRAND.md §2.
- **Small and system sizes:** the menu bar template, Finder at 16, favicon at 32, and the
  `.nexus` document icon.
- **Don'ts:** BRAND.md §6.
