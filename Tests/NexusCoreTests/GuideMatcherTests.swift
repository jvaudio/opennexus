import Testing

@testable import NexusCore

/// Guide mode's matcher (M41): each kind of match, following adds, renames, deletes,
/// reparents, undo and redo, on maps nobody typed.
@Suite struct GuideMatcherTests {
    static let mindmap = Guide(
        id: "mindmap", type: .mindmap,
        steps: [
            .init(id: "root", match: .init(depth: 0, named: true), title: "Name the central topic"),
            .init(id: "main", match: .init(depth: 1, named: true), min: 3, title: "Add three main topics"),
            .init(id: "sub", match: .init(depth: 2, each: true), title: "Give each a subtopic"),
            .init(id: "link", match: .init(edge: .init()), optional: true, title: "Connect ideas"),
        ])

    static let dfd = Guide(
        id: "dfd", type: .dfd,
        steps: [
            .init(id: "process", match: .init(nodeTypes: [.process], named: true), title: "Name the system"),
            .init(id: "externals", match: .init(nodeTypes: [.entity]), title: "Add external entities"),
            .init(id: "flows", match: .init(edge: .init(labelled: true)), title: "Label the flows"),
            .init(id: "stores", match: .init(nodeTypes: [.store]), optional: true, title: "Add data stores"),
            .init(id: "rules", match: .init(rules: "dfd"), optional: true, title: "Clear the rule checks"),
        ])

    func states(_ p: GuideProgress) -> [String] {
        p.steps.map {
            switch $0.state {
            case .done: "done"
            case .current: $0.met ? "current✓" : "current"
            case .skipped: "skipped"
            case .upcoming: "upcoming"
            }
        }
    }

    /// The mind map guide follows a map as it grows, is renamed, shrinks, is reshaped and undone.
    @Test func followsEditsUndoAndRedo() throws {
        var c = Canvas(id: "c1", title: "", rootText: "Central Topic")
        var undo = UndoStack()
        var p = GuideMatcher.progress(c, Self.mindmap)
        #expect(states(p) == ["current", "upcoming", "upcoming", "upcoming"] && p.done == 0 && !p.complete)

        c.edit("Name", undo: &undo) { $0.setText($0.canvas.root, "Launch") }
        var mains: [NodeID] = []
        c.edit("Mains", undo: &undo) { e in
            for t in ["Goals", "Main Topic", "Risks"] { mains.append(try! e.addChild(of: e.canvas.root, text: t)) }
        }
        p = GuideMatcher.progress(c, Self.mindmap)
        #expect(p.steps[1].count == 2, "a placeholder isn't a named topic")
        #expect(states(p) == ["done", "current", "upcoming", "upcoming"])

        c.edit("Rename", undo: &undo) { $0.setText(mains[1], "Channels") }
        p = GuideMatcher.progress(c, Self.mindmap)
        #expect(states(p) == ["done", "done", "current", "upcoming"] && p.steps[2].needed == 3)

        var subs: [NodeID] = []
        c.edit("Subs", undo: &undo) { e in for m in mains { subs.append(try! e.addChild(of: m, text: "Detail")) } }
        p = GuideMatcher.progress(c, Self.mindmap)
        #expect(states(p) == ["done", "done", "done", "current"] && p.complete && p.done == 3)

        // Delete a subtopic: that main topic has none again.
        c.edit("Delete", undo: &undo) { _ = try! $0.delete([subs[2]]) }
        p = GuideMatcher.progress(c, Self.mindmap)
        #expect(p.steps[2].count == 2 && !p.steps[2].met && p.current == 2)

        // Reparent a main topic under another: two main topics left, and the sub step counts them.
        c.edit("Reparent", undo: &undo) { try! $0.move(mains[2], toParent: mains[0], at: 0) }
        p = GuideMatcher.progress(c, Self.mindmap)
        #expect(p.steps[1].count == 2 && !p.steps[1].met && p.steps[2].needed == 2 && p.current == 1)

        // Undo both, then redo one.
        for _ in 0..<2 { undo.undo()!.apply(to: &c) }
        p = GuideMatcher.progress(c, Self.mindmap)
        #expect(p.complete)
        undo.redo()!.apply(to: &c)
        p = GuideMatcher.progress(c, Self.mindmap)
        #expect(!p.steps[2].met)
    }

