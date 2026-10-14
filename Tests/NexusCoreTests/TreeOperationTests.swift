import Testing

@testable import NexusCore

/// Builds the P0 sample map ("Launch plan").
func sampleCanvas() -> Canvas {
    var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let tree: [(String, [String])] = [
            ("Positioning", ["Developers", "Teams"]),
            ("Pricing", ["Free tier", "Pro", "Annual discount"]),
            ("Channels", ["Product Hunt", "Newsletter"]),
            ("Timeline", ["Beta · Nov", "GA · Jan"]),
            ("Risks", ["Competitor response"]),
        ]
        for (main, subs) in tree {
            let m = try! e.addChild(of: e.canvas.root, text: main)
            for s in subs { try! e.addChild(of: m, text: s) }
        }
    }
    return c
}

@Suite struct TreeOperationTests {
    @Test func sampleHasSixteenTopics() {
        let c = sampleCanvas()
        #expect(c.nodes.count == 16)
        #expect(c.validate().isEmpty)
        #expect(c.nodes[c.root]!.children.count == 5)
    }

    @Test func tabAddsChildWithDefaultText() throws {
        var c = Canvas(id: "c1", title: "t")
        var u = UndoStack()
        let id = try c.edit("Add", undo: &u) { try $0.addChild(of: $0.canvas.root) }
        #expect(c.nodes[id]?.text == "Main Topic")
        let sub = try c.edit("Add", undo: &u) { try $0.addChild(of: id) }
        #expect(c.nodes[sub]?.text == "Subtopic")
        #expect(c.parent(of: sub) == id)
    }

    @Test func returnOnRootAddsChild() throws {
        var c = Canvas(id: "c1", title: "t")
        var u = UndoStack()
        let id = try c.edit("Add", undo: &u) { try $0.addSibling(of: $0.canvas.root) }
        #expect(c.parent(of: id) == c.root)
    }

