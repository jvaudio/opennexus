import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

@MainActor
@Suite(.serialized) struct KeyboardFlowTests {
    /// F1 acceptance: a 20-topic, multi-level map built with keys only.
    @Test func buildTwentyTopicMapWithKeysOnly() throws {
        let h = CanvasHarness()
        // New documents open with the root in Edit mode (the app does this on open).
        h.controller.beginEditing(replacingWith: "")
        #expect(h.controller.mode == .edit)
        h.type("Launch plan")
        h.press("return")
        #expect(h.controller.mode == .select)
        #expect(h.text(h.canvas.root) == "Launch plan")

        h.press("tab")
        #expect(h.controller.mode == .edit)
        h.type("Positioning")  // replaces the selected default text
        h.press("tab")  // commit + child
        h.type("Developers")
        h.press("return")  // commit
        h.press("return")  // sibling after
        h.type("Teams")
        h.press("return")

        h.press("left")  // spatial: back to Positioning
        #expect(h.text(h.controller.selection.primary) == "Positioning")
        h.press("return")
        h.type("Pricing")
        h.press("tab")
        h.type("Free tier")
        h.press("return")
        h.press("return")
        h.type("Pro")
        h.press("return")
        h.press("shift+return")  // sibling before
        h.type("Trial")
        h.press("return")

        h.press("right")  // Pricing grew on the left side of the balanced map
        #expect(h.text(h.controller.selection.primary) == "Pricing")
        h.press("return")
        h.type("Channels")
        h.press("tab")
        h.type("Newsletter")
        h.press("return")
        h.press("return")
        h.type("Product Hunt")
        h.press("return")
        h.press("cmd+return")  // parent between Product Hunt and Channels
        h.type("Launch week")
        h.press("return")

        h.press("cmd+home")
        #expect(h.controller.selection.primary == h.canvas.root)
        h.press("tab")
        h.type("Timeline")
        h.press("tab")
        h.type("Beta")
        h.press("return")
        h.press("return")
        h.type("GA")
        h.press("return")

        h.press("cmd+home")
        h.press("tab")
        h.type("Risks")
        h.press("tab")
        h.type("Competitor response")
        h.press("return")
        h.press("return")
        h.type("Budget")
        h.press("return")
        h.press("return")
        h.type("Hiring")
        h.press("return")
        h.press("opt+cmd+up")  // reorder above Budget
        let risks = try #require(h.canvas.nodes.first { $0.value.text == "Risks" }?.key)
        #expect(h.canvas.nodes[risks]!.children.map { h.text($0) } == ["Competitor response", "Hiring", "Budget"])

        // Hiring sits on whichever side Risks landed; step back toward the root.
        let side = h.controller.scene.nodes[risks]!.frame.side
        h.press(side == .left ? "right" : "left")
        #expect(h.controller.selection.primary == risks)
        h.press("cmd+/")
        #expect(h.canvas.nodes[risks]!.folded)
        #expect(h.controller.scene.nodes[risks]!.hiddenCount == 3)
        h.press("cmd+/")
        #expect(!h.canvas.nodes[risks]!.folded)

        h.press("cmd+home")
        h.press("tab")
        h.type("Team")
        h.press("return")

        h.press("cmd+home")
        h.press("space")  // edit keeping text, caret at end
        h.type(" v2")
        h.press("esc")

        let c = h.canvas
        #expect(c.nodes.count == 20)
        #expect(c.validate().isEmpty)
        #expect(h.text(c.root) == "Launch plan v2")
        let parents = c.parentMap()
        let maxDepth = c.nodes.keys.map { c.depth(of: $0, parents: parents) }.max() ?? 0
        #expect(maxDepth >= 3)
        #expect(
            Set(c.nodes.values.map(\.text)).isSuperset(of: [
                "Positioning", "Pricing", "Channels", "Launch week",
                "Product Hunt", "Trial", "Pro", "Team",
            ]))
        let pricing = try #require(c.nodes.first { $0.value.text == "Pricing" }?.key)
        #expect(c.nodes[pricing]!.children.map { h.text($0) } == ["Free tier", "Trial", "Pro"])
        #expect(h.controller.mode == .select)
        #expect(h.window.firstResponder === h.host.canvasView)

