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

Every row of the inventory, with what changed and how it was checked. Screenshots are in
[`brand-aperture/`](brand-aperture), taken from a build of this branch (0.2, build 9000).

| # | Surface | Now | Checked |
| --- | --- | --- | --- |
| 1 | App icon | [x] Kit `AppIcon.appiconset`, all ten sizes; `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` | The catalog's image is pixel-identical to the kit at 1024, 512, 256, 128, 64, 32 and 16 px. `actool` writes `CFBundleIconFile` and `CFBundleIconName`. The system's icon for the app: [app-icon.png](brand-aperture/app-icon.png) |
| 2 | Icon Composer `.icon` | [ ] Human step, below | The format isn't documented for tools; until it exists the catalog icon is used |
| 3 | `.nexus` and `.nexusjson` document icons | [x] `NexusDocument.icns` from `brand/macos` (`scripts/build-icons.sh`); `UTTypeIconFile` and `CFBundleTypeIconFile` on both types | [document-icons.png](brand-aperture/document-icons.png): the system's icon for each type at icon-view and list-view sizes. Results has details on this Mac's icon cache |
| 4 | Stray `.icns` | [x] None | — |
| 5 | Welcome sheet | [x] `AppIconTile(size: 84)`, the running app's icon | [welcome.png](brand-aperture/welcome.png), matches `brand/reference/in-context/Welcome.png` |
| 6 | Settings › General › About | [x] `AppIconTile(size: 52)` beside "OpenNexus 0.2" | [settings-about.png](brand-aperture/settings-about.png) |
| 7 | Quick Capture glyph | [x] `ApertureMark(opticalSize: .boost(1.5), decorative: true)` at 20 pt | [quick-capture.png](brand-aperture/quick-capture.png) |
| 8 | Menu bar extra | [x] `MenuBarIcon` template, 18 pt, described "OpenNexus" | [menubar.png](brand-aperture/menubar.png): the compiled template tinted as a status item draws it. Showing the live item means turning on Start at login, which registers a login item |
| 9 | Standard About panel | [x] Shows the app icon (row 1) | — |
| 10 | Home window | [x] `BrandLockup(height: 30)` at the top of the sidebar | [home.png](brand-aperture/home.png) |
| 11 | Tutorial and keycap coach | [x] No mark; none added | — |
| 12 | App Intents and Shortcuts | [x] No custom images; the five App Shortcuts use SF Symbols for what they do, and Shortcuts shows the app icon | `Intents.swift` references only `systemImageName` symbols |
| 13 | Widgets | [x] No mark in the design; headers stay text | — |
| 14 | Quick Look | [x] Still draws content; the document icon is the fallback | Unchanged code |
| 15 | Share, Services, Spotlight | [x] System app and document icons | — |
| 16 | Help Book | [x] None | — |
| 17 | README | [x] `<picture>` header with the kit's light and dark lockups, alt "OpenNexus" | — |
| 18 | Docs site, favicons | [x] None; `brand/web/` is ready for one | — |
| 19 | DMG background | [x] None; `release.sh` makes a plain DMG, so nothing to replace | — |
| 20 | Handoff sources | [x] `Main`, `Welcome`, `SetGeneral`, `Integration` use the kit's SVGs; `Brand` shows the kit's board; `02-Brand.md` rewritten | Replaced by script from `brand/` files, not redrawn |
| 21 | Handoff screenshots | [x] `01-Main`, `02-Brand`, `14-Welcome`, `33-Integration`, `35-SetGeneral` are the kit's renders | Same sizes as before, except `02-Brand` (now 1440 × 1100) |
| 22 | CI | [x] The lint step runs `scripts/lint.sh`: Swift format, no old mark, `.icns` up to date | A probe file containing the old path fails it; without it, it passes |

## Results

- **Builds:** a clean build of all eight targets succeeds with no asset-catalog warnings. The
  Swift warnings it shows (actor isolation in `CanvasAccessibility`, `Text +` deprecations)
  were there before and aren't on lines this work touched.
- **Tests:** `swift test` runs 633 tests across the package's test targets. All pass, with one
  exception below. `ApertureMarkTests` (7) compares the mark with the kit at 1024, 64, 32 and 16 px in
  each palette, and checks that the tolerance still catches a mirrored mark, the wrong
  optical size and the wrong palette. `panAndZoom5000NodesAt120fps` missed its budget once
  while a clean Xcode build was loading the CPU; on its own it passes (zoom median 4.3 ms of
  8.3).
