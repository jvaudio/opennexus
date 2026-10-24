# Prompt for Claude Code: implement the OpenNexus "Aperture" logo and icon everywhere

Unzip `OpenNexus-Brand-Aperture.zip`, move the `OpenNexus-Brand-Aperture` folder to the repo root and rename it `brand/`. Then paste everything below the line into Claude Code at the repo root.

---

You are working in the OpenNexus repository: a native macOS 27 app (Swift 6, SwiftUI with AppKit) for mind maps and technical diagrams. We have chosen a final logo, **Aperture**. Your job is to implement it on every surface where the app, its documents, its extensions and the project present an icon or logo, and to remove every trace of earlier placeholder or "Triad" marks.

## Read first

1. `brand/BRAND.md` is the numeric spec: geometry, optical sizes, colours, lockups, surfaces and don'ts. It is the source of truth.
2. `brand/reference/brand-board.png` is the visual spec (design artboard *01 · Brand*).
3. `brand/reference/in-context/*.png` shows how the mark is used on the Welcome sheet, the About card in Settings › General, and the Quick Capture and Spotlight surfaces.
4. Look through the kit: `brand/xcode/` (asset-catalog-ready sets), `brand/macos/` (iconsets), `brand/icon/` (Icon Composer layers and references), `brand/svg/`, `brand/png/`, `brand/web/`.

Do not redraw, re-colour or "improve" the mark. Every asset was generated from one geometry. If you need a variant that doesn't exist, add it to `brand/tools/gen.py` and regenerate (see BRAND.md §7). Never hand-edit an SVG or PNG.

## Step 0: inventory before changing anything

Search the repo for every current icon or logo surface and list them in `docs/plans/brand-aperture.md` before editing. Look for:

- `.xcassets` catalogs
- `AppIcon` and any `.icon` file
- `ASSETCATALOG_COMPILER_APPICON_NAME` and `CFBundleIconFile` / `CFBundleIconName`
- `CFBundleDocumentTypes` and `UTExportedTypeDeclarations` (for `.nexus` icons)
- `MenuBarExtra` / `NSStatusItem` images
- Images used on the Welcome, Home, About and Settings views
- Widget, Quick Look, Spotlight and Share extension targets and their Info.plists
- README and docs images, web favicons, the DMG background, Help Book icons

Grep for old assets with `rg -i "triad|logo|appicon|brandmark|M12 32 L22 12"`.

## Step 1: asset catalogs

Copy these from `brand/xcode/` into the main app's asset catalog. Keep the names; they become the API.

| Asset | Use |
| --- | --- |
| `AppIcon.appiconset` | Fallback app icon |
| `AppIconImage.imageset` | The app icon as an in-UI vector image |
| `BrandMark.imageset` | Colour mark, light and dark variants, vector |
| `BrandMarkSmall.imageset` | Optical-size mark for use below 32 pt |
| `BrandLockup.imageset` | Horizontal lockup, light and dark |
| `BrandWordmark.imageset` | Wordmark only, light and dark |
| `MenuBarIcon.imageset` | Template image for the menu bar |
| `Colors/Brand*.colorset` | Brand colours |

Then:

- Add the colour sets to the design-token layer (`NexusTheme`) as `BrandColor.ring`, `.root`, `.upper`, `.lower`, `.wordOpen`, `.wordNexus`.
- Extensions that show the mark (widgets, Quick Look) need the mark assets in a catalog they can reach. Use a shared asset catalog in a framework or package resource bundle. Don't duplicate files per target.

## Step 2: app icon

**Preferred: an Icon Composer icon.** macOS 26 introduced the layered `.icon` format, and it gives the Liquid Glass Default, Dark, Clear and Tinted appearances.

1. Check whether the project already uses an `.icon` file, and what the installed Xcode supports. Use Apple's current documentation for Icon Composer and Xcode 27; do not guess the `.icon` file format.
2. If you can create it reliably, create `AppIcon.icon` from `brand/icon/icon-composer-layers/`, back to front:
   - **Background:** `0-background.svg` (Iris gradient). Dark appearance uses #2A2B33 → #121317.
   - **Layer 1:** `1-ring.svg`. Glass on, specular on.
   - **Layer 2:** `2-branches.svg`. Glass on.
   - **Layer 3:** `3-root.svg`. Topmost.
3. Point the target's app icon setting at it.
4. If the `.icon` bundle can only be authored in the Icon Composer app, stop at that step. Write exact click-by-click instructions into `docs/plans/brand-aperture.md` under "Human step: Icon Composer" so I can do it in about 5 minutes, and continue with the fallback below so the build still has the new icon.

**Fallback, always wired:** `AppIcon.appiconset` from Step 1. Set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for the app target. Remove old icon sets and any stray `.icns`.

## Step 3: `.nexus` document icon

1. Build `NexusDocument.icns` from `brand/macos/NexusDocument.iconset` with `iconutil -c icns`. Add a small script, `scripts/build-icons.sh`, that does this from the iconsets so the step is repeatable.
2. Reference the `.icns` from the exported UTType for `.nexus` (`UTTypeIcons` / `UTTypeIconFile`) and from `CFBundleDocumentTypes` (`CFBundleTypeIconFile`). Check against Apple's current documentation which keys macOS 27 honours, and keep both if harmless.
3. Make sure the Quick Look thumbnail extension still draws document *content*. The document icon is only the fallback.

## Step 4: native SwiftUI mark

Create `ApertureMark` in the UI package (e.g. `NexusTheme` or `OpenNexusApp/Brand/`). It is a SwiftUI `View` drawn with `Canvas` or `Shape`s from the BRAND.md geometry, so it scales without assets and can animate.

**API:**

