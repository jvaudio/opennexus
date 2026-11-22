# Handoff audit · 2026-11-21

The app checked against the 44 artboards in `Handoff/screenshots` (01–44), on `main` at
`69e0afd`, after the brand audit in [brand-aperture.md](brand-aperture.md).

## How it was checked

- **Renders.** The package's snapshot suites (`*SnapshotTests`, gated on
  `NEXUS_SNAPSHOT_DIR`) render 120-odd screens, plus a temporary suite for 04, 09, 17 and 24
  that the suites don't cover. They were captured off-screen, without the window server, so
  nothing showed on the screen: the canvas's scene layer drawn by `CALayer.render(in:)`, then
  the SwiftUI and AppKit views over it with `cacheDisplay`. That route can't show glass and
  vibrancy, the toggles' tint, the app catalog's images (the accent colour falls back to
  system blue) or the window's toolbar, which lives in `App/OpenNexus`; those were compared
  in code. A first pass drew the canvas upside down; findings that came from that (a kicker
  over a title, an underline above its text, child order) were checked again and dropped.
- **Comparison.** Each artboard against its render, its text spec in
  `Handoff/docs/screen-specs`, its source in `Handoff/design/source`, the tokens and the code.
  A difference that `docs/DECISIONS.md` or a milestone plan records is not a finding.
- **Not compared:** 01 (cover), 02 (brand, covered by the brand audit), 06 (the interactive
  prototype) and 34 (the Xmind review, a list of decisions).

## Fixed

