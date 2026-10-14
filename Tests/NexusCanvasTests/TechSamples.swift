import Foundation
import NexusCore

/// The artboards' sample canvases (18–23), built through the editor like a user would.
enum TechSamples {
    static func canvas(
        _ title: String, type: DiagramType, root: String, _ build: (inout CanvasEditor, NodeID) throws -> Void
    ) -> Canvas {
        var c = Canvas(id: "c1", title: title, type: type, rootText: root)
        var undo = UndoStack()
        try! c.edit("Seed", undo: &undo) { e in try build(&e, e.canvas.root) }
        return c
    }

    @discardableResult
    static func add(
        _ e: inout CanvasEditor, _ parent: NodeID, _ text: String, _ type: NodeType? = nil, label: String? = nil,
        lane: String? = nil
    ) throws -> NodeID {
        let n = try e.addChild(of: parent, text: text)
        e.update(n) {
            $0.nodeType = type
            $0.edgeLabel = label
            $0.lane = lane
        }
        return n
    }

    static func link(_ e: inout CanvasEditor, _ a: NodeID, _ b: NodeID, _ label: String, kind: String? = nil) {
        e.connect(a, to: b)
        let id = e.canvas.relationships.last!.id
        e.updateRelationship(id) {
            $0.label = label
            $0.kind = kind
            $0.dash = "solid"
            $0.line = "elbow"
            $0.width = 1.5
            $0.ends = ["none", "filled-arrow"]
        }
    }

    /// S5: password reset.
    static func flowchart() -> Canvas {
        canvas("Password reset", type: .flowchart, root: "Forgot password") { e, root in
            let email = try add(&e, root, "Enter email")
            let q = try add(&e, email, "Account exists?")
            let token = try add(&e, q, "Create reset token", label: "Yes")
            let neutral = try add(&e, q, "Show neutral message", label: "No")
            let send = try add(&e, token, "Email the link", .io)
            let done = try add(&e, send, "Done", .end)
            link(&e, neutral, done, "")
        }
    }

    /// S5: refund swimlane.
    static func swimlane() -> Canvas {
        var c = canvas("Refund", type: .swimlane, root: "Request refund") { e, root in
            e.update(root) {
                $0.lane = "customer"
                $0.nodeType = .process
            }
            let review = try add(&e, root, "Review", lane: "support")
            let approve = try add(&e, review, "Approve", lane: "finance")
            try add(&e, approve, "Refunded", .end, lane: "customer")
        }
        c.diagram.lanes = [
            Lane(id: "customer", title: "Customer"), Lane(id: "support", title: "Support"),
            Lane(id: "finance", title: "Finance"),
        ]
        return c
    }

    /// S6: checkout DFD.
    static func dfd() -> Canvas {
        canvas("Checkout redesign", type: .dfd, root: "Checkout redesign") { e, root in
            let customer = try add(&e, root, "Customer", .entity)
            let place = try add(&e, customer, "Place order", .process, label: "order details")
            let auth = try add(&e, place, "Authorize payment", .process, label: "payment req")
            let orders = try add(&e, place, "Orders", .store, label: "order")
            let provider = try add(&e, auth, "Payment provider", .entity, label: "auth request")
            let tokens = try add(&e, auth, "Card tokens", .store, label: "token")
            let fulfil = try add(&e, orders, "Fulfil order", .process, label: "pending orders")
            link(&e, provider, auth, "auth result")
            link(&e, fulfil, customer, "shipping notice")
            link(&e, customer, orders, "receipt")
            let b = try e.addBoundary(around: [place, auth, orders, fulfil, tokens], title: "Internal network")
            e.updateBoundary(b) {
                $0.meaning = "trust"
                $0.dash = "dashed"
            }
            let pci = try e.addBoundary(around: [auth, tokens], title: "PCI zone")
            e.updateBoundary(pci) {
                $0.meaning = "zone"
                $0.hatch = true
                $0.color = "#E5484D"
            }
        }
    }

