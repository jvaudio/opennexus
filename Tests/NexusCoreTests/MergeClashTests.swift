import Foundation
import Testing

@testable import NexusCore

/// M45: merges report clashes as data, take a choice per clash, merge subtopics as lists,
/// and merge two copies with no common version.
@Suite struct MergeClashTests {
    static func plan() -> DocumentModel {
        var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
        var undo = UndoStack()
        c.edit("Sample", undo: &undo) { e in
            for (m, subs) in [("Pricing", ["Free", "Pro"]), ("Channels", ["Newsletter"]), ("Risks", ["Churn"])] {
                let id = try! e.addChild(of: e.canvas.root, text: m)
                for s in subs { try! e.addChild(of: id, text: s) }
            }
        }
        return DocumentModel(canvases: [c])
    }

    func id(_ d: DocumentModel, _ t: String) -> NodeID { d.canvases["c1"]!.nodes.first { $0.value.text == t }!.key }

    func edit(_ d: DocumentModel, _ body: (inout CanvasEditor) throws -> Void) rethrows -> DocumentModel {
        var out = d
        var e = CanvasEditor(d.canvases["c1"]!)
        try body(&e)
        out.canvases["c1"] = e.canvas
        return out
    }

    func texts(_ d: DocumentModel, _ c: CanvasID = "c1") -> Set<String> { Set(d.canvases[c]!.nodes.values.map(\.text)) }

    @Test func theSameTopicOnBothSidesIsOneClashAndEachChoiceKeepsThatSide() {
        let base = Self.plan()
        let pro = id(base, "Pro")
        let mine = edit(base) { $0.setText(pro, "Pro (mine)") }
        let theirs = edit(base) {
            $0.setText(pro, "Pro (theirs)")
            $0.update(pro) { $0.note = Note(text: "From the other Mac") }
        }
        let m = DocumentMerge(base: base, current: mine, disk: theirs)
        #expect(m.clashes.count == 1)
        let clash = m.clashes[0]
        #expect(clash.kind == .topic && clash.node == pro && clash.canvasTitle == "Launch plan")
        #expect(clash.base == "Pro" && clash.mine == "Pro (mine)" && clash.theirs == "Pro (theirs)")
        #expect(clash.mineChanges == ["text"] && clash.theirsChanges == ["text", "note"])
        #expect(m.conflicts == ["“Pro (mine)”"])
        #expect(m.model.canvases["c1"]!.nodes[pro]!.text == "Pro (mine)")

        let t = DocumentMerge(base: base, current: mine, disk: theirs, choices: [clash.id: .theirs]).model
        #expect(t.canvases["c1"]!.nodes[pro]! == theirs.canvases["c1"]!.nodes[pro]!)
        #expect(t.canvases.count == 1)

        let both = DocumentMerge(base: base, current: mine, disk: theirs, choices: [clash.id: .both]).model
        #expect(both.canvases["c1"]!.nodes[pro]!.text == "Pro (mine)")
        #expect(both.canvasOrder == ["c1", "c2"])
        #expect(both.canvases["c2"]!.title == "Launch plan (theirs)")
        #expect(both.canvases["c2"]!.nodes[pro]!.text == "Pro (theirs)")
        #expect(both.canvases.values.allSatisfy { $0.validate().isEmpty })
    }

    @Test func topicsAddedUnderOneParentOnBothSidesAllArrive() throws {
        let base = Self.plan()
        let pricing = id(base, "Pricing")
        let mine = try edit(base) { _ = try $0.addChild(of: pricing, text: "Team") }
        let theirs = try edit(base) {
            _ = try $0.addChild(of: pricing, text: "Enterprise")
            $0.setText(id(base, "Free"), "Free tier")
        }
        let m = DocumentMerge(base: base, current: mine, disk: theirs)
        #expect(m.clashes.isEmpty)
        let c = m.model.canvases["c1"]!
        #expect(c.validate().isEmpty)
        #expect(c.nodes[pricing]!.children.map { c.nodes[$0]!.text } == ["Free tier", "Pro", "Enterprise", "Team"])
        // Both sides made the next id for their topic: the other side's keeps it.
        let enterprise = c.nodes.first { $0.value.text == "Enterprise" }!.key
        #expect(enterprise == theirs.canvases["c1"]!.nodes.first { $0.value.text == "Enterprise" }!.key)
    }

    @Test func newCanvasesOnBothSidesAreTwoCanvases() {
        let base = Self.plan()
        var mine = base
        mine.add([Canvas(id: "x", title: "Mine", rootText: "Mine")])
        var theirs = base
        theirs.add([Canvas(id: "x", title: "Theirs", rootText: "Theirs")])
        #expect(mine.canvasOrder == ["c1", "c2"] && theirs.canvasOrder == ["c1", "c2"])
        let m = DocumentMerge(base: base, current: mine, disk: theirs)
        #expect(m.clashes.isEmpty)
        #expect(m.model.canvases["c2"]?.title == "Theirs")
        #expect(Set(m.model.orderedCanvases.map(\.title)) == ["Launch plan", "Mine", "Theirs"])
    }

