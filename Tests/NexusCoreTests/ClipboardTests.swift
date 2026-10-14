import Foundation
import Testing

@testable import NexusCore

@Suite struct ClipboardTests {
    func id(_ c: Canvas, _ t: String) -> NodeID { c.nodes.first { $0.value.text == t }!.key }

    @Test func fragmentAndGraftCopyBranchesWithFreshIDs() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let pricing = id(c, "Pricing")
        let channels = id(c, "Channels")
        let free = id(c, "Free tier")
        let pro = id(c, "Pro")
        try c.edit("Link", undo: &undo) { e in
            _ = e.connect(free, to: pro, label: "upsell")
            _ = try e.addBoundary(around: [free, pro], title: "Plans")
        }
        // Selecting a topic and its own child copies the branch once.
        let f = c.fragment([pricing, id(c, "Pro")])
        #expect(f.nodes[f.root]!.children == [pricing])
        #expect(f.relationships.count == 1 && f.boundaries.count == 1)
        let before = c.nodes.count
        let tops = try c.edit("Paste", undo: &undo) { try $0.paste(f, under: channels) }
        #expect(tops.count == 1 && tops[0] != pricing)
        #expect(c.nodes.count == before + 4)
        #expect(c.nodes[tops[0]]!.text == "Pricing" && c.nodes[tops[0]]!.children.count == 3)
        #expect(c.parent(of: tops[0]) == channels)
        #expect(c.relationships.count == 2 && c.boundaries.count == 2, "inner links and groups come along")
        #expect(c.validate().isEmpty)
        undo.undo()!.apply(to: &c)
        #expect(c.nodes.count == before)
    }

    @Test func copiedRootPastesAsTopic() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let f = c.fragment([c.root])
        let risks = id(c, "Risks")
        let tops = try c.edit("Paste", undo: &undo) { try $0.paste(f, under: risks) }
        #expect(c.nodes[tops[0]]!.kind == .topic && c.nodes[tops[0]]!.text == "Launch plan")
        #expect(c.validate().isEmpty)
    }

    @Test func canvasSetPatchIsOneUndo() {
        var doc = DocumentModel(canvases: [sampleCanvas()])
        let original = doc
        var after = doc
        var other = Canvas(id: "c1", title: "Imported", rootText: "Imported")
        other.nodes[other.root]!.link = TopicLink.make(canvas: "c1", node: "n1")
        let ids = after.add([other])
        #expect(ids == ["c2"])
        #expect(
            after.canvases["c2"]!.nodes[after.canvases["c2"]!.root]!.link == TopicLink.make(canvas: "c2", node: "n1"),
            "links follow the new id")
        let p = doc.canvasSetPatch(to: after, focus: "c2", actionName: "Merge")
        #expect(p.changesCanvasSet && !p.isEmpty)
        doc.apply(p)
        #expect(doc.canvasOrder == ["c1", "c2"] && doc.canvases.count == 2)
        doc.apply(p.inverted)
        #expect(doc.canvasOrder == original.canvasOrder && doc.canvases == original.canvases)
        // Delete is the same machinery.
        var deleted = doc
        deleted.canvases["c1"] = nil
        deleted.canvasOrder = []
        deleted.canvases["c2"] = Canvas(id: "c2", title: "x")
        deleted.canvasOrder = ["c2"]
        let d = doc.canvasSetPatch(to: deleted, focus: "c2", actionName: "Delete")
        doc.apply(d)
        doc.apply(d.inverted)
        #expect(doc.canvases == original.canvases)
    }
}
