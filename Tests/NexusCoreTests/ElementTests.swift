import Testing

@testable import NexusCore

private func id(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }

@Suite struct ElementTests {
    /// Every element operation is exactly one undo step that restores the canvas.
    @Test func elementOperationsAreSingleUndoSteps() throws {
        let original = sampleCanvas()
        var c = original
        var undo = UndoStack()
        let pricing = id(c, "Pricing")
        let kids = c.nodes[pricing]!.children
        let ops: [(String, (inout CanvasEditor) throws -> Void)] = [
            ("Boundary", { _ = try $0.addBoundary(around: [pricing], title: "Money") }),
            ("Summary", { _ = try $0.addSummary(over: [kids[0], kids[2]]) }),
            ("Callout", { _ = try $0.addCallout(on: pricing, text: "Check") }),
            ("Zone", { _ = $0.addZone(origin: CanvasPoint(x: 600, y: -200)) }),
            ("Connect", { $0.connect(pricing, to: id(original, "Risks")) }),
            ("Move", { try $0.move(kids[1], toParent: id(original, "Channels")) }),
            ("Detach", { try $0.detach(id(original, "Teams"), at: CanvasPoint(x: 500, y: 400)) }),
        ]
        for (name, op) in ops {
            let before = c
            let count = undo.undoStack.count
            try c.edit(name, undo: &undo) { try op(&$0) }
            #expect(undo.undoStack.count == count + 1, "\(name) should record one step")
            #expect(c.validate().isEmpty, "\(name) left the canvas invalid")
            var probe = c
            undo.undoStack.last!.inverted.apply(to: &probe)
            #expect(probe == before, "\(name) didn't undo cleanly")
        }
        while let p = undo.undo() { p.apply(to: &c) }
        #expect(c == original)
    }

