# OpenNexus — Feature & Functionality Brief

Oct 13, 2026 · @Jerry Voelker

## Purpose of this brief

This brief tells the design team what to prototype for OpenNexus v1: a native macOS 27 app that matches Xmind's feature set and keyboard flow, then extends that flow to technical diagrams, local AI, and a guided first run. It is a functional spec, not a visual one. Every interaction is described; the look is yours to invent within the principles in the next section.

**What the prototype must prove**

1. A new user can build a 20-topic mind map in under two minutes without touching the mouse.
2. The same keystrokes (Tab, Return, arrows, Space) build a flowchart, a data flow diagram, and an architecture diagram with no mode-switching lessons.
3. Converting a mind map into another diagram type is a single, animated, reversible action.
4. Local AI feels like a quiet collaborator inside the canvas, not a chat app bolted on the side.
5. The first five minutes teach the keyboard model by doing, not by reading.

**How to read it**

- Section 3 inventories Xmind so nothing gets missed. Items marked *Parity* must exist in v1; *Beyond* items are where OpenNexus goes further.
- Section 4 (keyboard model) is the heart of the product. Treat it as non-negotiable unless flagged as an open question.
- Section 13 lists the exact screens and flows to deliver. Section 14 records the product decisions this brief is built on.

Source material: the OpenNexus Concept Overview, Xmind's own documentation and release notes (as of October 2026), and Apple's macOS 27 developer materials. Links are in Sources at the end.

## Design north star

The canvas is the product; everything else gets out of its way. The governing line from the concept doc is that the software should never get in the way of thinking. Each principle below is a test the designer can apply to any screen.

| Principle | What it means for design | Test |
| --- | --- | --- |
| Keyboard first, mouse welcome | Every create, edit, move, and style action has a key path. Mouse paths exist but are never the only way. | Can a power user complete the task with hands on the keyboard? |
| Zero-latency feel | New nodes appear under the cursor in the same frame the key is pressed. Layout animates after, never before, the user can type. | Is the user ever waiting to type? |
| Structure is automatic | Users never align or space boxes by hand unless they choose free layout. | Did the user have to drag something to make it look right? |
| Beautiful by default | A map made with zero styling choices is presentation-ready. | Would you screenshot the default output into a slide? |
| One model, many views | A mind map, outline, flowchart, and DFD are views over one graph of nodes and edges. | Can this content move to another diagram type without retyping? |
| Motion explains change | Animation shows where things came from and went. It is never decoration. | If the animation were removed, would the user lose track of something? |
| Calm chrome | Panels, toolbars and inspectors appear on demand and recede when typing starts. | How much of the window is canvas while typing? |
| Local and owned | Files are plain, documented, and on disk. AI runs on the Mac by default. | Does anything leave the machine without the user knowing? |

**Design references.** Xmind for the keyboard flow and the structure catalogue. Native macOS 27 apps (Freeform, Notes, Keynote) for chrome. Linear and Raycast for command palette speed. Things for calm, purposeful motion.

## Xmind research: what to match and where to go further

Xmind's strength is a tiny, consistent keyboard vocabulary sitting on top of a deep catalogue of structures and topic elements. Its 2026 releases moved toward native platform visuals, a floating toolbar beside the selection, project-management features (To-do, Task, Gantt) and an AI chat panel. OpenNexus should match the core catalogue, skip the cloud and team features, and spend the saved effort on technical diagram types and local AI.

### Feature inventory

| Area | Xmind today (Oct 2026) | OpenNexus v1 | Tag |
| --- | --- | --- | --- |
| Files | One file holds many sheets (maps); new from blank, template, or library | Same: a document holds many canvases of any diagram type, shown as tabs | Parity |
| Topic types | Central, Main, Subtopic, Floating, Summary | Same five, plus typed nodes per diagram (process, data store, actor, service, trust boundary) | Parity + Beyond |
| Structures | Mind Map, Logic Chart, Brace Map, Org Chart, Tree Chart, Tree Table, Timeline, Fishbone, Matrix (historically 12 variants) | All of these, plus Flowchart, DFD, Architecture, Threat Model, Sequence, UML Class, Swimlane Process | Parity + Beyond |
| Mixed structures | A branch can use a different structure from the rest of the map | Same; any branch can switch structure | Parity |
| Relationship | A free line between any two topics with a text label, line shape, start and end styles | Same; becomes the general "edge" in technical diagrams (data flows, calls, messages) | Parity |
| Boundary | Encloses a branch; 9 shapes; can carry a title | Same; doubles as group, zone, VPC/subnet, and trust boundary | Parity + Beyond |
| Summary | A bracket over sibling topics that spawns its own summary topic and children | Same | Parity |
| Callout | A speech-bubble note attached to a topic | Same | Parity |
| Topic enrichments | Markers, stickers, labels, notes (rich text), hyperlinks, topic links, attachments, local images, audio notes, LaTeX equations, tasks | Same set; audio notes optional for v1; add code blocks and metadata fields | Parity |
| Shapes | Up to 31 topic shapes; 4 flowchart shapes added Aug 2026 | Full flowchart set plus technical icon library (cloud, database, queue, user, lock) | Beyond |
| Styling | Themes, smart color themes, multi-branch color, branch line styles, copy/paste style, skeleton (structure-only) themes | Same, plus diagram-type-aware themes and semantic color (e.g. by trust level) | Parity + Beyond |
| Views | Map, Outliner, ZEN mode (distraction-free), Focus / drill-down on a branch, Pitch (auto-generated presentation) | Same five, plus Split view (map + outline live side by side) | Parity + Beyond |
| Selection helpers | Select siblings, select children, find and replace, filter by marker | Same, plus command palette and "select by type" | Parity |
| Tasks and planning | To-do vs Task split, assignees, duration, Gantt view (2026) | Out of v1; keep simple checkbox to-dos only | Defer |
| Collaboration | Real-time co-editing, cloud storage, version history, Spaces | Out of v1; file-based via iCloud Drive / Git instead | Skip |
| AI | Cloud AI with credits: text to map, summarize files and links, grow ideas, refine, image to map, chat panel inside the map | All on-device; same verbs plus diagram-aware actions (generate DFD from description, STRIDE threats) | Beyond |
| Export | PNG, SVG, PDF, Markdown, Word, Excel, PowerPoint, OPML, TextBundle | Same plus Mermaid, PlantUML, JSON, YAML, draw.io | Beyond |
| Import | Markdown, OPML, FreeMind, MindManager, and others | Same plus .xmind, Mermaid, draw.io | Parity + Beyond |
| Customization | Every shortcut is remappable in Settings; restore defaults | Same, plus shortcut profiles (Xmind, OmniGraffle, Vim-style) | Parity + Beyond |

