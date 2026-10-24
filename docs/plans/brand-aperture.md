# Brand: adopt Aperture everywhere

The logo is **Aperture** (chosen 2026-10-24): a ring left open on the right, with two
branches leaving through the gap. `brand/BRAND.md` is the numeric spec and
`brand/reference/brand-board.png` the visual one. The kit is `brand/`, copied unchanged
from `OpenNexus-Brand-Aperture.zip`; its `CLAUDE_CODE_PROMPT.md` is the brief this plan
follows.

## Step 0 · Inventory (before any change)

What presents an icon or logo today, found by searching for asset catalogs, icon build
settings, document types, status items and drawn marks. The old mark is the "Triad": a
triangle of three nodes, drawn in code or as inline SVG (`M12 32 L22 12 L32 32`, and an
older `M14 30 L22 14 L30 30`).

| # | Surface | Today | Where |
| --- | --- | --- | --- |
| 1 | App icon | **Empty**: `AppIcon.appiconset` has only `Contents.json`, so the app shows the generic icon | `App/OpenNexus/Assets.xcassets`; `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` (`make_project.py`) |
| 2 | Icon Composer `.icon` | None | — |
| 3 | `.nexus` and `.nexusjson` document icons | None: neither `CFBundleDocumentTypes` entry nor the exported `UTExportedTypeDeclarations` names an icon | `App/Support/Info.plist` |
| 4 | Stray `.icns` | None | — |
| 5 | Welcome sheet | `AppMark(size: 84)`: Triad on a graphite tile, drawn in code | `Sources/NexusCanvas/OnboardingViews.swift` |
| 6 | Settings › General › About card | `AppMark(size: 54)` | `Sources/NexusCanvas/SettingsCards.swift` (`AppMark`, `AboutCard`) |
| 7 | Quick Capture panel glyph | `AppMarkGlyph`: an 18 pt Triad | `Sources/NexusCanvas/QuickCaptureView.swift` |
| 8 | Menu bar extra (Quick Capture) | SF Symbol `triangle` | `App/OpenNexus/QuickCapture.swift` |
| 9 | Standard About panel | `orderFrontStandardAboutPanel`: shows the (empty) app icon | `App/OpenNexus/AppDelegate.swift` |
| 10 | Home window | No mark; the sidebar lists sections | `Sources/NexusCanvas/HomeView.swift` |
| 11 | Tutorial / keycap coach | No mark | `Sources/NexusCanvas/TourViews.swift` |
| 12 | App Intents / Shortcuts | No custom images; they take the app icon | `App/OpenNexus/Intents.swift` |
| 13 | Widgets | No mark; headers are text, as in artboard 33 | `Sources/NexusWidgetsUI`, `App/Extensions/Widgets` |
| 14 | Quick Look thumbnail and preview | Draw document content; a lock symbol for encrypted files | `App/Extensions/QuickLook*` |
| 15 | Share extension, Services, Spotlight | No mark; the system shows the app or document icon | `App/Extensions/Share`, `SpotlightImporter` |
| 16 | Help Book | None | — |
| 17 | README | No logo | `README.md` |
| 18 | Docs site, favicons | None (no docs site) | — |
| 19 | DMG | No background image; `release.sh` makes a plain DMG | `App/tools/release.sh` |
| 20 | Design handoff sources | Old mark in `Brand`, `Main`, `Welcome`, `SetGeneral`, `Integration` (`Handoff/design/source/*.dc.html`); "Triad" in `Handoff/docs/screen-specs/02-Brand.md` | `Handoff/` |
| 21 | Design handoff screenshots | Old mark in `01-Main`, `02-Brand`, `14-Welcome`, `33-Integration`, `35-SetGeneral` | `Handoff/screenshots/` |
| 22 | CI | No brand check | `.github/workflows/ci.yml` |

## Where the brief's paths land in this repo

| Brief | Here |
| --- | --- |
| `scripts/build-icons.sh`, `scripts/lint.sh` | `scripts/` (new) |
| `OpenNexusApp/Brand/` or `NexusTheme` for `ApertureMark` | `Sources/NexusCanvas/Brand/`. `NexusTheme` is the Foundation-only token layer (no SwiftUI), so `BrandColor` goes there and the SwiftUI views go in the UI package. |
| `design/source/`, `screenshots/` | `Handoff/design/source/`, `Handoff/screenshots/` |
| A shared catalog for extensions | Not needed: no extension shows the mark (rows 13–15). `ApertureMark` is code in a package any target can link. |

## Checklist

Filled in as each step lands; see Results.