    @Test func aDeletedBranchWithAnEditInsideKeepsThePathToTheEdit() throws {
        let base = Self.plan()
        let pricing = id(base, "Pricing")
        let pro = id(base, "Pro")
        let mine = edit(base) { $0.setText(pro, "Pro · $12") }
        let theirs = try edit(base) { _ = try $0.delete([pricing]) }
        let m = DocumentMerge(base: base, current: mine, disk: theirs)
        #expect(m.clashes.map(\.node) == [pro])
        #expect(m.clashes[0].theirs == nil && m.clashes[0].mine == "Pro · $12")
        let c = m.model.canvases["c1"]!
        #expect(c.validate().isEmpty)
        #expect(texts(m.model).isSuperset(of: ["Pricing", "Pro · $12"]))
        // Choosing theirs deletes the branch after all.
        let t = DocumentMerge(base: base, current: mine, disk: theirs, choices: [m.clashes[0].id: .theirs]).model
        #expect(
            !texts(t).contains("Pro · $12") && !texts(t).contains("Pricing") && t.canvases["c1"]!.validate().isEmpty)
    }

    @Test func aTopicMovedToDifferentParentsStaysWhereThisSidePutIt() throws {
        let base = Self.plan()
        let churn = id(base, "Churn")
        let mine = try edit(base) { try $0.move(churn, toParent: id(base, "Pricing")) }
        let theirs = try edit(base) { try $0.move(churn, toParent: id(base, "Channels")) }
        let m = DocumentMerge(base: base, current: mine, disk: theirs)
        let c = m.model.canvases["c1"]!
        #expect(c.validate().isEmpty)
        #expect(c.nodes[id(base, "Pricing")]!.children.contains(churn))
        #expect(!c.nodes[id(base, "Channels")]!.children.contains(churn))
    }

    @Test func canvasSettingsOnBothSidesAreOneClash() {
        let base = Self.plan()
        var mine = base
        mine.canvases["c1"]!.title = "Plan A"
        var theirs = base
        theirs.canvases["c1"]!.title = "Plan B"
        let m = DocumentMerge(base: base, current: mine, disk: theirs)
        #expect(m.clashes.map(\.kind) == [.settings] && m.model.canvases["c1"]!.title == "Plan A")
        let t = DocumentMerge(base: base, current: mine, disk: theirs, choices: [m.clashes[0].id: .theirs])
        #expect(t.model.canvases["c1"]!.title == "Plan B")
    }

    @Test func twoCopiesWithoutABaseKeepEverythingAndReportDifferences() throws {
        let base = Self.plan()
        let pro = id(base, "Pro")
        let mine = try edit(base) {
            _ = try $0.addChild(of: id(base, "Risks"), text: "Pricing war")
            $0.setText(pro, "Pro (laptop)")
        }
        let theirs = try edit(base) {
            _ = try $0.addChild(of: id(base, "Channels"), text: "Podcast")
            $0.setText(pro, "Pro (desktop)")
            _ = try $0.delete([id(base, "Free")])
        }
        let m = DocumentMerge(base: nil, current: mine, disk: theirs)
        #expect(m.clashes.map(\.node) == [pro])
        #expect(m.model.canvases["c1"]!.validate().isEmpty)
        // Nothing is deleted without a base: "Free" stays.
        #expect(texts(m.model).isSuperset(of: ["Pricing war", "Podcast", "Free", "Pro (laptop)"]))
        let t = DocumentMerge(base: nil, current: mine, disk: theirs, choices: [m.clashes[0].id: .theirs]).model
        #expect(texts(t).contains("Pro (desktop)"))
    }

    @Test func aCanvasDeletedHereAndEditedThereIsAClash() {
        var base = Self.plan()
        base.canvases["c2"] = Canvas(id: "c2", title: "Notes", rootText: "Notes")
        base.canvasOrder.append("c2")
        var mine = base
        mine.canvases["c2"] = nil
        mine.canvasOrder = ["c1"]
        var theirs = base
        theirs.canvases["c2"]!.title = "Meeting notes"
        let m = DocumentMerge(base: base, current: mine, disk: theirs)
        #expect(m.clashes.map(\.kind) == [.canvas] && m.clashes[0].mine == nil)
        #expect(m.model.canvases["c2"] == nil)
        let keep = DocumentMerge(base: base, current: mine, disk: theirs, choices: [m.clashes[0].id: .both]).model
        #expect(keep.canvases["c2"]?.title == "Meeting notes" && keep.canvasOrder == ["c1", "c2"])
    }
}