### What Xmind gets right (keep)

- **Three keys build a whole tree.** Tab, Return and arrow keys cover 80% of creation.
- **Typing replaces the selection.** With a topic selected, typing starts editing without pressing Space first.
- **Auto-layout never asks.** Topics reflow as the tree grows; users only position floating topics.
- **Branch-level structure.** One branch can be a fishbone while the rest stays a mind map.
- **Pitch mode** turns the map into a slide deck with no extra authoring.

### Where Xmind leaves room (improve)

- **Flowcharts feel bolted on.** Shapes exist, but edges between arbitrary nodes still go through Relationship, which has no keyboard path to a target. OpenNexus adds a keyboard "connect to" (section 4).
- **No semantic diagram types.** A DFD in Xmind is just shapes; nothing knows a data store from a process. OpenNexus nodes carry a type, so export to Mermaid or a threat model is lossless.
- **AI is cloud-only and metered** by monthly credits. OpenNexus runs it locally with no meter.
- **Discoverability.** Shortcuts live in a settings list. OpenNexus shows them in context (hint chips, command palette, the tutorial).

## The keyboard model

OpenNexus ships Xmind's default key map unchanged, so an Xmind user's hands work on day one, and then adds a small set of keys for connecting, typing and converting nodes in technical diagrams. Every key below works the same in every diagram type; only what the new node *is* changes.

> **Decided.** OpenNexus uses Xmind's mapping: **Tab creates a child** (subtopic) and **Return creates a sibling** (topic after). Typing over a selected node replaces its text, as in Xmind, and **Space** also enters Edit mode while keeping the existing text.

### Three states, always visible

The canvas is always in one of three states, and the designer must make the current one obvious at a glance:

- **Select mode** — one or more nodes highlighted; keys act on nodes. Typing any printable character replaces the node's text and enters Edit mode.
- **Edit mode** — a caret inside a node; keys edit text. Esc or Return commits and returns to Select mode on the same node. Tab commits and immediately creates a child.
- **Connect mode** (new) — entered from Select mode; every reachable node shows a one- or two-letter hint chip; pressing the letters picks the edge target.

&#91;embedded content: canvas keyboard states · 3 modes, 4 transitions\]

Every path leads back to Select mode, so the user is never more than one key (Esc) away from a known state.

### Create

| Action | Key | Notes |
| --- | --- | --- |
| Child topic | Tab | Works in Select and Edit mode; new child starts in Edit mode |
| Sibling after | Return | In Edit mode the first Return commits; the next Return creates the sibling |
| Sibling before | Shift-Return | In Edit mode, Shift-Return inserts a line break instead (as in Xmind) |
| Parent topic | Command-Return | Inserts a new node between the selection and its parent |
| Floating topic | Double-click canvas, or Option-Command-Return | Not attached to the tree |
| Duplicate branch | Command-D | New |
| Insert from slash menu | / at the start of an empty node | Picks shape or node type: /db, /process, /actor, /decision, /note |

### Edit text

| Action | Key | Notes |
| --- | --- | --- |
| Edit selected node | Space, or just start typing | Space keeps text, caret at end; typing replaces |
| Commit edit | Return or Esc | Both return to Select mode on the same node |
| Line break inside a node | Shift-Return |  |
| Bold / italic / link | Command-B / I / K | Rich text inside the node |

### Navigate and select

| Action | Key | Notes |
| --- | --- | --- |
| Move selection | Arrow keys | Spatial: moves to the nearest node in that direction, so it works in any layout |
| Jump to root | Command-Home |  |
| Extend selection | Shift-Arrow |  |
| Select siblings | Shift-Command-A | Xmind default |
| Select children | Option-Command-A | Xmind default |
| Select all | Command-A |  |
| Find and replace | Command-F | Matches highlight on canvas and in a list |
| Command palette | Command-K | New; every action, searchable, shows its shortcut |
| Quick jump to node | Command-J | New; fuzzy search node text, Return to fly there |

### Restructure

| Action | Key | Notes |
| --- | --- | --- |
| Reorder among siblings | Option-Command-Up / Down | New; animates the swap |
| Promote (outdent) | Shift-Tab | New in canvas, standard in outline |
| Demote under previous sibling | Option-Command-Right | New |
| Delete node and branch | Delete |  |
| Delete node, keep children | Option-Delete | New; children move up a level |
| Fold / unfold branch | Command-/ | Xmind default |
| Fold all / unfold all | Option-Command-/ |  |
| Change branch structure | Option-Command-1 … 9 | New; cycles structure for the selected branch |

### Add elements

