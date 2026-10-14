# 08 · Edges & elements

- Source: `design/source/Elements.dc.html`
- Screenshot: `screenshots/12-Elements.png`
- Artboard size: 1440×1100 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
08 · EDGES & ELEMENTS · EVERYTHING IS A NODE OR AN EDGE
Xmind’s elements, generalised for technical diagrams
Branch lines
AUTO
Curved · default
Straight
Elbow
Rounded elbow
Tapered · by depth
Drawn by the layout. Thickness steps down with depth (3 · 2 · 1.6 pt).
Relationship
⇧⌘L
drives
Channels
Timeline
Free line between any two nodes. Shape, dash, start/end caps, label position. Drag a node’s edge handle with the mouse.
Technical edges
TYPED
card data
gRPC :8443
200 OK
Data flow (DFD)
Call · protocol label
Return message (sequence)
The relationship becomes a typed edge. Labels default to protocol (HTTPS, gRPC, SQL) in architecture canvases.
Boundary
⇧⌘B
Nine shapes plus title. Wraps a branch or any selection; doubles as group, zone or network.
Trust boundary · VPC · subnet
ZONES
VPC · prod-us-east
SUBNET · private
TRUST BOUNDARY
Boundaries carry semantics in technical canvases: dashed for trust boundaries, nested for region › VPC › subnet. Trust level adds a pattern, never colour alone.
Summary
⇧⌘]
Free tier
Pro
Enterprise
3 plans
Brackets selected siblings and spawns its own topic, which can have children.
Callout
⇧⌘C
Risks
Legal review due
before beta · Nov 3
Speech bubble bound to its node; the pointer stays attached as the layout reflows.
Note
⇧⌘N
Rollout notes
flags.beta = true
Rollout
≡
Rich document behind a node, in a side sheet: headings, lists, code, tables, images.
Hyperlink · topic link
⇧⌘K
Pricing page
↗
See: Risks
⤳
camera flies
to target
Links to a URL, a file, another node or another canvas. Topic links fly the camera.
Attachment · image
⇧⌘I
Contract v3
Quick Look · Space
Drag any file onto a node. Focus the indicator and Space opens Quick Look.
Equation · code block
/math · /code
E[X] = Σ xᵢ · p(xᵢ)
func
retry(op) {
for
i in 0..<3 { … }
}
LaTeX renders in the node. Code blocks get syntax highlighting, for engineers.
To-do · markers · labels
⌃0 · ⌃1–9
Draft pricing
1
Legal review
Q4
Finance
done sparkle
Simple checkbox to-dos only in v1; a branch with every to-do done sparkles once.
```