    @Test func summaryNeedsSiblings() {
        var c = sampleCanvas()
        var undo = UndoStack()
        let (pro, teams) = (id(c, "Pro"), id(c, "Teams"))
        #expect(throws: ElementRefusal.summaryNeedsSiblings) {
            try c.edit("Summary", undo: &undo) { _ = try $0.addSummary(over: [pro, teams]) }
        }
        #expect(undo.undoStack.isEmpty)
    }

    /// Deleting a topic takes its dependent elements with it, in the same step.
    @Test func deletingTopicsCleansUpElements() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let pricing = id(c, "Pricing")
        let kids = c.nodes[pricing]!.children
        let (risks, teams) = (id(c, "Risks"), id(c, "Teams"))
        try c.edit("Setup", undo: &undo) { e in
            _ = try e.addBoundary(around: [pricing, risks])
            _ = try e.addSummary(over: [kids[0], kids[1]])
            let k = try e.addCallout(on: kids[2])
            try e.addChild(of: k, text: "Nested in callout")
            e.connect(kids[0], to: teams)
            e.connect(teams, to: risks)
        }
        let setup = c
        try c.edit("Delete", undo: &undo) { _ = try $0.delete([pricing]) }
        #expect(c.validate().isEmpty)
        #expect(c.summaries.isEmpty)
        #expect(c.callouts.isEmpty)
        #expect(!c.nodes.values.contains { $0.text == "Nested in callout" })
        #expect(c.boundaries.count == 1 && c.boundaries[0].nodes == [risks])
        #expect(c.relationships.count == 1)
        undo.undo()!.apply(to: &c)
        #expect(c == setup)
    }

    @Test func elementTopicsStayWithTheirElement() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let pricing = id(c, "Pricing")
        let kids = c.nodes[pricing]!.children
        let topic = try c.edit("Summary", undo: &undo) { try $0.addSummary(over: [kids[0], kids[1]]) }
        #expect(throws: ElementRefusal.belongsToElement) {
            try c.edit("Move", undo: &undo) { try $0.move(topic, toParent: $0.canvas.root) }
        }
        #expect(throws: ElementRefusal.wouldCreateCycle) {
            try c.edit("Move", undo: &undo) { try $0.move(pricing, toParent: kids[0]) }
        }
    }

    /// Direct manipulation: drop as child, before/after a sibling, detach, re-attach.
    @Test func dragOperations() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let channels = id(c, "Channels")
        let pro = id(c, "Pro")
        try c.edit("Move", undo: &undo) { try $0.move(pro, toParent: channels) }
        #expect(c.nodes[channels]!.children.last == pro)
        // Before the first sibling.
        try c.edit("Move", undo: &undo) { try $0.move(pro, toParent: channels, at: 0) }
        #expect(c.nodes[channels]!.children.first == pro)
        // After itself within the same parent is a no-op on order.
        let order = c.nodes[channels]!.children
        try c.edit("Move", undo: &undo) { try $0.move(pro, toParent: channels, at: 1) }
        #expect(c.nodes[channels]!.children == order)
        try c.edit("Detach", undo: &undo) { try $0.detach(pro, at: CanvasPoint(x: 300, y: 300)) }
        #expect(c.floating.contains(pro) && c.nodes[pro]!.kind == .floating)
        let zone = try c.edit("Zone", undo: &undo) { e in e.addZone(origin: CanvasPoint(x: 250, y: 250)) }
        try c.edit("Drag", undo: &undo) { try $0.moveFloating(pro, to: CanvasPoint(x: 320, y: 310)) }
        #expect(c.zones[0].members == [pro])
        try c.edit("Zone", undo: &undo) { $0.moveZone(zone, by: 100, 50) }
        #expect(c.nodes[pro]!.position == CanvasPoint(x: 420, y: 360))
        try c.edit("Attach", undo: &undo) { try $0.move(pro, toParent: $0.canvas.root) }
        #expect(!c.floating.contains(pro) && c.nodes[pro]!.kind == .topic && c.zones[0].members.isEmpty)
        let risks = id(c, "Risks")
        let copy = try c.edit("Duplicate", undo: &undo) { try $0.duplicate(channels, toParent: risks) }
        #expect(c.nodes[copy]!.children.count == c.nodes[channels]!.children.count)
        #expect(c.validate().isEmpty)
    }

    /// Elements, enrichments and rich text round-trip through JSON, unknown keys included.
    @Test func elementsRoundTripJSON() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let pricing = id(c, "Pricing")
        let kids = c.nodes[pricing]!.children
        try c.edit("Setup", undo: &undo) { e in
            let b = try e.addBoundary(around: [pricing], title: "VPC")
            e.updateBoundary(b) {
                $0.meaning = "vpc"
                $0.trust = "low"
                $0.hatch = true
                $0.extra["future"] = .string("kept")
            }
            _ = try e.addSummary(over: [kids[0], kids[2]])
            e.updateSummary(e.canvas.summaries[0].id) { $0.bracket = "square" }
            _ = try e.addCallout(on: pricing)
            _ = e.addZone(origin: CanvasPoint(x: 10, y: 20), members: [])
            e.connect(pricing, to: kids[0])
            let r = e.canvas.relationships[0].id
            e.updateRelationship(r) {
                $0.line = "elbow"
                $0.ends = ["dot", "filled-arrow"]
                $0.kind = "dataflow"
                $0.color = "source"
                $0.bend = CanvasPoint(x: 5, y: 5)
            }
            e.update(pricing) {
                $0.marks = [TextMark(start: 0, length: 3, bold: true, link: "https://example.com")]
                $0.sticker = AssetRef(asset: "🚀")
                $0.image = AssetRef(asset: "assets/abc.png", width: 120, height: 80)
                $0.attachments = [AssetRef(asset: "assets/def.pdf", name: "Spec.pdf")]
                $0.audio = AudioNote(asset: "assets/ghi.m4a", duration: 4.5)
            }
        }
        let decoded = try Canvas(json: c.json, path: "c")
        #expect(decoded == c)
        #expect(decoded.boundaries[0].extra["future"] == .string("kept"))
        #expect(decoded.json == c.json)
    }

    @Test func topicLinksParse() {
        let link = TopicLink.make(canvas: "c2", node: "n7")
        #expect(link == "nexus:topic/c2/n7")
        let parsed = TopicLink.parse(link)
        #expect(parsed?.canvas == "c2" && parsed?.node == "n7")
        #expect(TopicLink.parse("https://example.com") == nil)
    }
}