| Action | Key | Notes |
| --- | --- | --- |
| Relationship / edge | Shift-Command-L | Opens Connect mode instead of a mouse drag |
| Boundary | Shift-Command-B | Wraps the selection |
| Summary | Shift-Command-\] | Brackets selected siblings |
| Callout | Shift-Command-C |  |
| Note | Shift-Command-N | Opens the note editor beside the node |
| Hyperlink | Shift-Command-K |  |
| Image | Shift-Command-I |  |
| Label | Shift-Command-T | Xmind's published table lists Shift-Command-L for both Relationship and Label; we resolve the clash here |
| Priority marker 1–9 | Control-1 … 9 | New |
| Copy / paste style | Option-Command-C / V | Xmind default |

### View

| Action | Key | Notes |
| --- | --- | --- |
| Zoom in / out / actual size | Command-= / - / 0 |  |
| Fit map to window | Shift-Command-0 |  |
| Focus on branch (drill down) | Command-Period | Esc steps back out |
| ZEN mode | Option-Command-F | Xmind default |
| Toggle Outline | Command-Shift-O |  |
| Inspector panel | Command-I | Xmind's "format bar" key |
| Present | Command-Shift-P |  |

### Connect mode in detail

This is the one genuinely new interaction and needs its own prototype flow.

1. With a node selected, press Shift-Command-L.
2. All other nodes dim slightly and show hint chips (A, S, D, F, AS…), nearest first. A search field appears at the selection.
3. Type hint letters, or type part of the target's text to filter. Arrow keys also move a target highlight.
4. Return draws the edge with a drawing-on animation and opens its label in Edit mode.
5. Typing a name that matches no node offers "Create new node" so the user can connect to something that doesn't exist yet.
6. Esc at any point cancels with nothing changed.

### Discoverability

- Hold Command for one second: a translucent cheat sheet of keys for the current selection fades in over the canvas.
- Each menu item and palette row shows its shortcut.
- Shortcuts are remappable in Settings, with presets: OpenNexus (default, Xmind-compatible), Outliner-style, and Vim-style.

### Remapping, conflicts and the Hyper key

Every shortcut is remappable, and OpenNexus never ships a default that collides with macOS or with another OpenNexus command. A Raycast-style Hyper key gives OpenNexus its own clash-free namespace.

- **Hyper key.** The user picks one key (Caps Lock suggested, or right Option) that acts as Control-Option-Shift-Command pressed together. Almost nothing on macOS uses that four-modifier combination, so Hyper plus a letter is free for OpenNexus.
- **Defaults.** Xmind-compatible keys stay exactly as Xmind ships them. Every OpenNexus-only command also gets a Hyper binding, which becomes its primary binding wherever the standard one would clash.
- **Conflict detection.** The shortcut recorder in Settings warns the moment a key is taken, names the other command (in OpenNexus, a menu, or macOS), and offers Swap, Reassign, or Scope.
- **Scopes.** A binding can apply to one context only (Select, Edit, Outline, Connect mode), so a key can do different things where that is unambiguous.
- **Profiles.** OpenNexus (Xmind-compatible, default), Hyper-first, and Vim-style; profiles import and export as JSON so teams can share them.
- **Permission.** Turning Caps Lock into Hyper likely needs macOS Input Monitoring or Accessibility permission. Ask for it only when the user enables Hyper, with a one-screen explanation.
- **Design.** Give Hyper its own glyph, shown consistently in menus, the command palette, the Command-hold cheat sheet, and the tutorial keycap coach.

| Command | Standard binding | Hyper binding |
| --- | --- | --- |
| Connect mode | Shift-Command-L | Hyper-C |
| Label | Shift-Command-T | Hyper-L |
| AI ghost suggestions | Option-Space | Hyper-Space |
| AI prompt bar | Command-Shift-Space | Hyper-A |
| AI panel | Command-Shift-J | Hyper-J |
| Convert diagram type | Option-Command-T | Hyper-T |
| Change branch structure | Option-Command-1 … 9 | Hyper-1 … 9 |
| Present | Shift-Command-P | Hyper-P |
| Focus on branch | Command-Period | Hyper-F |
| Command palette | Command-K | Hyper-K |
| Quick Capture (system-wide) | none by default | Hyper-N |

## Canvas, nodes and elements

Everything on the canvas is either a **node** or an **edge**, and every Xmind element maps onto one of the two. Design one node component and one edge component with variants, rather than a separate look per feature.

### The canvas

- Infinite, smooth-zooming surface; trackpad pinch, two-finger pan, and Space-drag to pan.
- Default view centres the root with generous margin; new documents open in Edit mode on the root so the user can type immediately.
- A minimap appears in a corner only while panning or zoomed past 2x, then fades.
- Background options: plain, subtle dot grid, line grid (technical diagrams default to dot grid).
- Auto-layout is the default for every diagram type, technical diagrams included. Free layout is an opt-in toggle per canvas; when on, nodes snap to a grid and to each other with alignment guides.
- Multiple canvases per document appear as tabs along the top of the window, like Xmind sheets.

### Node anatomy

The designer should specify one node with these optional slots, so any combination composes cleanly:

1. **Shape** — rounded rectangle default; full library in section 6.
2. **Title** — rich text, wraps at a max width the user can adjust by dragging the node edge.
3. **Leading markers** — priority, progress, flags, emoji, checkbox.
4. **Image** — above or beside the title, resizable.
5. **Labels** — small pills under the title.
6. **Indicator icons** — note, link, attachment, comment, AI-generated; each opens its content on click or keyboard.
7. **Fold badge** — count of hidden children when collapsed.
8. **Type badge** — for technical nodes: "Process", "Data store", "External entity", "Service", "Trust boundary".
9. **Metadata fields** — optional key-value pairs (owner, protocol, port, data classification) shown in the inspector and, if pinned, on the node.