| Artboard | What differed | Now |
| --- | --- | --- |
| 30 Export | The format list (now with Xmind, tasks and calendar) set the sheet's height, so the sheet ran off the window and its footer, Copy / Cancel / Export…, couldn't be reached | The preview and options set the height; the formats scroll beside them (`FileViews.swift`) |
| 35–42 Settings | On the Mac, a row whose subtitle was longer than one line beside its control put the control under the title, at the left (Privacy's network rows, Comment author, Watermark) | `TrailingControl` keeps the control trailing and wraps the title beside it; it stacks only when the control would take more than 55% of the row |
| 36, 37, 42 Settings | Defaults that differ from the artboards, with no decision: alignment guides, "Use last skeleton…", ZEN appearance Dark, "Today" timer, toolbar Icons + text, Speak shortcut hints | As the artboards |
| 36 Editing | "Space" showed "Edit, keep text" as a trailing value | It's the subtitle, as on the artboard |
| 38 Files | Autosave repeated "Always on" as a trailing value | Removed; the subtitle says it |
| 41 Privacy | "…Check for Updates…." (two full stops) | One |
| 33 Integration | The import report's last line left out pictures and PDFs, which import through AI | "…indented text, and images or PDFs via AI." |
| 29 AI settings | The chosen model's ring, radio and badge used the system's teal | Aurora (`Tokens.Signal.aurora*`) |
| 17, 26, 27 Canvas | On a canvas narrower than about 900 pt the key hints ran under the zoom control | The Mac drops hints from the end to fit, as the iPad does |
| 19, 20, 22, 23 | The hint bar showed the mind map's hints on every canvas | Each type's own, worded as its artboard: next step / parallel step / shape; downstream + flow / sibling fed by same source / drill into process; dependency / peer service / wrap in VPC/subnet; message to next participant / next message in time / return message |
| 12, 19–23 | Edge labels in the system font; the tokens and every artboard set them in mono (and the sequence layout already measured them in mono) | Mono, on every canvas |
| 20–22 | Technical boundary titles in sentence case and the UI font, with a kind prefix even when the title names it ("ZONE · PCI zone") | Mono capitals, letter-spaced, without the repeated kind ("PCI ZONE", "VPC · PROD 10.0.0.0/16"). Group boundaries are unchanged |
| 20 DFD | The internal-network trust boundary was red like the PCI zone; the PCI zone drew solid | Trust boundaries are violet, except on a threat model (21, red); zones are red and dashed |
| 20 DFD | The PCI zone drew no hatch, having no trust level | A zone with no level hatches as medium trust |
| 21 Threat model | Asset cards, their badge and their link in Aurora teal, the AI colour | Violet, as the artboard |
| 32 Present | The strip's chosen transition, current slide, progress dot, timers and the step's ring were the accent colour or gold | Aurora; the chosen chip's text is dark, for contrast on teal |
| 43 Node styles | Brutal's lines, root border and hard shadow were fixed near-black, nearly invisible on Graphite and Blueprint | The theme's ink: unchanged on light themes |
| 17 Canvas | The `/` menu on a mind map opened on 32 icons, cut to nine rows, so Note, Code block and Equation never showed without typing | It leads with the artboard's list (Process, Database, Actor, Decision, Note, Code block, Equation, where the canvas has them), then the rest |
| 17 Canvas | The SELECT / EDIT pill was 40 pt tall | 30 pt, as the artboard |
| 16 Home | Template cards were about 120 pt tall with an empty lower half | Sized to their text, 14 pt padding |
| 16 Home | The empty-state card showed the artboard's annotation, "EMPTY STATE · FIRST LAUNCH AFTER TOUR", as a header, at 420 pt | No header, 340 pt |
| 27 Views | Filter chips wrapped ("type:" over "Threat") | One line |
| 31 Tutorial | Skip lesson, Pause and Resume in the system's link blue; "Don't show tips" too | Iris (the app's accent); "Don't show tips" secondary grey |
| 40 Integrations | The MCP tool chips sat in a grid with uneven gaps, and long names ran into their neighbours | They wrap with even gaps |
| 44 Format › Style | "Very important" truncated in its Quick style tile | Fits |
| 05 Motion | The broken-rule shake took 420 ms and the new edge's glow 600 ms; the tokens say 200 and 300 | `Motion.errorShake`, `Motion.connectDraw` |

## Checked and not changed

- **Branch colour order (17, 18).** The artboards' maps colour Pricing teal; the app colours
  the second main topic coral. The code's order is the tokens' (`branchPalette`), and the
  artboards' maps aren't the sample maps, so the order of their topics isn't known.
- **Threat status (21).** The artboard's T-01 reads Mitigated; a threat added with a
  mitigation reads Open until someone sets it. `DiagramTests` pins that rule.
- **Technical node kickers (11, 20, 22).** They looked drawn over their titles; that was the
  upside-down capture. On the right way up they sit above.
- **Shortcuts tiles (33)** keep SF Symbols, and **Home's lockup (16)** stays (brand audit).

## Fixed in the second pass

The items that were open, fixed by area. Seven agents worked on disjoint files in parallel;
each change was then reviewed, joined, built and tested here.

| Artboard | Now |
| --- | --- |
| 24 Format › Data | Separate Links (the topic's link as web, file or topic link, and the topics that link here), Attachments (name and size; a click opens it) and Provenance (for AI-made topics) sections, each hidden when empty; metadata keys in the UI font, values in mono, an Iris pin dot, "+ Add field" as a link, remove on hover, in a menu and as an accessibility action (`FormatPanelData.swift`) |
| 44 Format › Style | "Save into this theme" writes the topic's look into the document's style for its role (D211), one undo step; the structure reads "Logic Chart → right"; the fill menu trails the swatches; the current fill is ringed; Update style lines up with its siblings |
| 03 System | Liquid Glass off or Reduce Transparency on (in Settings, or the system's when Settings says System) gives every in-canvas surface an opaque one: hint bar, panels, palette, Present's strip, AI panel, tour, Quick Capture (`ChromeSurface.swift`); the window's bars use the same rule |
| 11 Nodes | A count chip at the primary topic's corner while more than one is selected, on the Mac and the iPad, readable on every theme's ring; hovering a topic lifts it 1 pt with the artboard's shadow (shadow only with Reduce Motion) |
| 04 Themes | The builder offers Tapered (a new optional `Theme.lineTaper`; themes without it read and write as before); "Start from" names the base theme; 380 pt wide with labels above their controls |
| 08 Shortcuts | The Hyper card's key and tap action are menus; the nine branch-structure rows fold into one "Change branch structure ⌥⌘1 … 9" row |
| 13 Icons | All 32 technical icons drawn from the artboard's own paths |
| 17 Window | Subtitle "iCloud Drive · edited" (where the file is, and saved or edited); a sidebar button before the title opens the navigation panel; ⌥⌘T in a keycap; a 34 pt canvas tab bar |
| 18 Structures | Shared trunks (org bus, timeline axis, fishbone spine, the root brace) drawn once in ink; the fishbone's arrowhead; tree-table rows white with a branch stripe; matrix cells white with neutral borders. The SVG export draws the same |
| 19 Flowchart | Rounded steps; END below its node and I/O beside it, no captions on swimlanes; lanes in one rounded pool with dividers, the second lane violet; a decision's question wraps in a compact diamond |
| 20 DFD | A broken rule outlines the store it reaches |
| 21 Threat model | Trust boundaries hatch; risk pills solid (Low green, N/A grey); mono IDs; the table docked full width under the canvas, the hint bar giving way to it; the STRIDE inspector's risk a pill, "—" for an empty applicable row; the suggestion card says "3 more … for 2.0" and "DoS" |
| 22 Architecture | A Region boundary (Format › Meaning, solid), VPC dashed, subnet finely dashed, hairlines with no tint; external SaaS dashed with a dashed edge; icon library with short names and mono headers. Xmind export uses the same boundary colours (`Boundary.drawnColor`) |
| 23 Sequence | Every participant the same rounded box, with its icon |
| 25 Palette | A glyph per command; amber Connect and Aurora AI tiles; no category as a subtitle; the jump footer's "(400 ms)" |
| 26 Split | The "Live-linked" chip (dismissible); the outline footer fits |
| 27 Views | Focus grows a branch to its own side; the critical filter chip carries ▲; the search toggles wrap |
| 28 AI | @mentions as Iris chips without the @; the topic pill in its branch colour |
| 30 Export | Mermaid and PlantUML previews syntax-coloured; the SVG metadata sample and "Scope and scale shared with PNG." |
| 36–42 Settings | Illustration cards carry their caption inside, as one card; the mouse-aids, theme, frame, VoiceOver and masking previews drawn as the artboards; Mat colour as four swatches plus custom (the default mat is now the lavender swatch, #C9C5FA); Files › Using and Watermark as plain rows, Xmind's watermark sentence as the footnote; padding 0–120 and the ⌘ delay 0.2–1.8 s |
| 14, 15 Onboarding | Welcome's rhythm and footer as the artboard, with the dot grid; role cards as tall as the tallest, borderless until chosen; 40 pt footer buttons; the Architect icon |
| 05 Motion | Reorder, reparent and drop settle on the `settle` spring; structure change and Convert glide for 500 and 600 ms; parallax starts below 40% zoom; on the iPad too |

Found on the way and fixed:

- **Balanced wrapping broke words.** To even out a topic's lines, the measurer narrowed it
  to the smallest width with the same line count, and a word broken in two still counts as
  one line, so "Workaround available?" drew as "Workaroun / d available?". It now never
  goes narrower than the longest word. 289 of the 8,317 cases in `MacMeasures.json` were
  breaking a word; they're wider now, and the fixture is re-recorded.

## Fixed in the third pass

| Artboard | Now |
| --- | --- |
| 18 Structures | A matrix quadrant's title is its cell's heading: no fill or border, bold, in its branch colour, darkened where needed to keep 4.5:1 on the cell. A topic with its own style keeps it |
| 22 Architecture | Library tiles drag onto the canvas, on the Mac and the iPad: dropped on a topic, the icon becomes its child; on empty canvas, the selection's. The footer says so. Other text dropped on the canvas is refused |
| 24 Format › Data | Clicking an attachment shows it in Quick Look on the Mac too (the iPad already did), with the panel's Open With; the row reads "size · Quick Look". Space isn't bound here: on the canvas it edits the topic, and the row takes Space when it has the keyboard focus |
| 41 Privacy | A masked key keeps its type prefix ("sk_live_████", "AKIA", "ghp_", "xoxb-") and loses the rest, in the preview and in masked exports |
| 25 Palette | Titles in sentence case ("Convert diagram type…"), keeping acronyms, words with inner capitals, product names and feature names ("Copy as Mermaid", "Export canvas as PNG", "Open Quick Capture"). Menus keep title case, as macOS menus do; a translated title is left as its language writes it |

## Still open

| Artboard | What differs | Why not now |
| --- | --- | --- |
| 05 Motion | Deep levels drifting slower than the root below 40% zoom | Moving levels apart would re-path every branch line on each pan frame, over the pan budget |
| 21 Threat model | The sample's boundary reads "TRUST BOUNDARY · TRUST LOW→HIGH" where the artboard says "PCI ZONE · …" | A sample's title, not the app |

## Results

After both passes:

- `swift test`: everything passes except `ImageToMapTests.exportedMapReadsBack` and
  `GanttTests.taskLineShowsOnTopics`, which fail the same way on `69e0afd` without these
  changes. New tests: `ApertureMarkTests.iconTileArtMatchesTheFullBleedIcon`,
  `StylingTests.themeTaperIsOptionalAndTapersLines`,
  `StylingCommandTests.saveStyleIntoThemeReachesTheRole`,
  `TechInteractionTests.matrixTitlesAreHeadings` and `iconDroppedFromTheLibrary`,
  `ViewsTests.paletteTitlesAreSentenceCase`; `ViewsTests.focusDrillsAndClimbs`
  and `XmindStyleFidelityTests.nearBoundaryShapesAndMeaningsAreReported` follow the new rules.
- Goldens re-recorded where the change is the point: `ns-graphite-brutal`,
  `ns-blueprint-brutal`, and the starters apiDesign, bugTriage, businessModelCanvas,
  cicdPipeline, dataPipeline, habitTracker, leanCanvas, literatureReview, loginSequence,
  oauth, riskRegister, severityFlow, techDebt and valueProposition. Every other golden still matches. `MacMeasures.json` re-recorded (D490).
- The string catalog regenerated with the repo's writer (`NEXUS_WRITE_CATALOG`) after each
  pass, so every new key is in it and none that's unused.
- `scripts/lint.sh` passes; `scripts/build-ios.sh` builds all 14 modules; the Mac app builds
  with `xcodebuild`.
- The changed screens were rendered off-screen and compared with their artboards again,
  among them Settings, the Format panel, the DFD, threat model, architecture, org chart,
  swimlane, sequence, Present, the slash menu, the filter bar and a multi-selection.
- Not checked on screen: the iPad (the simulator's CoreSimulator is out of date on this
  Mac), the window's toolbar and glass, which the off-screen renders can't show, and the
  hover lift and glide, which are motion.