- **Lint:** `scripts/lint.sh` passes.
- **Accessibility** (`App/tools/axaudit.swift`, as a real assistive client): Welcome,
  Settings, Home and Quick Capture report 0 issues. The Home lockup is an image read as
  "OpenNexus". The icon tiles on Welcome and About, and the Quick Capture glyph, are hidden,
  because the name is printed beside them.
- **Document icon in Finder:** Launch Services resolves both types to this build, and its
  record for `com.opennexus.document` names `Contents/Resources/NexusDocument.icns`. The
  system's icon for `.nexusjson`, and for a new package type declared the same way, matches
  `brand/macos/NexusDocument.iconset` exactly. For `.nexus`, it matches at 16 and 128 px,
  but this Mac returns the generic page at 32 and 512 px: the sizes asked for while the type
  still resolved to builds without an icon. That is the icon cache, which only an
  administrator can clear (`sudo rm -rf /Library/Caches/com.apple.iconservices.store`, then
  restart). A Mac that never showed `.nexus` files before 0.2 won't have those entries.
- **Dock:** the Dock hides automatically on this Mac, so instead of a screenshot,
  `app-icon.png` is `NSWorkspace.icon(forFile:)` for the built app: the image the Dock and
  Finder draw.

## Human step: Icon Composer (about 5 minutes)

Apple documents `.icon` files only as something you create in the Icon Composer app ("Creating
your app icon using Icon Composer"); the format inside the bundle isn't published. So
`AppIcon.icon` is yours to author. Until it exists, the app uses the kit's pre-shaped
`AppIcon.appiconset`, already wired. Once a file named `AppIcon.icon` is in the target, Xcode
uses it instead of the catalog icon: the App Icon setting, `AppIcon`, matches by name.

1. Open **Icon Composer**: Xcode › Open Developer Tool › Icon Composer.
2. **File › New.** In the toolbar's platform menu, choose **macOS** only.
3. **Background.** Select the icon at the top of the sidebar, then in the inspector:
   1. Set **Fill** to **Gradient**: #6E67F6 at the top, #4C43DB at the bottom, angled 155°.
   2. Switch the canvas appearance to **Dark**. Under Fill, choose **Vary for Dark**, then set the gradient to #2A2B33 → #121317.
   3. Switch back to **Default**.

   Don't import `0-background.svg` as a layer; it's the same gradient, for tools without a fill setting.
4. **Layers.** Drag these from `brand/icon/icon-composer-layers/` into the sidebar, each into its own group, in this order:
   1. `1-ring.svg`
   2. `2-branches.svg`
   3. `3-root.svg`

   They're full-bleed 1024 × 1024 and already placed, so leave the position at 0, 0 and the scale at 100%. Check on the canvas that the white root dot sits on top of the branches. If it's behind them, drag its group so it draws last.
5. **Liquid Glass**, set group by group:
   - **Ring:** Liquid Glass on, Specular **Automatic** (or Inside).
   - **Branches:** Liquid Glass on.
   - **Root:** Liquid Glass on, Shadow **Neutral** (soft).
6. **Dark appearance colours.** With the canvas on **Dark**:
   - Select the ring layer. Under Fill, choose **Vary for Dark** and set Solid #8F89FF.
   - Do the same for the root, with #F5F5F7.
   - Leave the branches as they are: the Aurora and Amber layer reads well on graphite.
7. **Check the appearances.** Use the canvas toolbar to look at Default, Dark, Clear and Tinted. The ring and root must stay legible. Compare Default with `brand/png/opennexus-appicon-1024.png`.
8. **Save** as `AppIcon.icon` in `App/OpenNexus/`. That folder is synchronised with the app target, so the file joins the target by itself.
9. **Build:** `xcodebuild -project App/OpenNexus.xcodeproj -scheme OpenNexus build`. If Xcode reports two icons named `AppIcon`, delete `App/OpenNexus/Assets.xcassets/AppIcon.appiconset`: Apple says the `.icon` file replaces the catalog's icon.
10. **Check** the render matches the kit:

    ```bash
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" App/OpenNexus/AppIcon.icon --export-image --output-file /tmp/appicon.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
    ```

    Repeat with `--rendition Dark`.
11. **Commit** `App/OpenNexus/AppIcon.icon`.

## Human step: GitHub uploads

These are set in GitHub's settings, not committed as configuration:

- **Social preview:** repository Settings › General › Social preview › Edit › Upload `brand/web/social-preview-1280x640.png`.
- **Avatar:** github.com/settings/profile (or the organisation's settings) › Profile picture › Upload `brand/web/github-avatar-512.png`.
