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

/// M20: a zone copies with its members' branches and the relationships that touch them,
/// zone ends included (D196).
@Suite struct ZoneClipboardTests {
    func id(_ c: Canvas, _ t: String) -> NodeID { c.nodes.first { $0.value.text == t }!.key }

    /// A zone "Ideas" around "Parking lot" › "Later idea", an empty zone "Other", and one
    /// relationship of each kind the copy has to handle.
    func zoneCanvas() throws -> (Canvas, zone: String, other: String) {
        var c = sampleCanvas()
        var undo = UndoStack()
        let pricing = id(c, "Pricing")
        let ids = try c.edit("Zones", undo: &undo) { e -> (String, String) in
            let top = e.addFloating(at: CanvasPoint(x: 2000, y: 1400), text: "Parking lot")
            let later = try e.addChild(of: top, text: "Later idea")
            let z = e.addZone(
                title: "Ideas", origin: CanvasPoint(x: 1960, y: 1340), width: 320, height: 200, members: [top])
            let other = e.addZone(title: "Other", origin: CanvasPoint(x: -800, y: 600))
            _ = e.connect(.topic(later), to: .topic(top), label: "inside")
            _ = e.connect(.topic(top), to: .zone(z), label: "to own zone")
            _ = e.connect(.topic(later), to: .topic(pricing), label: "to topic outside")
            _ = e.connect(.zone(z), to: .zone(other), label: "to zone outside")
            _ = e.connect(.topic(pricing), to: .topic(id(e.canvas, "Pro")), label: "not touching")
            e.update(later) {
                var t = Todo(done: false)
                t.after = [TaskDependency(task: pricing)]
                $0.todo = t
            }
            return (z, other)
        }
        return (c, ids.0, ids.1)
    }

    @Test func zoneFragmentCarriesTheZoneAndEveryTouchingRelationship() throws {
        let (c, zone, _) = try zoneCanvas()
        let f = c.zoneFragment([zone])
        let top = id(c, "Parking lot")
        #expect(f.zones.map(\.id) == [zone] && f.zones[0].members == [top])
        #expect(f.floating == [top] && f.nodes[top]?.kind == .floating)
        #expect(f.nodes[top]?.position == CanvasPoint(x: 2000, y: 1400), "members keep their place")
        #expect(f.nodes[f.root]?.children == [top], "a build without zone paste pastes the branch")
        #expect(f.relationships.map(\.label) == ["inside", "to own zone", "to topic outside", "to zone outside"])
        // The clipboard holds the fragment's JSON: it reads back as the same fragment.
        let back = try Canvas(json: f.json, path: "clipboard")
        #expect(back == f && back.zones == f.zones && back.relationships == f.relationships)
    }

    @Test func pasteIntoTheSameCanvasKeepsOutsideEnds() throws {
        var (c, zone, other) = try zoneCanvas()
        var undo = UndoStack()
        let f = c.zoneFragment([zone])
        let before = c
        let pricing = id(c, "Pricing")
        let ids = c.edit("Paste Zone", undo: &undo) { $0.pasteZones(f, at: CanvasPoint(x: 0, y: 0), sameCanvas: true) }
        let z = try #require(c.zones.first { $0.id == ids.first })
        #expect(ids.count == 1 && z.id != zone && z.title == "Ideas")
        #expect(z.origin == CanvasPoint(x: 0, y: 0) && z.width == 320 && z.height == 200)
        let top = try #require(z.members.first)
        #expect(c.floating.contains(top) && c.nodes[top]?.kind == .floating)
        #expect(c.nodes[top]?.position == CanvasPoint(x: 40, y: 60), "the member keeps its place in the zone")
        let later = try #require(c.nodes[top]?.children.first)
        #expect(c.nodes[later]?.text == "Later idea")
        #expect(c.nodes[later]?.todo?.after.map(\.task) == [pricing], "dependencies outside survive in place")
        let new = c.relationships.suffix(4)
        #expect(new.map(\.label) == ["inside", "to own zone", "to topic outside", "to zone outside"])
        #expect(new.map(\.from) == [.topic(later), .topic(top), .topic(later), .zone(z.id)])
        #expect(new.map(\.to) == [.topic(top), .zone(z.id), .topic(pricing), .zone(other)])
        #expect(Set(c.relationships.map(\.id)).count == c.relationships.count)
        #expect(c.validate().isEmpty)
        undo.undo()!.apply(to: &c)
        #expect(c == before && c.zones == before.zones && c.relationships == before.relationships)
    }

    @Test func pasteElsewhereDropsOutsideEnds() throws {
        let (src, zone, _) = try zoneCanvas()
        let f = src.zoneFragment([zone])
        // Another canvas that happens to have topics with the same ids.
        var c = sampleCanvas()
        c.id = "c2"
        var undo = UndoStack()
        let ids = c.edit("Paste Zone", undo: &undo) {
            $0.pasteZones(f, at: CanvasPoint(x: 100, y: 100), sameCanvas: false)
        }
        let z = try #require(c.zones.first { $0.id == ids.first })
        let top = try #require(z.members.first)
        let later = try #require(c.nodes[top]?.children.first)
        #expect(c.relationships.map(\.label) == ["inside", "to own zone"])
        #expect(c.relationships.map(\.to) == [.topic(top), .zone(z.id)])
        #expect(c.nodes[later]?.todo?.after.isEmpty == true, "a dependency on a topic left behind goes")
        #expect(c.validate().isEmpty)
    }

    @Test func zoneEndsInsideTheCopyFollowIt() throws {
        // Two zones copied together: a relationship between them joins the two copies.
        var (c, zone, other) = try zoneCanvas()
        var undo = UndoStack()
        let f = c.zoneFragment([zone, other])
        #expect(f.zones.count == 2)
        let ids = c.edit("Paste", undo: &undo) { $0.pasteZones(f, by: 0, 3000, sameCanvas: false) }
        #expect(ids.count == 2)
        let rel = try #require(c.relationships.last { $0.label == "to zone outside" })
        #expect(rel.from == .zone(ids[0]) && rel.to == .zone(ids[1]))
        let moved = try #require(c.zones.first { $0.id == ids[1] })
        #expect(moved.origin == CanvasPoint(x: -800, y: 3600))
    }

    @Test func graftStillCopiesTopicRelationshipsOnly() throws {
        // Topic paste of a zone fragment (an older build's path): the branch arrives under
        // the parent with its topic-to-topic relationships.
        var (c, zone, _) = try zoneCanvas()
        var undo = UndoStack()
        let f = c.zoneFragment([zone])
        let risks = id(c, "Risks")
        let rels = c.relationships.count
        let tops = try c.edit("Paste", undo: &undo) { try $0.paste(f, under: risks) }
        #expect(tops.count == 1 && c.nodes[tops[0]]?.text == "Parking lot" && c.nodes[tops[0]]?.kind == .topic)
        #expect(c.parent(of: tops[0]) == risks && c.nodes[tops[0]]?.position == nil)
        #expect(c.relationships.count == rels + 1 && c.relationships.last?.label == "inside")
    }
}
