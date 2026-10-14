# F3 · Convert diagram type

- Source: `design/source/Convert.dc.html`
- Screenshot: `screenshots/10-Convert.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
F3 · CONVERT · ⌥⌘T
One action, animated, reversible
⌘Z
returns to the previous type in one step
Convert “Checkout redesign” to…
Filter types
Mind Map
1
Logic Chart
2
Org Chart
3
Timeline
4
Flowchart
5
Data Flow
6
Architecture
7
Sequence
8
Previews are rendered from this canvas, not a stock thumbnail. Arrow keys move; ↩ converts; Esc closes. Hierarchy types convert losslessly; technical types ask for node types next.
Confirm node types
Data Flow needs to know what each first-level branch is. Suggestions came from the on-device model.
Customer
✦
Type for Customer
External entity
Process
Data store
External entity
Cart service
✦
Type for Cart service
Process
Process
Data store
External entity
Payment provider
✦
Type for Payment provider
External entity
Process
Data store
External entity
Orders DB
✦
Type for Orders DB
Data store
Process
Data store
External entity
Fraud check
✦
Type for Fraud check
Process
Process
Data store
External entity
Back
Convert · ↩
0 ms · mind map
selection kept
300 ms · nodes in flight
edges fade, glide curve
620 ms · flowchart
badges fade in
```
