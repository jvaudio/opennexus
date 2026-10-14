# S7 · Threat model

- Source: `design/source/ThreatModel.dc.html`
- Screenshot: `screenshots/21-ThreatModel.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
Payments threat model.nexus
9 threats · 3 open High
Threat Model
⌥⌘T
Colour by risk
✦ Suggest STRIDE threats
Export…
PCI ZONE · TRUST LOW→HIGH
2.0
Authorize payment
Payment provider
D2
Card tokens
Spoofed provider callback
H
Token table tampering
M
Card data in logs
H
Mutual TLS
Cardholder data
ASSET
✦ 3 more STRIDE threats suggested for 2.0
Repudiation · DoS · Elevation
⌃⇧↩
accept all
Style
Branch
Canvas
Data
STRIDE
PROCESS · 2.0
Authorize payment
S
Spoofing
Forged provider callback
High
T
Tampering
Amount altered in transit
Med
R
Repudiation
✦ Suggested · no signed audit log
Med
I
Info disclosure
Card data in debug logs
High
D
Denial of service
✦ Suggested · retry storms
Low
E
Elevation
Not applicable
N/A
Owner
Payments team
Data class.
PCI · Restricted
Protocol
HTTPS / mTLS
Threat table · filter: Open
Export CSV
Copy as Markdown
ID
Element
STRIDE
Threat
Risk
Mitigation
Status
T-01
2.0 Authorize payment
Spoofing
Forged provider callback
High
Mutual TLS
Mitigated
T-02
2.0 Authorize payment
Info disclosure
Card data written to debug logs
High
—
Open
T-03
D2 Card tokens
Tampering
Token table edited outside service
Med
Row-level signing
In review
T-04
Payment provider
Repudiation
Disputed charge without evidence
Med
—
Open
```
