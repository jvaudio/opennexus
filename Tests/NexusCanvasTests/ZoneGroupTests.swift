import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusKeys

/// M34: a rubber band selects the zones it encloses (D258); Arrange and the Format panel
/// act on every selected zone (D259, D260); VoiceOver reads a zone with the group and
/// adds or removes it (D262); Duplicate Branch carries callouts (D261).
@MainActor
@Suite(.serialized) struct ZoneGroupTests {
    /// The two-zone canvas, mouse events and helpers of the M27 tests.
    let base = ZoneSelectionTests()

    func node(_ h: CanvasHarness, _ text: String) -> NodeID { base.node(h, text) }

    func rect(_ h: CanvasHarness, _ zone: String) throws -> CGRect {
        try #require(h.controller.scene.zones.first { $0.zone.id == zone }?.rect)
    }

    /// A rubber band dragged with real mouse events from `start` to `end` (world points).
    func band(_ h: CanvasHarness, from start: CGPoint, to end: CGPoint, flags: NSEvent.ModifierFlags = []) {
        let v = h.host.canvasView
        v.mouseDown(with: base.event(h, .leftMouseDown, at: start, flags: flags))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        v.mouseDragged(with: base.event(h, .leftMouseDragged, at: mid, flags: flags))
        v.mouseDragged(with: base.event(h, .leftMouseDragged, at: end, flags: flags))
        v.mouseUp(with: base.event(h, .leftMouseUp, at: end, flags: flags))
    }

    // MARK: Rubber band (D258)

