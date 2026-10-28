# Starters, Guide mode and Present: reviewed plan

Oct 27, 2026 · Jerry Voelker · reviewed against the code at `c600391` · **Status: accepted
2026-10-27**, with the recommended answer to every decision below

The goal is unchanged: one shared catalogue of diagram types, with three features on it.

- A picker on every **+**.
- An optional Guide mode.
- An Xmind-style Present mode with real motion.

What changed in review is the starting point. Much of the foundation already exists. The original draft assumed a blank slate:
- 16 diagram types with per-type behaviour.
- 25 templates.
- Two type pickers.
- A step-driven tour.
- DFD rule checks.
- A Present mode with saved slide order, a presenter view and exports.

Building beside these would duplicate them. This plan **consolidates and extends** them instead. That makes each phase smaller and keeps the 637 existing tests as a safety net.

## What changed in review

| Draft | Revised | Why |
| --- | --- | --- |
| New `DiagramType` struct as the registry | Keep the existing `DiagramType` id. Add a `DiagramDescriptor` per type (code) and a **Starter** per picker card (data) | `DiagramType` already exists as an open enum with 16 values (`Identifiers.swift:62`). Its traits are spread over about 7 `switch`es. A new type also needs layout and rendering code, so only starters can honestly be "one file". |
| "Add one bundled JSON/YAML file" | **JSON** starters and guides, validated by a published schema | The package has zero dependencies and its own canonical JSON (D2). Foundation has no YAML. |
| User types from `~/Library/Application Support/OpenNexus/Types` | Built-ins first. Later: **Save Canvas as Starter…** and **Install Starter…** (open panel) | The app is sandboxed, so that path resolves inside the app's container, not the user's Library. The brief says galleries install "from a file or URL only" (README §15). |
| Add a node `role` field | Use the existing **`nodeType`** (process, entity, store, threat, …) with its inference, plus tree position. Edges and boundaries match too | `NodeRole` already means Xmind's topic kind, and `Role` means the user's job. `nodeType` is the semantic role, and `DiagramCatalog.effectiveType` infers it, so guides work on maps nobody typed. Data flows are edges and trust boundaries are elements, not nodes. |
| Picker on ⌘N, ⌘T and every + | Picker on **⌘T and the tab-bar +** (new canvas). **⌘N stays a blank document.** File › New Document from Starter… opens the picker | M8 and D107 made ⌘N a blank mind map, as in Xmind; Home's copy says so. ⌘N → blank is the fastest path; a sheet on it would slow every document. |
| ⌘1–⌘9 jump to categories | Type to filter (category names match too); ⇥ moves to the sidebar | ⌘1–⌘4 are global (Canvas, Outline, Split, Gantt). |
| Guide on ⇧⌘G, Back/Next on ⌥⌘←/⌥⌘→ | Guide on **⌃⌘G** (free). No Back/Next: the current step comes from the document. **Skip** is a command | ⇧⌘G is Find Previous, a macOS standard. ⌥⌘→ is Demote. |
| New nodes inherit the current step's role | Guide **suggests only**; it never edits the document by itself | Auto-assigning writes undo steps the user didn't ask for, and it fights inference and freeform users. |
| Guide state saved in the document | Save only **skipped steps** (an edit, undoable). Visibility is window state | Progress is derived from the document, like the current slide (M5: view state is never stored or undone). Opening the guide shouldn't mark a file edited. |
| Older files open as Blank, no guide | Older files open as their type, and the guide works on them | Every canvas already stores `type`. |
| Present: new mode, camera abstraction, ⌘↩ / ⌥⌘↩ | **Present, part 4**: extend the existing mode. Keep ⇧⌘P; add **Present from Selected Topic ⌥⌘P** | Present ships today (M5, M21, M28, M35). `Camera` exists and Present already reuses it. ⌘↩ is Add Parent and ⌥⌘↩ is Add Floating, both Xmind chords. ⌥⌘P plays from the selection in Keynote. |
| Per-slide transition overrides | Deck-wide **styles** only | D234 rejected a per-slide toggle as "a setting nobody finds". Merge already groups slides. |
| Particle burst (CAEmitterLayer) | Cut (Showtime may reuse the existing "done" sparkle) | "Calm chrome" is a design principle; the draft itself flags effect overload. |
| swift-snapshot-testing | The existing `ImageDiff` goldens (`REGENERATE_GOLDENS=1`) | The project has no third-party test dependencies. |
| Phases behind feature flags | Each milestone ships complete, with the **Calm** style reproducing today's Present | There's no flag system; the repo's rule is "don't start the next milestone with failing tests". |
| Tips quote keys ("Press Tab") | Tips quote **command ids**, rendered for the active profile | The Outliner profile binds Tab to Demote, and Vim uses its own keys. A literal "Tab" would be wrong for them. |
| Keymap open question | **Resolved:** every repo doc says Tab = child, Return = sibling | Only the external Concept Overview disagrees, and it isn't in the repo. Fix that document; nothing here changes. |