    /// The step on the selected topic is current, whether or not it's done; skipped steps
    /// make way; an optional step comes after the required ones.
    @Test func currentStepFollowsSelectionAndSkips() throws {
        var c = Canvas(id: "c1", title: "", rootText: "Launch")
        var undo = UndoStack()
        var main: NodeID = "n1"
        c.edit("x", undo: &undo) { e in main = try! e.addChild(of: e.canvas.root, text: "Goals") }
        var p = GuideMatcher.progress(c, Self.mindmap, selection: c.root)
        #expect(p.current == 0 && p.steps[0].state == .current && p.steps[0].met)
        p = GuideMatcher.progress(c, Self.mindmap, selection: main)
        #expect(p.current == 1)
        p = GuideMatcher.progress(c, Self.mindmap, skipped: ["main"])
        #expect(states(p) == ["done", "skipped", "current", "upcoming"])
        p = GuideMatcher.progress(c, Self.mindmap, skipped: ["main", "sub"])
        #expect(p.complete && p.current == 3, "then the optional step")
        #expect(p.done == 3)
    }

    /// Depths count from the central topic: a named floating topic doesn't name it, and its
    /// children aren't main topics or hosts for subtopics.
    @Test func floatingTopicsAreOutsideTheTree() throws {
        var c = Canvas(id: "c1", title: "", rootText: "Central Topic")
        var undo = UndoStack()
        c.edit("x", undo: &undo) { e in
            let f = e.addFloating(at: CanvasPoint(x: 400, y: 0), text: "Parking lot")
            for t in ["Later", "Maybe", "Never"] { _ = try! e.addChild(of: f, text: t) }
        }
        let p = GuideMatcher.progress(c, Self.mindmap)
        #expect(!p.steps[0].met && p.steps[1].count == 0 && p.steps[2].needed == 0)
    }

    /// Untyped data flows: inference makes processes, entities and stores; flows count only
    /// labelled; the rules step reads DFDRules.
    @Test func dfdOnAnUntypedMap() throws {
        var c = Canvas(id: "c1", title: "", type: .dfd, rootText: "Context")
        var undo = UndoStack()
        var p = GuideMatcher.progress(c, Self.dfd)
        #expect(p.steps.allSatisfy { !$0.met } && p.current == 0, "an empty map passes no rule check")
        var shop: NodeID = "n1"
        var customer: NodeID = "n1"
        c.edit("x", undo: &undo) { e in
            shop = try! e.addChild(of: e.canvas.root, text: "Online shop")
            customer = try! e.addChild(of: shop, text: "Customer")
            _ = try! e.addChild(of: shop, text: "Orders DB")
        }
        p = GuideMatcher.progress(c, Self.dfd)
        #expect(p.steps[0].nodes == [shop] && p.steps[1].nodes == [customer] && p.steps[3].met)
        #expect(!p.steps[2].met && p.current == 2, "flows aren't labelled yet")
        #expect(!p.steps[4].met && p.steps[4].count > 0, "unlabelled flows break a rule")
        c.edit("Label", undo: &undo) { e in
            for id in e.canvas.nodes[shop]!.children { e.update(id) { $0.edgeLabel = "data" } }
        }
        p = GuideMatcher.progress(c, Self.dfd)
        #expect(p.steps[2].count == 2 && p.steps[2].met && p.complete)
        // An explicit type wins over inference.
        c.edit("Type", undo: &undo) { $0.update(customer) { $0.nodeType = .store } }
        p = GuideMatcher.progress(c, Self.dfd)
        #expect(!p.steps[1].met && p.current == 1)
    }

