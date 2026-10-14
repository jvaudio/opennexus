# S6 · Data flow diagram

- Source: `design/source/DFD.dc.html`
- Screenshot: `screenshots/20-DFD.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
Checkout redesign.nexus
Data Flow · Level 1
Context
›
Level 1
›
2.0 Authorize payment
⌘.
Data Flow
⌥⌘T
Graphite
On-device · Apple
LEVELS
Context (Level 0)
Level 1
1.0 Place order
2.0 Authorize payment
3.0 Fulfil order
RULE CHECKS
1 flow skips a process
Stores all written
Levels balanced
TRUST BOUNDARY · INTERNAL NETWORK
PCI ZONE
EXTERNAL ENTITY
Customer
PROCESS
1.0
Place order
PROCESS
2.0
Authorize payment
EXTERNAL ENTITY
Payment provider
PROCESS
3.0
Fulfil order
D1
Orders
DATA STORE
D2
Card tokens
order details
payment req
auth request
auth result
token
order
pending orders
shipping notice
receipt
!
A data flow must touch a process
“receipt” goes from Customer straight to D1 Orders. Entities can’t write to stores directly.
Insert process ↩
Reroute via 1.0
Ignore
⇥
downstream + flow
↩
sibling fed by same source
⌘.
drill into process
```
