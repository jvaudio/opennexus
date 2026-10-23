import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// The mouse's fold control (D215): hovering a topic with children shows a "−" where its
/// branch leaves; clicking it folds the branch, and the folded branch's "+N" unfolds it.
@MainActor
@Suite(.serialized) struct FoldControlTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    /// A topic's centre in the canvas view's coordinates.
    func center(_ h: CanvasHarness, _ id: NodeID) -> CGPoint {
        let v = h.host.canvasView
        let r = v.camera.toView(h.controller.scene.nodes[id]!.frame.rect)
        return CGPoint(x: r.midX, y: r.midY)
    }

    func event(_ h: CanvasHarness, _ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: h.host.canvasView.convert(p, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func hover(_ h: CanvasHarness, _ p: CGPoint) { h.host.canvasView.mouseMoved(with: event(h, .mouseMoved, at: p)) }

    func click(_ h: CanvasHarness, _ p: CGPoint) {
        let v = h.host.canvasView
        v.mouseDown(with: event(h, .leftMouseDown, at: p))
        v.mouseUp(with: event(h, .leftMouseUp, at: p))
    }

    /// A canvas rect's centre in view coordinates.
    func viewCenter(_ h: CanvasHarness, _ world: CGRect) -> CGPoint {
        let r = h.host.canvasView.camera.toView(world)
        return CGPoint(x: r.midX, y: r.midY)
    }

    @Test func hoverShowsTheMinusOnlyWhereThereAreChildren() {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        let pricing = node(h, "Pricing")
        hover(h, center(h, pricing))
        #expect(v.foldHover == pricing)
        let r = try! #require(v.foldControl(pricing))
        let f = h.controller.scene.nodes[pricing]!.frame.rect
        #expect(r.minX > f.midX && abs(r.midY - f.midY) < 1, "on the branch side, level with the topic")
        // A leaf and the central topic have none.
        hover(h, center(h, node(h, "Pro")))
        #expect(v.foldHover == nil && v.foldControl(pricing) == nil)
        hover(h, center(h, h.canvas.root))
        #expect(v.foldHover == nil)
        // Off the canvas, it goes away.
        hover(h, center(h, pricing))
        let exit = NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        v.mouseExited(with: exit)
        #expect(v.foldHover == nil)
    }

    @Test func theMinusStaysWhileThePointerMovesOntoIt() {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        let pricing = node(h, "Pricing")
        hover(h, center(h, pricing))
        let minus = viewCenter(h, v.foldControl(pricing)!)
        #expect(v.node(at: minus) != pricing, "the control sits past the topic's edge")
        hover(h, minus)
        #expect(v.foldHover == pricing)
    }

    @Test func clickingTheMinusFoldsAndThePlusUnfolds() {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        let pricing = node(h, "Pricing")
        let pro = node(h, "Pro")
        h.controller.select(pro)
        hover(h, center(h, pricing))
        let depth = h.undo.stack.undoStack.count
        click(h, viewCenter(h, v.foldControl(pricing)!))
        #expect(h.canvas.nodes[pricing]?.folded == true)
        #expect(h.undo.stack.undoStack.count == depth + 1, "one undo step")
        #expect(h.controller.selection.primary == pricing, "the selection leaves the hidden branch")
        #expect(h.controller.scene.nodes[pricing]?.hiddenCount == 3)
        // The "+3" badge unfolds it, without hovering first.
        hover(h, .zero)
        let plus = try! #require(v.foldControl(pricing))
        click(h, viewCenter(h, plus))
        #expect(h.canvas.nodes[pricing]?.folded == false)
        #expect(h.controller.selection.primary == pricing)
    }

    @Test func clickingTheTopicItselfStillSelects() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        hover(h, center(h, pricing))
        click(h, center(h, pricing))
        #expect(h.canvas.nodes[pricing]?.folded == false && h.controller.selection.primary == pricing)
    }

    @Test func noControlOutsideSelectMode() {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        h.controller.beginEditing(pricing)
        hover(h, center(h, pricing))
        #expect(v.foldHover == nil)
    }
}
