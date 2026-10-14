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
| D16 | Licence file deferred: README §4 leaves Apache-2.0 vs MIT to the product owner. | Not ours to choose. |