        // Every step is undoable back to the blank document.
        while h.undo.undo(h.store) {}
        #expect(h.canvas.nodes.count == 1)
        #expect(h.text(h.canvas.root) == "Central Topic")
    }

    @Test func typingReplacesAndSpaceKeepsText() {
        let h = CanvasHarness()
        h.press("tab")
        h.type("Alpha")
        h.press("return")
        h.type("Beta")  // typing over the selection replaces it
        h.press("return")
        #expect(h.text(h.controller.selection.primary) == "Beta")
        h.press("space")
        h.type("!")
        h.press("return")
        #expect(h.text(h.controller.selection.primary) == "Beta!")
    }

    @Test func emptyCommitKeepsDefaultText() {
        let h = CanvasHarness()
        h.press("tab")
        h.press("delete")  // clear the selected default text
        h.press("return")
        #expect(h.text(h.controller.selection.primary) == "Main Topic")
    }

    @Test func lineBreakInsideNode() {
        let h = CanvasHarness()
        h.press("tab")
        h.type("Two")
        h.press("shift+return")
        h.type("lines")
        h.press("return")
        #expect(h.text(h.controller.selection.primary) == "Two\nlines")
        let n = h.controller.scene.nodes[h.controller.selection.primary]!
        #expect(Double(n.textRect.height) == n.textStyle.lineHeight * 2)
    }

    @Test func refusalsShowToastsAndChangeNothing() {
        let h = CanvasHarness()
        let before = h.canvas
        h.press("cmd+return")
        #expect(h.controller.toast?.text == "The central topic has no parent")
        h.press("delete")
        #expect(h.controller.toast?.text == "The central topic can’t be deleted")
        #expect(h.canvas == before)
    }

    @Test func deleteKeepChildrenAndPromote() {
        let h = CanvasHarness()
        h.press("tab")
        h.type("A")
        h.press("tab")
        h.type("B")
        h.press("tab")
        h.type("C")
        h.press("return")
        h.press("shift+tab")  // promote C next to B
        let a = h.canvas.nodes[h.canvas.root]!.children[0]
        #expect(h.canvas.nodes[a]!.children.map { h.text($0) } == ["B", "C"])
        h.press("left")
        #expect(h.text(h.controller.selection.primary) == "A")
        h.press("opt+delete")
        #expect(h.canvas.nodes[h.canvas.root]!.children.map { h.text($0) } == ["B", "C"])
    }

    @Test func markersAndSmartColor() {
        let h = CanvasHarness()
        h.press("tab")
        h.press("return")
        h.press("ctrl+2")
        #expect(h.canvas.nodes[h.controller.selection.primary]!.priority == 2)
        h.press("ctrl+0")
        #expect(h.canvas.nodes[h.controller.selection.primary]!.todo == Todo(done: false))
        h.press("shift+cmd+r")
        #expect(h.canvas.style.paletteShift == 1)
    }

    @Test func structureSwitchToLogicChart() {
        let h = CanvasHarness()
        for _ in 0..<4 {
            h.press("tab")
            h.press("return")
            h.press("cmd+home")
        }
        h.press("opt+cmd+2")
        #expect(h.canvas.layout.structure == .logicRight)
        let rootX = h.controller.scene.nodes[h.canvas.root]!.frame.center.x
        #expect(h.controller.scene.nodes.values.filter { $0.frame.depth == 1 }.allSatisfy { $0.frame.center.x > rootX })
        h.press("opt+cmd+1")
        #expect(h.controller.scene.nodes.values.filter { $0.frame.depth == 1 }.contains { $0.frame.center.x < rootX })
    }

    @Test func connectAndMarkerKeysResolveThroughRegistry() {
        let h = CanvasHarness()
        // Unbound or not-yet-built commands do nothing and never start typing.
        h.press("shift+cmd+l")
        #expect(h.controller.mode == .select)
    }
}
