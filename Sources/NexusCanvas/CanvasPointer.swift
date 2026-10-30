import Foundation
import NexusCore
import NexusScene
import NexusTheme
import QuartzCore

/// The modifier keys held during a click, drag or tap.
public struct PointerModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = PointerModifiers(rawValue: 1 << 0)
    public static let command = PointerModifiers(rawValue: 1 << 1)
    public static let option = PointerModifiers(rawValue: 1 << 2)
    public static let control = PointerModifiers(rawValue: 1 << 3)
}

/// The view a `CanvasPointer` works in: the Mac's `CanvasView` or the iPad's touch canvas.
@MainActor
package protocol PointerSurface: AnyObject {
    var camera: Camera { get }
    /// Moves the camera at once, ending any camera animation.
    func panCamera(to c: Camera)
    func update(animated: Bool)
    func fitToWindow()
    /// Shows a hint just below and right of a rect in view coordinates; nil hides it.
    func showDropHint(_ text: String?, below viewRect: CGRect)
    /// A click selected something anew.
    func pointerChangedSelection()
    /// A click on the topic that was already the only one selected.
    func pointerClickedSelectedTopic(_ id: NodeID)
}

/// Clicking, dragging and the fold controls on a canvas, for the mouse and for touch
/// (M47b; moved out of `CanvasView`). Positions are in view coordinates: drag to move a
/// topic or reparent it with drop hints and guides, drag zones, the legend, a selection
/// band or (with ⌥) the canvas; click a topic's "−" or "+N", its indicators, progress ring
/// or to-do box.
@MainActor
package final class CanvasPointer {
    package unowned let controller: CanvasController
    package unowned let renderer: SceneRenderer
    package unowned let surface: any PointerSurface
    package let rubberBand = CAShapeLayer()
    package let dropIndicator = CAShapeLayer()
    /// The topic showing its "−" fold control (D215).
    package private(set) var foldHover: NodeID?

    package init(controller: CanvasController, renderer: SceneRenderer, surface: any PointerSurface) {
        self.controller = controller
        self.renderer = renderer
        self.surface = surface
        // The band goes under the element overlay, the drop indicator on top.
        let world = renderer.world
        world.insertSublayer(rubberBand, below: renderer.elements.overlayLayer)
        rubberBand.fillColor = RGBA(hex: "#5850EC").alpha(0.08).cgColor
        rubberBand.strokeColor = RGBA(hex: "#5850EC").alpha(0.6).cgColor
        rubberBand.lineWidth = 1
        rubberBand.isHidden = true
        rubberBand.actions = NodeLayer.noActions
        dropIndicator.fillColor = nil
        dropIndicator.lineCap = .round
        dropIndicator.isHidden = true
        dropIndicator.actions = NodeLayer.noActions
        world.addSublayer(dropIndicator)
    }

    var camera: Camera { surface.camera }
    var elements: ElementRenderer { renderer.elements }

    // MARK: Hit testing

    package func node(at viewPoint: CGPoint) -> NodeID? {
        let p = camera.toWorld(viewPoint)
        for id in controller.scene.order.reversed() {
            if let f = renderer.animatedFrame(id), f.rect.contains(p) { return id }
        }
        return nil
    }

    func treeNode(at w: CGPoint, excluding: Set<NodeID>) -> NodeID? {
        for id in controller.scene.order.reversed() where !excluding.contains(id) {
            if let f = controller.scene.nodes[id]?.frame, f.rect.insetBy(dx: -6, dy: -6).contains(w) { return id }
        }
        return nil
    }

    /// The zones a rubber band wholly encloses, back to front (D258). A band that only
    /// crosses a zone selects the topics it touches, so a zone's topics can still be
    /// banded from outside it; ⌘-drag bands topics only.
    package func bandZones(_ band: CGRect) -> [String] {
        controller.scene.zones.filter { band.contains($0.rect) }.map(\.zone.id)
    }

    /// What a right-click (or a long press) at a point in the view lands on (M17), or nil
    /// for no menu (AI suggestions, Present, Map Shot).
    package func menuTarget(at p: CGPoint) -> CanvasMenuTarget? {
        let c = controller
        guard c.present == nil, c.mapShot == nil, c.palette == nil, c.jump == nil else { return nil }
        let w = camera.toWorld(p)
        if let l = c.scene.legend, l.rect.contains(w) { return .legend }
        if let id = node(at: p) {
            guard CanvasController.ghostIndex(id) == nil else { return nil }
            if let k = c.canvas.callouts.first(where: { $0.topic == id }) { return .element(.callout(k.id)) }
            if let n = c.scene.nodes[id], n.image != nil, let f = renderer.animatedFrame(id) {
                let local = CGPoint(x: w.x - f.rect.minX, y: w.y - f.rect.minY)
                if n.imageRect.contains(local) { return .image(id) }
            }
            return .topic(id)
        }
        if let el = elements.hitTest(w) { return .element(el) }
        return .canvas(w)
    }

    // MARK: Fold control (D215)

    /// Whether a topic offers the "−": it has children showing and isn't the central topic,
    /// whose branches leave in several directions.
    package func offersFoldButton(_ id: NodeID) -> Bool {
        let c = controller
        guard id != c.canvas.root, CanvasController.ghostIndex(id) == nil, let n = c.canvas.nodes[id] else {
            return false
        }
        return !n.children.isEmpty && !n.folded
    }

    /// Shows the "−" on the topic under the pointer, and keeps it while the pointer is on
    /// it. Returns whether the pointer is on a fold control (the Mac's pointing hand).
    @discardableResult
    package func updateFoldHover(_ p: CGPoint) -> Bool {
        let c = controller
        guard c.mode == .select, c.present == nil, c.mapShot == nil, !renderer.exportMode else {
            setFoldHover(nil)
            return false
        }
        let w = camera.toWorld(p)
        if let h = foldHover, foldControl(h)?.contains(w) == true { return true }
        setFoldHover(node(at: p).flatMap { offersFoldButton($0) ? $0 : nil })
        return foldTarget(atWorld: w) != nil
    }

    package func setFoldHover(_ id: NodeID?) {
        guard id != foldHover else { return }
        if let old = foldHover { renderer.nodeLayers[old]?.showsFoldButton = false }
        foldHover = id
        if let id { renderer.nodeLayers[id]?.showsFoldButton = true }
    }

    /// A topic's fold control ("−" or "+N") in canvas coordinates.
    package func foldControl(_ id: NodeID) -> CGRect? {
        guard let local = renderer.nodeLayers[id]?.foldControlRect, let f = renderer.animatedFrame(id) else {
            return nil
        }
        return local.offsetBy(dx: f.rect.minX, dy: f.rect.minY)
    }

    /// The topic whose "−" or "+N" is at a canvas point: the hovered topic first, then
    /// every folded one.
    package func foldTarget(atWorld w: CGPoint) -> NodeID? {
        if let h = foldHover, foldControl(h)?.contains(w) == true { return h }
        for (id, layer) in renderer.nodeLayers where !layer.badge.isHidden && !layer.isHidden {
            if foldControl(id)?.contains(w) == true { return id }
        }
        return nil
    }

    /// Folds or unfolds from the control, one undo step. A selection inside the branch
    /// moves to the folded topic, as it does in Xmind.
    package func toggleFoldFromControl(_ id: NodeID) {
        let c = controller
        guard let n = c.canvas.nodes[id], !n.children.isEmpty else { return }
        let inside = Set(c.canvas.subtree(id)).subtracting([id])
        c.restructure(Loc.t(n.folded ? "Unfold" : "Fold")) { try $0.toggleFold(id) }
        if !n.folded, c.selection.nodes.contains(where: inside.contains) { c.select(id) }
        setFoldHover(nil)
    }

    // MARK: Dragging

    enum DropTarget: Equatable {
        case child(NodeID)
        case before(NodeID)
        case after(NodeID)
    }

    enum Drag {
        case pan(start: CGPoint, offset: CGPoint)
        /// `zones`: the zones selected when a ⇧-band began, which it adds to.
        case rubber(start: CGPoint, extend: Bool, zones: [String])
        case node(
            id: NodeID, start: CGPoint, subtree: [NodeID], origins: [NodeID: CGPoint], floating: Bool,
            active: Bool, target: DropTarget?)
        /// The clicked zone `id`, and every selected zone in `ids`, which move together.
        case zone(
            id: String, ids: [String], start: CGPoint, members: [NodeID], origins: [NodeID: CGPoint], active: Bool)
        /// The legend (M14), moved by its top-left corner.
        case legend(start: CGPoint, origin: CGPoint, active: Bool)
    }

    var drag: Drag?
    private var zoneDragOffset = CGSize.zero

    /// Whether a drag of a topic, zone or the legend is under way (not a band or a pan).
    package var isMovingSomething: Bool {
        switch drag {
        case .node(_, _, _, _, _, let active, _)?, .zone(_, _, _, _, _, let active)?, .legend(_, _, let active)?:
            active
        default: false
        }
    }

    /// A press at a point in the view, after the platform has handled Present and the
    /// context-menu click. `bandOrPan` is what a drag on empty canvas does: a band, or a
    /// pan (⌥ on the Mac; one finger can be either on the iPad).
    package func down(at p: CGPoint, clickCount: Int, modifiers: PointerModifiers, emptyDrag: EmptyDrag? = nil) {
        let w = camera.toWorld(p)
        if controller.mode == .connect { controller.cancelConnect() }
        // The "−" folds a branch; a folded branch's "+N" unfolds it (D215).
        if controller.mode == .select, clickCount == 1, let id = foldTarget(atWorld: w) {
            toggleFoldFromControl(id)
            return
        }
        // Clicking a ghost accepts it (one undo), like ⌃↩.
        if let id = node(at: p), let i = CanvasController.ghostIndex(id) {
            if controller.ghosts != nil { controller.acceptGhost(i) } else { controller.previewPlan(nil) }
            return
        }
        // The legend sits above the topics: drag to move it, double-click to edit it.
        if let l = controller.scene.legend, l.rect.contains(w), controller.mode != .edit {
            if clickCount == 2 {
                controller.editLegend()
            } else {
                controller.selectLegend()
                drag = .legend(start: w, origin: l.rect.origin, active: false)
            }
            return
        }
        controller.deselectLegend()
        if let id = node(at: p), let n = controller.scene.nodes[id], let f = renderer.animatedFrame(id) {
            let local = CGPoint(x: w.x - f.rect.minX, y: w.y - f.rect.minY)
            if clickCount == 1, handleDecorationClick(id, n, local) { return }
            if clickCount == 2 {
                controller.beginEditing(id)
                return
            }
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                controller.select(id, extend: true)
            } else if !controller.selection.contains(id) || controller.selectedElement != nil {
                controller.select(id)
                surface.pointerChangedSelection()
            } else if controller.selection.nodes.count == 1 {
                surface.pointerClickedSelectedTopic(id)
            }
            let floating = controller.canvas.floating.contains(id)
            let sub = controller.canvas.subtree(id, includeFolded: false)
            var origins: [NodeID: CGPoint] = [:]
            for d in sub { origins[d] = renderer.springs[d]?.value }
            drag = .node(
                id: id, start: w, subtree: sub, origins: origins, floating: floating, active: false, target: nil)
            return
        }
        if let el = elements.hitTest(w) {
            if clickCount == 2 {
                controller.selectElement(el)
                controller.beginEditingElement(el)
                return
            }
            // ⇧- or ⌘-click adds a zone to the selected zones or takes it out (D228); a
            // click on one of several selected zones keeps them, to drag them together.
            if case .zone(let zid) = el, modifiers.contains(.command) || modifiers.contains(.shift) {
                controller.toggleZone(zid)
                return
            }
            let zones = controller.selectedZones
            if !(zones.count > 1 && el == .zone(el.id) && zones.contains(el.id)) { controller.selectElement(el) }
            if case .zone(let zid) = el, controller.canvas.zones.contains(where: { $0.id == zid }) {
                if w.y - (controller.scene.zones.first { $0.zone.id == zid }?.rect.minY ?? 0) < 30,
                    w.x - (controller.scene.zones.first { $0.zone.id == zid }?.rect.minX ?? 0) < 30
                {
                    controller.updateZone(zid) { $0.collapsed.toggle() }
                    return
                }
                let ids = controller.selectedZones
                var members: [NodeID] = []
                for z in controller.canvas.zones where ids.contains(z.id) {
                    for m in z.members { members += controller.canvas.subtree(m) }
                }
                var origins: [NodeID: CGPoint] = [:]
                for d in members { origins[d] = renderer.springs[d]?.value }
                drag = .zone(id: zid, ids: ids, start: w, members: members, origins: origins, active: false)
            }
            return
        }
        if clickCount == 2 {
            switch controller.doubleClickAction {
            case "fit": surface.fitToWindow()
            case "nothing": break
            default: controller.addFloating(at: w)
            }
            return
        }
        // A ⇧-band adds to the selected zones, so it remembers them (D258).
        let extend = modifiers.contains(.shift)
        let zones = extend ? controller.selectedZones : []
        if controller.selectedElement != nil { controller.selectElement(nil) }
        switch emptyDrag ?? (modifiers.contains(.option) ? .pan : .band) {
        case .pan: drag = .pan(start: p, offset: camera.offset)
        case .band: drag = .rubber(start: w, extend: extend, zones: zones)
        case .none: drag = nil
        }
    }

    /// What dragging on empty canvas does.
    package enum EmptyDrag: Sendable {
        case band, pan, none
    }

    /// Clicks on a topic's indicators, progress ring or to-do box.
    func handleDecorationClick(_ id: NodeID, _ n: SceneNode, _ local: CGPoint) -> Bool {
        for (i, r) in n.indicatorRects.enumerated() where r.insetBy(dx: -2, dy: -2).contains(local) {
            switch n.indicators[i] {
            case .note: controller.onRequest?(.note(id))
            case .comment: controller.onRequest?(.comments(id))
            case .link, .topicLink, .file: controller.followLink(of: id)
            case .attachment: controller.onRequest?(.attachment(id, 0))
            case .audio: controller.onRequest?(.audio(id))
            case .ai: return false
            }
            return true
        }
        if n.progress != nil, CGRect(x: n.leadRect.minX, y: n.leadRect.minY, width: 20, height: 18).contains(local) {
            controller.select(id)
            controller.toggleBranchTodos(id)
            return true
        }
        if n.todo != nil {
            var x = n.leadRect.minX + (n.progress != nil ? SceneBuilder.markerWidth : 0)
            x += n.priority != nil ? SceneBuilder.priorityWidth : 0
            if CGRect(x: x, y: n.leadRect.minY, width: 18, height: 18).contains(local) {
                controller.select(id)
                controller.perform(.toggleTodo)
                return true
            }
        }
        return false
    }

    /// The pointer moved with the button (or finger) down.
    package func dragged(to p: CGPoint, modifiers: PointerModifiers) {
        let w = camera.toWorld(p)
        switch drag {
        case .pan(let start, let offset)?:
            var c = camera
            c.offset = CGPoint(x: offset.x + p.x - start.x, y: offset.y + p.y - start.y)
            surface.panCamera(to: c)
        case .rubber(let start, _, _)?:
            let r = CGRect(
                x: min(start.x, w.x), y: min(start.y, w.y), width: abs(w.x - start.x), height: abs(w.y - start.y))
            rubberBand.isHidden = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rubberBand.path = CGPath(rect: r, transform: nil)
            CATransaction.commit()
        case .node(let id, let start, let sub, let origins, let floating, var active, _)?:
            let dx = w.x - start.x
            let dy = w.y - start.y
            if !active && hypot(dx, dy) * camera.zoom < 4 { return }
            guard id != controller.canvas.root else { return }
            active = true
            var offset = CGSize(width: dx, height: dy)
            var target: DropTarget?
            var guideLines: [(CGPoint, CGPoint)] = []
            var guideLabel: (String, CGPoint)?
            let excluded = Set(sub)
            if floating, let f = controller.scene.nodes[id]?.frame, let o = origins[id] {
                // Smart guides: snap the dragged topic's centre to neighbours' centres.
                let moved = CGPoint(x: o.x + dx, y: o.y + dy)
                let snap: CGFloat = controller.snapDistance / camera.zoom
                for (nid, n) in controller.scene.nodes where !excluded.contains(nid) {
                    let c = n.frame.center
                    if abs(c.x - moved.x) < snap {
                        offset.width += c.x - moved.x
                        guideLines.append(
                            (CGPoint(x: c.x, y: min(c.y, moved.y) - 40), CGPoint(x: c.x, y: max(c.y, moved.y) + 40)))
                        let gap = abs(c.y - moved.y) - (n.frame.size.height + f.size.height) / 2
                        if gap > 0 {
                            guideLabel = (
                                Loc.f("%lld pt", Int(gap.rounded())), CGPoint(x: c.x + 24, y: (c.y + moved.y) / 2)
                            )
                        }
                    }
                    if abs(c.y - moved.y) < snap {
                        offset.height += c.y - moved.y
                        guideLines.append(
                            (CGPoint(x: min(c.x, moved.x) - 40, y: c.y), CGPoint(x: max(c.x, moved.x) + 40, y: c.y)))
                        guideLabel =
                            guideLabel ?? (Loc.t("aligned centre"), CGPoint(x: (c.x + moved.x) / 2, y: c.y - 12))
                    }
                }
                // Snap to grid (Settings › Editing) when no guide caught the topic.
                if let g = controller.gridSnap, guideLines.isEmpty {
                    let target = CGPoint(x: (moved.x / g).rounded() * g, y: (moved.y / g).rounded() * g)
                    offset.width += target.x - moved.x
                    offset.height += target.y - moved.y
                }
                if controller.canvas.layout.flexibleFloating, let t = treeNode(at: w, excluding: excluded) {
                    target = .child(t)
                }
            } else if controller.alwaysShowGuides, let o = origins[id] {
                // Settings › Editing › Always show alignment guides: guides (no snapping) in any layout.
                let moved = CGPoint(x: o.x + dx, y: o.y + dy)
                let near = controller.snapDistance / camera.zoom
                for (nid, n) in controller.scene.nodes where !excluded.contains(nid) {
                    let c = n.frame.center
                    if abs(c.x - moved.x) < near {
                        guideLines.append(
                            (CGPoint(x: c.x, y: min(c.y, moved.y) - 40), CGPoint(x: c.x, y: max(c.y, moved.y) + 40)))
                    }
                    if abs(c.y - moved.y) < near {
                        guideLines.append(
                            (CGPoint(x: min(c.x, moved.x) - 40, y: c.y), CGPoint(x: max(c.x, moved.x) + 40, y: c.y)))
                    }
                }
                if !modifiers.contains(.shift), let t = treeNode(at: w, excluding: excluded),
                    let tf = controller.scene.nodes[t]?.frame
                {
                    let rel = (w.y - tf.rect.minY) / max(tf.size.height, 1)
                    let hasParent = controller.canvas.parent(of: t) != nil
                    target = hasParent && rel < 0.28 ? .before(t) : hasParent && rel > 0.72 ? .after(t) : .child(t)
                }
            } else if !modifiers.contains(.shift), let t = treeNode(at: w, excluding: excluded),
                let tf = controller.scene.nodes[t]?.frame
            {
                let rel = (w.y - tf.rect.minY) / max(tf.size.height, 1)
                let hasParent = controller.canvas.parent(of: t) != nil
                target = hasParent && rel < 0.28 ? .before(t) : hasParent && rel > 0.72 ? .after(t) : .child(t)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for d in sub {
                guard let o = origins[d] else { continue }
                let moved = CGPoint(x: o.x + offset.width, y: o.y + offset.height)
                renderer.springs[d] = SpringValue(moved)
                renderer.nodeLayers[d]?.zPosition = 10
                if d == id {
                    renderer.nodeLayers[d]?.shadowOpacity = 1
                    renderer.nodeLayers[d]?.shadowColor = RGBA.black.alpha(0.18).cgColor
                    renderer.nodeLayers[d]?.shadowRadius = 12
                    renderer.nodeLayers[d]?.shadowOffset = .layerShadow(0, 6)
                }
            }
            renderer.applyFrames(all: false)
            for d in sub { renderer.moving.insert(d) }
            renderer.applyFrames(all: true)
            showDrop(target, floatingLabel: floating)
            elements.showGuides(guideLines, label: guideLabel?.0, at: guideLabel?.1)
            elements.updateGeometry(
                selected: controller.selectedElement, connect: nil,
                frame: { [weak renderer] in renderer?.animatedFrame($0)?.rect })
            renderer.decorRenderer.updateGeometry(frame: { [weak renderer] in renderer?.animatedFrame($0)?.rect })
            CATransaction.commit()
            renderer.moving.removeAll()
            drag = .node(
                id: id, start: start, subtree: sub, origins: origins, floating: floating, active: active, target: target
            )
        case .zone(let zid, let ids, let start, let members, let origins, var active)?:
            let dx = w.x - start.x
            let dy = w.y - start.y
            if !active && hypot(dx, dy) * camera.zoom < 4 { return }
            active = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for d in members {
                guard let o = origins[d] else { continue }
                renderer.springs[d] = SpringValue(CGPoint(x: o.x + dx, y: o.y + dy))
            }
            renderer.applyFrames(all: true)
            CATransaction.commit()
            drag = .zone(id: zid, ids: ids, start: start, members: members, origins: origins, active: active)
            zoneDragOffset = CGSize(width: dx, height: dy)
            for id in ids { elements.offsetZone(id, by: zoneDragOffset) }
            elements.updateGeometry(
                selected: controller.selectedElement, connect: nil,
                frame: { [weak renderer] in renderer?.animatedFrame($0)?.rect })
        case .legend(let start, let origin, var active)?:
            let dx = w.x - start.x
            let dy = w.y - start.y
            if !active && hypot(dx, dy) * camera.zoom < 4 { return }
            active = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.legendLayer.frame.origin = CGPoint(x: origin.x + dx, y: origin.y + dy)
            CATransaction.commit()
            drag = .legend(start: start, origin: origin, active: active)
        case nil:
            break
        }
    }

    /// Drop targets (S3): a glowing line for before / after, a halo for "as child".
    private func showDrop(_ t: DropTarget?, floatingLabel: Bool) {
        guard let t else {
            dropIndicator.isHidden = true
            surface.showDropHint(nil, below: .zero)
            return
        }
        let theme = controller.theme
        dropIndicator.isHidden = false
        dropIndicator.strokeColor = theme.ring.cgColor
        dropIndicator.shadowColor = theme.ring.cgColor
        dropIndicator.shadowOpacity = 0.6
        dropIndicator.shadowRadius = 6
        dropIndicator.shadowOffset = .zero
        switch t {
        case .child(let id):
            guard let f = controller.scene.nodes[id]?.frame.rect else { return }
            let r = f.insetBy(dx: -6, dy: -6)
            dropIndicator.path = CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)
            dropIndicator.lineWidth = 3
            dropIndicator.fillColor = theme.ringSoft.alpha(0.3).cgColor
            if floatingLabel {
                let text = controller.canvas.nodes[id]?.text ?? ""
                surface.showDropHint(Loc.f("Drop to attach under %@", text), below: camera.toView(r))
            }
        case .before(let id), .after(let id):
            guard let f = controller.scene.nodes[id]?.frame.rect else { return }
            let y: CGFloat = { if case .before = t { return f.minY - 6 } else { return f.maxY + 6 } }()
            let p = CGMutablePath()
            p.move(to: CGPoint(x: f.minX, y: y))
            p.addLine(to: CGPoint(x: f.maxX, y: y))
            dropIndicator.path = p
            dropIndicator.lineWidth = 3
            dropIndicator.fillColor = nil
        }
    }

    /// The button (or finger) came up: the drag's effect, as one undo step.
    package func up(at p: CGPoint, modifiers: PointerModifiers) {
        let w = camera.toWorld(p)
        defer { cancel() }
        switch drag {
        case .rubber(let start, let extend, let selectedZones)?:
            let r = CGRect(
                x: min(start.x, w.x), y: min(start.y, w.y), width: abs(w.x - start.x), height: abs(w.y - start.y))
            guard r.width > 3 || r.height > 3 else { return }
            // A band around whole zones selects those zones; ⌘ keeps it to topics (D258).
            let zones = modifiers.contains(.command) ? [] : bandZones(r)
            if !zones.isEmpty {
                controller.selectZones(selectedZones + zones.filter { !selectedZones.contains($0) })
                return
            }
            let hits = controller.scene.order.filter { controller.scene.nodes[$0]!.frame.rect.intersects(r) }
            guard let first = hits.first else { return }
            let base = extend ? controller.selection.nodes : []
            controller.setSelection(Selection(primary: first, nodes: base + hits.filter { !base.contains($0) }))
        case .node(let id, let start, _, _, let floating, let active, let target)?:
            guard active else { return }
            let dx = w.x - start.x
            let dy = w.y - start.y
            if floating {
                if case .child(let t)? = target {
                    controller.moveTopic(id, toParent: t, at: nil)
                } else if controller.canvas.nodes[id]?.position != nil, let s = renderer.springs[id] {
                    controller.moveFloating(id, to: s.value)
                } else {
                    controller.moveFloating(id, to: CGPoint(x: dx, y: dy))
                }
            } else if modifiers.contains(.shift) {
                controller.detachTopic(id, at: renderer.springs[id]?.value ?? w)
            } else if let target {
                let dup = modifiers.contains(.option)
                switch target {
                case .child(let t): controller.moveTopic(id, toParent: t, at: nil, duplicate: dup)
                case .before(let t), .after(let t):
                    guard let p = controller.canvas.parent(of: t),
                        let i = controller.canvas.nodes[p]?.children.firstIndex(of: t)
                    else { break }
                    let isAfter: Bool = { if case .after = target { return true } else { return false } }()
                    controller.moveTopic(id, toParent: p, at: isAfter ? i + 1 : i, duplicate: dup)
                }
            } else if controller.dragToFloat, hypot(dx, dy) > 80 {
                // Dragged well off its branch onto empty canvas: it floats there.
                controller.detachTopic(id, at: renderer.springs[id]?.value ?? w)
            } else {
                // Dropped on empty canvas: settle back.
                surface.update(animated: true)
            }
        case .zone(let zid, let ids, _, _, _, let active)?:
            guard active else {
                // A plain click on one of several selected zones selects just that one.
                if ids.count > 1, modifiers.intersection([.command, .shift]).isEmpty {
                    controller.selectElement(.zone(zid))
                }
                return
            }
            for id in ids { elements.offsetZone(id, by: .zero) }
            controller.moveZones(ids, by: zoneDragOffset)
        case .legend(let start, let origin, let active)?:
            guard active else { return }
            controller.moveLegend(to: CanvasPoint(x: origin.x + w.x - start.x, y: origin.y + w.y - start.y))
        default:
            break
        }
    }

    /// Ends a drag without its effect (and tidies up after one with it).
    package func cancel() {
        drag = nil
        rubberBand.isHidden = true
        dropIndicator.isHidden = true
        surface.showDropHint(nil, below: .zero)
        elements.showGuides([], label: nil, at: nil)
        for l in renderer.nodeLayers.values where l.zPosition != 0 {
            l.zPosition = 0
            l.shadowOpacity = l.node.map { $0.appearance.shadow == nil ? 0 : 1 } ?? 0
        }
    }
}