## What already exists

| Area | Today | Where |
| --- | --- | --- |
| Diagram types | 16 open-enum ids. `displayName` and `defaultStructure` live in `Canvas.swift`; node palettes, `isTechnical`, `rootIsTitle` and `effectiveType` in `DiagramCatalog` | `Identifiers.swift:62-82`, `Canvas.swift:307-346`, `Diagram.swift:150-302` |
| Type lists in code | About 7 separate lists and switches | `HomeView.swift:107-143`, `CanvasController+Diagrams.swift:207`, `MapTools.swift:222`, `CanvasController+Preferences.swift:165`, `DocumentWindowController.swift:543`, … |
| Templates | 25 `MapTemplate`s as Swift closures over an indented-outline DSL (`>type` suffixes), grouped by job role. They create a new **document** only | `Templates.swift:113-633` |
| Type pickers | Home's New row (⇧⌘N inside Home, then 1–7) and Convert (⌥⌘T, 1–8) | `HomeView.swift:195`, `CanvasController+Diagrams.swift:272` |
| New canvas | ⌘T and the tab-bar + call `addCanvas()`, which always makes a mind map | `DocumentWindowController.swift:329` |
| Semantic node types | `Node.nodeType`, inferred when nil; set from the slash menu, Icon Library and Convert. No inspector control | `Node.swift:188`, `Diagram.swift:277` |
| Guidance | The first-run tour: hard-coded lessons; steps complete on commands (`expects`) or document checks (`Check`). Plus empty-canvas hints and tips | `Tour.swift:12-60`, `TourViews.swift` |
| Rule checks | `DFDRules.check` (5 rules, D52) in a DFD panel; a STRIDE checklist tab | `DFD.swift:80`, `FormatPanelStride.swift` |
| Present | Generated slides: a title slide, then one per main topic, one per flow (technical types) or one per message (sequence). Saved `order`, `skipped`, `merged` and `presentHidden`; Glide / Zoom / Cut; dimming; presenter view on a second display; PDF, .pptx and MP4 export | `Presentation.swift`, `PresentViews.swift`, `SlideExporter.swift` |
| Motion | `Motion` tokens (springs, curves, durations). `presentStep` (500 ms, "content builds in sequence" in 05-Motion) is **defined but unused** | `Tokens.swift:45-82` |
| Camera | Offset + zoom applied as a layer transform; text re-rasterises in quarter-zoom steps | `CanvasView.swift:622-693` |
| File format | `presentation` and `filters` are written but **missing from the published schema** | `Canvas.swift:316`, `schema/nexus.schema.json` |

## Foundation · M39 · One catalogue: descriptors and starters

A pure refactor. Users see no change. Everything after it reads from here.

**Two concepts, kept apart:**

1. **`DiagramDescriptor`** (NexusCore, Swift). One per `DiagramType`: display name, default structure, category, summary, search aliases, node-type palette, `isTechnical`, `rootIsTitle`, slide strategy (hierarchy, flow or sequence), and the default guide.
   - It replaces the scattered switches. The CLI and MCP (`nexus new --type`, `MapTools`) read the same table.
   - A new diagram type still needs layout and rendering code. This just gives it one place to declare itself.
2. **`Starter`** (data, JSON in `NexusCanvas/Resources/Starters/`). One per picker card:
   - id, name, category, summary, aliases, base type and structure;
   - an **outline** in the existing template DSL;
   - an optional guide id and Present style.
   - Every type gets a "Blank ‹type›" starter. The 25 templates become starters.

```json
{
  "id": "dfd",
  "name": "Data flow diagram",
  "category": "security",
  "summary": "Processes, stores and the data that moves between them.",
  "aliases": ["dfd", "data flow", "context diagram"],
  "type": "dfd",
  "structure": "flow.down",
  "outline": "Online store >process\n  Customer >entity\n  Orders >store",
  "guide": "dfd",
  "present": { "style": "dynamic" }
}
```