```swift
ApertureMark(palette: .automatic /* .light, .dark, .appIcon, .mono(Color) */,
             opticalSize: .automatic /* or .boost(Double) */)
```

**Behaviour:**

- `.automatic` palette follows the colour scheme.
- `.automatic` optical size picks b from the rendered size: 1.0 at 128 pt and above, 1.5 at 32 pt or below, 1.9 at 16 pt or below, interpolated between.
- The view always lays out as a square using the `8 8 50 50` viewBox.

**Geometry notes:**

- The ring is an arc of radius 14 centred at (26, 32), from −g to +g the long way, so the gap faces +x.
- SwiftUI's `clockwise` flag is inverted in y-down space. Verify it visually against `brand/png/opennexus-mark-1024.png`; do not reason about it.
- Branches are cubic Béziers exactly as in BRAND.md. All strokes use `.round` caps.
- Draw order: ring, branches, end nodes, root.

**Accessibility:**

- `accessibilityLabel("OpenNexus")` when used as a logo.
- `.accessibilityHidden(true)` when decorative next to the visible name.

**Tests:** add snapshot tests that render `ApertureMark` at 1024, 64, 32 and 16 px for each palette. Compare against the PNGs in `brand/png/` and the `brand/xcode/AppIcon.appiconset` sizes, with a small per-pixel tolerance for anti-aliasing. Record the reference images with the existing snapshot tooling.

Also create a `BrandLockup` view that composes `Image("BrandLockup")`. Don't rebuild the wordmark from live text, because the kit's wordmark is outlined Geist.

## Step 5: replace every in-app surface

Use the design artboards in `design/source/` and `screenshots/` from the main handoff package for placement and size.

| Surface | Implementation |
| --- | --- |
| Welcome sheet (S1, artboard 14) | 84 pt app icon tile at the top of the glass sheet: `Image(nsImage: NSApp.applicationIconImage)` or `AppIconImage` |
| Home window | Lockup (or mark plus title) in the sidebar or header, per artboard 16. Use `BrandMarkSmall` below 32 pt. |
| About | Custom About window or `orderFrontStandardAboutPanel(options:)` with the app icon. Settings › General's About card (artboard 35) shows a 52 pt icon tile next to "OpenNexus 1.0". |
| Tutorial and keycap coach (F5) | Any brand marks use `ApertureMark` |
| Menu bar extra / Quick Capture | `MenuBarIcon` template image (18 pt). The Quick Capture panel's leading glyph is `ApertureMark(opticalSize: .boost(1.5))` at 20 pt, as on artboard 33. |
| App Intents / Shortcuts | These inherit the app icon; make sure no stale custom images are referenced |
| Widgets | Brand mark in the widget header where the design shows it. The widget gallery icon comes from the app icon. |
| Share extension, Services, Spotlight | Use the app or document icon; remove old images |
| Help Book (if present) | Replace its icon and header with the lockup |
| Dock / Finder / Launchpad | Covered by Steps 2 and 3 |

Remove all old logo assets and code paths. Nothing named "Triad", and no placeholder icons, may remain. Add a CI check (a grep in `scripts/lint.sh`) that fails if `M12 32 L22 12` or `Triad` reappears.

## Step 6: repository and web

- **README.md:** add a `<picture>` header with `brand/svg/lockup/opennexus-lockup-dark.svg` for `prefers-color-scheme: dark` and `-light.svg` otherwise, alt text "OpenNexus".
- **Docs site:** if one exists, wire up `brand/web/favicon.svg`, `favicon.ico`, `apple-touch-icon.png`, `icon-192.png`, `icon-512.png` and a manifest.
- **Manual uploads:** list `web/social-preview-1280x640.png` (GitHub social preview) and `web/github-avatar-512.png` (org avatar) under "Human steps" in the plan doc. They are uploaded in GitHub settings, not committed as config.
- **DMG and packaging:** if there is a DMG or installer background, use the dark lockup on #121317.

## Step 7: verify

1. Clean build of every target, with no asset-catalog warnings about missing sizes or unassigned children.
2. Check the compiled app icon: inspect `Assets.car` with `assetutil --info` or check that `actool` produced the icon. Render the `.icns` into PNGs with `sips`/`iconutil` and compare against `brand/png/opennexus-appicon-1024.png`.
3. Refresh Launch Services (`lsregister -f <app>`). Confirm in Finder that a `.nexus` file shows the new document icon; describe how you checked it.
4. Run the app and take screenshots of:
   - the Dock icon
   - the Welcome sheet
   - Settings › General › About
   - the menu bar extra, in light and dark menu bars
   - Quick Capture
   - a `.nexus` file in Finder (icon and list views)

   Attach them to the PR description.
5. Run the snapshot tests and the new lint check, and confirm both pass.
6. Run accessibility checks: VoiceOver reads "OpenNexus" for logo images, and decorative marks are hidden.

## Constraints

- Do not alter geometry, proportions or colours. If something looks wrong, check it against BRAND.md and the reference PNGs, then fix your implementation, not the asset.
- Keep `brand/` as the single source; targets reference it or the shared catalog.
- No network calls, no new third-party dependencies for this work, no font embedding (the wordmark is outlined).
- Small, reviewable commits: (1) assets and catalogs, (2) app and document icons, (3) `ApertureMark` with tests, (4) in-app surfaces, (5) repo, web and lint. Then open one PR titled **"Brand: adopt Aperture logo and app icon everywhere"**.

## Definition of done

- Every surface in Step 0's inventory is checked off in `docs/plans/brand-aperture.md`, with a screenshot or a note.
- The app, document and menu bar icons show Aperture after a clean install.
- No old mark remains anywhere in the repo, and lint enforces it.
- Snapshot tests for `ApertureMark` pass.
- Any steps needing a human (Icon Composer authoring, GitHub uploads) are written up with exact instructions.
