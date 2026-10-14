import Foundation
import Testing

@testable import NexusCore

private func id(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }

/// Everything Convert must never touch.
private func content(_ c: Canvas) -> Canvas {
    var x = c
    x.type = .mindmap
    x.layout = CanvasLayout()
    x.diagram = DiagramData()
    for k in x.nodes.keys { x.nodes[k]!.nodeType = nil }
    return x
}

/// Artboard 20's checkout DFD as a tree plus relationships.
func checkoutDFD() -> Canvas {
    var c = Canvas(id: "c1", title: "Checkout redesign", type: .dfd, rootText: "Checkout redesign")
    var undo = UndoStack()
    c.edit("Seed", undo: &undo) { e in
        let root = e.canvas.root
        let customer = try! e.addChild(of: root, text: "Customer")
        let place = try! e.addChild(of: customer, text: "Place order")
        e.update(place) { $0.edgeLabel = "order details" }
        let auth = try! e.addChild(of: place, text: "Authorize payment")
        e.update(auth) { $0.edgeLabel = "payment req" }
        let provider = try! e.addChild(of: auth, text: "Payment provider")
        e.update(provider) { $0.edgeLabel = "auth request" }
        let tokens = try! e.addChild(of: auth, text: "Card tokens")
        e.update(tokens) { $0.edgeLabel = "token" }
        let orders = try! e.addChild(of: place, text: "Orders")
        e.update(orders) { $0.edgeLabel = "order" }
        let fulfil = try! e.addChild(of: orders, text: "Fulfil order")
        e.update(fulfil) { $0.edgeLabel = "pending orders" }
        for (n, t) in [
            (customer, NodeType.entity), (place, .process), (auth, .process), (provider, .entity), (tokens, .store),
            (orders, .store), (fulfil, .process),
        ] {
            e.update(n) { $0.nodeType = t }
        }
        e.connect(provider, to: auth)
        e.updateRelationship(e.canvas.relationships[0].id) { $0.label = "auth result" }
        e.connect(fulfil, to: customer)
        e.updateRelationship(e.canvas.relationships[1].id) { $0.label = "shipping notice" }
        // The violation on the artboard: an entity writes straight to a store.
        e.connect(customer, to: orders)
        e.updateRelationship(e.canvas.relationships[2].id) { $0.label = "receipt" }
    }
    return c
}

@Suite struct ConvertTests {
    /// Property test (acceptance): map → flowchart → DFD → map is lossless for random maps.
    @Test(arguments: Array(UInt64(1)...30)) func convertChainIsLossless(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var c = sampleCanvas()
        var undo = UndoStack()
        for _ in 0..<60 { randomOperation(&c, &undo, &rng) }
        let original = c
        var types: [NodeID: NodeType] = [:]
        for k in c.nodes[c.root]!.children { types[k] = NodeTypeSuggester.dfd(c.nodes[k]!.text) }
        c.edit("To flowchart", undo: &undo) { $0.convert(to: .flowchart) }
        #expect(c.type == .flowchart && c.layout.structure == .flowDown)
        c.edit("To DFD", undo: &undo) { $0.convert(to: .dfd, nodeTypes: types) }
        #expect(c.type == .dfd)
        c.edit("To map", undo: &undo) { $0.convert(to: .mindmap) }
        #expect(c.type == .mindmap)
        #expect(c.layout.structure == original.layout.structure, "the original structure comes back")
        #expect(content(c) == content(original), "nodes, text, hierarchy, relationships and elements unchanged")
        #expect(c.validate().isEmpty)
        // Confirmed node types are kept for the next technical conversion.
        for (k, t) in types { #expect(c.nodes[k]?.nodeType == t) }
        // Three undo steps return to the original exactly.
        for _ in 0..<3 { undo.undo()!.apply(to: &c) }
        #expect(c == original)
    }

    @Test func hierarchyRoundTripIsExact() {
        var c = sampleCanvas()
        var undo = UndoStack()
        let original = c
        c.edit("To flowchart", undo: &undo) { $0.convert(to: .flowchart) }
        c.edit("To map", undo: &undo) { $0.convert(to: .mindmap) }
        #expect(c == original)
        c.edit("To org", undo: &undo) { $0.convert(to: .org) }
        #expect(c.layout.structure == .orgDown)
        #expect(content(c) == content(original))
    }

    @Test func inferenceFollowsTheArtboards() {
        var c = sampleCanvas()
        var undo = UndoStack()
        c.edit("Q", undo: &undo) { e in
            let q = try! e.addChild(of: e.canvas.root, text: "Account exists?")
            _ = try! e.addChild(of: q, text: "Done")
            e.convert(to: .flowchart)
        }
        #expect(DiagramCatalog.effectiveType(c.root, in: c) == .start)
        #expect(DiagramCatalog.effectiveType(id(c, "Account exists?"), in: c) == .decision)
        #expect(DiagramCatalog.effectiveType(id(c, "Done"), in: c) == .end)
        #expect(DiagramCatalog.effectiveType(id(c, "Pricing"), in: c) == .process)
        #expect(NodeTypeSuggester.dfd("Orders DB") == .store)
        #expect(NodeTypeSuggester.dfd("Customer") == .entity)
        #expect(NodeTypeSuggester.dfd("Fraud check") == .process)
        #expect(NodeTypeSuggester.architecture("postgres") == "db")
        #expect(NodeTypeSuggester.architecture("order-events") == "queue")
        #expect(NodeTypeSuggester.architecture("edge-gw") == "gateway")
        #expect(NodeTypeSuggester.architecture("orders") == "service")
        #expect(DiagramCatalog.icons.count == 32)
        #expect(Set(DiagramCatalog.icons.map(\.slug)).count == 32)
    }
}

@Suite struct DFDRuleTests {
    @Test func artboardViolationIsFound() {
        let c = checkoutDFD()
        let v = DFDRules.check(c)
        let skips = v.filter { $0.rule == .touchesProcess }
        #expect(skips.count == 1)
        let r = skips[0]
        #expect(r.title == "A data flow must touch a process")
        #expect(
            r.detail == "“receipt” goes from Customer straight to D1 Orders. Entities can’t write to stores directly.")
        #expect(r.fixes.first == .insertProcess(flow: c.relationships[2].id))
        #expect(r.fixes.contains(.rerouteVia(flow: c.relationships[2].id, process: id(c, "Place order"))))
        #expect(!v.contains { $0.rule == .storeWritten })
        #expect(!v.contains { $0.rule == .processIO })
        let summary = DFDRules.summary(v)
        #expect(summary[0].text == "1 flow skips a process" && !summary[0].ok)
        #expect(summary[1].text == "Stores all written" && summary[1].ok)
        #expect(DFDRules.numbers(c)[id(c, "Authorize payment")] == "2.0")
        #expect(DFDRules.numbers(c)[id(c, "Orders")] == "D1")
        #expect(DFDRules.numbers(c)[id(c, "Card tokens")] == "D2")
        #expect(DFDRules.numbers(c)[id(c, "Fulfil order")] == "3.0")
    }