Steps:

1. Add `DiagramDescriptor` and route every type switch through it. Golden tests stay green.
2. Add `Starter` decoding, `schema/starter.schema.json` and `StarterLibrary`, which replaces `TemplateLibrary`.
3. Convert the 25 templates to JSON. A migration test proves each JSON starter builds **byte-identical canonical JSON** to the Swift template it replaces; then the closures are deleted.
4. Bring Starter and guide text into `Localizable.xcstrings`, which `catalogCoversEveryDataDrivenString` enforces, and into the pseudo-language snapshots.
5. Schema: add `presentation`, `filters` and `presentHidden` to `nexus.schema.json` and its `NexusFormat` copy (`guide` follows in M41, with the feature). `schemaVersion` stays 1: the additions are optional, and older builds keep them through `extra` (D4).

**Categories:** the picker groups by what you're making: Thinking, Planning, Process, Architecture, Security, Software. The onboarding role becomes a **For you** filter rather than the grouping.

**Done when:** no `switch` over `DiagramType` remains outside the descriptor table, all 25 starters build identically, and the CLI lists starters.

## Feature 1 · M40 · Starter picker

**Entry points:**

| Path | Behaviour |
| --- | --- |
| ⌘T, tab-bar +, tab menu › New Canvas | Picker sheet → new canvas (tab) in this document |
| ⌘N | Unchanged: a blank document of the default type |
| File › New Document from Starter… (the existing `file.newChooseType`; ⇧⌘N inside Home) | The same picker → a new document |
| Home | Its type row and template shelf are replaced by the same gallery view |
| Convert (⌥⌘T) | Reads the descriptor table (no visual change) |
| CLI / MCP | `nexus new --starter dfd`; MCP lists starters |

**Layout:** as drafted.
- A sidebar with All, Recent, For you and the categories.
- A grid of cards: live thumbnail, name, summary, and a **Guided** badge where a guide exists.
- A search field focused on open, matching names, aliases and categories.
- **Start with Guide** (remembered per starter) and Cancel / Create.
- **Blank** sits first: the user's default type and structure, the same thing ⌘N makes.

**Keyboard:**
- Typing filters while the arrow keys move the grid selection, as in Xcode's template chooser.
- ↩ creates, Esc cancels, double-click creates.
- Focus starts on the last-used starter, so **⌘T ↩** is two keystrokes.
- **⌥-click on +** skips the picker and uses the last starter.
- Setting: **Choose a starter for new canvases** (on by default).

**Build:**
1. Route `addCanvas()` and every creator through a `NewCanvas` coordinator that takes a starter id.
2. `StarterGalleryView` (SwiftUI), hosted in a sheet and inside Home.
3. Thumbnails come from the existing offscreen renderer (`ImageExporter`). They're cached per starter, theme, appearance and scale, rendered lazily with placeholders, and pre-warmed when the app is idle.
4. Create = one undo step. The new canvas opens with a live caret on the root (key→caret budget: 16 ms).
5. Hovering a card animates its thumbnail, except under Reduce Motion. Cards are VoiceOver buttons: name, summary, category, Guided.

**Done when:**
- Every + path shows the picker, and the picker opens in under 100 ms.
- The canvas appears under 150 ms after ↩.
- Keyboard-only creation works.
- All 16 types and 25 templates are selectable.
- `axaudit` is clean.

## Feature 2 · M41 · Guide mode

A trailing panel (⌃⌘G, View › Guide; a registered command) shows:
- the target structure;
- one tip;
- where you are, derived live from the document.

It never blocks typing and never edits the document by itself.

**Guide schema (JSON, per guide):** matching uses what the model already has.

```json
{
  "id": "dfd",
  "steps": [
    { "id": "process", "match": { "nodeType": "process" }, "min": 1,
      "title": "Name the system you're modelling",
      "tip": "Start with one process for the whole system. {topic.addChild} adds what it talks to." },
    { "id": "externals", "match": { "nodeType": "entity" }, "min": 1,
      "title": "Add external entities",
      "tip": "People or systems outside your control that send or receive data." },
    { "id": "flows", "match": { "edge": { "labelled": true } }, "min": 1,
      "title": "Label the data flows",
      "tip": "Name the data each flow carries, e.g. “login request”." },
    { "id": "stores", "match": { "nodeType": "store" }, "optional": true,
      "title": "Add data stores" },
    { "id": "rules", "match": { "rules": "dfd" }, "optional": true,
      "title": "Clear the rule checks" }
  ]
}
```