    /// S7: payments threat model.
    static func threatModel() -> Canvas {
        canvas("Payments threat model", type: .threatModel, root: "Payments threat model") { e, root in
            let auth = try add(&e, root, "Authorize payment", .process)
            let provider = try add(&e, auth, "Payment provider", .entity)
            let tokens = try add(&e, auth, "Card tokens", .store)
            let spoof = try e.addThreat(
                on: provider, category: .spoofing, title: "Spoofed provider callback", risk: "High")
            try add(&e, spoof, "Mutual TLS", .mitigation)
            try e.addThreat(on: auth, category: .infoDisclosure, title: "Card data in logs", risk: "High")
            try e.addThreat(on: tokens, category: .tampering, title: "Token table tampering", risk: "Med")
            try add(&e, tokens, "Cardholder data", .asset)
            let pci = try e.addBoundary(around: [auth, provider, tokens], title: "Trust low→high")
            e.updateBoundary(pci) {
                $0.meaning = "trust"
                $0.hatch = true
            }
        }
    }

    /// S8: platform reference architecture.
    static func architecture() -> Canvas {
        canvas("Platform reference", type: .architecture, root: "Platform reference") { e, root in
            let users = try add(&e, root, "Users", "actor")
            let gw = try add(&e, users, "edge-gw", "gateway", label: "HTTPS")
            let auth = try add(&e, gw, "auth", "service", label: "gRPC")
            try add(&e, auth, "sessions", "cache", label: "RESP")
            let orders = try add(&e, gw, "orders", "service", label: "gRPC")
            try add(&e, orders, "postgres", "db", label: "SQL · 5432")
            let events = try add(&e, orders, "order-events", "queue", label: "AMQP")
            let worker = try add(&e, events, "fulfil-worker", "container", label: "AMQP")
            try add(&e, worker, "payments", "saas", label: "HTTPS")
            let ids = e.canvas.nodes.filter {
                ["auth", "sessions", "orders", "postgres", "order-events", "fulfil-worker"].contains($0.value.text)
            }.map(\.key)
            let priv = try e.addBoundary(around: ids, title: "Private subnet")
            e.updateBoundary(priv) { $0.meaning = "subnet" }
            let vpc = try e.addBoundary(around: ids + [gw], title: "prod 10.0.0.0/16")
            e.updateBoundary(vpc) { $0.meaning = "vpc" }
        }
    }

    /// S9: sign-in sequence.
    static func sequence() -> Canvas {
        canvas("Sign-in flow", type: .sequence, root: "Sign-in flow") { e, root in
            let user = try add(&e, root, "User", "actor")
            let web = try add(&e, root, "Web app")
            let auth = try add(&e, root, "Auth service")
            let db = try add(&e, root, "Users DB", "db")
            func msg(_ a: NodeID, _ b: NodeID, _ l: String, _ ret: Bool = false) {
                e.connect(a, to: b)
                e.updateRelationship(e.canvas.relationships.last!.id) {
                    $0.label = l
                    $0.kind = ret ? "return" : "message"
                }
            }
            msg(user, web, "Sign in")
            msg(web, auth, "POST /token")
            msg(auth, db, "SELECT user")
            msg(db, auth, "row", true)
            msg(auth, web, "200 · JWT", true)
            msg(web, user, "dashboard", true)
            msg(web, auth, "refresh tok")
        }
    }

    /// S4: the launch plan with details for every structure.
    static func structures(_ s: LayoutStructure) -> Canvas {
        var c = canvas("Launch plan", type: .mindmap, root: "Launch plan") { e, root in
            for (m, subs) in [
                ("Positioning", ["Developers", "Teams"]), ("Pricing", ["Free tier", "Pro"]),
                ("Channels", ["Newsletter", "Product Hunt"]), ("Timeline", ["Beta · Nov", "GA · Jan"]),
            ] {
                let id = try e.addChild(of: root, text: m)
                for x in subs { try e.addChild(of: id, text: x) }
            }
        }
        c.layout.structure = s
        return c
    }
}
