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

    /// D170: a relationship can end on a zone. Files without endpoint kinds still read as
    /// topics, a zone end writes `fromKind`/`toKind`, and repair, validation, removing the
    /// zone and merging all drop relationships to a missing zone.
    @Test func zoneRelationshipEnds() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let (pricing, risks) = (id(c, "Pricing"), id(c, "Risks"))
        var zone = ""
        try c.edit("Setup", undo: &undo) { e in
            zone = e.addZone(title: "Later", origin: CanvasPoint(x: 600, y: -300))
            e.connect(.topic(pricing), to: .zone(zone), label: "parks")
            e.connect(.zone(zone), to: .topic(risks))
        }
        #expect(c.validate().isEmpty)
        let json = c.relationships[0].json
        #expect(json.objectValue?["toKind"] == .string("zone") && json.objectValue?["fromKind"] == nil)
        #expect(c.relationships[1].json.objectValue?["fromKind"] == .string("zone"))
        let decoded = try Canvas(json: c.json, path: "c")
        #expect(decoded == c && decoded.json == c.json)
        // An older file: no kinds, both ends are topics, and nothing new is written.
        let old: JSONValue = [
            "id": "r9", "from": "n1", "to": "n2", "label": "", "line": "curved", "ends": ["none", "arrow"],
        ]
        let r = try Relationship(json: old, path: "r")
        #expect(r.from == .topic(NodeID("n1")) && r.to == .topic(NodeID("n2")) && r.json == old)
        #expect(r.topics?.from == NodeID("n1") && r.endZones.isEmpty)

        // Removing the zone takes its relationships, in the same undo step.
        let before = c
        try c.edit("Remove", undo: &undo) { $0.removeElement(.zone(zone)) }
        #expect(c.relationships.isEmpty && c.validate().isEmpty)
        undo.undo()!.apply(to: &c)
        #expect(c == before)

        // A hand-edited file whose zone is gone: validation says so, repair drops it.
        var broken = c
        broken.zones = []
        #expect(broken.validate().contains { $0.contains("missing topic or element") })
        let fixes = broken.repair()
        #expect(broken.relationships.isEmpty && broken.validate().isEmpty)
        #expect(fixes.contains { $0.contains("to missing topics or elements") })

        // Merge: the disk removed the zone while the app renamed a topic.
        var disk = c
        try disk.edit("Remove", undo: &undo) { $0.removeElement(.zone(zone)) }
        var current = c
        try current.edit("Rename", undo: &undo) { $0.setText(pricing, "Prices") }
        let merged = DocumentMerge(
            base: DocumentModel(canvases: [c]), current: DocumentModel(canvases: [current]),
            disk: DocumentModel(canvases: [disk])
        ).model.canvases[c.id]
        #expect(merged?.zones.isEmpty == true && merged?.relationships.isEmpty == true)
        #expect(merged?.nodes[pricing]?.text == "Prices" && merged?.validate().isEmpty == true)
    }

    /// D180, D181: relationships can end on a boundary or a summary's bracket.
    @Test func boundaryAndSummaryRelationshipEnds() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let (pricing, risks, channels) = (id(c, "Pricing"), id(c, "Risks"), id(c, "Channels"))
        let kids = c.nodes[pricing]!.children
        var (boundary, summary) = ("", "")
        try c.edit("Setup", undo: &undo) { e in
            boundary = try e.addBoundary(around: [channels], title: "Reach")
            _ = try e.addSummary(over: Array(kids.prefix(2)), text: "Paid")
            summary = e.canvas.summaries[0].id
            e.connect(.topic(risks), to: .boundary(boundary), label: "watches")
            e.connect(.summary(summary), to: .boundary(boundary))
        }
        #expect(c.validate().isEmpty)
        let first = c.relationships[0].json.objectValue
        #expect(first?["toKind"] == .string("boundary") && first?["fromKind"] == nil)
        let second = c.relationships[1].json.objectValue
        #expect(second?["fromKind"] == .string("summary") && second?["toKind"] == .string("boundary"))
        #expect(second?["from"] == .string(summary) && second?["to"] == .string(boundary))
        let decoded = try Canvas(json: c.json, path: "c")
        #expect(decoded == c && decoded.json == c.json)
        #expect(RelationshipEnd(kind: "boundary", id: "b1") == .boundary("b1"))
        #expect(RelationshipEnd(kind: "summary", id: "s1").kind == "summary")
        // A kind from a newer build reads as a topic id, so repair drops it.
        var future = c
        future.relationships[0].to = RelationshipEnd(kind: "lane", id: "l1")
        #expect(!future.validate().isEmpty)
        future.repair()
        #expect(future.relationships.count == 1 && future.validate().isEmpty)

        // Removing the boundary or the summary takes their relationships, in one undo step.
        let before = c
        try c.edit("Remove", undo: &undo) { $0.removeElement(.boundary(boundary)) }
        #expect(c.relationships.isEmpty && c.validate().isEmpty)
        undo.undo()!.apply(to: &c)
        #expect(c == before)
        try c.edit("Remove", undo: &undo) { $0.removeElement(.summary(summary)) }
        #expect(c.relationships.map(\.to) == [.boundary(boundary)] && c.validate().isEmpty)
        undo.undo()!.apply(to: &c)
        #expect(c == before)

        // Deleting the boundary's topics, or a summarised sibling, goes the same way.
        try c.edit("Delete", undo: &undo) { _ = try $0.delete([channels]) }
        #expect(c.boundaries.isEmpty && c.relationships.isEmpty && c.validate().isEmpty)
        undo.undo()!.apply(to: &c)
        try c.edit("Delete", undo: &undo) { _ = try $0.delete([kids[0]]) }
        #expect(c.summaries.isEmpty && c.relationships.map(\.from) == [.topic(risks)] && c.validate().isEmpty)
        undo.undo()!.apply(to: &c)
        #expect(c == before)

        // A hand-edited file whose boundary is gone: validation says so, repair drops it.
        var broken = c
        broken.boundaries = []
        #expect(broken.validate().count == 2)
        broken.repair()
        #expect(broken.relationships.isEmpty && broken.validate().isEmpty)
        // A boundary that repair empties takes its relationships too.
        var emptied = c
        emptied.nodes[channels] = nil
        emptied.nodes[c.root]!.children.removeAll { $0 == channels }
        emptied.repair()
        #expect(emptied.boundaries.isEmpty && emptied.relationships.isEmpty && emptied.validate().isEmpty)

        // Merge: the disk removed the summary while the app renamed a topic.
        var disk = c
        try disk.edit("Remove", undo: &undo) { $0.removeElement(.summary(summary)) }
        var current = c
        try current.edit("Rename", undo: &undo) { $0.setText(risks, "Threats") }
        let merged = DocumentMerge(
            base: DocumentModel(canvases: [c]), current: DocumentModel(canvases: [current]),
            disk: DocumentModel(canvases: [disk])
        ).model.canvases[c.id]
        #expect(merged?.summaries.isEmpty == true && merged?.relationships.count == 1)
        #expect(merged?.validate().isEmpty == true)
    }

    /// D181: copying a branch brings relationships whose boundaries and summaries come too.
    @Test func copiedBranchesKeepElementEnds() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let (pricing, risks) = (id(c, "Pricing"), id(c, "Risks"))
        let kids = c.nodes[pricing]!.children
        try c.edit("Setup", undo: &undo) { e in
            let b = try e.addBoundary(around: [kids[2]])
            _ = try e.addSummary(over: Array(kids.prefix(2)))
            e.connect(.summary(e.canvas.summaries[0].id), to: .boundary(b), label: "inside")
            e.connect(.topic(risks), to: .boundary(b), label: "outside")
        }
        let f = c.fragment([pricing])
        #expect(f.relationships.map(\.label) == ["inside"] && f.summaries.count == 1 && f.boundaries.count == 1)
        try c.edit("Paste", undo: &undo) { e in _ = try e.paste(f, under: risks) }
        #expect(c.validate().isEmpty)
        #expect(c.boundaries.count == 2 && c.summaries.count == 2)
        let pasted = try #require(c.relationships.last)
        #expect(pasted.label == "inside" && pasted.from == .summary(c.summaries[1].id))
        #expect(pasted.to == .boundary(c.boundaries[1].id))
    }

    /// M34 (D259): Arrange on several zones keeps their order among themselves; one zone
    /// moves as `reorderZone` moves it.
    @Test func reorderZonesMovesTheGroup() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let ids = try c.edit("Zones", undo: &undo) { e in
            (0..<5).map { i in
                e.addZone(
                    title: "Z\(i)", origin: CanvasPoint(x: Double(i) * 400, y: 900), width: 300, height: 200,
                    members: [])
            }
        }
        func order() -> [String] { c.zones.map(\.title) }
        let picked = [ids[3], ids[1]]
        try c.edit("Front", undo: &undo) { $0.reorderZones(picked, .front) }
        #expect(order() == ["Z0", "Z2", "Z4", "Z1", "Z3"])
        try c.edit("Back", undo: &undo) { $0.reorderZones(picked, .back) }
        #expect(order() == ["Z1", "Z3", "Z0", "Z2", "Z4"])
        try c.edit("Forward", undo: &undo) { $0.reorderZones(picked, .forward) }
        #expect(order() == ["Z0", "Z1", "Z3", "Z2", "Z4"], "each one step past an unselected zone")
        try c.edit("Forward", undo: &undo) { $0.reorderZones([ids[2], ids[4]], .forward) }
        #expect(order() == ["Z0", "Z1", "Z3", "Z2", "Z4"], "a zone behind a selected one at the front stays")
        try c.edit("Backward", undo: &undo) { $0.reorderZones([ids[0], ids[2]], .backward) }
        #expect(order() == ["Z0", "Z1", "Z2", "Z3", "Z4"], "the rearmost stays; Z2 steps back past Z3")
        // One zone: the same as reorderZone.
        for order in [CanvasEditor.ZOrder.front, .back, .forward, .backward] {
            var a = c
            var b = c
            var u = UndoStack()
            try a.edit("One", undo: &u) { $0.reorderZones([ids[2]], order) }
            try b.edit("One", undo: &u) { $0.reorderZone(ids[2], order) }
            #expect(a.zones == b.zones)
        }
        let before = c
        try c.edit("Front", undo: &undo) { $0.reorderZones(picked, .front) }
        undo.undo()!.apply(to: &c)
        #expect(c == before)
    }

    @Test func topicLinksParse() {
        let link = TopicLink.make(canvas: "c2", node: "n7")
        #expect(link == "nexus:topic/c2/n7")
        let parsed = TopicLink.parse(link)
        #expect(parsed?.canvas == "c2" && parsed?.node == "n7")
        #expect(TopicLink.parse("https://example.com") == nil)
    }
}