    /// Relationships count on a mind map; boundaries count on any type.
    @Test func edgesAndBoundaries() throws {
        var c = Canvas(id: "c1", title: "", rootText: "Launch")
        var undo = UndoStack()
        c.edit("x", undo: &undo) { e in
            let a = try! e.addChild(of: e.canvas.root, text: "A")
            let b = try! e.addChild(of: e.canvas.root, text: "B")
            _ = e.connect(a, to: b, label: "")
            _ = try! e.addBoundary(around: [a, b], title: "Zone")
        }
        let g = Guide(
            id: "x", type: .mindmap,
            steps: [
                .init(id: "any", match: .init(edge: .init()), title: "Any"),
                .init(id: "labelled", match: .init(edge: .init(labelled: true)), title: "Labelled"),
                .init(id: "zone", match: .init(boundary: true), title: "Zone"),
            ])
        let p = GuideMatcher.progress(c, g)
        #expect(p.steps.map(\.met) == [true, false, true] && p.steps[2].nodes.count == 2)
    }

    /// Skips are an edit: saved only when there are some, undone like any other.
    @Test func skipsAreSavedAndUndone() throws {
        var c = Canvas(id: "c1", title: "", rootText: "Launch")
        var undo = UndoStack()
        c.edit("Skip", undo: &undo) { $0.toggleGuideSkip("main", in: "mindmap") }
        #expect(c.guide.skipped(in: "mindmap") == ["main"] && c.guide.skipped(in: "dfd").isEmpty)
        #expect(c.json["guide"] == ["id": "mindmap", "skipped": ["main"]])
        let back = try Canvas(json: c.json, path: "c")
        #expect(back.guide == c.guide)
        undo.undo()!.apply(to: &c)
        #expect(c.guide.isDefault && c.json["guide"] == nil, "undone, and not written when empty")
        c.edit("Skip", undo: &undo) { $0.toggleGuideSkip("main", in: "mindmap") }
        c.edit("Restore", undo: &undo) { $0.toggleGuideSkip("main", in: "mindmap") }
        #expect(c.guide.isDefault)
        // A skip in another guide (after Convert) replaces the old one's.
        c.edit("Skip", undo: &undo) { $0.toggleGuideSkip("main", in: "mindmap") }
        c.edit("Skip", undo: &undo) { $0.toggleGuideSkip("flows", in: "dfd") }
        #expect(c.guide == GuideSettings(id: "dfd", skipped: ["flows"]))
    }

    /// Guide files read: one node type or several, every match field, defaults.
    @Test func readsGuideJSON() throws {
        let json: JSONValue = [
            "id": "g", "type": "architecture", "example": ["Root", "  Child"],
            "steps": [
                ["id": "a", "match": ["nodeType": "db"], "title": "A"],
                [
                    "id": "b", "match": ["nodeType": ["service", "fn"], "depth": 1, "named": true, "each": true],
                    "min": 2, "optional": true, "title": "B", "tip": "Press {topic.addChild}",
                ],
                ["id": "c", "match": ["edge": ["labelled": true], "kind": "floating"], "title": "C"],
                ["id": "d", "match": ["boundary": true, "rules": "dfd"], "title": "D"],
            ],
        ]
        let g = try Guide(json: json)
        #expect(g.id == "g" && g.type == .architecture && g.example == ["Root", "  Child"])
        #expect(g.steps[0].match.nodeTypes == ["db"] && g.steps[0].min == 1 && !g.steps[0].optional)
        #expect(g.steps[1].match == .init(nodeTypes: ["service", "fn"], depth: 1, named: true, each: true))
        #expect(g.steps[1].min == 2 && g.steps[1].optional && g.steps[1].tip == "Press {topic.addChild}")
        #expect(g.steps[2].match.edge == .init(labelled: true) && g.steps[2].match.kind == .floating)
        #expect(g.steps[3].match.boundary && g.steps[3].match.rules == "dfd")
        #expect(throws: (any Error).self) { try Guide(json: ["id": "x", "type": "mindmap", "steps": [["id": "a"]]]) }
    }
}
