import Foundation
import Testing

@testable import NexusCore

private func id(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }

@Suite struct FilterTests {
    @Test func parseChips() {
        #expect(NodeFilter.parse("type: Threat") == .init(field: "type", op: .equals, value: "Threat"))
        #expect(NodeFilter.parse("status ≠ Mitigated") == .init(field: "status", op: .notEquals, value: "Mitigated"))
        #expect(NodeFilter.parse("status != Open")?.op == .notEquals)
        #expect(NodeFilter.parse("pricing") == .init(field: "text", op: .contains, value: "pricing"))
        #expect(NodeFilter.parse("nonsense: x")?.field == "text", "unknown fields fall back to text")
        #expect(NodeFilter.parse("  ") == nil)
    }

    /// Artboard 27's filter: open high-risk threats.
    @Test func openHighThreats() throws {
        var c = checkoutDFD()
        c.type = .threatModel
        var undo = UndoStack()
        let auth = id(c, "Authorize payment")
        try c.edit("Threats", undo: &undo) { e in
            let a = try e.addThreat(on: auth, category: .spoofing, title: "Spoofed callback", risk: "High")
            e.setThreatField(a, Stride.statusKey, "Open")
            let b = try e.addThreat(on: auth, category: .tampering, title: "Tampering", risk: "Med")
            _ = b
            let d = try e.addThreat(on: auth, category: .infoDisclosure, title: "Card data in logs", risk: "High")
            _ = d
            let m = try e.addThreat(on: auth, category: .denialOfService, title: "Retry storm", risk: "High")
            e.setThreatField(m, Stride.statusKey, "Mitigated")
        }
        let f = NodeFilter(
            name: "Open threats · High",
            clauses: ["type: Threat", "risk: High", "status ≠ Mitigated"].compactMap(NodeFilter.parse))
        #expect(f.matching(in: c).map { c.nodes[$0]!.text } == ["Spoofed callback", "Card data in logs"])
        let back = try NodeFilter(json: f.json, path: "f")
        #expect(back == f)
        c.filters = [f]
        #expect(try Canvas(json: c.json, path: "c").filters == [f])
    }

    @Test func markerLabelTodo() {
        var c = sampleCanvas()
        let pro = id(c, "Pro")
        c.nodes[pro]!.markers = ["priority-1"]
        c.nodes[pro]!.labels = ["Q4"]
        c.nodes[pro]!.todo = Todo(done: false)
        #expect(NodeFilter(clauses: [NodeFilter.parse("marker: priority")!]).matching(in: c) == [pro])
        #expect(NodeFilter(clauses: [NodeFilter.parse("label: q4")!]).matching(in: c) == [pro])
        #expect(NodeFilter(clauses: [NodeFilter.parse("todo: open")!]).matching(in: c) == [pro])
        #expect(NodeFilter(clauses: [NodeFilter.parse("free")!]).matching(in: c) == [id(c, "Free tier")])
    }
}

@Suite struct SearchTests {
    func doc() -> DocumentModel {
        var a = sampleCanvas()
        let pricing = id(a, "Pricing")
        a.nodes[pricing]!.note = Note(text: "Keep the free tier generous; metered pricing elsewhere.")
        a.nodes[pricing]!.labels = ["Pricing & plans"]
        var b = Canvas(id: "c2", title: "Threats", rootText: "Price ceiling")
        b.nodes[b.root]!.text = "Price ceiling"
        return DocumentModel(canvases: [a, b])
    }

    @Test func optionsNarrowMatches() {
        let d = doc()
        var o = SearchOptions()
        #expect(TextSearch.find("pric", o, in: d, current: "c1").count == 1)
        o.notes = true
        o.labels = true
        #expect(TextSearch.find("pric", o, in: d, current: "c1").count == 3)
        o.allCanvases = true
        #expect(TextSearch.find("pric", o, in: d, current: "c1").count == 4)
        o.matchCase = true
        #expect(TextSearch.find("pric", o, in: d, current: "c1").count == 1, "only the note's lowercase “pricing”")
        o.matchCase = false
        o.wholeWords = true
        #expect(TextSearch.find("pric", o, in: d, current: "c1").isEmpty)
        o.wholeWords = false
        o.regex = true
        #expect(TextSearch.find("Pri(c|z)e", o, in: d, current: "c1").count == 1)
        #expect(TextSearch.find("Pri(", o, in: d, current: "c1").isEmpty, "invalid regex finds nothing")
    }

