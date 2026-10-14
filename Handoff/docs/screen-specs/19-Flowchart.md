# S5 · Flowchart & swimlane

- Source: `design/source/Flowchart.dc.html`
- Screenshot: `screenshots/19-Flowchart.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
Account recovery.nexus
2 canvases
Flowchart
⌥⌘T
Classic
Dot grid
On-device · Apple
Share
Password reset
Refund (swimlane)
START
Forgot password
PROCESS
Enter email
Account
exists?
DECISION
Create reset token
Email the link
I/O
Show neutral message
END
Done
Yes
No
⇥
from a Decision
adds a branch and opens its edge label pre-filled “Yes”, then “No”. ↩ adds a parallel step at the same level.
✦ Possibly missing
Rate-limit reset requests before “Create reset token”
⌃↩
insert ·
esc
dismiss
CUSTOMER
SUPPORT
FINANCE
Request refund
Review
Approve
Refunded
⌥↑
⌥↓
moves a step between lanes
HAND-OFF
SELECT
⇥
next step
↩
parallel step
/
shape
⇧⌘L
connect
```
