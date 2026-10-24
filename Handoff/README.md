# OpenNexus: build handoff package

OpenNexus is an open-source, native **macOS 27** app for mind maps and technical diagrams. It matches Xmind's feature set and keyboard flow, then goes further with flowcharts, data flow diagrams, threat models, architecture and sequence diagrams, on-device AI, and a guided first run.

This package contains everything an AI coding agent (or a human team) needs to build v1:

- the product brief
- the full visual design: 52 artboards, as live HTML source and as screenshots
- design tokens
- an Xmind gap analysis
- text specs for each screen
- a step-by-step build plan with acceptance criteria

> **For the person handing this off:** unzip the package and give the agent the whole folder. Then paste the prompt in [§1](#1-the-agent-prompt) as its first message, or point it at `AGENT_PROMPT.md`, which holds the same text. Nothing else is needed.

---

## Contents

0. [Package map](#0-package-map)
1. [The agent prompt](#1-the-agent-prompt)
2. [How to read the design](#2-how-to-read-the-design)
3. [Product in one page](#3-product-in-one-page)
4. [Target platform and tech stack](#4-target-platform-and-tech-stack)
5. [Architecture](#5-architecture)
6. [Data model and the `.nexus` file format](#6-data-model-and-the-nexus-file-format)
7. [The keyboard model and command registry](#7-the-keyboard-model-and-command-registry)
8. [Visual system, themes, node styles, motion](#8-visual-system-themes-node-styles-motion)
9. [Screen and artboard index](#9-screen-and-artboard-index)
10. [Settings inventory](#10-settings-inventory)
11. [Build plan: milestones and acceptance criteria](#11-build-plan-milestones-and-acceptance-criteria)
12. [Quality bars: performance, accessibility, privacy](#12-quality-bars-performance-accessibility-privacy)
13. [Testing strategy](#13-testing-strategy)
14. [Known design gaps and prototype artefacts](#14-known-design-gaps-and-prototype-artefacts)
15. [Out of scope for v1](#15-out-of-scope-for-v1)
16. [Licences](#16-licences)

---

## 0. Package map

```
OpenNexus-Handoff/
├── README.md                    ← you are here (master instructions)
├── AGENT_PROMPT.md              ← copy-paste prompt for the coding agent
├── docs/
│   ├── 00-original-request.md   ← what the product owner asked the designer for
│   ├── 01-feature-brief.md      ← THE functional spec (≈48k chars). Highest authority.
│   ├── 02-xmind-gap-analysis.md ← 78 decisions from the 89-article Xmind user guide review
│   ├── design-tokens.json       ← colours, type, radii, spacing, motion, themes, node styles
│   └── screen-specs/NN-*.md     ← verbatim text of every artboard (labels, values, shortcuts)
├── screenshots/
│   ├── NN-<Artboard>.png        ← 52 retina PNGs (2×), numbered in canvas order
│   ├── prototype-states/        ← live prototype captured in all 9 node styles + 2 themes
│   └── contact-sheet.jpg        ← every artboard on one page
└── design/
    ├── index.html               ← open in a browser: clickable index of all artboards
    ├── source/*.dc.html         ← the 52 artboards as live, data-driven HTML
    ├── source/canvas.json       ← board positions, titles, row headings
    ├── source/support.js        ← viewer bootstrap (renders the templates with React)
    └── viewer/                  ← React UMD, template shim, fonts (offline-capable)
```

**If two sources disagree, follow this order of authority:**

1. `docs/01-feature-brief.md`. Its Decisions table is final.
2. The artboards. Rows H–K (review, settings, styling, new features) supersede older rows wherever they go deeper.
3. `docs/02-xmind-gap-analysis.md`.
4. `docs/design-tokens.json`.
5. This README's architecture suggestions. These are recommendations, and the agent may improve on them with a written rationale.

---

## 1. The agent prompt

The same text is in `AGENT_PROMPT.md`.

```text
You are the lead engineer building OpenNexus v1, an open-source native macOS 27 app for
mind maps and technical diagrams (Xmind-class keyboard flow + flowcharts, DFDs, threat
models, architecture and sequence diagrams + on-device AI).

Everything you need is in this folder. Before writing code:
  1. Read README.md end to end.
  2. Read docs/01-feature-brief.md end to end. It is the functional spec; its Decisions
     table is final.
  3. Skim docs/02-xmind-gap-analysis.md and docs/design-tokens.json.
  4. Open design/index.html in a browser (or look at screenshots/) to see all 52 artboards.
     For any screen you build, read its screenshot AND docs/screen-specs/NN-*.md AND, when
     you need exact values, design/source/<Name>.dc.html (the logic class lists the data).

Then work milestone by milestone through README §11. For each milestone:
  - Write a short plan (files, types, tests) in docs/plans/Mx.md before coding.
  - Build it. Match the artboards' layout, copy, spacing, shortcuts and states. Use native
    SwiftUI/AppKit controls for chrome; the custom canvas follows the design pixel-for-pixel.
  - Write the tests listed in README §13 for that milestone and make them pass.
  - Verify the milestone's acceptance criteria and record results in docs/plans/Mx.md.
  - Commit with a clear message. Do not start the next milestone with failing tests.

Non-negotiables:
  - Keyboard first: every action is a registered Command with a key path (README §7).
    Menus, palette, cheat sheet and Settings › Shortcuts are all generated from the registry.
  - Zero-latency typing: a new node with a live caret appears within 16 ms; layout animates
    after, never before, the user can type.
  - Local and owned: no network calls, telemetry or accounts. AI uses Apple on-device
    frameworks only (Foundation Models, Translation, Vision, NaturalLanguage, SpeechAnalyzer,
    Image Playground). Nothing leaves the Mac unless the user explicitly exports or shares.
    *Amended in M38 (D275):* the one exception is software update checks, off until the user
    turns them on, made by Sparkle's update service, not by the app, which still has no
    network entitlement.
  - Plain, documented, diff-friendly .nexus package format with a published JSON schema.
  - Accessibility: full VoiceOver tree for the canvas, Reduce Motion / Transparency honoured,
    colour never the only signal, WCAG AA for all themes (AAA for High Contrast).
  - No watermark on any export, ever.

When the design is silent or ambiguous, choose the option most consistent with the brief's
design north star, note it in docs/DECISIONS.md with a one-line rationale, and continue.
Only stop to ask the human when a choice is irreversible or contradicts the brief.

Out of scope for v1: collaboration, accounts, comments, Gantt/tasks, iPad/iPhone, plugin
marketplace UI, cloud AI. Design hooks for plugins, but do not build the marketplace.
```

---

## 2. How to read the design

### Screenshots

`screenshots/NN-Name.png` are 2× PNGs at the artboard's native size, mostly 1440×900 pt. Some boards are 1100–1300 pt tall, and the review board is 2400 pt. The `NN` prefix follows the canvas order in §9. `contact-sheet.jpg` shows all of them on one page.

### Live artboards

Open `design/index.html` in Chrome or Safari. Each card opens the artboard rendered from its source. Board **06 · P0 Live keyboard prototype** is fully interactive:

1. Click **Start typing**, then drive it with the keyboard: Tab, Return, arrows, Space, ⇧⌘L, ⌥⌘T, ⌥Space, ⌥⌘S.
2. Try **Sample map**, the **Classic / Graphite / Blueprint** theme buttons, and the **Style** menu.

It works offline from `file://`. Fonts are bundled, and Google Fonts are only used when online.

### Source format (`*.dc.html`)

Each artboard is plain HTML plus a small template language. You need this when extracting exact values.

- **`<x-dc>`** wraps the artboard. `<helmet>` holds its `<style>` and font `<link>`.
- **`{{a.b}}`** is a dotted lookup into the object returned by `renderVals()`. It is never an expression.
- **`<sc-for list="{{items}}" as="i">`** repeats its children. **`<sc-if value="{{flag}}">`** renders them conditionally.
- **`<script type="text/x-dc" data-dc-script>`** contains `class Component extends DCLogic { renderVals() {…} }`. The arrays and objects there are the data behind the screen: settings rows, shapes, shortcuts, menu items, style definitions.
- Event and lifecycle names follow React (`onKeyDown`, `componentDidMount`), because `support.js` renders with React 18.

### Text specs

`docs/screen-specs/NN-Name.md` holds each artboard's visible text in reading order. Grep these for any label, shortcut or default value.

### Example lookups

| Need | Look at |
| --- | --- |
| Exact CSS of each node style | `NodeStyles.dc.html` → `defs` array, and `Prototype.dc.html` → `styleLook()` |
| Keyboard behaviour that actually runs | `Prototype.dc.html` → `onKey`, `mkNode`, `layout` and connect / convert / AI methods |
| Settings rows and defaults | `Set*.dc.html` → `sec()` and the `T / S / G / R / B / K / I` row helpers (toggle, select, segmented, slider, button, keys, info) |

---

## 3. Product in one page

### What v1 must prove (from the brief)

1. A new user builds a **20-topic mind map in under 2 minutes without the mouse**.
2. The same keys (Tab, Return, arrows, Space) build a **flowchart, DFD and architecture diagram** with no mode lessons.
3. **Converting** a mind map to another diagram type is one animated, reversible action.
4. Local AI is a **quiet collaborator inside the canvas**, not a bolted-on chat.
5. The first five minutes **teach the keyboard by doing**.

### Design north star

- Keyboard first, mouse welcome.
- Zero-latency feel.
- Structure is automatic: auto-layout always, free layout opt-in per canvas.
- Beautiful by default.
- One model, many views.
- Motion explains change.
- Calm chrome.
- Local and owned.

### Feature pillars

Each pillar lists the artboards that show it.

- **Canvas and keyboard:** three always-visible states (SELECT, EDIT, CONNECT), Xmind's key map unchanged, plus Connect mode, Convert, a slash menu, a command palette (⌘K) and quick jump (⌘J). Artboards: 05, 06, P0, F2, F3, 07, 08.
- **Structures:**
  - Xmind's nine: Mind Map, Logic, Brace, Org, Tree, Timeline, Fishbone, Matrix, Tree Table. They can be mixed per branch.
  - Technical types: Flowchart and swimlane, DFD with trust boundaries and rule checks, Threat Model with STRIDE, Architecture with a 32-icon set, and Sequence.
  - Artboards: S4–S9, 09.
- **Elements:**
  - Relationships, boundaries, summaries, callouts, notes and links.
  - Markers, stickers, labels, numbering, to-dos and audio notes.
  - Zones and floating topics.
  - Artboards: 08, FMT-2, EN, ZN.
- **Styling:**
  - Twelve themes and a theme builder.
  - Nine node styles.
  - Format panel v2: Style, Map and Data tabs, quick styles, and copy, paste, reset and update of styles.
  - Artboards: 03, NS, FMT-1…3.
- **Views:** Outline, Split, ZEN, Focus, filters, a navigation panel (Search, Outline, Notes, Tags, To-dos), find and replace, and Present mode. Artboards: S12, Views, NAV, F6.
- **AI (on-device):**
  - Canvas AI: ghost suggestions (⌥Space), inline prompt (⇧⌘Space), the AI panel (⇧⌘J) with multiple chats, Discussion mode and depth settings, and work breakdown.
  - Apple frameworks: Translate, Data masking, Remove background, stickers via Image Playground, and Record to map.
  - Artboards: S13, AI+.
- **Files:**
  - `.nexus` packages with autosave, versions and recovery snapshots, plus encryption, merge and print.
  - Import from .xmind and many other formats; export to PNG, JPEG, SVG, PDF, Mermaid, PlantUML, Markdown, JSON/YAML, draw.io, OPML, Office/Keynote and CSV.
  - Map Shot.
  - Artboards: S14, FT, CX, Integration.
- **macOS integration:**
  - Quick Look and Spotlight.
  - App Intents and Shortcuts, Services and the Share extension.
  - Quick Capture, widgets, Handoff and iCloud Drive.
  - An opt-in local MCP server and the `nexus` CLI.
  - Artboards: Integration, SET-8.
- **First run:** Welcome, role picker, Home window, and a 5-lesson tutorial with the keycap coach. Artboards: S1, S2, F5.

---

## 4. Target platform and tech stack

| Area | Choice |
| --- | --- |
| OS | macOS 27 or later, **Apple silicon only**. The brief limits support to Macs that run Apple's on-device model. |
| Language | Swift 6 with strict concurrency |
| UI | SwiftUI for the app shell, settings, sheets, panels and palette. AppKit (`NSViewRepresentable`) where SwiftUI lacks control: the canvas, key handling, the menu bar, first-responder routing and Quick Capture `NSPanel`. |
| Canvas rendering | A custom layer-backed `NSView` with Core Animation (`CALayer` / `CAShapeLayer`). Text uses TextKit 2. Visible-rect culling is required, and Metal is optional if 5k-node targets need it. *Do not* build the canvas from SwiftUI views per node; it will miss the 16 ms and 120 fps targets. |
| Documents | `NSDocument` (or `ReferenceFileDocument`) with a **file package** (`.nexus`), autosave in place, versions (File › Revert To) and iCloud Drive |
| AI | `FoundationModels`: `LanguageModelSession`, `@Generable` guided generation and tool calling. Also `Translation`, `Vision` (subject lift, OCR), `NaturalLanguage` (entity tagging for masking), `SpeechAnalyzer` / `SpeechTranscriber` and `ImagePlayground`. |
| OS hooks | Quick Look Preview and Thumbnail extensions, `CoreSpotlight`, `AppIntents`, Share extension, Services, WidgetKit, Handoff (`NSUserActivity`) |
| CLI and MCP | A Swift `nexus` executable (ArgumentParser) sharing the core packages. `nexus mcp` runs a stdio MCP server. Both are off by default and enabled in Settings › Integrations. |
| Build | Xcode 27 with the macOS 27 SDK, an SPM workspace, and GitHub Actions CI (build, test, lint) |
| Licence | Permissive (Apache-2.0 or MIT; the product owner chooses) |

> Before using an API, check it against the macOS 27 SDK and Apple's current documentation. Some names above, especially in FoundationModels and SpeechAnalyzer, are recent. Do not guess signatures.

---

## 5. Architecture

Suggested Swift packages. Keep the core free of UI so the CLI, MCP server, Quick Look extension and tests can use it.

```
NexusCore      Graph model (Document, Canvas, Node, Edge, Element), IDs, styles-as-data,
               operations as reversible Commands, undo/redo (coalescing; Merge = one undo),
               selection model, rule engine hooks (DFD/threat checks). No AppKit.
NexusLayout    One engine per structure (mind map, logic, brace, org, tree, timeline,
               fishbone, matrix, tree table, flowchart, swimlane, sequence, free).
               Incremental: re-layout only the dirty subtree. Pure functions → frames.
NexusFormat    .nexus read/write, JSON Schema, migrations, stable key ordering, encryption
               (CryptoKit, password + Keychain), recovery snapshots.
NexusInterop   Importers (xmind, opml, md, mermaid, plantuml subset, drawio, freemind,
               mindmanager, edrawmind, docx, textbundle, indented text) and exporters (png,
               jpeg, svg, pdf, mermaid, plantuml, md, json/yaml, drawio, opml, docx, pptx,
               key, csv, video). Import report for anything lossy.
NexusTheme     Tokens, 12 themes, .nexustheme codec, 9 node styles, colour themes/palettes,
               contrast checker.
NexusKeys      Command registry, key map + profiles (OpenNexus/Xmind, Outliner, Vim),
               conflict detection, Hyper key, mode state machine (Select/Edit/Connect),
               hint-letter assignment for Connect mode.
NexusAI        Thin, testable wrappers around Apple frameworks; prompt templates; @Generable
               output types (Suggestions, Breakdown, Reorganize plan); availability states
               (Apple Intelligence off / model downloading / unsupported).
NexusCanvas    AppKit canvas view: rendering, hit testing, animation (springs per tokens),
               editing overlay, drag/drop, smart guides, zoom/pan, accessibility tree.
OpenNexusApp   SwiftUI app: windows, Home, tabs, sidebar/navigation panel, Format panel,
               palette, Present, Settings, onboarding, menus generated from NexusKeys.
Extensions     QuickLook, Spotlight, Share, Widgets, AppIntents, nexus CLI, MCP server.
```

### Principles

- **Every user action is a `Command`.** A command has an id, a title, a category, default key(s), a scope (canvas, editor, global), `isEnabled(context)` and `perform(context)`. The menu bar, command palette, ⌘-hold cheat sheet, Settings › Shortcuts and App Intents are all derived from the registry. Nothing is hand-wired twice.
- **One graph, many views.** Structure type is a property of a canvas or branch. Diagram conversion maps node *types* (topic → process, decision, data store, …) and re-runs layout. It is never a copy, and converting back must be lossless.
- **Styles are data.** A topic's effective style resolves in this order:
  1. node override
  2. quick style
  3. branch level
  4. node style preset
  5. theme
  6. defaults

  Keep this resolution pure and cached.
- **Typing never waits.** Insert the node at a provisional frame and focus the editor immediately. Run layout on the next tick, then animate everything else to the new positions. New input retargets in-flight springs.
- **Undo** covers every model change, including style, layout mode, conversion, AI accepts and merges.

---

## 6. Data model and the `.nexus` file format

### Package layout

The brief requires a text-first, diff-friendly, documented format with a published schema.

```
MyMap.nexus/                 (directory bundle, UTType com.opennexus.document conforms to com.apple.package)
├── manifest.json            { "format": "opennexus", "schemaVersion": 1, "app": "1.0", "canvases": ["c1","c2"], "encrypted": false }
├── canvases/c1.json         one file per canvas, keys sorted, 2-space indent, stable node order
├── canvases/c2.json
├── theme.json               document theme + custom colour themes / quick styles
├── assets/                  images, audio notes, stickers (content-hashed filenames)
└── snapshots/               recovery snapshots (excluded from Git by a generated .gitignore)
```

### Canvas JSON shape

This is a starting point; publish the final version as `schema/nexus.schema.json`.

```json
{
  "id": "c1", "title": "Launch plan", "type": "mindmap", "layout": { "mode": "auto", "structure": "mindmap.balanced" },
  "style": { "theme": "classic", "nodeStyle": "outline", "colorTheme": "rainbow", "palette": "classic" },
  "root": "n1",
  "nodes": {
    "n1": { "text": "Launch plan", "kind": "root", "children": ["n2","n3"] },
    "n2": { "text": "Positioning", "kind": "topic", "children": [], "folded": false,
            "markers": ["priority-1"], "labels": ["Q4"], "todo": { "done": false },
            "note": { "format": "md", "text": "…" }, "link": "https://…", "style": { "shape": "rounded" } }
  },
  "floating": [], "zones": [],
  "relationships": [ { "id": "r1", "from": "n2", "to": "n3", "label": "drives", "line": "curved", "ends": ["none","arrow"] } ],
  "boundaries": [], "summaries": [], "callouts": [],
  "diagram": { "nodeTypes": { "n3": "process" }, "trustZones": [], "threats": [] }
}
```

### Requirements

- Stable ordering is required: no random dictionary order and no floating-point noise in stored positions. Round to 0.5 pt.
- Unknown keys must round-trip unchanged, for forward compatibility.
- `nexus validate file.nexus` checks a file against the schema.
- Quick Look renders a thumbnail and preview from the manifest and the first canvas.
- Spotlight indexes topic text, notes and labels.

---

## 7. The keyboard model and command registry

The full tables are in brief §4 and on artboard **05 Keyboard**. The rules that matter most:

### Default key map

- Use **Xmind's key map, unchanged**: Tab adds a child, Return adds a sibling after, ⇧Return a sibling before, ⌘Return a parent, ⌥⌘Return a floating topic.
- **Typing over a selection replaces its text**, and **Space** edits while keeping the text.
- In Edit mode, the first Return commits, ⇧Return inserts a line break, and Tab commits and adds a child.

### Three states

- The states are **Select**, **Edit** and **Connect**. Esc always leads back to Select.
- The canvas state pill sits bottom-left and is always visible.
- The selection ring uses the state's colour: Iris for Select and Edit, Amber for Connect.

### Connect mode (⇧⌘L)

1. Other nodes dim, and hint chips (A S D F … AS) pop in nearest-first with a 40 ms stagger.
2. Type hint letters, part of a node's text, or use the arrows.
3. Return draws the edge and opens its label in Edit mode.
4. If nothing matches, "Create new node" is offered.
5. Esc cancels with nothing changed.

### Discoverability

- Holding ⌘ for 1 s shows a cheat sheet.
- Every menu and palette row shows its shortcut.
- The third time a user mouses to an action that has a key, a one-time toast names the key.

### Remapping (artboard 06)

- Shortcuts are searchable.
- Conflicts are detected per scope.
- Profiles: OpenNexus (Xmind-compatible), Outliner and Vim, plus an "Xmind" alias set (⌘R, ⌘⌫, ⌘;).
- The Raycast-style **Hyper key** is shown as ✦.
- Restore defaults is available.

### Shortcuts added in rows H–K

Register these and check them for conflicts:

| Key | Action | Artboard |
| --- | --- | --- |
| ⌥⌘S | Cycle node style (300 ms morph) | NS, P0 |
| ⌥⌘C / ⌥⌘V / ⌥⌘R | Copy / paste / reset style | FMT-1 |
| ⌃⌥1–8 | Apply quick style 1–8 | FMT-1 |
| ⌥⌘Z | Insert zone | ZN |
| ⌥⌘] / ⌥⌘[ | Bring to front / send to back (zones, floating) | ZN |
| ⌃⌘1–5 | Navigation panel tabs: Search, Outline, Notes, Tags, To-dos | NAV |
| ⌥↩ / ⌥⌘↩ | Replace / Replace all (in Find) | NAV |
| ⌃1–9 · ⇧⌘M | Markers · marker picker | EN |
| ⌘[ | Fly back after following a topic link | EN |
| ⌘T / ⌥⌘N | New canvas / new canvas from selected topic | FT |
| ⌃⌘M | Map Shot | CX |
| ⌃⌘C | Copy selection or branch as image | CX, brief |
| ✦ N | Quick Capture (global, Hyper) | SET-8 |

Two clashes were already resolved during design:

- The navigation tabs use ⌃⌘, because ⌥⌘1–9 changes branch structure.
- "New canvas from topic" uses ⌥⌘N, because ⇧⌘T is Label.

Keep the conflict checker strict so new clashes fail CI. A unit test should assert that no two commands in the same scope share a key in any profile.

---

## 8. Visual system, themes, node styles, motion

The values are in `docs/design-tokens.json`. The artboards are **02 System**, **03 Themes**, **04 Motion**, **07 Nodes**, **08 Elements** and **NS Node styles**.

### Look

- The visual language is "Luminous Graphite": an opaque, content-first canvas with Liquid Glass only on floating chrome (toolbar, palette, HUDs, prompt bar).
- Glass never sits behind node text.
- Reduce Transparency swaps glass for opaque surfaces.

### Signal colours

| Colour | Light | Dark | Role |
| --- | --- | --- | --- |
| Iris | #5850EC | #8F89FF | Select and Edit |
| Amber | #F2B135 | #F2B135 | Connect. Ink text only, never white text. |
| Aurora | #0F9F9A | #3FD3C9 | AI |

### Themes

- 12 ship, each with light and dark variants designed together.
- Classic, Graphite, Blueprint and High Contrast are required first.
- The theme builder exports `.nexustheme` and checks contrast live.
- The colour mode depends on the diagram type: by branch for mind maps, by node type for DFD and architecture, by risk for threat models.

### Node styles (9)

Outline (default), Soft, Solid, Underline, Capsule, Sketch, Brutal, Glow and Minimal.

- Each style is independent of the theme, which supplies colour, and the structure, which supplies layout.
- Pick a style in **Format › Map › Node style**, from the palette, or cycle with **⌥⌘S**.
- Each preset defines root, main and sub looks plus branch-line character: curved, elbow (Brutal), dotted (Minimal) or glowing (Glow).
- Implement presets as data. Users can save a modified preset as a custom style.
- See `screenshots/43-NodeStyles.png` and `screenshots/prototype-states/`.

### Motion

- Use the springs `snap` (0.28 / 0.80) and `settle` (0.36 / 0.68), and the curves `glide` (.65, 0, .35, 1) and `exit` (.4, 0, 1, 1).
- Each moment has a duration and a Reduce Motion fallback: create 180 ms, delete 160 ms, reorder 250 ms, fold 220 ms, reflow 300 ms, structure change 450–600 ms, convert 600 ms, connect 300 ms, focus 400 ms, present step 500 ms, AI ghost 250 ms each.
- With Reduce Motion on, all of these become a 150 ms cross-fade.

---

## 9. Screen and artboard index

Screenshot names are `screenshots/NN-<File>.png`. Specs are `docs/screen-specs/NN-<File>.md`. Sources are `design/source/<File>.dc.html`.

### A · Foundations

| # | Artboard | What it specifies |
| --- | --- | --- |
| 01 | 00 · OpenNexus overview (`Main`) | Product positioning, pillars |
| 02 | 01 · Brand (`Brand`) | The Aperture mark, lockups and app icon; the spec is `brand/BRAND.md` |
| 03 | 02 · Visual system & tokens (`System`) | Colours, type, materials, radii, spacing, elevation, state pill |
| 04 | 03 · Theme sheet & builder (`Themes`) | 4 required themes on one map; theme builder; launch set of 12 |
| 05 | 04 · Motion spec (`Motion`) | Curves, durations, Reduce Motion fallbacks for every moment |

### B · Keyboard

| # | Artboard | What it specifies |
| --- | --- | --- |
| 06 | P0 · Live keyboard prototype (`Prototype`) | Interactive F1–F4 and node styles. The reference for feel. |
| 07 | 05 · Keyboard model (`Keyboard`) | States, Connect mode, discoverability, full key map |
| 08 | 06 · Settings › Shortcuts (`Shortcuts`) | Remapping, profiles, conflicts, Hyper key (= SET-6) |
| 09 | F2 · Connect mode flow (`ConnectFlow`) | Step-by-step Connect states |
| 10 | F3 · Convert diagram type (`Convert`) | ⌥⌘T picker with live previews; mapping; reversibility |

### C · Components

| # | Artboard | What it specifies |
| --- | --- | --- |
| 11 | 07 · Node component (`Nodes`) | Anatomy, roles, every state |
| 12 | 08 · Edges & elements (`Elements`) | Relationships, boundaries, summaries, callouts, notes, etc. |
| 13 | 09 · Technical icon set (`Icons`) | 32 icons on a 24-pt grid (SF Symbols style) |

### D · Screens: first run and mind maps

| # | Artboard | What it specifies |
| --- | --- | --- |
| 14 | S1 · Welcome sheet (`Welcome`) | Dark welcome |
| 15 | S1 · Role picker (`RolePicker`) | Light role picker, which filters templates |
| 16 | S2 · Home window (`Home`) | Recents, templates, new-document type picker |
| 17 | S3 · Mind map canvas (`Canvas`) | Select, Edit, multi-select, folded, drop targets |
| 18 | S4 · Other structures (`Structures`) | Logic, Org, Timeline, Fishbone, Matrix, … |

### E · Screens: technical diagrams

| # | Artboard | What it specifies |
| --- | --- | --- |
| 19 | S5 · Flowchart & swimlane (`Flowchart`) | Decisions with Yes/No branches, lanes |
| 20 | S6 · Data flow diagram (`DFD`) | Trust boundaries, rule-violation state |
| 21 | S7 · Threat model (`ThreatModel`) | STRIDE, threat table, inspector checklist |
| 22 | S8 · Architecture (`Architecture`) | Icon library, VPC and subnet boundaries, protocol labels |
| 23 | S9 · Sequence (`Sequence`) | Lifelines, messages, returns |

### F · Screens: panels, views, AI, export

| # | Artboard | What it specifies |
| --- | --- | --- |
| 24 | S10 · Inspector overview (`Inspector`) | Superseded in detail by FMT-1…3 |
| 25 | S11 · Command palette (`Palette`) | ⌘K and ⌘J with results and key hints |
| 26 | S12 · Outline & Split (`Split`) | Live-linked selection |
| 27 | Views · ZEN, Focus, filter (`Views`) | ZEN, Focus and the filter bar |
| 28 | S13 · Local AI in canvas (`AI`) | Ghosts, prompt bar, AI panel |
| 29 | S13 · AI settings (`AISettings`) | Model picker, privacy, Apple Intelligence off (= SET-5) |
| 30 | S14 · Export sheet (`Export`) | PNG, SVG and Mermaid with live preview |

### G · Flows

| # | Artboard | What it specifies |
| --- | --- | --- |
| 31 | F5 · Tutorial & keycap coach (`Tutorial`) | Lessons 1–5 |
| 32 | F6 · Present mode (`Present`) | DFD stepping, slide strip, presenter view |
| 33 | macOS 27 integration & import (`Integration`) | Quick Capture, widgets, Quick Look, Shortcuts, `nexus` CLI, import list |

### H · Review

| # | Artboard | What it specifies |
| --- | --- | --- |
| 34 | R · Xmind user guide review (`Review`) | 78 decisions. See `docs/02-xmind-gap-analysis.md`. |

### I · Settings

| # | Artboard | What it specifies |
| --- | --- | --- |
| 35 | SET-1 · General (`SetGeneral`) | See §10 |
| 36 | SET-2 · Editing (`SetEditing`) | |
| 37 | SET-3 · Appearance (`SetAppearance`) | |
| 38 | SET-4 · Files & Backup (`SetFiles`) | |
| 39 | SET-7 · Export defaults (`SetExport`) | |
| 40 | SET-8 · Integrations (`SetIntegrations`) | |
| 41 | SET-9 · Privacy & Data (`SetPrivacy`) | |
| 42 | SET-10 · Accessibility (`SetAccessibility`) | |

### J · Styling

| # | Artboard | What it specifies |
| --- | --- | --- |
| 43 | NS · Node styles (`NodeStyles`) | 9 presets on the same map |
| 44 | FMT-1 · Format › Topic (`FormatTopic`) | Quick styles; style actions; structure; 32 shapes; fill; border; text; numbering; size; branch line; spacing; Update Style |
| 45 | FMT-2 · Format › Elements (`FormatElements`) | Relationship (4 lines, 11 end caps), boundary (9 shapes, meaning, trust), callout, summary, zone |
| 46 | FMT-3 · Format › Map (`FormatMap`) | Skeletons, node style, colour themes and palettes, canvas, map style, advanced layout, custom colour theme |

### K · New and enhanced features

| # | Artboard | What it specifies |
| --- | --- | --- |
| 47 | NAV · Navigation & find (`Navigation`) | Panel tabs, find and replace, highlights, counts |
| 48 | EN · Enrich topics (`Enrich`) | Markers, stickers, labels, numbering, to-dos, links and backlinks, audio, floating toolbars |
| 49 | ZN · Zones (`Zones`) | Zones, floating topics, smart guides, z-order |
| 50 | FT · File tools (`FileTools`) | Merge, encrypt, canvas tab menu, print and tiling |
| 51 | CX · Map Shot (`CaptureExport`) | Capture overlay, frames, split by branch, branch export |
| 52 | AI+ · New AI actions (`AIPlus`) | Multi-chat, breakdown, translate, masking, background removal, stickers, record to map |

Settings panes 5 (AI) and 6 (Shortcuts) are artboards 29 and 08. Together with the eight SET boards, that makes the full set of **10 panes**.

---

## 10. Settings inventory

The sidebar lists these panes in this order, with the icon tint shown. Every row, its control type and its default are on the artboards. Generate the panes from a declarative schema, mirroring the `sec()` / `T S G R B K I` helpers in the sources, so the search field in Settings can find every row.

| # | Pane | Tint | Sections, as designed |
| --- | --- | --- | --- |
| 1 | General | #8E8E96 | App, Writing, Updates, Help & tips, About |
| 2 | Editing | #1E8BE0 | Typing, Layout & guides, Mouse & trackpad, New documents (incl. "use last skeleton & colour theme") |
| 3 | Appearance | #D6408B | Default look (theme grid, node style), Theme, Canvas, Motion & effects, ZEN & chrome |
| 4 | Files & Backup | #E08A00 | Saving (autosave), File format, Recovery (snapshots), Security |
| 5 | AI | #0F7F7A | Model, privacy, AI panel depth (Quick / Balanced / Deep), Discussion mode default, Image Playground and Translation, "Apple Intelligence off" state |
| 6 | Shortcuts | #5850EC | Profiles, search, conflicts, Hyper key, restore defaults |
| 7 | Export | #C25E00 | 6 image frames (None, Soft shadow, Window, Gradient mat, Paper, Dark mat), Images, PDF & print, Text & structure, watermark fixed at **Never** |
| 8 | Integrations | #7A4CC2 | Quick Capture (✦N), macOS (Services, Share, Widgets, Spotlight, Quick Look), Agents: MCP & CLI (off by default; shows `nexus mcp` config) |
| 9 | Privacy & Data | #17171C | Network activity (expected: none), Diagnostics (opt-in, local), AI data, Data masking |
| 10 | Accessibility | #1E6FB8 | Vision, Motion & transparency, VoiceOver, Keyboard |

---

## 11. Build plan: milestones and acceptance criteria

Work in order. Each milestone ends with green tests, a short demo note in `docs/plans/Mx.md`, and a commit.

### M0 · Foundations

- **Build:**
  - Repo, SPM packages, CI, lint (SwiftLint / swift-format) and licence.
  - `NexusCore` model with the undo stack.
  - `NexusFormat` read/write and the JSON schema.
  - Tokens imported from `design-tokens.json` into `NexusTheme`.
  - `NexusKeys` registry skeleton.
- **Accept when:**
  - Round-trip tests pass: load, save and diff give byte-identical output.
  - The schema validates sample files.
  - CI is green.

### M1 · Canvas and keyboard core (F1)

- **Build:**
  - The AppKit canvas with Select and Edit modes and the state pill.
  - Create, edit, navigate and restructure keys from §7 and the brief.
  - Mind-map and logic-chart auto-layout.
  - Fold, undo and autosave.
  - The ⌘-hold cheat sheet and the toolbar.
  - The document window shell, styled after P0.
- **Accept when:**
  - Matches screenshots 06 and 17.
  - A scripted UI test builds a 20-topic, 3-level map using only keys.
  - Key-to-caret time is under 16 ms (signposts).
  - A 1,000-node reflow takes under 50 ms.
  - Typing is never blocked by animation.

### M2 · Styling

- **Build:**
  - The 12 themes and the theme builder.
  - The 9 node styles with ⌥⌘S cycling.
  - Format panel tabs (Style, Map, Data) with every control on FMT-1…3.
  - Quick styles, and copy, paste, reset and update of styles.
  - Smart Color (⇧⌘R).
  - The custom colour theme editor with the contrast check.
- **Accept when:**
  - Snapshot tests render the NS sample map in all 9 styles × 4 required themes.
  - The contrast checker passes AA for all themes and AAA for High Contrast.

### M3 · Elements and Connect (F2)

- **Build:**
  - Connect mode, with hint assignment, filter, create-new and labelling.
  - Relationships with every line shape and end cap.
  - Boundaries (with meaning and trust level), summaries, callouts and notes.
  - Links and backlinks, markers, stickers, labels, numbering, to-dos and audio notes.
  - Zones and floating topics with smart guides and z-order.
- **Accept when:**
  - Matches 09, 12, 45, 48 and 49.
  - The Connect UI test covers both the hint path and the text-filter path.
  - Esc leaves the model unchanged.

### M4 · Structures and technical diagrams (F3)

- **Build:**
  - All 9 Xmind structures, mixed per branch (⌥⌘1–9).
  - Flowchart and swimlane, DFD with the trust-boundary rule engine, threat model with STRIDE and the CSV threat table, architecture with the icon set and VPC/subnet boundaries, and sequence.
  - Convert (⌥⌘T) with live previews and the 600 ms morph.
  - The slash menu.
- **Accept when:**
  - Matches 18–23 and 10.
  - Converting map → flowchart → DFD → map is lossless (property test).
  - DFD rule violations show the shake and a badge.

### M5 · Views and navigation

- **Build:**
  - The ⌘K command palette (generated from the registry) and ⌘J quick jump.
  - Outline and Split views with live-linked selection.
  - ZEN, Focus (⌘.) and the filter bar.
  - The navigation panel (⌃⌘1–5), find and replace (regex, scope), and counts.
  - Present mode (F6): auto slides, H to hide a topic, a choice of aspect ratios (16:9 by default), a slide theme picker, a ? key list, presenter view, and export as PDF, Keynote, PowerPoint or video.
- **Accept when:** matches 25–27, 32 and 47.

### M6 · On-device AI (F4 and AI+)

- **Build:**
  - Ghost suggestions (⌥Space; ⌃↩ accepts one, ⌃⇧↩ accepts all).
  - The prompt bar (⇧⌘Space).
  - The AI panel (⇧⌘J): multiple chats, depth, Discussion mode, and a plan-of-changes diff before applying.
  - Work breakdown and AI to-dos.
  - Translate map, data masking, remove image background, make a sticker, and record to map.
  - Availability states: Apple Intelligence off, model downloading, unsupported.
- **Accept when:**
  - Matches 28, 29 and 52.
  - The first ghost appears in under 1.5 s on Apple silicon.
  - The network monitor shows zero outbound connections.
  - Every AI change is a single undo.

### M7 · Files, import and export

- **Build:**
  - The export sheet (⇧⌘E) with live preview for every format in brief §11.
  - The import list on artboard 33, plus the import report.
  - Paste of Markdown or indented text creating a branch.
  - Map Shot (⌃⌘M), split by branch, and branch export.
  - Print with tiling.
  - Merge documents.
  - Encryption with Keychain.
  - Recovery snapshots and Revert To.
- **Accept when:**
  - Matches 30, 50 and 51.
  - Golden-file tests pass for each importer and exporter.
  - A corpus of real `.xmind` files imports with a report and no crashes.
  - No watermark appears anywhere.

### M8 · Settings, Home and onboarding

- **Build:**
  - All 10 Settings panes, with search.
  - The Home window: recents, the template shelf filtered by role, and the new-document type picker.
  - Welcome, the role picker, and the tutorial (F5, 5 lessons) with the keycap coach.
  - Tips, plus the toast shown the third time a user reaches for the mouse.
- **Accept when:**
  - Matches 08, 14–16, 29, 31 and 35–42.
  - Every setting persists and takes effect live.

### M9 · macOS integration

- **Build:**
  - Quick Look thumbnail and preview, and Spotlight indexing.
  - App Intents (create from clipboard, export as PNG, add to inbox).
  - Services and the Share extension, including the Safari clipper.
  - Quick Capture as a global ✦N glass panel.
  - Widgets.
  - Handoff.
  - The `nexus` CLI and MCP server (opt-in, stdio, local files only).
- **Accept when:**
  - Matches 33 and 40.
  - The intents appear in Shortcuts.
  - `nexus export`, `nexus validate` and `nexus mcp` work, and their tests pass.

### M10 · Hardening

- **Build:**
  - The VoiceOver canvas tree, read as "Topic, level 2, 3 children, collapsed".
  - Dynamic Type for chrome.
  - Full keyboard reachability.
  - Performance passes against the 5k-node, 120 fps target.
  - Localisation scaffolding.
  - Crash-free fuzzing of the file loader.
- **Accept when:**
  - Every row in §12 is met and recorded.
  - An accessibility audit with Accessibility Inspector reports no issues.

The milestones below came after the handoff: an Xmind parity review (M11–M22), checks against real Xmind files and the gaps they found (M23–M36), release packaging (M37) and software updates (M38). Each one's plan, results and known gaps are in `docs/plans/Mx.md`, and its decisions in `docs/DECISIONS.md`.

### M11 · Task planning

- **Build:**
  - Task fields on a topic: start, due, owner, progress and priority.
  - Dependencies of all four kinds, with a lag.
  - A Gantt view of the canvas (⌘4) that skips non-working days.
  - Gantt export as PNG, JPEG and PDF, and task export as CSV and ICS.
  - Xmind task import (Zen and XMind 8).
- **Accept when:**
  - Task fields and dependencies round-trip byte-identically, and files without them are written as before.
  - Every task field can be set from the keyboard, each edit one undo step, and no dependency cycle can be made.
  - ICS output follows RFC 5545 and opens in Calendar.
  - A 1,000-task Gantt lays out in under 50 ms.

### M12 · Image to map

- **Build:** a picture, screenshot or PDF page becomes an editable map on this Mac: Vision for the text, layout rules (Apple Intelligence optional) for the hierarchy.
- **Accept when:**
  - Imports work from File › Import…, a drop and a paste.
  - Indented lists, mind-map screenshots and column posters rebuild their hierarchy.
  - The import report shows, and adding to an open document is one undo step.

### M13 · Zone and Excel export

- **Build:** Export Zone… and Print Zone…, and Excel (.xlsx) export.
- **Accept when:**
  - A zone exports as PNG, JPEG, SVG and PDF, cropped to it, and prints.
  - The workbook has one sheet per canvas, with rows in outline order.

### M14 · Comments and legends

- **Build:** comment threads on topics and a movable map legend with marker descriptions, both imported from Xmind.
- **Accept when:**
  - Both are optional in the file and round-trip.
  - Comments are added, edited and deleted with undo, shown as a badge, and found by the Notes tab, filters and VoiceOver.
  - The legend is drawn in exports.

### M15 · Export to Xmind

- **Build:** a modern Xmind (Zen) file from `.nexus`, from the export sheet and `nexus export --to xmind`.
- **Accept when:**
  - Topics, structure, notes, labels, markers, relationships, boundaries, summaries, images, comments, legends and tasks survive OpenNexus → .xmind → OpenNexus.
  - What doesn't survive is listed in an export report.

### M16 · Zone relationships

- **Build:** relationships that end on a zone, as in Xmind 26.03.
- **Accept when:** they draw from Connect mode, survive save, load and undo, render in every export, and import from Xmind.

### M17 · Canvas context menus

- **Build:** right-click menus on topics, selections, relationships, boundaries, summaries, callouts, zones, images, the legend and empty canvas, built from the command registry.
- **Accept when:**
  - A menu shows only what can run.
  - Each item does exactly what its command does.
  - VoiceOver reaches the same actions.

### M18 · Element ends, styles and XMind 8

- **Build:**
  - Relationships that end on boundaries, summaries and callouts.
  - `.xmind` export of themes and topic styles.
  - XMind 8 export.
- **Accept when:**
  - The new ends survive every format and VoiceOver names them.
  - Styles go to Xmind and come back.
  - XMind 8 files round-trip, and every archive part parses.

### M19 · Image to map, continued

- **Build:**
  - Every PDF page, read off the main thread with progress.
  - Fishbone diagrams, connector tracing, unwrapped lowercase lines, right-to-left and vertical text.
- **Accept when:** the image bench reads each layout, including one real-Vision fishbone.

### M20 · Zone gaps

- **Build:** export every zone at once, and copy, cut, paste and duplicate zones.
- **Accept when:**
  - Each zone exports as its own file, or as PDF pages.
  - A copied zone carries its topics and relationships to any canvas or document.

### M21 · Present and legend gaps

- **Build:**
  - The legend in Present and its exports.
  - Task lines and Timeline slides.
  - Moving the legend from the keyboard and VoiceOver.
- **Accept when:** every action is a registry command with a key, and the format additions are optional and round-trip.

### M22 · Tasks and comments in formats and agents

- **Build:**
  - Tasks and comments in Markdown, OPML, MindManager import and Excel.
  - The same in `nexus` and the MCP tools.
  - Dates on AI work breakdowns.
- **Accept when:** each format round-trips tasks and comments exactly, and agent edits are marked as AI and need edit access.

### M23 · Real Xmind files

- **Build:**
  - Checks against two real Xmind 26 maps.
  - Imported themes: the sheet background, branch colours and topic-class styles carried on the canvas (`style.colors`, `style.roles`).
  - The env-gated `XmindRealFileTests` harness.
- **Accept when:**
  - Every topic imports at its path, with its folds and markers.
  - The import looks like Xmind's own thumbnail.
  - `.xmind` and XMind 8 round trips keep the outline and the look.

### M24 · Fold from the mouse

- **Build:** a "−" fold control on hover where a branch leaves its topic; the "+N" badge unfolds on click. The structure picker's names now come from the structures they apply (D216).
- **Accept when:**
  - Folding is one undo step, and a selection inside the branch moves to the topic.
  - There's no control on the central topic or leaves, or outside Select mode.

### M25 · Xmind style fidelity

- **Build:**
  - Boundary and summary styles in `.xmind` and XMind 8.
  - Level styles, quick styles and branch colours that survive a round trip.
  - Theme element classes imported.
- **Accept when:**
  - Each round-trips in Xmind's own keys.
  - An edit made in Xmind wins over OpenNexus's record.
  - Files without the record import as before.

### M26 · Context menu gaps

- **Build:**
  - Paste and New Zone at the right-clicked point.
  - Context menus in the outline and the Gantt.
- **Accept when:**
  - ⌘V and ⌥⌘Z are unchanged.
  - Every menu item equals its key.
  - VoiceOver reaches the menus.

### M27 · Zone gaps, part 2

- **Build:**
  - Branch and zone scopes for `nexus export` and the MCP `export` tool.
  - Several zones selected and copied at once.
  - Callouts in copy and paste.
  - A safe "same canvas" check for topic paste.
- **Accept when:**
  - Scoped files match the app's export.
  - Groups copy, cut, duplicate, delete and drag together.
  - Callouts get fresh ids.

### M28 · Present legend fit

- **Build:**
  - Slides framed around the corner legend.
  - A per-slide legend.
  - Timeline slides for flow and message diagrams.
- **Accept when:** no framed topic is under the legend on screen or in exports, and each slide lists only its own markers.

### M29 · Image import and Markdown tasks

- **Build:**
  - Fishbone sub-causes in image import.
  - Page progress with Cancel for File › Import… of a long PDF.
  - Floating topics' tasks in Markdown.
- **Accept when:**
  - The image bench still passes.
  - Cancel opens nothing.
  - Floating tasks round-trip exactly.

### M30 · Fishbone sub-causes

- **Build:** fishbone causes that make room for their sub-causes.
- **Accept when:**
  - No two topics come within 4 pt of each other.
  - Sub-causes stay clear of their bone.
  - OpenNexus's own fishbone export reads back through image import.

### M31 · Xmind remaining gaps

- **Build:**
  - Xmind data OpenNexus doesn't use (Pitch settings, unknown keys and extensions, layer order) kept and written back.
  - XMind 8 themes.
  - Xmind's important, minor and expired topics.
  - Canvas-level boundary, summary and relationship defaults.
  - Eighth-step progress markers.
- **Accept when:**
  - Re-saving an Xmind file through OpenNexus keeps what Xmind wrote.
  - Each mapping round-trips exactly in `.xmind` and XMind 8.

### M32 · Xmind's timeline and the fold control

- **Build:**
  - "Timeline (alternating)": Xmind's horizontal timeline, with branches above and below the axis.
  - The fold control on the point where a branch line leaves its topic, in every structure.
- **Accept when:**
  - Xmind timelines import and export as alternating.
  - The layout has no overlaps on either side.
  - The "−" and "+N" sit on the drawn line's start.

### M33 · Menu and outline gaps

- **Build:**
  - An image pasted from the empty-canvas menu becomes a floating topic.
  - Popovers open on outline rows (and Gantt rows).
  - Outline rows get VoiceOver actions.
  - Singular-aware counts in `nexus validate`.
- **Accept when:**
  - Each item works from its menu and key, one undo step each.
  - VoiceOver's actions equal the menu.

### M34 · Zone selection, part 3

- **Build:**
  - A rubber band around whole zones selects them.
  - Arrange and the Format panel act on a group of zones.
  - VoiceOver zone elements and a Zones rotor.
  - Duplicate Branch carries callouts.
- **Accept when:**
  - A band that only crosses a zone still selects its topics.
  - Mixed values show as mixed.
  - Each change is one undo step.

### M35 · Present, part 3

- **Build:**
  - An opaque legend card.
  - Timeline slides framed below their chart.
  - Progress dots that never meet the legend.
  - The strip reachable from the keyboard and VoiceOver.
- **Accept when:**
  - No framed content is under the legend or the chart, on screen or in exports, at any window width.

### M36 · Fishbone ribs and image import

- **Build:**
  - Fishbone sub-causes on their own small ribs, as Xmind draws them.
  - Image import that reads ribs, lower-bone sub-causes and wrapped sub-causes.
  - The import window, with a "Grouping…" phase and Cancel, for single pictures too.
- **Accept when:**
  - No fishbone topic touches another or its bone.
  - OpenNexus's own fishbone exports, wrapped sub-causes included, read back exactly.
  - The image bench still passes.

### M37 · Release packaging

- **Build:**
  - `App/tools/release.sh`: a Developer ID–signed Release archive, signature checks, and a signed DMG.
  - Notarization and stapling when a notarytool profile exists.
  - Install docs in the README.
- **Accept when:**
  - Every signed part passes the checks.
  - The DMG installs on another Mac running macOS 27.
  - The full suite, lint and the app build pass on the released commit.

### M38 · Software updates

- **Build:**
  - Opt-in updates through Sparkle: Check for Updates…, the Settings › General › Updates rows (check, install, channel) and a feed of every release (`appcast.xml`).
  - EdDSA-signed updates.
  - `App/tools/publish.sh`.
- **Accept when:**
  - Nothing is fetched until the user turns checks on or chooses Check for Updates.
  - The app keeps no network entitlement.
  - A signed update installs on quit, and a wrongly signed one is refused.

---

## 12. Quality bars: performance, accessibility, privacy

| Measure | Target |
| --- | --- |
| Key press to new node with live caret | < 16 ms |
| Layout reflow, 1,000 nodes | < 50 ms |
| Pan and zoom with 5,000 nodes | 120 fps on ProMotion |
| Open a 1,000-node document | < 1 s |
| First AI ghost suggestion | < 1.5 s |
| Network traffic with default settings | none (update checks are opt-in, D275) |
| Theme contrast | AA for all themes, AAA for High Contrast |

Measure with `os_signpost` and XCTest performance tests. Keep a `Benchmarks/` folder with generated 1k and 5k maps.

### Accessibility

- VoiceOver works on the canvas, and Connect mode announces targets.
- Reduce Motion and Reduce Transparency are honoured everywhere.
- Colour is never the only signal. Node types carry shape and badge; trust levels carry patterns.
- Every control has a label.

### Privacy

- There are no accounts, analytics SDKs or cloud calls.
- Diagnostics are opt-in and stay local until the user shares them.
- Data masking runs before any export or share when it is enabled.

---

## 13. Testing strategy

| Layer | Tests |
| --- | --- |
| NexusCore | Command do/undo symmetry (property-based), selection, conversion round trips |
| NexusLayout | Golden frames per structure; incremental equals full layout; performance tests |
| NexusFormat | Byte-stable round trip, schema validation, migration, encryption, unknown-key passthrough, fuzzing |
| NexusInterop | Golden files per importer and exporter; an `.xmind` corpus; the import report |
| NexusKeys | No conflicts per scope and profile; hint assignment is nearest-first and unique; mode transitions |
| NexusTheme | Contrast per theme; style resolution order; `.nexustheme` codec |
| NexusAI | Mocked sessions; `@Generable` decoding; availability states; never called when AI is off |
| UI (XCUITest) | F1, keyboard-only 20 topics; F2, Connect; F3, convert and back; F4, AI accept and accept-all; F5, tutorial; F6, present |
| Visual | Snapshot tests of key screens against `screenshots/`, light and dark, with tolerance |

---

## 14. Known design gaps and prototype artefacts

These are artefacts of the HTML prototype, not design intent. Do not copy them.

- In P0, a sub-topic can wrap mid-word after switching to a heavier node style, for example "Team / s" in Brutal (`prototype-states/P0-sample-map-brutal.png`). The prototype measures text before the style's font weight applies. The real app must measure with the final style.
- In P0, a relationship label chip ("drives") can sit on top of the root node. Route label chips to the edge midpoint and avoid overlapping nodes.
- The prototype's AI suggestions are canned strings. The real app calls Foundation Models.

These areas are under-specified. Decide, then record the decision in `docs/DECISIONS.md`:

- The exact rule set for the DFD and threat checks beyond what artboards 20 and 21 show.
- Video export codec and settings.
- The full 24-skeleton gallery. FMT-3 shows 9; derive the rest from structures × node styles × colour themes.
- Vim-profile key bindings beyond the basics.
- Localisation languages for v1 (suggest English first, with the strings pipeline ready).

---

## 15. Out of scope for v1

- Real-time collaboration, accounts, sign-in, comments, teams and SSO
- Gantt, task assignment and non-working days
- iPad and iPhone apps
- Plugin marketplace UI. Design the plugin hooks only: node types, icon packs, exporters, layouts and AI actions.
- Cloud AI models, Private Cloud Compute, AI credits and reasoning streams
- A cloud community gallery. The gallery installs from a file or URL only.

---

## 16. Licences

- **This design package:** © 2026 Jerry Voelker, provided for building OpenNexus.
- **Bundled viewer fonts** (in `design/viewer/fonts`): Geist, Geist Mono, Bricolage Grotesque, Newsreader and Kalam, all under the SIL Open Font License 1.1. They are used for viewing the design only; the app itself uses system fonts. If the Sketch node style ships with Kalam, include its OFL licence.
- **Bundled React 18.3.1 UMD** (in `design/viewer/lib`): MIT licence, included.