- **Match kinds:**
  - `nodeType`, using inference so untyped maps work;
  - `kind` + `depth`, for mind maps (root named, ≥ 3 main topics, each with a subtopic);
  - `edge` (labelled or typed);
  - `boundary`, for trust boundaries;
  - `rules`, which reuses `DFDRules`;
  - plus `parent` and `min` per parent.
- **Tips** quote command ids (`{topic.addChild}`). They're rendered with the active profile's keycaps by the tour's existing `CoachKey`, so remapping or switching to Outliner or Vim stays correct.
- **First wave:** Mind map, Flowchart, DFD, Architecture, Threat model (with STRIDE suggestions from `Stride.suggestions`). Other starters show "Guide coming soon".

**Matcher:**
- `GuideMatcher.progress(canvas, guide, selection) -> GuideProgress` is a pure function in NexusCore, like `DFDRules.check`.
- It runs on the document store's patch observer (undo and redo included) and on selection changes (observation tracking).
- It's coalesced to the next run-loop turn, never on the keystroke path.
- Budget: under 2 ms for 1,000 nodes, with a performance test.

**Current step:**
- The step matching the selected node. Otherwise, the first required step not yet met.
- Clicking a step selects its first matching node.
- For an unmet step, clicking it **suggests** the next action: the keycap, and a ghost via the existing suggestion UI. The guide doesn't create the node itself.

**Panel:**
- A header (type, "3 of 6", close).
- A step list with node-type glyphs and states:
  - Upcoming;
  - Current, pulsing **once** on change, then static, and a plain highlight under Reduce Motion;
  - Done, with a check;
  - Skipped, dashed.
- A mini diagram above the list for tree types, drawn from the steps by the real layout engine. Graph types (DFD, architecture, threat model) show the list alone.
- A tip card with Skip.
- Completion offers **Present** or **Hide guide**.
- It shares the trailing slot with the AI panel: opening one closes the other, so the canvas never squeezes between three panels.

**Storage:**
- `canvas.guide = { id, skipped: [...] }`, written only when it isn't the default. Skip is an undoable edit.
- Visibility is window state, like `formatPanelVisible`.

**Also:** a **Type** control on the Format panel's Data tab, backed by a registered "Set Node Type…" command. Today nodeType can only be set from the slash menu, Icon Library or Convert.

**Done when:**
- The matcher's unit tests cover each guide: add, rename, delete, reparent, undo/redo and untyped maps.
- Goldens of the panel pass in light, dark and pseudo-language.
- The VoiceOver walk-through and `axaudit` are clean.
- Typing latency is unchanged (`keyToCaretUnder16ms` with the guide open).

## Feature 3 · M42 · Present, part 4: motion and controls

This builds on M5/M21/M28/M35. Saved decks keep working: slide ids (`title`, `branch:‹id›`, `flow:…`) stay stable, so `order`, `skipped` and `merged` survive.

**Starting:**
- **Present** ⇧⌘P (unchanged).
- **Present from Selected Topic** ⌥⌘P (new).

**Styles:** deck-wide `presentation.style`. The existing `transition` field still reads.

| Style | Camera | Builds | Emphasis |
| --- | --- | --- | --- |
| Calm | Glide (today) | None | Dim (today) |
| **Dynamic** (default) | Fly-to | Children pop in, connectors draw on | Dim + blur |
| Showtime | Fly-to | As Dynamic, faster stagger | Focus grows 1.15× with glow; sparkle on marked slides |

**Motion:** every value lives in `Motion` tokens, with no literal timings in views.
- **Fly-to:** replace the Zoom transition's two linear legs with a van Wijk–Nuij smooth zoom path (`Motion.fly`, about 700 ms). Cut under Reduce Motion, as today.
- **Builds:** implement the specified `presentStep`, "content builds in sequence".
  - Children scale and fade in on the `snap` spring, about 60 ms apart.
  - Connectors draw on, reusing the editor's relationship draw-on.
  - Under Reduce Motion: a 150 ms cross-fade.
- **Spotlight:** today's dimming plus Focus mode's existing blur on non-focus content.

**Slides:**
- A new deck setting **Depth**: main topics (today) or every topic with children (an Xmind-style walk).
- An optional **Overview between branches**.
- Technical types keep their flow and message ordering.