**Node roles** (from Xmind): Central (root), Main (first level), Subtopic, Floating (unattached), Summary (owned by a summary bracket). Each role has a default style in every theme.

**States to design for every node:** default, hover, selected, multi-selected, editing, drag source, drop target (child / before / after), search match, AI-suggested (ghost), and error (e.g. a DFD rule broken).

### Edges and elements

| Element | What it is | Keyboard path | Design notes |
| --- | --- | --- | --- |
| Branch line | Parent-to-child connector, drawn by the layout | Automatic | Styles: curved, straight, elbow, rounded elbow, tapered; thickness by depth |
| Relationship / edge | Free connector between any two nodes, with a label | Shift-Command-L, then Connect mode | Line shape, dash, start/end arrowheads, label position; in technical diagrams this is a data flow, call, or message |
| Boundary | Shape around a branch or selection, with an optional title | Shift-Command-B | 9+ shapes; in technical diagrams it becomes a group, zone, network, or trust boundary |
| Summary | Bracket over siblings that spawns its own topic | Shift-Command-\] | The summary topic can have children |
| Callout | Bubble attached to a node | Shift-Command-C | Pointer stays attached as the node moves |
| Note | Rich text document behind a node | Shift-Command-N | Opens in a side sheet; supports headings, lists, code, tables, images |
| Hyperlink / topic link | Link to a URL, file, or another node or canvas | Shift-Command-K | Topic links fly the camera to the target |
| Attachment | Any file embedded in the document | Drag a file onto a node | Shows file icon and Quick Look on Space when the indicator is focused |
| Equation | LaTeX rendered in the node | /math |  |
| Code block | Monospaced snippet with syntax highlighting | /code | New; for engineers |
| To-do | Checkbox marker with done state | Control-0 toggles | Strikes through title when done |

### Direct manipulation (mouse and trackpad)

- Drag a node onto another to reparent; drop zones show as a glowing insertion line (before / after) or a halo (as child).
- Option-drag duplicates; Shift-drag detaches to a floating node.
- Drag from a node's edge handle to draw a relationship.
- Rubber-band select on empty canvas.
- A floating toolbar appears beside the selection after the pointer rests (Xmind added this in Aug 2026); it never appears while typing.
- Right-click shows a context menu that mirrors the command palette for the selection.

## Diagram types

Every diagram type is a layout and a node vocabulary over the same graph, so Tab always means "the next thing that follows from this" and Return always means "another one like this". The table below is the contract the designer prototypes against.

### Hierarchical structures (Xmind parity)

| Structure | Layout | Tab creates | Return creates | Typical use |
| --- | --- | --- | --- | --- |
| Mind Map | Radial, balanced or one-sided (left / right) | Child branch | Sibling branch | Brainstorming |
| Logic Chart | Left-to-right tree | Child to the right | Sibling below | Argument, breakdown |
| Brace Map | Children grouped by a curly brace | Child inside brace | Sibling inside brace | Part-whole |
| Org Chart | Top-down tree | Report below | Peer beside | Teams |
| Tree Chart | Top-down or indented tree | Child | Sibling | Taxonomy |
| Tree Table | Nested cells | Child column | Row below | Structured lists |
| Timeline | Horizontal or vertical axis | Detail under event | Next event on axis | Roadmaps, history |
| Fishbone | Spine with angled bones | Cause on a bone | Next bone | Root-cause analysis |
| Matrix | Row and column grid | Item inside cell | Next cell | SWOT, 2x2 |

### Technical diagrams (OpenNexus additions)

| Diagram | Node vocabulary | Tab creates | Return creates | Edge meaning | Smart help |
| --- | --- | --- | --- | --- | --- |
| Flowchart | Start/End, Process, Decision, I/O, Subprocess, Document, Connector | Next step, connected by an arrow | Parallel step at the same level | Control flow | From a Decision, Tab creates a branch and prompts "Yes"/"No" labels |
| Swimlane Process | Lanes (actors) holding steps | Next step in the same lane | Step in the lane below | Hand-off | Option-Up/Down moves a step to another lane |
| Data Flow Diagram | External Entity, Process, Data Store, Trust Boundary | Downstream element with a data-flow edge | Sibling element fed by the same upstream | Labelled data flow | Rule checks: flows must touch a process; level-0/1 drill-down per process |
| Threat Model | DFD elements plus Threat, Mitigation, Asset nodes | Threat on the selected element | Another threat | Attack path | STRIDE checklist per element type; risk rating labels; threat table export |
| Architecture | Client, Service, API Gateway, Database, Queue, Cache, Storage, External SaaS, Container, Region / VPC / Subnet boundaries | Dependency (callee) with an edge | Peer service | Call / network path with protocol label | Icon library; edge labels default to protocol (HTTPS, gRPC, SQL) |
| Network | Device, Router, Firewall, Switch, Host, Zone | Connected device | Peer device | Link | Zones as boundaries |
| Sequence | Participants (lifelines) and messages | Message to the next participant | Next message in time | Message | Return message with Option-Return; activation bars automatic |
| UML Class | Class, Interface, Enum with members | Member (field or method) | Next member | Association, inheritance, composition | Type a member as `+ name: Type` and it formats itself |
| Decision Tree | Decision, Chance, Outcome | Option branch | Alternative option | Branch | Optional probability and value fields roll up |
| Whiteboard | Freeform sticky notes, shapes, pen | Linked note to the right | Note below | Arrow | Free layout by default; Apple Pencil-style ink via trackpad not required |

