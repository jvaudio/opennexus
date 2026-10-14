# Decisions

Choices made where the design was silent or ambiguous, each with a one-line rationale
(per the agent prompt). Newest at the bottom of each milestone.

## M0 · Foundations

| # | Decision | Rationale |
| --- | --- | --- |
| D1 | **Undo is patch-based**: every edit runs through `CanvasEditor`, which records the before-image of each touched node (and of the non-node canvas fields when they change). A `Patch` is invertible and mergeable. | One mechanism covers typing, restructuring, style, layout mode, conversion and AI accepts; coalescing and "Merge = one undo" fall out of `Patch.merged`. Cheap at 5k nodes because only touched nodes are copied. |
| D2 | **Canonical JSON writer of our own** (sorted keys by code point, 2-space indent, `"key": value`, LF, trailing newline, integers without `.0`). `JSONEncoder` is not used for files. | Foundation's pretty printer writes `"key" : value` and its number formatting is not guaranteed stable; byte-identical round trips need full control. |
| D3 | **Defaults are omitted** on write (`folded: false`, empty `markers`, `ai: false`…), but `text`, `kind` and `children` are always written. | Smaller files and quieter diffs. Round trip is byte-identical for files in canonical form; a hand-edited file is normalised once on first save. |
| D4 | **Unknown keys round-trip** via an `extra` bag on every model type, at every level (manifest, canvas, node, todo, note, relationship, layout, style). Elements that later milestones type (zones, boundaries, summaries, callouts, `diagram`) already round-trip through the canvas's `extra`. | Forward compatibility requirement in README §6. |
| D5 | **Node ids are sequential per canvas** (`n1`, `n2`…), seeded from the highest existing id on load. Node keys in `nodes` are sorted lexicographically like every other object key. | Diff-friendly and deterministic; one sort rule for the whole file. |
| D6 | **Open string enums** (`DiagramType`, `NodeRole`, `LayoutStructure`, `LayoutMode`) instead of Swift enums. | Values from newer files are preserved instead of failing to decode. |
| D7 | Schema allows unknown keys everywhere except inside `nodes` (whose keys must be ids). `nexus validate` also checks tree invariants (one parent per node, reachability, dangling relationships). | JSON Schema cannot express tree invariants; forward compatibility needs open objects. |
| D8 | **Node typography follows P0** (root 20 / main 15 / sub 13.5 pt) rather than artboard 02's 22 / 16 / 14. | P0 is "the reference for feel" and artboard 07 also labels Central as 20 pt; all sizes stay ≥ 12 pt. Theme data can override later. |
| D9 | **Layout spacing follows P0** (main sibling gap 20, deeper 10, root→main 64, parent→child 40) rather than the token sheet's 14 / 56 / 28. | Same reason as D8; screenshots 06 and 17 were captured from P0's values. |
| D10 | **Commands have scopes** `global`, `canvas` (Select), `editor` (Edit), `connect`, `outline`, `find`. Global conflicts with every scope; others only with themselves. | Lets ⌘K be the palette in Select mode and Link in Edit mode, as the brief specifies, while keeping the conflict test strict. |
| D11 | **Xmind alias set lives in the default profile**: ⌘R → Relationship (Connect mode), ⌘⌫ → Delete keeping children, ⌘; → Focus. | Review row asks for the aliases; ⌘R's Xmind meaning is unconfirmed, so it maps to the closest OpenNexus command. Revisit if a user reports a mismatch. |
| D12 | **Profiles**: OpenNexus (default), Hyper-first, Outliner (Tab demotes, ⌥↩ adds a child), Vim-style (`h j k l`, `i`/`a` edit, `o`/`O` siblings, `x` delete, `z` fold, `g` root; typing does **not** replace the selection). | Brief names these profiles; Vim beyond the basics is under-specified (README §14). Chords cannot express `dd`, so `x` deletes. |
| D13 | **The app is AppKit-lifecycle** (`NSApplication` + `NSDocument`, programmatic menus) with SwiftUI hosted for panels and settings. | Menus must be generated from the registry and the canvas needs first-responder control; the document needs file-package autosave and versions. |
| D14 | **Sandboxed with no network entitlement.** | "Local and owned": the OS enforces that the app cannot open connections. |
| D15 | The Xcode project is hand-maintained and uses **synchronized folders** (`App/OpenNexus/` is picked up automatically). All logic lives in the Swift package; the app target is thin. | Keeps the project file tiny and merge-friendly; no generator dependency for contributors. |
| D16 | **MIT licence** (product owner's choice, 2026-10-14). | README §4 left Apache-2.0 vs MIT to the product owner. |

## M1 · Canvas and keyboard core

| # | Decision | Rationale |
| --- | --- | --- |
| D17 | **Branch lines are recomputed every frame from animated node frames** (display-link spring stepping) instead of separate Core Animation path animations. | Lines stay glued to nodes through overshoot, and new input retargets springs in flight (motion rule 2). |
| D18 | **Node text is measured and drawn with AppKit string drawing (TextKit)**, the same engine as the `NSTextView` editor. | One engine for measure, draw and edit removes P0's mid-word wrap artefact (README §14). |
| D19 | **The editor opens at the node's final frame**; the node's shape grows in behind it. | Caret live at 0 ms while the creation animation still plays (brief §8). |
| D20 | **Creating a topic and naming it are two undo steps** (as in Xmind and P0). | Native `NSUndoManager` grouping per event; merging would need to rewrite a registered action. |
| D21 | Edit-mode typing has its own per-session undo manager. | ⌘Z while editing undoes typing only and never touches model undo with stale text-view state. |
| D22 | Keys map from key codes for special keys and from the current layout's unshifted character for printable keys (US ANSI fallback). | Shortcuts follow the user's layout for letters while arrows, Tab, Return stay positional. |
| D23 | ⌥⌘1…9 on the root changes the canvas structure; on any other topic it sets that branch's structure. | Matches "change branch structure" while giving the root a keyboard path to the canvas layout. |
| D24 | Empty-canvas drag pans in M1; rubber-band selection arrives with drag-and-drop (M3). | Keeps the mouse useful before direct manipulation is built. |
| D25 | Document chrome follows the system appearance; the canvas follows the theme. | Native macOS behaviour; themes colour content, not chrome. |

## M2 · Styling

| # | Decision | Rationale |
| --- | --- | --- |
| D26 | **Node styles are style layers** (a `TopicStyle` per role plus line character) resolved with colour tokens (`branch`, `branch@0.14`, `ink`, `ring@0.2`, `canvas`, `mainBg`, `auto`, hex). | "Implement presets as data" (README §8); users can save a modified preset as a quick style or theme. |
| D27 | **Node styles never change the canvas colour** (Sketch's paper and Glow's dark canvas on artboard NS are pairing suggestions). | Theme supplies colour; style supplies shape (README §8). P0's live `styleLook` works on every theme the same way. |
| D28 | **Auto contrast is on by default** and guarantees the theme's target (AA, or AAA for High Contrast): text is toned toward ink or white; if neither can pass, a solid fill is deepened just enough. | Contrast is a hard requirement for every theme; gap analysis asks for "text colour auto-adapts to background". |
| D29 | Palette id `theme` (new default) means "use the theme's own eight colours"; the six FMT-3 colour themes override it. | Lets Graphite, Paper and the rest keep their designed palettes while colour themes still recolour any theme. |
| D30 | Colour-theme modes: **Rainbow** (next colour per main branch), **Multi** (by sibling position), **Mono** (one colour), **Gradient** (first → last palette colour across main branches). | FMT-3 names the four modes but not their rules. |
| D31 | **Auto balance on** keeps P0's count-based split (ties favour the right); **off** puts every main topic on the right. | Matches P0 and the screenshots; a height-based split moved branches unexpectedly. |
| D32 | **Numbering on a topic numbers its children**; "Apply to siblings" (default on) stores it on the parent so the selected topic and its siblings are numbered. | Matches Xmind's behaviour and FMT-1's "2.1 PRICING" example. |
| D33 | The **Sketch style uses Noteworthy** (ships with macOS) rather than bundling Kalam. | No bundled font or extra licence; Kalam (OFL) can be added later if wanted. |
| D34 | **Skeleton gallery of 24** = FMT-3's nine plus fifteen structure × node style × line pairings. | README §14 asks us to derive the rest. |
| D35 | Custom themes, colour themes and quick styles live in the document's `theme.json` (`StyleLibrary`), and library edits ride on patches so they undo. | Files carry their own look; one undo mechanism. An app-wide library can come with Settings (M8). |
| D36 | Golden snapshots render offscreen with `CALayer.render(in:)` (flipping the hosted root explicitly) instead of capturing the window. | Runs without screen-recording permission or a visible window, so CI can run it. |
| D37 | **Summary and callout topics are real nodes** (`kind` summary / callout) referenced by their element; they never re-parent, and removing the element removes their branch. | They edit, style, undo and export like any topic and can have children (artboard 12), with one code path. |
| D38 | **Connect hints are prefix-free**, so a typed hint is never ambiguous. They're assigned nearest-first from the home row, and typing that matches no hint filters by text. | Artboard 09: "the likeliest target is always one key". Prefix-free sets let two-letter hints exist on large maps without a timeout. |
| D39 | When a Connect filter matches nothing, ↩ **creates the new topic under the central topic**, then connects to it. | Predictable placement; the label opens straight away and the topic can be dragged anywhere afterwards. |
| D40 | **Plain drag on empty canvas rubber-bands; ⌥-drag (and two-finger scroll) pans.** | Rubber-band selection was carried from M1. Trackpad scrolling already pans, so the plain drag goes to selection. |
| D41 | **Stickers are emoji** (`emoji:` asset refs) from a starter set of 80 in five categories; image stickers use the same field with a package asset. | Ships with no artwork licence; "Make a sticker" (Image Playground) lands with AI in M6. |
| D42 | **Rich-text marks only add emphasis** (bold, italic, underline, strike, link) over the topic's style. ⌘B on an already-bold topic beeps; weight is restyled in the Format panel. | A mark that removes emphasis would make the style resolver and exports ambiguous. |
| D43 | **Linked files are referenced, not copied**; dropped images and attachments *are* copied into `assets/` by content hash. | A link means "open that file"; a drop means "keep this with the map". Hashing dedupes. |
| D44 | **Boundaried branches reserve space in the layout** (padding plus a title band), and summary brackets sit outside enclosing boundaries. | Without it a boundary drew over neighbouring topics; spacing is part of the layout, not the drawing. |
| D45 | **Curved relationships bow to the side that crosses fewer topics** unless the user has bent them. | Keeps edges off the central topic (artboard 12) without a router. Elbow routing around obstacles comes with M4's technical canvases. |
| D46 | **Wrapped text is balanced**: the narrowest width with the same line count. | No lone last words in callouts or long topics; it's cheap because measurements are cached. |
| D47 | **Audio notes record locally to m4a; transcription is deferred to M6** (on-device Speech). | Recording needs only the microphone entitlement; the transcript belongs with the local-AI work. |
| D48 | The **floating toolbars are deferred**; their actions are already reachable by keyboard, menus and the Format panel. | Keyboard first. The toolbars arrive with the Insert menu and slash commands. |
