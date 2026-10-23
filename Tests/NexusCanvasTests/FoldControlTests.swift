import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusLayout

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

    /// D250: in every structure, the "−" and the "+N" sit where the topic's branch lines
    /// leave it: on the line itself where it leaves from a corner, the middle of the
    /// bottom or a stem (indented trees, timelines, org charts, fishbone bones).
    @Test(arguments: [
        LayoutStructure.logicRight, .mindmapBalanced, .orgDown, .treeIndented, .timelineHorizontal,
        .timelineVertical, .timelineAlternating, .fishboneLeft, .fishboneRight,
    ])
    func theControlSitsWhereTheBranchLeaves(structure: LayoutStructure) throws {
        let h = CanvasHarness(model: DocumentModel(canvases: [roadmapCanvas(structure)]))
        let v = h.host.canvasView
        v.fitToWindow()
        let topics = h.canvas.nodes.filter { $0.key != h.canvas.root && !$0.value.children.isEmpty }.map(\.key)
        #expect(topics.count == 7)
        var families = Set<String>()
        for id in topics {
            let scene = h.controller.scene
            let n = try #require(scene.nodes[id])
            let edge = try #require(scene.edges.first { $0.child == h.canvas.nodes[id]!.children[0] })
            families.insert(edge.family)
            let child = try #require(scene.nodes[edge.child]).frame
            let line = BranchLines.path(
                from: n.frame, to: child, family: edge.family, shape: BranchLineShape(name: edge.line.shape),
                parentBaseline: edge.parentBaseline)
            var start = CGPoint.zero
            var first = true
            line.applyWithBlock { el in
                if first { start = el.pointee.points[0] }
                first = false
            }
            hover(h, center(h, id))
            #expect(v.foldHover == id)
            let minus = try #require(v.foldControl(id))
            let label = "\(structure.rawValue) \(h.canvas.nodes[id]!.text) (\(edge.family))"
            if edge.family == "fishboneCause" {
                // A bone label's causes hang off the bone, which leaves the label nearest the spine.
                let bone = try #require(scene.edges.first { $0.child == id })
                let path = BranchLines.path(
                    from: scene.nodes[bone.parent]!.frame, to: n.frame, family: bone.family)
                let under = path.copy(
                    strokingWithWidth: NodeLayer.foldButtonSize, lineCap: .round, lineJoin: .round, miterLimit: 1)
                #expect(under.contains(CGPoint(x: minus.midX, y: minus.midY)), "\(label): over the bone")
            } else {
                #expect(minus.contains(start), "\(label): over where the line leaves")
                if !["logic", "mindmap"].contains(edge.family) {
                    // Straight lines run under the control's centre.
                    let under = line.copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
                    #expect(under.contains(CGPoint(x: minus.midX, y: minus.midY)), "\(label): on the line")
                }
            }
            #expect(!n.frame.rect.contains(CGPoint(x: minus.midX, y: minus.midY)), "\(label): past the edge")
            // Folded, the "+N" takes its place, over the same point.
            click(h, viewCenter(h, minus))
            #expect(h.canvas.nodes[id]?.folded == true, "\(label)")
            hover(h, .zero)
            let plus = try #require(v.foldControl(id))
            let f = try #require(h.controller.scene.nodes[id]).frame.rect
            let j = try #require(h.controller.scene.nodes[id]?.junction)
            let open = try #require(n.junction)
            let at = CGPoint(x: f.minX + j.point.x, y: f.minY + j.point.y)
            #expect(plus.contains(at), "\(label): the badge is on the junction")
            #expect(j.edge == open.edge, "\(label): on the same edge")
            // Org charts stack leaves in a column, which a fold can't see; a fishbone's
            // sub-causes can move out from a lower bone (D240), and their line with them.
            if !(structure == .orgDown && edge.family == "indent") && edge.family != "fishboneSub" {
                #expect(abs(j.point.x - open.point.x) <= 6, "\(label): where the line left")
            }
            click(h, viewCenter(h, plus))
            #expect(h.canvas.nodes[id]?.folded == false, "\(label)")
        }
        #expect(!families.isEmpty)
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