### Templates (starting points)

Ship a template gallery, grouped by role, that opens a pre-built canvas:

- **Engineering:** system context, container diagram (C4 levels 1–2), API request flow, incident timeline, sprint retro.
- **Architecture:** cloud reference architecture, migration plan, ADR outline, capability map.
- **Security:** STRIDE threat model, attack tree, data classification map, access review, incident response runbook.
- **Planning:** project breakdown, roadmap timeline, SWOT matrix, meeting notes, decision log.
- **Learning:** book notes, lecture outline, research map.

### Converting between types

Conversion is a first-class action (Option-Command-T opens a type picker with live previews).

- **Mind map → Flowchart / DFD / Architecture:** each branch becomes a node; parent-child links become edges; the user is asked to confirm a node type for each first-level branch, with AI suggestions pre-filled.
- **Any → Outline / Markdown:** always lossless for text; edge-only relationships become indented "→ links to" lines.
- **Back again:** converting back restores the original layout if nothing structural changed.
- The conversion animates: nodes fly from old to new positions while edges redraw, about 600 ms, so users can follow where each idea went.
- Undo returns to the previous type in one step.

## Visual design, themes and motion

Chrome follows macOS 27's refined Liquid Glass; the canvas stays opaque, crisp and content-first. Apple reduced default transparency and reworked sidebars in macOS 27 after readability complaints about macOS 26, so glass belongs on floating controls (toolbar, palette, floating toolbar, HUDs), never behind diagram text.

### Visual system

- **Window:** unified toolbar, collapsible sidebar (documents, canvases, outline), canvas, and an inspector that slides in on the right only when asked.
- **Typography:** SF Pro for UI; theme-selectable diagram fonts (SF Pro, New York, SF Mono, plus user fonts). Node text never below 12 pt at 100% zoom.
- **Color:** each theme defines a palette of 8 branch colors, a neutral ramp, and semantic colors (success, warning, critical, trust-level low / medium / high). Light and dark variants are designed together, not inverted.
- **Themes at launch (suggested 12):** Classic, Paper, Graphite (dark), Midnight Neon, Blueprint (technical), Whiteboard (hand-drawn feel), Pastel, High Contrast, Monochrome Print, Solarized, plus two "skeleton" themes that show structure only.
- **Smart color:** auto-assign branch colors from the theme; Shift-Command-R reshuffles (Xmind offers a similar smart color theme).
- **Technical theme rules:** DFD and architecture themes color by node type, not by branch; trust boundaries use dashed outlines; threat nodes use the critical color.
- **Inspector tabs:** Style (shape, fill, border, text), Branch (line style, color, structure), Canvas (theme, background, layout), Data (metadata fields, links, attachments).

### Motion system

Motion should feel springy and physical, quick enough to never block typing. Every animation respects the system Reduce Motion setting, which swaps movement for a 150 ms cross-fade.

| Moment | Animation | Target duration |
| --- | --- | --- |
| Create node (Tab / Return) | Node grows from the parent's connector point while the branch line draws toward it; siblings ease aside | 180 ms; the caret is live at 0 ms |
| Delete node | Node shrinks into its parent; neighbours close the gap | 160 ms |
| Reorder / reparent | Node lifts (shadow), travels along a short arc, settles with a slight overshoot | 250 ms |
| Fold / unfold | Children collapse into the fold badge, which pulses once with the count | 220 ms |
| Auto-layout reflow | All moved nodes spring to new positions together | 300 ms |
| Structure change (e.g. mind map → logic chart) | Nodes morph shape and fly to new positions; lines redraw | 450–600 ms |
| Diagram conversion | Same as above plus node-type badges fade in | 600 ms |
| Connect mode | Hint chips pop in nearest-first in a 40 ms stagger; chosen edge draws from source to target | 300 ms draw |
| Focus / drill-down | Camera flies to the branch; the rest blurs and dims | 400 ms |
| Presentation step | Camera glides between branches; content builds in sequence | 500 ms |
| AI suggestions | Ghost nodes shimmer in at 50% opacity; accepting solidifies them | 250 ms per node, staggered |
| Error (rule broken) | Gentle horizontal shake of the offending node plus a badge | 200 ms |

**Effects to explore (tasteful, optional):** a soft glow trail along newly drawn edges; a subtle parallax depth when zooming out on large maps; a celebratory sparkle when every to-do in a branch is done; animated data-flow "dots" travelling along DFD edges in presentation mode.

## Views and modes

Six ways to look at the same content, each one key away, and switching between them never loses the selection.

| View | Purpose | Behaviour | Key |
| --- | --- | --- | --- |
| Canvas | Default spatial view | Everything in sections 4–7 | Command-1 |
| Outline | Linear editing of the same tree, like a document | Same keys: Return sibling, Tab indent, Shift-Tab outdent; notes inline; technical edges listed under their source | Command-2 |
| Split | Canvas and outline side by side, live-linked | Selecting in one highlights in the other; typing in either updates both | Command-3 |
| ZEN | Distraction-free canvas | Hides all chrome; full screen; a faint word/node count in a corner; Esc exits | Option-Command-F |
| Focus (drill-down) | Work on one branch as if it were the whole map | Breadcrumb at top shows the path back; Esc climbs one level | Command-Period |
| Present | Turn the canvas into slides automatically | See below | Shift-Command-P |

### Present mode (Xmind "Pitch" equivalent)