    @Test func replaceIsOneUndoStep() {
        var d = doc()
        var o = SearchOptions()
        o.notes = true
        var c = d.canvases["c1"]!
        var undo = UndoStack()
        let before = c
        let matches = TextSearch.find("tier", o, in: d, current: "c1")
        #expect(matches.count == 2)
        let n = c.edit("Replace All", undo: &undo) {
            TextSearch.replace(matches, query: "tier", with: "plan", o, in: &$0)
        }
        #expect(n == 2)
        #expect(c.nodes[id(c, "Free plan")] != nil)
        #expect(c.nodes[id(c, "Pricing")]!.note!.text.contains("free plan generous"))
        d.canvases["c1"] = c
        #expect(TextSearch.find("tier", o, in: d, current: "c1").isEmpty)
        #expect(undo.undoStack.count == 1)
        undo.undo()!.apply(to: &c)
        #expect(c == before)
        // Regex templates.
        o.regex = true
        var c2 = before
        let m2 = TextSearch.find("(Free) (tier)", o, in: DocumentModel(canvases: [c2]), current: "c1")
        c2.edit("Replace", undo: &undo) {
            _ = TextSearch.replace(m2, query: "(Free) (tier)", with: "$2 $1", o, in: &$0)
        }
        #expect(c2.nodes.values.contains { $0.text == "tier Free" })
    }

    @Test func counts() {
        var c = sampleCanvas()
        c.nodes[id(c, "Pro")]!.ai = true
        c.nodes[id(c, "Pro")]!.note = Note(text: "x")
        let all = CanvasCounts(c)
        #expect(all.topics == 16)
        #expect(all.notes == 1 && all.aiCreated == 1)
        #expect(all.words == c.nodes.values.reduce(0) { $0 + $1.text.split(separator: " ").count })
        let sel = CanvasCounts(c, nodes: [id(c, "Pro"), id(c, "Free tier")])
        #expect(sel.topics == 2 && sel.words == 3 && sel.characters == 12)
        #expect(c.path(to: id(c, "Pro")).map { c.nodes[$0]!.text } == ["Launch plan", "Pricing"])
    }
}

@Suite struct DeckTests {
    @Test func mapSlides() {
        let c = sampleCanvas()
        let s = Deck.slides(c)
        #expect(s.map(\.title) == ["Launch plan", "Positioning", "Pricing", "Channels", "Timeline", "Risks"])
        #expect(s[2].focus.contains(id(c, "Pro")) && !s[2].focus.contains(id(c, "Teams")))
        #expect(s[2].kicker == "LAUNCH PLAN · MIND MAP · STEP 2 OF 5")
    }

    @Test func dfdStepsThroughFlows() {
        let c = checkoutDFD()
        let s = Deck.slides(c)
        #expect(s.first?.id == "title")
        #expect(s[1].title == "Order details → Place order")
        #expect(s[1].highlight == [id(c, "Customer"), id(c, "Place order")])
        #expect(s.count == 1 + FlowGraph(c).flows.count)
    }

    @Test func skipMergeHideReorderPersist() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let channels = "branch:\(id(c, "Channels").rawValue)"
        let positioning = "branch:\(id(c, "Positioning").rawValue)"
        c.edit("S", undo: &undo) { $0.toggleSkip(channels) }
        c.edit("M", undo: &undo) { $0.toggleMerge(positioning) }
        let risks = id(c, "Risks")
        c.edit("H", undo: &undo) { $0.update(risks) { $0.presentHidden = true } }
        var s = Deck.slides(c)
        #expect(s.map(\.title) == ["Launch plan", "Positioning · Pricing", "Channels", "Timeline"])
        #expect(s[2].skipped)
        #expect(s[1].kicker.hasSuffix("STEP 1 OF 2"))
        let ids = s.map(\.id)
        c.edit("Reorder", undo: &undo) { $0.moveSlide(ids[3], to: 1, in: ids) }
        s = Deck.slides(c)
        #expect(s.map(\.title) == ["Launch plan", "Timeline", "Positioning · Pricing", "Channels"])
        let back = try Canvas(json: c.json, path: "c")
        #expect(back == c)
        #expect(Deck.slides(back) == s)
    }

    @Test func sequenceSlides() {
        var c = Canvas(id: "c1", title: "Sign-in", type: .sequence, rootText: "Sign-in")
        var undo = UndoStack()
        c.edit("Seed", undo: &undo) { e in
            let a = try! e.addChild(of: e.canvas.root, text: "User")
            let b = try! e.addChild(of: e.canvas.root, text: "Web")
            e.connect(a, to: b)
            e.updateRelationship(e.canvas.relationships[0].id) { $0.label = "Sign in" }
        }
        #expect(Deck.slides(c).map(\.title) == ["Sign-in", "Sign in"])
    }
}
