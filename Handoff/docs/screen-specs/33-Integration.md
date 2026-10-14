# macOS 27 integration & import

- Source: `design/source/Integration.dc.html`
- Screenshot: `screenshots/33-Integration.png`
- Artboard size: 1440×1040 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
MACOS 27 · FEELS APPLE-MADE · FILES THAT OUTLIVE THE APP
Quick Capture, widgets, Quick Look, Shortcuts, and the .nexus package
Try a pricing page A/B test
→ Inbox map · Product ideas
↩ save · ⇥ choose map
✦ N
from any app
Quick Capture
A small glass panel jots an idea into an inbox map without switching apps. Services menu and Share extension send selected text the same way.
INBOX
A/B pricing page
Webhook retries
+5 more
RECENT MAPS
Checkout DFD
Q1 roadmap
SPOTLIGHT · “card tokens”
D2 Card tokens
Checkout redesign.nexus › Level 1
Widgets & Spotlight
Recent maps and the inbox map on the desktop. Spotlight indexes node text and opens straight to the node.
Launch plan.nexus
Open with OpenNexus
Quick Look
Space
Finder thumbnails and a full preview from the package’s rendered snapshot; no app launch.
SHORTCUTS · APP INTENTS · SIRI
Create mind map from clipboard
Add idea to inbox map
Export canvas as PNG
Convert map to Mermaid
Open Quick Capture
Shortcuts
Every intent is also exposed to Siri. Handoff and iCloud Drive sync with no proprietary cloud.
LAUNCH PLAN.NEXUS/ · FOLDER BUNDLE
manifest.json schema 1.0 · app 1.0
canvases/
product-map.json
rollout-flow.json
threats.json
assets/ images, attachments
preview.png Quick Look
{ "id": "n_7f2", "type": "service",
  "title": "Payments", "parent": "n_1a0",
  "fields": { "protocol": "gRPC" } }
Native format
Human-readable JSON per canvas, stable key order so Git diffs are clean, published schema. Autosave and File › Revert To built in.
IMPORT REPORT · Strategy 2026.xmind
4
sheets → canvases
312
topics, markers, notes
2
not converted
· Audio note on “Kickoff” (kept as attachment)
· Gantt task dates (not in v1)
Also imports MindNode, Word (.docx), TextBundle, OPML, Markdown, Mermaid, PlantUML subset, draw.io, FreeMind, MindManager and EdrawMind (best effort), indented text, and images or PDFs via AI.
Import
.xmind is the migration path. Pasting Markdown or indented text onto the canvas creates a branch directly.
```