**Controls:**
- Click advances.
- **B** and **W** black and white the screen.
- Digits then ↩ jump to a slide, as in Keynote; ↩ alone still advances.
- **O** shows an overview.
- **Esc** ends on the current slide's topic, selected and framed, instead of reframing the whole map.
- Hold ⇧ for a laser pointer.
- All of these join the **?** key list (D266).

**Presenter view:**
- Full screen on the second display.
- The current and next slides rendered for real (today: a title and a wireframe).
- Notes in larger type, elapsed time and a clock.

**Exports:**
- Investigate **vector** PDF: M5 promised it, but slides are raster today.
- Speaker notes in .pptx.
- Animated HTML stays a non-goal.

**Done when:**
- Unit tests cover slide ordering per type and depth.
- Goldens cover each style's resting frames.
- A fly-to performance test (motion **on**) keeps the median main-thread frame under 8.3 ms on the 1k map and under 16.7 ms on the 5k map.
- Reduce Motion replaces every effect.
- Old decks open unchanged under Calm.

## Order and parallel work

```
M39 catalogue ──► M40 picker ──► M41 guide
M42 present (needs only M39's descriptor field, so it can start any time)
```

- M39 is the risky one: it touches every type switch. It's also the one the existing tests protect best.
- M42 is independent of M40 and M41, and the motion work suits a second contributor or the designer's specs.
- Relative size: M39 medium, M40 medium, M41 large, M42 large.

**Design handoff before each phase:**
- M40: a picker card, sheet and Home embedding (in Home's existing type-card style, artboard 16).
- M41: the guide panel and its states.
- M42: motion specs for the three styles, extending 05-Motion.

## Testing

- **Unit:**
  - descriptors and starter decoding, and schema validation;
  - the template migration (byte-identical);
  - `GuideMatcher` per guide;
  - slide ordering per type and depth;
  - key-token rendering per profile.
- **Goldens (`ImageDiff`):** picker cards, the guide panel and Present styles in light, dark, High Contrast and pseudo-language.
- **Headless flows (`CanvasHarness`):** ⌘T → picker → ↩, the guide following edits, Present controls.
- **XCUITest:** every + path opens the picker; keyboard-only creation; Esc paths. This still needs Automation permission on the CI Mac (an open M5 gap).
- **Performance:** picker open under 100 ms, matcher under 2 ms per 1k nodes, key→caret unchanged, fly-to frame times.
- **Accessibility:** a VoiceOver walk through the picker, guide and presenter view, `axaudit`, and Reduce Motion paths.

## Decisions

Accepted 2026-10-27: the answers in **bold**. Decisions marked † contradict an earlier recorded decision, and would need a new DECISIONS row if changed.

1. **⌘N keeps making a blank document**, and the picker is on ⌘T and +. Alternative: the picker on ⌘N too, reversing M8/D107 †.
2. **The guide suggests only.** Alternative: it auto-types new nodes or auto-places them.
3. **Deck-wide styles; no per-slide transition overrides.** Alternative: per-slide overrides (against D234 †).
4. **Dynamic is the default style for every deck** (Calm reproduces today's look exactly). Alternative: Calm stays the default and Dynamic is opt-in.
5. **User starters come later, via Save as Starter / Install Starter.** Alternative: a watched folder, which would need a sandbox exception.
6. **The picker lists all 16 types and 25 templates.** The draft counts 12 types from the Concept Overview, which isn't in the repo. If it names types the code lacks (e.g. "network"), they're new engine work, out of this plan.
7. **Particle burst cut.** Alternative: Showtime-only.

## Risks

- **M39 regressions.** Consolidating type switches touches layout, rendering, CLI and MCP. Mitigations: a pure-refactor milestone, the byte-identical migration test, and the full suite.
- **Panel crowding.** Format, AI and Guide panels could all claim the trailing edge; the shared slot rule handles Guide and AI.
- **Graph-diagram matching.** Edges and boundaries make the matcher more than tree walking; unit tests per guide carry it.
- **Present default change.** Existing decks look different under Dynamic (see decision 4). Calm is one setting away.
- **Localisation load.** About 41 starters and 5 guides of text, all in the catalogue and pseudo-language tests from day one.
- **Deep-zoom cost.** Slides cap zoom at 1.4 and text re-rasterises in steps. Cull off-screen layers during flights, and measure on the 5k map.

## Non-goals (unchanged, plus)

- AI-written guide content (it could later use the on-device model).
- Video and animated-HTML export of the new motion.
- Collaborative presenting.
- New diagram engines (types the code doesn't have).
- A watched starter folder.