- Auto-generates a slide sequence: title slide from the root, then one slide per main branch, then deeper levels as builds.
- A side strip lets the user reorder, skip, or merge slides, and pick a transition style (glide, zoom, cut).
- Presenter view on a second display shows the next slide, notes, and a timer.
- For technical diagrams, slides can **step through a flow**: highlight one edge at a time along a flowchart or DFD path, with the animated data-flow dots.
- Export the sequence as PDF, PowerPoint, or Keynote, or as a video (Xmind added a similar "Pitch Video" in 2026).

### Filtering and search

- Filter bar (Command-Shift-F) dims nodes that don't match a marker, label, type, or text query, and can hide them entirely.
- Saved filters appear in the sidebar, for example "All open threats rated High".

## Local AI

AI in OpenNexus runs on the Mac by default, appears inside the canvas as suggestions the user accepts with a key, and never interrupts typing. macOS 27's Foundation Models framework gives apps direct access to Apple's on-device model, accepts images alongside text, supports tool calling, and lets apps plug in other model providers through the same Swift API; Core AI and MLX cover bring-your-own open models. That makes a free, metered-by-nothing AI layer realistic, which is a clear contrast to Xmind's credit-based cloud AI.

### Where AI shows up

1. **Ghost suggestions (primary surface).** With a node selected, press Option-Space (Control-Space is taken by macOS input switching) (or pause after creating a node, if enabled). Three to five faint ghost children shimmer in. Control-Return accepts the highlighted one, Control-Shift-Return accepts all, arrow keys move between them, Esc dismisses. Typing continues normally and ignores them.
2. **Inline prompt bar.** Command-Shift-Space opens a small glass field anchored to the selection: "Expand this into a sprint plan", "Turn this branch into a DFD". Results arrive as ghosts, never applied silently.
3. **AI panel (optional).** Command-Shift-J opens a side panel for longer conversations about the whole document. The panel can read the map, reference nodes by name, and propose changes as a diff.
4. **Command palette verbs.** Every AI action is also a palette command, so it is keyboard-reachable without learning new keys.

### Actions to design

| Action | Input | Output |
| --- | --- | --- |
| Generate map | A prompt, or a blank document's first line | Root plus two levels of branches, as ghosts |
| Expand branch | Selected node and its context | 3–5 child ideas |
| Rewrite | Selected nodes | Shorter, clearer, or more formal titles, shown as before / after |
| Summarize | A branch | A Summary element with one-line takeaway |
| Reorganize | A messy branch | Proposed regrouping, previewed with the reflow animation before accepting |
| Find gaps | A map | Highlighted spots with "Possibly missing: …" ghost nodes |
| Import to map | Pasted text, a PDF, a Markdown file, a photo of a whiteboard (on-device OCR) | A structured map |
| Describe to diagram | "Users log in via the gateway to the auth service, which reads Postgres" | An architecture or DFD canvas with typed nodes and labelled edges |
| Threat suggestions | A DFD or architecture diagram | STRIDE threats per element, as Threat nodes with draft mitigations |
| Explain | Any node or edge | A short explanation in a callout |
| Write it up | A whole canvas | A Markdown document (design doc, runbook, or summary) in a sheet the user can export |
| Diagram as code | A canvas | Mermaid or PlantUML, with a live preview round-trip |

### Trust and control

- **Model picker in Settings:** Apple on-device (default) · a local model via MLX / Core AI · a local server on the same Mac, such as Ollama or LM Studio. v1 offers no cloud models, including Apple Private Cloud Compute.
- A small status chip in the toolbar shows which local model is active. Nothing leaves the Mac.
- AI-created nodes carry a subtle sparkle indicator until the user edits them; a filter can show all AI-created content.
- Each accepted AI action is one undo step.
- OpenNexus runs only on Macs that support Apple's on-device model, so no "unsupported hardware" state is needed. If the user has turned Apple Intelligence off, AI entry points show a one-line explanation and a link to System Settings rather than disappearing silently.

## First-run experience and tutorial

The tutorial is a real canvas the user builds, not a slideshow: in about four minutes they make their first map with the keyboard, convert it to a flowchart, and try one AI action. Every step can be skipped, and the whole tour is replayable from Help.

### Flow

1. **Welcome (10 s).** Full-window glass sheet over a slowly self-building mind map in the background. One line: "Think at the speed of your keyboard." Buttons: Start the 4-minute tour · Skip to a blank map · Import from Xmind.
2. **Pick your world.** Three or four role cards (Engineer, Architect, Security, Planner / Student). The choice sets the tutorial's example topic and the default template shelf. Changeable later.
3. **Lesson 1 — Type.** A root node is already in Edit mode with a blinking caret and a ghost hint: "Name your idea". User types, presses Return.
4. **Lesson 2 — Tab and Return.** An animated keycap appears beside the node: "Tab adds a child". The user presses it; the node grows with the creation animation and the keycap ticks green. Then "Return adds a sibling", then "Shift-Return adds one before", then "Command-Return adds a parent". The keycap sequence speeds up as the user succeeds.
5. **Lesson 3 — Move around.** "Use the arrows to move" with a soft spotlight following the selection. Then Option-Command-Up/Down to reorder, Command-/ to fold.
6. **Lesson 4 — Connect.** Shift-Command-L opens Connect mode; hint chips pulse; the user picks a target and labels the edge.
7. **Lesson 5 — Transform.** Option-Command-T. The user's own map morphs into a flowchart or DFD (depending on role) with the full conversion animation. This is the "wow" moment; design it carefully.
8. **Lesson 6 — Ask AI.** Option-Space on a branch; ghost suggestions shimmer in; Control-Return accepts one.
9. **Finish.** A summary card of the keys just learned with a "Hold Command any time to see these again" tip, then the user's tutorial map stays as their first document.

### Teaching patterns