    @Test func aBandAroundWholeZonesSelectsThem() throws {
        let (h, ideas, backlog) = try base.harness()
        let a = try rect(h, ideas)
        let b = try rect(h, backlog)
        let both = a.union(b)
        // From below right of both zones, on empty canvas, to above left of them.
        let outside = CGPoint(x: both.maxX + 40, y: both.maxY + 40)
        band(h, from: outside, to: CGPoint(x: both.minX - 30, y: both.minY - 30))
        #expect(h.controller.selectedZones == [ideas, backlog])
        #expect(h.host.canvasView.elements.selectedZones == [ideas, backlog], "both draw selected")
        // ⌘C takes both, as with ⇧-click.
        h.press("cmd+c")
        let data = try #require(h.controller.pasteboard.data(forType: .nexusFragment))
        #expect(
            try Canvas(json: try CanonicalJSON.parse(data), path: "clipboard").zones.map(\.title) == [
                "Ideas", "Backlog",
            ])
        // A band around one zone selects just that one; ⇧ adds to the selected zones.
        try base.click(h, ideas)
        band(h, from: CGPoint(x: b.maxX + 30, y: b.maxY + 30), to: CGPoint(x: b.minX - 20, y: b.minY - 20))
        #expect(h.controller.selectedZones == [backlog])
        try base.click(h, ideas)
        band(
            h, from: CGPoint(x: b.maxX + 30, y: b.maxY + 30), to: CGPoint(x: b.minX - 20, y: b.minY - 20),
            flags: .shift)
        #expect(h.controller.selectedZones == [ideas, backlog])
    }

    @Test func aBandThatOnlyCrossesAZoneSelectsItsTopics() throws {
        let (h, ideas, backlog) = try base.harness()
        let a = try rect(h, ideas)
        let lot = node(h, "Parking lot")
        let later = node(h, "Later idea")
        let topics = [lot, later].compactMap { h.controller.scene.nodes[$0]?.frame.rect }.reduce(CGRect.null) {
            $0.union($1)
        }
        #expect(a.contains(topics), "the topics sit inside the zone")
        // From below the zone to inside its top-right corner: it covers both topics, not
        // the whole zone.
        band(
            h, from: CGPoint(x: a.minX - 30, y: a.maxY + 30),
            to: CGPoint(x: (topics.maxX + a.maxX) / 2, y: (topics.minY + a.minY) / 2))
        #expect(h.controller.selectedZones.isEmpty && h.controller.selectedElement == nil)
        #expect(Set(h.controller.selection.nodes) == [lot, later])
        // ⌘ keeps a band around whole zones to topics.
        let both = a.union(try rect(h, backlog))
        band(
            h, from: CGPoint(x: both.maxX + 40, y: both.maxY + 40), to: CGPoint(x: both.minX - 30, y: both.minY - 30),
            flags: .command)
        #expect(h.controller.selectedZones.isEmpty)
        #expect(Set(h.controller.selection.nodes) == [lot, later, node(h, "Someday")])
    }

    // MARK: Arrange (D259)

    /// "Ideas", "Backlog" and a third zone, "Other", in that order (back to front).
    func threeZones() throws -> (CanvasHarness, ideas: String, backlog: String, other: String) {
        let (h, ideas, backlog) = try base.harness()
        let other = try #require(
            h.controller.perform("Zone") { e in
                e.addZone(title: "Other", origin: CanvasPoint(x: 3000, y: 1340), width: 300, height: 200, members: [])
            })
        return (h, ideas, backlog, other)
    }

    @Test func arrangeMovesEverySelectedZone() throws {
        let (h, ideas, backlog, other) = try threeZones()
        // Selected with the mouse: a click, then a ⇧-click.
        try base.click(h, ideas)
        try base.click(h, backlog, flags: .shift)
        #expect(h.controller.selectedZones == [ideas, backlog])
        let depth = h.undo.stack.undoStack.count
        h.press("opt+cmd+]")
        #expect(h.canvas.zones.map(\.id) == [other, ideas, backlog], "both in front, in their order")
        #expect(h.undo.stack.undoStack.count == depth + 1, "one undo step")
        #expect(h.controller.selectedZones == [ideas, backlog], "still selected")
        h.press("opt+cmd+[")
        #expect(h.canvas.zones.map(\.id) == [ideas, backlog, other])
        #expect(h.undo.stack.undoStack.count == depth + 2)
        // The zone menu's Bring to Front acts on the group too.
        h.controller.prepareContextMenu(.element(.zone(ideas)))
        #expect(h.controller.runMenuAction(.command(.bringToFront)))
        #expect(h.canvas.zones.map(\.id) == [other, ideas, backlog])
        h.undo.undo(h.store)
        h.undo.undo(h.store)
        h.undo.undo(h.store)
        #expect(h.canvas.zones.map(\.id) == [ideas, backlog, other])
        // One zone alone moves alone.
        try base.click(h, ideas)
        h.press("opt+cmd+]")
        #expect(h.canvas.zones.map(\.id) == [backlog, other, ideas])
    }

    // MARK: Format panel (D260)

    @Test func theFormatPanelEditsEverySelectedZone() throws {
        let (h, ideas, backlog, other) = try threeZones()
        let c = h.controller
        c.perform("Frame") { $0.updateZone(ideas) { $0.frame = "dashed" } }
        try base.click(h, ideas)
        try base.click(h, backlog, flags: .shift)
        let zone = try #require(h.canvas.zones.first { $0.id == backlog })
        let section = ZoneSection(controller: c, zone: zone)
        #expect(section.ids == [ideas, backlog])
        #expect(section.mixed(\.frame) && section.common(\.frame) == nil, "dashed and rounded")
        #expect(!section.mixed(\.collapsed) && section.common(\.collapsed) == false)
        #expect(c.commonZoneValue(\.autoResize) == true)
        // One change, every selected zone, one undo step; the zone outside the group stays.
        let depth = h.undo.stack.undoStack.count
        section.set { $0.frame = "square" }
        #expect(h.undo.stack.undoStack.count == depth + 1)
        #expect(h.canvas.zones.filter { [ideas, backlog].contains($0.id) }.allSatisfy { $0.frame == "square" })
        #expect(h.canvas.zones.first { $0.id == other }?.frame == "rounded")
        #expect(ZoneSection(controller: c, zone: zone).common(\.frame) == "square")
        section.set { $0.collapsed = true }
        #expect(h.canvas.zones.filter { $0.collapsed }.map(\.id) == [ideas, backlog])
        h.undo.undo(h.store)
        h.undo.undo(h.store)
        #expect(h.canvas.zones.first { $0.id == ideas }?.frame == "dashed")
        #expect(h.canvas.zones.first { $0.id == backlog }?.frame == "rounded")
        // Order, Reset style and Remove act on the group, one undo step each.
        c.reorderZones(section.ids, .front)
        #expect(h.canvas.zones.map(\.id) == [other, ideas, backlog])
        c.resetElementStyle(.zone(backlog))
        #expect(h.canvas.zones.allSatisfy { $0.frame == "rounded" })
        section.removeZones()
        #expect(h.canvas.zones.map(\.id) == [other] && h.undo.stack.undoStack.count == depth + 3)
        #expect(h.canvas.nodes.values.contains { $0.text == "Someday" }, "the content stays")
        // The panel itself draws for a group.
        h.undo.undo(h.store)
        c.selectZones([ideas, backlog])
        UserDefaults.standard.set("style", forKey: "format.tab")
        let panel = NSHostingView(rootView: FormatPanel(controller: c))
        panel.frame = CGRect(x: 0, y: 0, width: 330, height: 900)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.fittingSize.height > 0)
        // One zone alone: just that one.
        try base.click(h, other)
        let one = ZoneSection(controller: c, zone: try #require(h.canvas.zones.first { $0.id == other }))
        #expect(one.ids == [other] && !one.mixed(\.frame))
    }

    // MARK: VoiceOver (D262)

    @Test func voiceOverReadsTheGroupAndAddsZones() throws {
        let (h, ideas, backlog, other) = try threeZones()
        let v = h.host.canvasView
        v.assistiveAppOverride = true
        let tree = v.accessibilityTree
        let items = tree.zoneItems()
        #expect(items.map(\.id) == [ideas, backlog, other])
        // The zones are children of the canvas, after the topics.
        let roots = v.accessibilityChildren() ?? []
        #expect(roots.compactMap { $0 as? ZoneItem }.map(\.id) == [ideas, backlog, other])
        #expect(roots.first is TopicElement)
        func item(_ id: String) throws -> ZoneItem { try #require(tree.zoneItem(id)) }
        #expect(try item(ideas).accessibilityLabel() == "Ideas. Zone around 2 topics.")
        #expect(try item(ideas).accessibilityRoleDescription() == "zone")
        let f = try item(ideas).accessibilityFrame()
        #expect(f.width > 0 && f.height > 0)
        // Selected with the mouse: read as a group.
        try base.click(h, ideas)
        #expect(try item(ideas).accessibilityLabel() == "Ideas. Zone around 2 topics. Selected.")
        try base.click(h, backlog, flags: .shift)
        #expect(
            try item(ideas).accessibilityLabel() == "Ideas. Zone around 2 topics. Selected, 1 of 2 selected zones.")
        #expect(
            try item(backlog).accessibilityLabel() == "Backlog. Zone around 1 topic. Selected, 2 of 2 selected zones.")
        #expect(try item(ideas).isAccessibilitySelected() && item(backlog).isAccessibilitySelected())
        #expect(try item(backlog).isAccessibilityFocused() && !item(ideas).isAccessibilityFocused())
        #expect(try !item(other).isAccessibilitySelected())
        #expect((v.accessibilityValue() as? String) == (try item(backlog).accessibilityLabel()))
        // Add to Selection on the third zone; Remove from Selection takes one out.
        func action(_ id: String, _ name: String) throws -> NSAccessibilityCustomAction {
            try #require(try item(id).accessibilityCustomActions()?.first { $0.name == name })
        }
        #expect(try item(other).accessibilityCustomActions()?.contains { $0.name == "Remove from Selection" } == false)
        #expect(try action(other, "Add to Selection").handler?() == true)
        #expect(h.controller.selectedZones == [ideas, backlog, other])
        #expect(try item(other).accessibilityLabel()?.hasSuffix("Selected, 3 of 3 selected zones.") == true)
        #expect(try action(ideas, "Remove from Selection").handler?() == true)
        #expect(h.controller.selectedZones == [backlog, other])
        #expect(try item(backlog).accessibilityLabel()?.hasSuffix("Selected, 1 of 2 selected zones.") == true)
        // The zone's menu items act on the group (Duplicate Zone duplicates both).
        let dup = try #require(try item(other).accessibilityCustomActions()?.first { $0.name.hasPrefix("Duplicate") })
        #expect(dup.handler?() == true)
        #expect(h.canvas.zones.count == 5 && h.controller.selectedZones.count == 2)
        // Pressing a zone selects it alone.
        #expect(try item(ideas).accessibilityPerformPress())
        #expect(h.controller.selectedZones == [ideas])
        // The Zones rotor walks them, read with the selection.
        let rotor = try #require(v.accessibilityCustomRotors().first { $0.label == "Zones" })
        let p = NSAccessibilityCustomRotor.SearchParameters()
        p.searchDirection = .next
        let first = try #require(rotor.itemSearchDelegate?.rotor(rotor, resultFor: p))
        #expect(first.customLabel == "Ideas. Zone around 2 topics. Selected.")
    }

    // MARK: Duplicate Branch (D261)

    @Test func duplicateBranchCarriesCallouts() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        let bubble = try #require(
            h.controller.perform("Callout") { e in try e.addCallout(on: pricing, text: "Check margins") })
        _ = h.controller.perform("Nested") { e in try e.addCallout(on: bubble, text: "Ask finance") }
        let before = h.canvas
        h.controller.select(pricing)
        let depth = h.undo.stack.undoStack.count
        h.press("cmd+d")
        #expect(h.undo.stack.undoStack.count == depth + 1, "one undo step")
        let copy = h.controller.selection.primary
        #expect(copy != pricing && h.canvas.nodes[copy]?.text == "Pricing")
        let new = h.canvas.callouts.filter { k in !before.callouts.contains { $0.id == k.id } }
        #expect(new.count == 2)
        let margins = try #require(new.first { h.canvas.nodes[$0.topic]?.text == "Check margins" })
        #expect(margins.host == copy && margins.topic != bubble)
        #expect(new.contains { $0.host == margins.topic && h.canvas.nodes[$0.topic]?.text == "Ask finance" })
        #expect(h.canvas.validate().isEmpty)
        h.undo.undo(h.store)
        #expect(h.canvas == before)
    }
}