    @Test func fixesClearTheViolation() throws {
        for fix in 0..<3 {
            var c = checkoutDFD()
            var undo = UndoStack()
            let v = DFDRules.check(c).first { $0.rule == .touchesProcess }!
            try c.edit("Fix", undo: &undo) { _ = try $0.apply(v.fixes[fix], violation: v.id) }
            #expect(!DFDRules.check(c).contains { $0.rule == .touchesProcess }, "fix \(v.fixes[fix])")
            #expect(c.validate().isEmpty)
            undo.undo()!.apply(to: &c)
            #expect(c == checkoutDFD())
        }
    }

    @Test func otherRules() {
        var c = checkoutDFD()
        var undo = UndoStack()
        let customer = id(c, "Customer")
        c.edit("Break", undo: &undo) { e in
            let lonely = try! e.addChild(of: e.canvas.root, text: "Audit log")
            e.update(lonely) { $0.nodeType = .store }
            let sink = try! e.addChild(of: customer, text: "Black hole")
            e.update(sink) { $0.nodeType = .process }
        }
        let v = DFDRules.check(c)
        #expect(v.contains { $0.rule == .storeWritten && $0.subject == .node(id(c, "Audit log")) })
        #expect(v.contains { $0.rule == .processIO && $0.title == "A process with no output" })
        #expect(v.contains { $0.rule == .labelled })
    }

    @Test func levelsBalance() {
        var parent = checkoutDFD()
        var child = Canvas(id: "c2", title: "2.0 Authorize payment", type: .dfd, rootText: "Authorize payment")
        var undo = UndoStack()
        let auth = id(parent, "Authorize payment")
        parent.edit("Link", undo: &undo) { $0.update(auth) { $0.subCanvas = "c2" } }
        child.edit("Seed", undo: &undo) { e in
            let place = try! e.addChild(of: e.canvas.root, text: "Place order")
            e.update(place) { $0.nodeType = .entity }
            let check = try! e.addChild(of: place, text: "Check card")
            e.update(check) {
                $0.nodeType = .process
                $0.edgeLabel = "payment req"
            }
        }
        let unbalanced = DFDRules.check(parent) { $0 == "c2" ? child : nil }
        #expect(unbalanced.contains { $0.rule == .levelsBalanced })
        child.edit("Balance", undo: &undo) { e in
            let check = id(e.canvas, "Check card")
            for (text, label, type) in [
                ("Payment provider", "auth request", NodeType.entity), ("Card tokens", "token", .store),
            ] {
                let n = try! e.addChild(of: check, text: text)
                e.update(n) {
                    $0.nodeType = type
                    $0.edgeLabel = label
                }
            }
            let provider = id(e.canvas, "Payment provider")
            e.connect(provider, to: check)
            e.updateRelationship(e.canvas.relationships[0].id) { $0.label = "auth result" }
        }
        let balanced = DFDRules.check(parent) { $0 == "c2" ? child : nil }
        #expect(!balanced.contains { $0.rule == .levelsBalanced })
    }

