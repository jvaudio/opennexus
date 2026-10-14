# S8 · Architecture diagram

- Source: `design/source/Architecture.dc.html`
- Screenshot: `screenshots/22-Architecture.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
Platform reference.nexus
Architecture · auto-layout
Architecture
⌥⌘T
Blueprint
Line grid
On-device · Apple
Icon library
⇧⌘Y
Search icons
DATA
Database
Cache
Queue
Storage
Stream
Data store
Document
Warehouse
COMPUTE
Service
Gateway
Function
Container
NETWORK
Region
Firewall
Router
SaaS
Drag onto the canvas, or ↩ to insert as a child of the selection. Icon packs install from file or URL.
REGION · us-east-1
VPC · prod 10.0.0.0/16
PUBLIC SUBNET
PRIVATE SUBNET
CLIENT
Users
API GATEWAY
edge-gw
SERVICE
auth
CACHE
sessions
SERVICE
orders
DATABASE
postgres
QUEUE
order-events
CONTAINER
fulfil-worker
EXT. SAAS
payments
HTTPS
gRPC
gRPC
RESP
AMQP
AMQP
HTTPS
SQL ▍
SQL · 5432
gRPC
HTTPS
⇥
dependency
↩
peer service
⇧⌘B
wrap in VPC/subnet
```