- **Keycap coach:** a small floating 3D keycap near the selection that depresses when the right key is pressed. It never covers the node being edited.
- **Progress dots** at the bottom; each lesson is 20–40 seconds.
- **Forgiveness:** wrong key? The coach gently shows what that key did (with undo) and repeats the prompt.
- **No modal walls** after the welcome sheet: the user can click away at any point and the tour pauses in a corner pill.

### After the tour

- **Progressive tips:** the first time a user mouses to do something that has a shortcut three times, a quiet toast suggests the key. Tips can be turned off.
- **Empty states:** a new blank canvas shows the root in Edit mode plus three faint hint keycaps (Tab · Return · /) that fade after the first keystroke.
- **Xmind switchers:** importing a .xmind file triggers a one-screen "What's the same, what's new" card highlighting Connect mode, diagram types, and local AI.

## Import, export and file format

Export is one sheet (Shift-Command-E) with a live preview that updates as options change; the native format is an open, diff-friendly package so files survive the app.

### Export formats

| Format | Scope | Key options | Fidelity |
| --- | --- | --- | --- |
| PNG | Canvas, selection, or branch | Scale 1x–4x, transparent background, padding, theme override | Visual |
| JPEG | Canvas, selection, or branch | Quality, background colour | Visual |
| SVG | Canvas, selection, or branch | Embed fonts or outline text, include metadata | Visual, editable |
| PDF | Canvas, all canvases, or presentation | Page size, fit to page or tile, include notes as appendix | Visual |
| Mermaid | Canvas | Diagram flavour (mindmap, flowchart, sequence, classDiagram) auto-chosen from type | Structural |
| PlantUML | Canvas | Same | Structural |
| Markdown | Canvas or document | Headings vs nested bullets, include notes, include Mermaid block | Text + structure |
| JSON / YAML | Document | OpenNexus schema; pretty or compact | Lossless |
| draw.io (.drawio) | Canvas | Keep positions and styles where possible | Visual + structural |
| OPML | Canvas | Hierarchy only | Hierarchy |
| Word, PowerPoint, Keynote | Document or presentation | Outline as headings; diagrams as images | Document |
| CSV | Threat model or task list | Threat table with element, STRIDE category, risk, mitigation | Tabular |

### Import

- **.xmind** (high priority: the migration path), OPML, Markdown, Mermaid, PlantUML (subset), draw.io, FreeMind / MindManager (best effort), plain text with indentation, and images or PDFs via AI.
- Pasting Markdown or indented text onto the canvas creates a branch directly.
- An import report lists anything that could not be converted.

### Native format

- `.nexus` package: a folder bundle containing a human-readable JSON (or YAML) document per canvas, an assets folder, and a manifest with a schema version.
- Text-first and stable ordering so it diffs cleanly in Git; a documented, published schema.
- Autosave and macOS version browsing (File > Revert To) built in; iCloud Drive works with no extra setup.
- Quick Look plug-in shows a thumbnail and preview in Finder; Spotlight indexes node text.

### Share and copy

- Copy a selection as image, as Markdown, or as Mermaid from a submenu (Control-Command-C copies as image by default).
- Share sheet, drag a branch out of the window to Finder or another app as PNG.
- Map shot (Xmind feature): capture the visible area as an image with one key.

## App shell, macOS 27 integration and quality bars

OpenNexus should feel like an Apple-made app: SwiftUI chrome with the system's refined Liquid Glass, standard menus, and deep OS hooks, with a custom high-performance canvas underneath.

### App shell

- **Home window:** recent documents as large thumbnails, template shelf filtered by role, "New blank" with a type picker (Mind Map, Flowchart, DFD, Architecture, Threat Model, Sequence, Whiteboard…), and an Import button.
- **Document window:** canvas tabs across the top, sidebar (canvases, outline, filters, AI history), inspector on the right, toolbar with view switcher, diagram type, theme, AI status chip, share.
- **Full menu bar** with every command, so macOS Help menu search finds them.
- **Settings:** General, Editing (shortcut profile, typing replaces selection on/off, auto-layout defaults), Appearance (theme defaults, Reduce Motion override), AI (model picker, privacy), Shortcuts (remappable, searchable, conflict detection, Hyper key, profiles, restore defaults), Export defaults.

### macOS integration

- Native document model: tabs, multiple windows, Stage Manager, full screen, split view.
- Quick Look and Spotlight for `.nexus` files.
- App Intents and Shortcuts: "Create mind map from clipboard", "Export canvas as PNG", "Add idea to inbox map"; available to Siri.
- Services menu and Share extension: send selected text from any app into a new or existing map.
- Quick Capture: a global hotkey opens a small glass panel to jot an idea into an inbox map without switching apps (Xmind has a similar Quick Entry).
- Handoff and iCloud Drive sync of files; no proprietary cloud.
- Widgets: recent maps and the inbox map on the desktop.

### Accessibility

- Full VoiceOver support: the canvas exposes a tree that reads "Topic, level 2, 3 children, collapsed". Connect mode announces targets.
- Every action reachable by keyboard (this is already the design centre).
- Dynamic Type for UI chrome; canvas zoom for diagram text.
- Contrast: all themes meet WCAG AA for node text; a High Contrast theme meets AAA.
- Colour is never the only signal: node types also carry shape and badge; trust levels carry patterns.
- Reduce Motion and Reduce Transparency honoured everywhere.

### Performance targets

| Measure | Target |
| --- | --- |
| Key press to new node with live caret | Under 16 ms (one frame at 60 Hz) |
| Layout reflow on a 1,000-node map | Under 50 ms |
| Smooth pan and zoom | 120 fps on ProMotion displays with 5,000 nodes |
| Open a 1,000-node document | Under 1 second |
| First AI ghost suggestion visible | Under 1.5 seconds on Apple silicon |

