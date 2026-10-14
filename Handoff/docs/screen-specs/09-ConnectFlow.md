# F2 · Connect mode flow

- Source: `design/source/ConnectFlow.dc.html`
- Screenshot: `screenshots/09-ConnectFlow.png`
- Artboard size: 1440×1100 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
F2 · CONNECT MODE · ARCHITECTURE CANVAS
An edge to anything, without leaving the keyboard
Hints are assigned nearest-first so the likeliest target is always one key. Typing that matches no hint filters by text instead.
1
Select the source
⇧⌘L
CLIENT
Web app
API
Gateway
SVC
Orders
SVC
Auth
QUEUE
Events
CACHE
Sessions
DB
Postgres
SELECT
Auth service is selected. One chord enters Connect mode; no drag handle, no target hunting.
2
Hint chips pop in, nearest first
A S D F
CLIENT
Web app
F
API
Gateway
A
SVC
Orders
G
SVC
Auth
QUEUE
Events
H
CACHE
Sessions
D
DB
Postgres
S
Connect to
A
Gateway
S
Postgres
CONNECT
Everything else dims. Chips stagger in 40 ms apart. The closest node is pre-highlighted, so ↩ alone connects to it.
3
Type to filter by text
pos
CLIENT
Web app
API
Gateway
SVC
Orders
SVC
Auth
QUEUE
Events
CACHE
Sessions
DB
Postgres
S
Connect to
pos
S
Postgres
CONNECT
“pos” matches no hint, so it filters node text. A dashed preview line shows exactly what ↩ will draw.
4
Return draws it, label opens
↩
CLIENT
Web app
API
Gateway
SVC
Orders
SVC
Auth
QUEUE
Events
CACHE
Sessions
DB
Postgres
reads · SQL
EDIT
The edge draws on from source to target in 300 ms with a glow trail; its label is already in Edit mode. ↩ again commits; Esc anywhere leaves nothing behind.
```
