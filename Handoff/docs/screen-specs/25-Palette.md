# S11 · Command palette & quick jump

- Source: `design/source/Palette.dc.html`
- Screenshot: `screenshots/25-Palette.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
S11 · COMMAND PALETTE ⌘K · QUICK JUMP ⌘J
conv
Selection: Checkout branch
COMMANDS
⇄
Convert diagram type…
Mind map → flowchart, DFD, architecture…
⌥⌘T
✦ T
—
Connect to…
Connect mode from the selection
⇧⌘L
✦ C
↶
Undo last conversion
Back to Mind Map in one step
⌘Z
—
⧉
Copy as Mermaid (convert on copy)
Flowchart flavour chosen from type
⌃⌘C
—
◎
Select by type · Container
4 nodes on this canvas
—
—
AI · ON-DEVICE
✦
Convert branch to a DFD with suggested node types
Result arrives as ghosts · one undo step
⇧⌘Space
SETTINGS
⚙
Shortcuts › Convert diagram type…
Rebind
↑↓ move
↩ run
⌘↩ run and keep open
⇥ show actions
Recent first, then fuzzy match
JUMP
pay
7 nodes · 3 canvases
Payments service
Platform reference › VPC › Private subnet
SERVICE
Payment provider
Checkout redesign › Level 1
ENTITY
Payment request
Checkout redesign › Level 1 › flow
EDGE
Payments threat model
Canvas
CANVAS
Payroll
Q1 roadmap › Finance
TOPIC
↩ flies the camera there (400 ms) and selects the node · ⇧↩ adds to selection
Linear/Raycast speed. Opens in under 50 ms, results update per keystroke, and the top result is always the one ↩ runs.
Every row teaches. Standard and Hyper keys sit on each command, so the palette doubles as the shortcut reference.
Context-aware. Commands that don’t apply to the selection are hidden, not greyed. “Select by type” lives here too.
```