### Open source and extensibility

- Public repo, permissive licence, documented file schema.
- Plugin points (post-v1, but design the hooks now): custom node types and icon packs, custom exporters, custom layouts, AI actions.
- Community template and theme gallery that installs from a file or URL.

## Prototype scope

The prototype needs 14 screens and 6 interactive flows; the flows matter more than the screens, because the product is the feel of typing. Build the P0 flows as clickable, keyboard-driven prototypes (ProtoPie, Origami, or a SwiftUI spike), not static frames.

### Interactive flows

| # | Flow | Why it matters | Priority |
| --- | --- | --- | --- |
| F1 | Build a 3-level mind map from the keyboard: type root, Tab, Return, Shift-Return, Command-Return, arrows, reorder, fold | Proves the core promise and the creation animation | P0 |
| F2 | Connect mode: select a node, Shift-Command-L, pick a target by hint letters, label the edge | The one new interaction model | P0 |
| F3 | Convert the F1 map into a flowchart, then a DFD, then back | The "one workspace, many artifacts" wow moment | P0 |
| F4 | AI ghost suggestions: Option-Space, browse, accept one, accept all, dismiss | Shows AI as a calm collaborator | P0 |
| F5 | First-run tutorial lessons 1–5 | First impression | P1 |
| F6 | Present mode stepping through a DFD path with animated flow | Polish and delight | P2 |

### Screens

| # | Screen | Key states to show |
| --- | --- | --- |
| S1 | Welcome sheet and role picker | Light and dark |
| S2 | Home window: recents, templates, new-document type picker | Empty and populated |
| S3 | Mind map canvas, typing | Select, Edit, multi-select, folded branch, drop targets |
| S4 | Same canvas in Logic Chart, Org Chart, Timeline, Fishbone, Matrix | One frame each |
| S5 | Flowchart canvas | Decision with Yes/No branches, swimlane variant |
| S6 | Data flow diagram with trust boundaries | Rule-violation state |
| S7 | Threat model | Threat nodes, STRIDE checklist in the inspector, threat table |
| S8 | Architecture diagram | Icon library open, VPC and subnet boundaries, protocol labels |
| S9 | Sequence diagram | Lifelines, messages, return messages |
| S10 | Inspector: Style, Branch, Canvas, Data tabs | Each tab |
| S11 | Command palette and quick jump | With results and shortcut hints |
| S12 | Outline and Split views | Live-linked selection |
| S13 | AI: ghost suggestions, inline prompt bar, AI panel, model picker in Settings | Including "Apple Intelligence turned off" |
| S14 | Export sheet | PNG, SVG, Mermaid with live preview |

### Also deliver

- **Node and edge component library** with every state in section 5.
- **Theme sheet:** at least Classic, Graphite (dark), Blueprint, and High Contrast applied to the same map.
- **Motion spec** for every row in the motion table: easing curves, durations, and Reduce Motion fallbacks.
- **Icon set** for technical node types (minimum 24 icons). Also logo and app icon direction for OpenNexus; the name comes from "nexus" meaning connection, network, and relationship.
- **Keycap coach** component for the tutorial.

### Explicitly out of scope for v1

Real-time collaboration, cloud accounts, comments, Gantt and task assignment, iPad and iPhone apps, and plugin marketplace UI.

## Decisions

The product owner resolved every open question on 2026-10-13; the sections above reflect each decision.

| # | Question | Decision | Where it lands |
| --- | --- | --- | --- |
| 1 | Tab vs Return | Xmind default: Tab adds a child, Return adds a sibling | Section 4 |
| 2 | Typing replaces selection | Keep Xmind style; Space also enters Edit mode, keeping the text | Section 4 |
| 3 | Minimum hardware | Only Macs that run Apple's on-device model | Sections 9 and 12 |
| 4 | Private Cloud Compute | v1 is strictly on-device and local; no cloud models | Section 9 |
| 5 | Layout default | Auto-layout for every diagram type; free layout is opt-in per canvas | Section 5 |
| 6 | Name and icon | OpenNexus (nexus = connection, network, relationship); designer proposes logo and icon direction | Section 13 |
| 7 | Shortcut clashes | Full remapping with conflict detection, plus a Raycast-style Hyper key | Section 4 |

## Sources

- OpenNexus Concept Overview (attached document)
- [Xmind shortcuts table (Mac and Windows)](https://xmind.com/blog/shortcuts-in-xmind-that-improve-mapping-efficiency)
- [Xmind user guide: shortcuts and customization](https://xmind.com/user-guide/preferences-shortcuts-new)
- [Xmind user guide: topic types, relationship, boundary, summary](https://xmind.com/user-guide/the-basics)
- [Xmind user guide: topic, boundary and callout styles](https://xmind.com/user-guide/style-new)
- [Xmind structures template (fishbone, matrix, timeline, logic, org, tree)](https://templates.xmind.com/templates/16-structures-y5u2qw)
- [Xmind What's New (AI chat panel, Visual Refresh)](https://xmind.com/whats-new)
- [Xmind changelog (floating toolbar, flowchart shapes, Aug 2026)](https://xmind.com/changelog)
- [Xmind pricing (AI credits, Gantt, tasks)](https://xmind.com/pricing)
- [Xmind 2026 To-do vs Task](https://xmind.com/blog/to-do-vs-task)
- [Apple: What's new in macOS 27 (Foundation Models, Core AI)](https://developer.apple.com/macos/whats-new/)
- [Liquid Glass refinements in macOS 27](https://en.wikipedia.org/wiki/Liquid_Glass)