    @Test func ignoreSticks() throws {
        var c = checkoutDFD()
        var undo = UndoStack()
        let v = DFDRules.check(c).first { $0.rule == .touchesProcess }!
        try c.edit("Ignore", undo: &undo) { _ = try $0.apply(.ignore, violation: v.id) }
        #expect(!DFDRules.check(c).contains { $0.id == v.id })
        let json = c.json
        #expect(try Canvas(json: json, path: "c").diagram.ignoredRules == [v.id])
    }
}

@Suite struct StrideTests {
    @Test func tableAndSuggestions() throws {
        var c = checkoutDFD()
        var undo = UndoStack()
        c.type = .threatModel
        let auth = id(c, "Authorize payment")
        try c.edit("Threats", undo: &undo) { e in
            let t = try e.addThreat(on: auth, category: .spoofing, title: "Forged provider callback", risk: "High")
            let m = try e.addChild(of: t, text: "Mutual TLS")
            e.update(m) { $0.nodeType = .mitigation }
            try e.addThreat(on: auth, category: .infoDisclosure, title: "Card data, \"debug\" logs", risk: "High")
        }
        let threats = Stride.threats(c)
        #expect(threats.map(\.id) == ["T-01", "T-02"])
        #expect(threats[0].elementName == "2.0 Authorize payment")
        #expect(threats[0].mitigation == "Mutual TLS" && threats[0].status == "Open")
        let csv = Stride.csv(threats)
        #expect(csv.hasPrefix("ID,Element,STRIDE,Threat,Risk,Mitigation,Status\r\n"))
        #expect(csv.contains("\"Card data, \"\"debug\"\" logs\""))
        let md = Stride.markdown(threats)
        #expect(
            md.contains(
                "| T-01 | 2.0 Authorize payment | Spoofing | Forged provider callback | High | Mutual TLS | Open |"))
        // Suggestions skip covered categories and follow STRIDE-per-element.
        let s = Stride.suggestions(for: auth, in: c)
        #expect(s.map(\.0) == [.tampering, .repudiation, .denialOfService, .elevation])
        #expect(Stride.suggestions(for: id(c, "Customer"), in: c).map(\.0) == [.spoofing, .repudiation])
        #expect(Stride.suggestions(for: id(c, "Card tokens"), in: c).first?.0 == .tampering)
    }
}

@Suite struct MermaidTests {
    @Test func sequenceText() {
        var c = Canvas(id: "c1", title: "Sign-in flow", type: .sequence, rootText: "Sign-in flow")
        var undo = UndoStack()
        c.edit("Seed", undo: &undo) { e in
            let root = e.canvas.root
            let u = try! e.addChild(of: root, text: "User")
            e.update(u) { $0.nodeType = "actor" }
            let w = try! e.addChild(of: root, text: "Web app")
            e.connect(u, to: w)
            e.updateRelationship(e.canvas.relationships[0].id) { $0.label = "Sign in" }
            e.connect(w, to: u)
            e.updateRelationship(e.canvas.relationships[1].id) {
                $0.label = "dashboard"
                $0.kind = "return"
            }
        }
        #expect(
            Mermaid.sequence(c) == """
                sequenceDiagram
                    title Sign-in flow
                    actor P1 as User
                    participant P2 as Web app
                    P1->>P2: Sign in
                    P2-->>P1: dashboard

                """)
    }

    @Test func flowchartText() {
        var c = Canvas(id: "c1", title: "Reset", type: .flowchart, rootText: "Forgot password")
        var undo = UndoStack()
        c.edit("Seed", undo: &undo) { e in
            let q = try! e.addChild(of: e.canvas.root, text: "Account exists?")
            let y = try! e.addChild(of: q, text: "Create \"reset\" token")
            e.update(y) { $0.edgeLabel = "Yes" }
        }
        #expect(
            Mermaid.flowchart(c) == """
                flowchart TD
                    n1(["Forgot password"])
                    n2{"Account exists?"}
                    n3["Create #quot;reset#quot; token"]
                    n1 --> n2
                    n2 -->|Yes| n3

                """)
    }
}
