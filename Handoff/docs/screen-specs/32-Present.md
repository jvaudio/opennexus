# F6 · Present mode stepping a DFD

- Source: `design/source/Present.dc.html`
- Screenshot: `screenshots/32-Present.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
CHECKOUT · DATA FLOW · STEP 3 OF 5
Payment request reaches the PCI zone
PCI ZONE
Customer
1.0
Place order
2.0
Authorize
payment
Payment provider
D2
Card tokens
payment request
SLIDES · AUTO-GENERATED · DRAG TO REORDER
Transition
Glide
Zoom
Cut
Step through flow ✓
16:9 ▾
Dark ▾
? keys
01
Title · Checkout data flow
02
Customer places order
03
Payment request → PCI zone
04
Provider returns result
05
Token stored in D2 · skipped
06
Fulfilment
→
next step
S
skip
M
merge with next
H
hide topic from slides
esc
end
Export: PDF · PowerPoint · Keynote · Video
PRESENTER VIEW · DISPLAY 2
06:42
Next
Provider returns auth result
Call out that the request crosses the PCI boundary here; mTLS mitigates T-01.
```
