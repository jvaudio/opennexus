# S9 · Sequence diagram

- Source: `design/source/Sequence.dc.html`
- Screenshot: `screenshots/23-Sequence.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
Sign-in flow.nexus
Sequence · 4 participants
Sequence
⌥⌘T
Paper
Copy as Mermaid
User
Web app
Auth service
Users DB
1 · Sign in
2 · POST /token
3 · SELECT user
row
200 · JWT
dashboard
7 · refresh tok
return message ready · ⌥↩
⇥
message to next participant
↩
next message in time
⌥↩
return message
activation bars are automatic
SAME KEYS · UML CLASS CANVAS
Session
CLASS
+ id: UUID
− token: String
+ expiresAt: Date
+ refresh(): Session
+ revoke(): Void
Type + expiresAt: Date and it formats itself: visibility glyph, name, coloured type. ⇥ adds a member, ↩ the next one.
— association
▷ inheritance
◆ composition
```
