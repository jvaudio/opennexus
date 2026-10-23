import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusKeys

/// M27: several zones selected at once (⇧- and ⌘-click, Select All Zones) copy, cut,
/// duplicate, delete and move together (D228); topic copy knows the document it came
/// from (D230).
@MainActor
@Suite(.serialized) struct ZoneSelectionTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    /// Two zones, "Ideas" around "Parking lot" › "Later idea" and "Backlog" around
    /// "Someday", with a relationship from one zone's topic to the other's and one from
    /// "Someday" to "Pricing".
    func harness() throws -> (CanvasHarness, ideas: String, backlog: String) {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("nexus-test-\(UUID().uuidString)"))
        let pricing = node(h, "Pricing")
        let ids = try #require(
            h.controller.perform("Zones") { e -> (String, String) in
                let lot = e.addFloating(at: CanvasPoint(x: 2000, y: 1400), text: "Parking lot")
                let later = try e.addChild(of: lot, text: "Later idea")
                let someday = e.addFloating(at: CanvasPoint(x: 2600, y: 1400), text: "Someday")
                let a = e.addZone(
                    title: "Ideas", origin: CanvasPoint(x: 1960, y: 1340), width: 320, height: 200, members: [lot])
                let b = e.addZone(
                    title: "Backlog", origin: CanvasPoint(x: 2560, y: 1340), width: 280, height: 200,
                    members: [someday])
                _ = e.connect(.topic(later), to: .topic(someday), label: "between")
                _ = e.connect(.topic(someday), to: .topic(pricing), label: "to pricing")
                return (a, b)
            })
        return (h, ids.0, ids.1)
    }

    /// A left-button event at a world point, as the canvas view receives it.
    func event(
        _ h: CanvasHarness, _ type: NSEvent.EventType, at world: CGPoint, flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        let v = h.host.canvasView
        return NSEvent.mouseEvent(
            with: type, location: v.convert(v.camera.toView(world), to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A point inside the zone, clear of its topics and its collapse caret.
    func inside(_ h: CanvasHarness, _ zone: String) throws -> CGPoint {
        let r = try #require(h.controller.scene.zones.first { $0.zone.id == zone }?.rect)
        return CGPoint(x: r.maxX - 12, y: r.maxY - 12)
    }

    func click(_ h: CanvasHarness, _ zone: String, flags: NSEvent.ModifierFlags = []) throws {
        let p = try inside(h, zone)
        h.host.canvasView.mouseDown(with: event(h, .leftMouseDown, at: p, flags: flags))
        h.host.canvasView.mouseUp(with: event(h, .leftMouseUp, at: p, flags: flags))
    }

    @Test func shiftAndCommandClickSelectSeveralZones() throws {
        let (h, ideas, backlog) = try harness()
        try click(h, ideas)
        #expect(h.controller.selectedZones == [ideas])
        try click(h, backlog, flags: .shift)
        #expect(h.controller.selectedZones == [ideas, backlog])
        #expect(h.controller.selectedElement == .zone(backlog), "the zone clicked last is the Format panel's")
        #expect(h.host.canvasView.elements.selectedZones == [ideas, backlog], "both draw selected")
        // ⌘-click takes one out again; a plain click on one of several keeps just that one.
        try click(h, ideas, flags: .command)
        #expect(h.controller.selectedZones == [backlog] && h.controller.selectedElement == .zone(backlog))
        try click(h, ideas, flags: .command)
        #expect(h.controller.selectedZones == [backlog, ideas])
        try click(h, backlog)
        #expect(h.controller.selectedZones == [backlog])
        // Selecting a topic ends the zone selection.
        h.controller.selectZones([ideas, backlog])
        h.controller.select(node(h, "Pricing"))
        #expect(h.controller.selectedZones.isEmpty && h.controller.selectedElement == nil)
    }

    @Test func copyAndPasteSeveralZonesTogether() throws {
        let (h, ideas, backlog) = try harness()
        h.controller.selectZones([ideas, backlog])
        h.press("cmd+c")
        let pb = h.controller.pasteboard
        #expect(pb.string(forType: .string) == "Parking lot\n\tLater idea\nSomeday\n")
        let data = try #require(pb.data(forType: .nexusFragment))
        let f = try Canvas(json: try CanonicalJSON.parse(data), path: "clipboard")
        #expect(f.zones.map(\.title) == ["Ideas", "Backlog"])
        let depth = h.undo.stack.undoStack.count
        let rels = h.canvas.relationships.count
        h.press("cmd+v")
        #expect(h.undo.stack.undoStack.count == depth + 1, "one undo step")
        #expect(h.canvas.zones.count == 4)
        let pasted = Array(h.canvas.zones.suffix(2))
        #expect(pasted.map(\.title) == ["Ideas", "Backlog"] && h.controller.selectedZones == pasted.map(\.id))
        // They keep their places relative to each other, the first at the paste point.
        let p = try #require(h.controller.floatingPlacement?())
        #expect(pasted[0].origin == CanvasPoint(x: Double(p.x), y: Double(p.y)))
        #expect(pasted[1].origin.x - pasted[0].origin.x == 600 && pasted[1].origin.y == pasted[0].origin.y)
        // The relationship between the two zones' topics joins the copies.
        let between = try #require(h.canvas.relationships.last { $0.label == "between" })
        let inFirst = Set(pasted[0].members.flatMap { h.canvas.subtree($0) })
        #expect(between.from.topic.map(inFirst.contains) == true && between.to.topic == pasted[1].members.first)
        #expect(h.canvas.relationships.count == rels + 2 && h.canvas.validate().isEmpty)
        h.undo.undo(h.store)
        #expect(h.canvas.zones.map(\.id) == [ideas, backlog] && h.controller.selectedZones.isEmpty)
    }

    /// Right-clicking one of several selected zones keeps them all, so the zone menu's
    /// Duplicate acts on the group as ⌘D does; another zone's menu selects just that zone.
    @Test func theZoneMenuActsOnTheWholeGroup() throws {
        let (h, ideas, backlog) = try harness()
        let c = h.controller
        c.selectZones([ideas, backlog])
        c.prepareContextMenu(.element(.zone(backlog)))
        #expect(c.selectedZones == [ideas, backlog] && c.selectedElement == .zone(backlog))
        let items = c.contextMenu(for: .element(.zone(backlog))).flatMap(\.items)
        #expect(items.contains { $0.action == .command(.duplicateZone) })
        #expect(c.perform(.duplicateZone))
        #expect(h.canvas.zones.count == 4, "both zones duplicated")
        // A zone outside the group narrows the selection to it.
        c.selectZones([ideas])
        c.prepareContextMenu(.element(.zone(backlog)))
        #expect(c.selectedZones == [backlog])
    }

    @Test func cutAndDeleteTakeEverySelectedZone() throws {
        let (h, ideas, backlog) = try harness()
        let before = h.canvas
        h.controller.selectZones([ideas, backlog])
        let depth = h.undo.stack.undoStack.count
        h.press("cmd+x")
        #expect(h.undo.stack.undoStack.count == depth + 1)
        #expect(h.canvas.zones.isEmpty && h.controller.selectedZones.isEmpty)
        #expect(!h.canvas.nodes.values.contains { ["Parking lot", "Later idea", "Someday"].contains($0.text) })
        #expect(h.canvas.validate().isEmpty)
        h.undo.undo(h.store)
        #expect(h.canvas == before && h.canvas.zones == before.zones)
        // Delete removes the zones (not their topics), one undo step.
        h.controller.selectZones([ideas, backlog])
        h.press("delete")
        #expect(h.canvas.zones.isEmpty)
        #expect(h.undo.stack.undoStack.count == depth + 1)
        #expect(h.canvas.nodes.values.contains { $0.text == "Someday" })
        h.undo.undo(h.store)
        #expect(h.canvas.zones == before.zones)
    }

    @Test func duplicateAndSelectAllZones() throws {
        let (h, ideas, backlog) = try harness()
        h.controller.select(node(h, "Pricing"))
        #expect(h.controller.canPerform(.selectAllZones))
        #expect(CommandRegistry.standard[.selectAllZones]?.menu == .edit)
        #expect(h.controller.perform(.selectAllZones))
        #expect(h.controller.selectedZones == [ideas, backlog])
        let depth = h.undo.stack.undoStack.count
        h.press("cmd+d")
        #expect(h.undo.stack.undoStack.count == depth + 1)
        let copies = Array(h.canvas.zones.suffix(2))
        #expect(h.canvas.zones.count == 4 && h.controller.selectedZones == copies.map(\.id))
        // Beside the pair: their combined width plus 40 pt to the right.
        let xs: [Double] = copies.map(\.origin.x)
        #expect(xs == [2880, 3480])
        #expect(h.canvas.relationships.filter { $0.label == "to pricing" }.count == 2, "outside ends are kept")
        #expect(h.canvas.validate().isEmpty)
        // Not offered on a canvas without zones.
        h.undo.undo(h.store)
        h.controller.perform("Remove") { e in
            e.removeZone(ideas)
            e.removeZone(backlog)
        }
        #expect(!h.controller.canPerform(.selectAllZones))
    }

    @Test func draggingOneOfSeveralZonesMovesThemAll() throws {
        let (h, ideas, backlog) = try harness()
        let before = h.canvas.zones
        h.controller.selectZones([ideas, backlog])
        let v = h.host.canvasView
        let start = try inside(h, backlog)
        let end = CGPoint(x: start.x + 100, y: start.y + 50)
        let depth = h.undo.stack.undoStack.count
        v.mouseDown(with: event(h, .leftMouseDown, at: start))
        #expect(h.controller.selectedZones == [ideas, backlog], "pressing on one keeps the others")
        v.mouseDragged(with: event(h, .leftMouseDragged, at: end))
        v.mouseUp(with: event(h, .leftMouseUp, at: end))
        #expect(h.undo.stack.undoStack.count == depth + 1, "one undo step")
        for (old, new) in zip(before, h.canvas.zones) {
            #expect(abs(new.origin.x - old.origin.x - 100) <= 0.5 && abs(new.origin.y - old.origin.y - 50) <= 0.5)
        }
        let lot = try #require(h.canvas.nodes[node(h, "Parking lot")]?.position)
        #expect(abs(lot.x - 2100) <= 0.5 && abs(lot.y - 1450) <= 0.5, "members move with their zones")
        #expect(h.controller.selectedZones == [ideas, backlog])
    }

    // MARK: Topic paste knows its source (D230)

    /// "Build" waits for "Design", both under "Timeline".
    func taskDocument() -> DocumentModel {
        var doc = launchPlanDocument()
        var c = doc.canvases["c1"]!
        var undo = UndoStack()
        try! c.edit("Tasks", undo: &undo) { e in
            let timeline = e.canvas.nodes.first { $0.value.text == "Timeline" }!.key
            let design = try e.addChild(of: timeline, text: "Design")
            let build = try e.addChild(of: timeline, text: "Build")
            try e.addDependency(build, on: design)
        }
        doc.canvases["c1"] = c
        return doc
    }

    @Test func topicPasteKeepsDependenciesOnlyInItsOwnDocument() throws {
        let h = CanvasHarness(model: taskDocument())
        h.controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("nexus-test-\(UUID().uuidString)"))
        let design = node(h, "Design")
        h.controller.select(node(h, "Build"))
        h.press("cmd+c")
        #expect(h.controller.pasteboard.string(forType: .nexusFragmentSource) == h.controller.fragmentSource)
        // Another open document with the same canvas id and topic ids.
        let other = CanvasHarness(model: taskDocument())
        other.controller.pasteboard = h.controller.pasteboard
        #expect(other.controller.canvasID == h.controller.canvasID && other.canvas.nodes[design]?.text == "Design")
        other.controller.select(node(other, "Risks"))
        other.controller.paste()
        let elsewhere = try #require(other.controller.selection.nodes.first)
        #expect(other.canvas.nodes[elsewhere]?.text == "Build")
        #expect(other.canvas.nodes[elsewhere]?.todo?.after.isEmpty == true, "the lookalike Design isn't the one")
        #expect(other.canvas.validate().isEmpty)
        // Back in its own canvas, the dependency on Design is kept.
        h.controller.select(node(h, "Risks"))
        h.controller.paste()
        let here = try #require(h.controller.selection.nodes.first)
        #expect(h.canvas.nodes[here]?.todo?.after.map(\.task) == [design])
    }
}