    @Test func siblingBeforeAndAfter() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let pricing = c.nodes[c.root]!.children[1]
        let after = try c.edit("Add", undo: &u) { try $0.addSibling(of: pricing) }
        let before = try c.edit("Add", undo: &u) { try $0.addSibling(of: pricing, before: true) }
        let kids = c.nodes[c.root]!.children
        #expect(kids.firstIndex(of: before)! + 1 == kids.firstIndex(of: pricing)!)
        #expect(kids.firstIndex(of: after)! == kids.firstIndex(of: pricing)! + 1)
    }

    @Test func addParentInsertsBetween() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let pricing = c.nodes[c.root]!.children[1]
        let p = try c.edit("Add", undo: &u) { try $0.addParent(of: pricing) }
        #expect(c.nodes[c.root]!.children[1] == p)
        #expect(c.nodes[p]!.children == [pricing])
        #expect(throws: TreeOperationRefusal.rootHasNoParent) {
            try c.edit("Add", undo: &u) { try $0.addParent(of: $0.canvas.root) }
        }
    }

    @Test func deleteSelectsPreviousSiblingAndDropsRelationships() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let kids = c.nodes[c.root]!.children
        c.edit("Connect", undo: &u) { $0.connect(kids[2], to: kids[3], label: "drives") }
        let next = try c.edit("Delete", undo: &u) { try $0.delete([kids[2]]) }
        #expect(next == kids[1])
        #expect(c.relationships.isEmpty)
        #expect(c.nodes.count == 13)
        #expect(c.validate().isEmpty)
    }

    @Test func cannotDeleteRoot() {
        var c = sampleCanvas()
        var u = UndoStack()
        #expect(throws: TreeOperationRefusal.cannotDeleteRoot) {
            try c.edit("Delete", undo: &u) { try $0.delete([$0.canvas.root]) }
        }
    }

    @Test func deleteKeepingChildrenLiftsThem() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let pricing = c.nodes[c.root]!.children[1]
        let grandkids = c.nodes[pricing]!.children
        try c.edit("Delete", undo: &u) { try $0.deleteKeepingChildren(pricing) }
        let kids = c.nodes[c.root]!.children
        #expect(Array(kids[1...3]) == grandkids)
        #expect(c.validate().isEmpty)
    }

    @Test func promoteDemoteReorder() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let positioning = c.nodes[c.root]!.children[0]
        let teams = c.nodes[positioning]!.children[1]
        try c.edit("Promote", undo: &u) { try $0.promote(teams) }
        #expect(c.nodes[c.root]!.children[1] == teams)
        try c.edit("Demote", undo: &u) { try $0.demote(teams) }
        #expect(c.nodes[positioning]!.children.last == teams)
        try c.edit("Move", undo: &u) { try $0.reorder(teams, by: -1) }
        #expect(c.nodes[positioning]!.children.first == teams)
        #expect(throws: TreeOperationRefusal.atEdge) {
            try c.edit("Move", undo: &u) { try $0.reorder(teams, by: -1) }
        }
        #expect(throws: TreeOperationRefusal.alreadyMainTopic) {
            try c.edit("Promote", undo: &u) { try $0.promote(positioning) }
        }
    }

    @Test func duplicateCopiesBranchAfterOriginal() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let pricing = c.nodes[c.root]!.children[1]
        let copy = try c.edit("Duplicate", undo: &u) { try $0.duplicate(pricing) }
        #expect(c.nodes[c.root]!.children[2] == copy)
        #expect(c.nodes[copy]!.children.map { c.nodes[$0]!.text } == ["Free tier", "Pro", "Annual discount"])
        #expect(c.nodes.count == 20)
    }

    @Test func foldAndFoldAll() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let pricing = c.nodes[c.root]!.children[1]
        try c.edit("Fold", undo: &u) { try $0.toggleFold(pricing) }
        #expect(c.hiddenCount(under: pricing) == 3)
        #expect(c.visibleNodes().count == 13)
        try c.edit("Fold All", undo: &u) { try $0.toggleFoldAll() }
        #expect(c.visibleNodes().count == 16)
        try c.edit("Fold All", undo: &u) { try $0.toggleFoldAll() }
        #expect(c.visibleNodes().count == 6)
    }

    @Test func markersAndTodos() {
        var c = sampleCanvas()
        var u = UndoStack()
        let n = c.nodes[c.root]!.children[0]
        c.edit("Marker", undo: &u) { $0.toggleMarker(n, priority: 2) }
        #expect(c.nodes[n]!.priority == 2)
        c.edit("Marker", undo: &u) { $0.toggleMarker(n, priority: 2) }
        #expect(c.nodes[n]!.priority == nil)
        c.edit("Todo", undo: &u) { $0.toggleMarker(n, priority: 0) }
        #expect(c.nodes[n]!.todo == Todo(done: false))
        c.edit("Todo", undo: &u) { $0.toggleMarker(n, priority: 0) }
        #expect(c.nodes[n]!.todo == Todo(done: true))
    }

    @Test func floatingTopics() throws {
        var c = sampleCanvas()
        var u = UndoStack()
        let f = c.edit("Float", undo: &u) { $0.addFloating(at: CanvasPoint(x: 100.3, y: -40.26)) }
        #expect(c.floating == [f])
        #expect(c.nodes[f]!.position == CanvasPoint(x: 100.5, y: -40.5))
        let child = try c.edit("Add", undo: &u) { try $0.addChild(of: f) }
        #expect(c.validate().isEmpty)
        _ = try c.edit("Delete", undo: &u) { try $0.delete([f]) }
        #expect(c.nodes[child] == nil)
        #expect(c.floating.isEmpty)
    }

    @Test func editingTextClearsAIFlag() {
        var c = sampleCanvas()
        var u = UndoStack()
        let n = c.nodes[c.root]!.children[0]
        c.edit("AI", undo: &u) { $0.update(n) { $0.ai = true } }
        c.edit("Type", undo: &u) { $0.setText(n, "Audience") }
        #expect(c.nodes[n]!.ai == false)
        #expect(c.nodes[n]!.text == "Audience")
    }
}
