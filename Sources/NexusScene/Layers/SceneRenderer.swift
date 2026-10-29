import CoreGraphics
import Foundation
import NexusCore
import NexusLayout
import NexusTheme
import QuartzCore

/// The canvas's layer tree, kept in step with a scene: the grid, then the world (bands,
/// zones, boundaries, decor, branch lines, summaries, relationships, pointers, topics, the
/// legend and the element overlay), with the camera, culling, text scale and the topics'
/// springs. `CanvasView` hosts it on the Mac and steps the springs on its display link;
/// exports host it with no view or window (M47a).
@MainActor
package final class SceneRenderer {
    /// What the controller says about the scene beyond the scene itself.
    package struct State {
        package var parents: [NodeID: NodeID] = [:]
        package var selected: Set<NodeID> = []
        package var primary: NodeID?
        /// The topic being edited in place.
        package var editing: NodeID?
        package var editingElement: ElementRef?
        package var selectedElement: ElementRef?
        package var selectedZones: Set<String> = []
        package var connect: ConnectState?
        /// Slides show no selection ring.
        package var presenting = false
        package var legendActive = false
        package var ringWidth: CGFloat = 3
        package var glowTrail = false
        package var flowDots = false
        package init() {}
    }

    package let rootLayer = CALayer()
    package let grid = GridLayer()
    /// Topics, lines and elements in world coordinates, under the camera's transform.
    package let world = CALayer()
    package let edgesLayer = CALayer()
    package let nodesLayer = CALayer()
    package let elements = ElementRenderer()
    package let decorRenderer = DecorRenderer()
    /// The legend box, above the topics (M14).
    package let legendLayer = LegendLayer()

    package var nodeLayers: [NodeID: NodeLayer] = [:]
    package var edgeLayers: [NodeID: CAShapeLayer] = [:]
    package var springs: [NodeID: SpringValue] = [:]
    package var scales: [NodeID: SpringScalar] = [:]
    /// Topics whose springs are still running.
    package var moving = Set<NodeID>()
    private var edgesByNode: [NodeID: [NodeID]] = [:]
    private var edgeInfo: [NodeID: SceneEdge] = [:]
    private var capLayers: [NodeID: CAShapeLayer] = [:]
    private var lastBackground: (RGBA, Theme.Grid)?
    private var imageCache: [String: CGImage] = [:]
    /// The scene the layers show.
    package private(set) var scene = Scene()

    /// Offscreen export: no selection ring, no grid.
    package var exportMode = false {
        didSet {
            grid.suppressed = exportMode
            grid.isHidden = exportMode
        }
    }
    package private(set) var camera = Camera()
    /// The host's size, in points.
    package var viewSize: CGSize = .zero {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rootLayer.bounds = viewBounds
            CATransaction.commit()
        }
    }
    /// Pixels per point where it's shown (exports draw at 2×).
    package var backingScale: CGFloat = 2 {
        didSet {
            rootLayer.contentsScale = backingScale
            grid.contentsScale = backingScale
        }
    }
    /// On screen, topics outside the view are hidden; offscreen renders draw everything.
    package var onScreen = false
    /// Off only for tests and tools that need every layer live.
    package var cullingEnabled = true
    /// How many topic layers the last cull left on screen.
    package private(set) var visibleNodeLayers = 0
    /// An asset's bytes by name (topic images and stickers).
    package var asset: (String) -> Data? = { _ in nil }

    package init() {
        rootLayer.isGeometryFlipped = true
        rootLayer.actions = NodeLayer.noActions
        rootLayer.contentsScale = backingScale
        grid.contentsScale = backingScale
        grid.actions = NodeLayer.noActions
        rootLayer.addSublayer(grid)
        world.anchorPoint = .zero
        world.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        world.actions = NodeLayer.noActions
        edgesLayer.actions = NodeLayer.noActions
        nodesLayer.actions = NodeLayer.noActions
        world.addSublayer(decorRenderer.bandsLayer)
        world.addSublayer(elements.zonesLayer)
        world.addSublayer(elements.boundariesLayer)
        world.addSublayer(decorRenderer.layer)
        world.addSublayer(edgesLayer)
        world.addSublayer(elements.summariesLayer)
        world.addSublayer(elements.relationshipsLayer)
        world.addSublayer(elements.pointersLayer)
        world.addSublayer(nodesLayer)
        world.addSublayer(legendLayer)
        world.addSublayer(elements.overlayLayer)
        rootLayer.addSublayer(world)
    }

    package var viewBounds: CGRect { CGRect(origin: .zero, size: viewSize) }

    // MARK: Updates

    /// Rebuilds layers from `scene`. With `animated`, new topics grow from their parent's
    /// connector point, leaving ones shrink into their nearest remaining ancestor, and
    /// every topic's spring heads for its new place; `morph` also morphs their looks
    /// (⌥⌘S). Returns whether springs are still running (the host steps them).
    @discardableResult
    package func update(_ scene: Scene, state: State, animated animate: Bool, morph: Bool = false) -> Bool {
        self.scene = scene
        let theme = scene.theme
        NodeLayer.ringWidth = state.ringWidth
        elements.glowTrail = state.glowTrail
        elements.flowDots = state.flowDots
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if lastBackground.map({ $0.0 != scene.canvasColor || $0.1 != scene.grid }) ?? true {
            rootLayer.backgroundColor = scene.canvasColor.cgColor
            grid.pattern = scene.grid
            grid.place(in: viewBounds, force: true)
            lastBackground = (scene.canvasColor, scene.grid)
        }

        let parents = state.parents
        // Nodes leaving the scene shrink into their nearest visible ancestor.
        for (id, layer) in nodeLayers where scene.nodes[id] == nil {
            var anchor = parents[id]
            while let a = anchor, scene.nodes[a] == nil { anchor = parents[a] }
            exit(layer, toward: anchor.flatMap { springs[$0]?.target }, animate: animate)
            nodeLayers[id] = nil
            springs[id] = nil
            scales[id] = nil
            moving.remove(id)
        }

        for id in scene.order {
            guard let n = scene.nodes[id] else { continue }
            let layer: NodeLayer
            if let l = nodeLayers[id] {
                layer = l
            } else {
                layer = NodeLayer(id: id)
                layer.textScale = textScale
                nodeLayers[id] = layer
                nodesLayer.addSublayer(layer)
                // New nodes grow from the parent's connector point.
                var start = n.frame.center
                if animate, let p = parents[id], let ps = springs[p], let pn = scene.nodes[p] {
                    let dir = CGFloat(n.frame.side.rawValue)
                    start =
                        n.frame.side == .down
                        ? CGPoint(x: ps.value.x, y: ps.value.y + pn.frame.size.height / 2)
                        : CGPoint(x: ps.value.x + dir * pn.frame.size.width / 2, y: ps.value.y)
                    scales[id] = SpringScalar(value: 0.3, target: 1)
                    layer.opacity = 0
                    let fadeIn = CABasicAnimation(keyPath: "opacity")
                    fadeIn.fromValue = 0
                    fadeIn.toValue = 1
                    fadeIn.duration = Motion.createNode
                    layer.add(fadeIn, forKey: "fade-in")
                    layer.opacity = 1
                }
                springs[id] = SpringValue(start)
            }
            layer.apply(
                n, theme: theme, canvas: scene.canvasColor,
                selected: state.selected.contains(id) && !state.presenting && !exportMode,
                primary: state.primary == id, editing: state.editing == id, morph: morph,
                image: n.image.flatMap { image(for: $0.asset) },
                sticker: n.sticker.flatMap { $0.hasPrefix("emoji:") ? nil : image(for: $0) })
            layer.connectState(
                state.connect.map { c in
                    c.source == .topic(id)
                        ? .source
                        : c.target?.node == id ? .target : c.matches.contains { $0.node == id } ? .candidate : .dimmed
                }, theme: theme)
            springs[id]?.target = n.frame.center
            if !animate {
                springs[id]?.snap()
                scales[id] = nil
            }
            moving.insert(id)
        }

        // Branch lines, keyed by child.
        var seen = Set<NodeID>()
        edgesByNode.removeAll(keepingCapacity: true)
        edgeInfo.removeAll(keepingCapacity: true)
        for e in scene.edges {
            seen.insert(e.child)
            let l =
                edgeLayers[e.child]
                ?? {
                    let s = CAShapeLayer()
                    s.lineJoin = .round
                    s.actions = NodeLayer.noActions
                    edgesLayer.addSublayer(s)
                    edgeLayers[e.child] = s
                    return s
                }()
            let line = e.line
            if line.taper {
                l.fillColor = line.color.cgColor
                l.strokeColor = nil
                l.lineDashPattern = nil
            } else {
                l.fillColor = nil
                l.strokeColor = line.color.cgColor
                l.lineWidth = line.width
                l.lineCap = line.dash == "dotted" ? .round : .round
                l.lineDashPattern =
                    switch line.dash {
                    case "dotted": [0.01, NSNumber(value: line.width * 2.6)]
                    case "dashed": [NSNumber(value: line.width * 3), NSNumber(value: line.width * 2.5)]
                    default: nil
                    }
            }
            if line.glow {
                l.shadowColor = line.color.cgColor
                l.shadowOpacity = 0.8
                l.shadowRadius = 4
                l.shadowOffset = .zero
            } else {
                l.shadowOpacity = 0
            }
            l.opacity = Float(e.opacity)
            capLayers[e.child]?.opacity = Float(e.opacity)
            edgeInfo[e.child] = e
            edgesByNode[e.parent, default: []].append(e.child)
            edgesByNode[e.child, default: []].append(e.child)
        }
        for (child, l) in edgeLayers where !seen.contains(child) {
            l.removeFromSuperlayer()
            edgeLayers[child] = nil
            capLayers[child]?.removeFromSuperlayer()
            capLayers[child] = nil
        }

        applyFrames(all: true)
        elements.textScale = textScale
        elements.editingElement = state.editingElement
        elements.selectedZones = state.selectedZones
        elements.update(
            scene: scene, selected: state.selectedElement, connect: state.connect,
            frame: { [weak self] in self?.animatedFrame($0)?.rect }, animated: animate)
        decorRenderer.textScale = textScale
        decorRenderer.update(scene: scene, frame: { [weak self] in self?.animatedFrame($0)?.rect })
        legendLayer.theme = scene.theme
        legendLayer.canvasColor = scene.canvasColor
        if legendLayer.contentsScale != textScale {
            legendLayer.contentsScale = textScale
            legendLayer.setNeedsDisplay()
        }
        legendLayer.legend = scene.legend
        legendLayer.selected = state.legendActive
        CATransaction.commit()
        cull()
        if moving.contains(where: { !(springs[$0]?.isSettled ?? true) || !(scales[$0]?.isSettled ?? true) }) {
            return true
        }
        moving.removeAll()
        return false
    }

    private func exit(_ layer: NodeLayer, toward point: CGPoint?, animate: Bool) {
        guard animate else {
            layer.removeFromSuperlayer()
            return
        }
        let group = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.toValue = 0.3
        var anims: [CAAnimation] = [fade, shrink]
        if let point {
            let move = CABasicAnimation(keyPath: "position")
            var p = point
            move.toValue = NSValue(bytes: &p, objCType: "{CGPoint=dd}")
            anims.append(move)
        }
        group.animations = anims
        group.duration = Motion.deleteNode
        group.timingFunction = CAMediaTimingFunction(
            controlPoints: Float(Motion.exit.c1x), Float(Motion.exit.c1y), Float(Motion.exit.c2x),
            Float(Motion.exit.c2y))
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.add(group, forKey: "exit")
        CATransaction.commit()
    }

    /// The animated frame of a node (spring position, grow-in scale).
    package func animatedFrame(_ id: NodeID) -> NodeFrame? {
        guard let n = scene.nodes[id], let s = springs[id] else { return nil }
        let k = scales[id]?.value ?? 1
        return NodeFrame(
            center: s.value, size: CGSize(width: n.frame.size.width * k, height: n.frame.size.height * k),
            side: n.frame.side, depth: n.frame.depth)
    }

    /// Moves topic layers to their springs' values (all, or only the moving ones) and
    /// redraws the branch lines that meet them.
    package func applyFrames(all: Bool) {
        let ids = all ? Set(nodeLayers.keys) : moving
        var dirtyEdges = Set<NodeID>()
        for id in ids {
            guard let layer = nodeLayers[id], let s = springs[id] else { continue }
            layer.position = s.value
            let k = scales[id]?.value ?? 1
            layer.transform = k == 1 ? CATransform3DIdentity : CATransform3DMakeScale(k, k, 1)
            for c in edgesByNode[id] ?? [] { dirtyEdges.insert(c) }
        }
        for child in dirtyEdges {
            guard let l = edgeLayers[child], let e = edgeInfo[child], let pf = animatedFrame(e.parent),
                let cf = animatedFrame(child)
            else { continue }
            let path = BranchLines.path(
                from: pf, to: cf, family: e.family, shape: BranchLineShape(name: e.line.shape),
                parentBaseline: e.parentBaseline, childBaseline: e.childBaseline)
            l.path =
                e.line.taper
                ? BranchLines.tapered(path, startWidth: e.line.width * 1.8, endWidth: max(1, e.line.width * 0.5)) : path
            updateCap(child, edge: e, parent: pf, child: cf)
        }
    }

    /// End caps (FMT-1 › Branch line › End cap): arrow, dot or bar where the line meets the child.
    private func updateCap(_ id: NodeID, edge e: SceneEdge, parent pf: NodeFrame, child cf: NodeFrame) {
        guard e.line.endCap != "none" else {
            capLayers[id]?.isHidden = true
            return
        }
        let cap =
            capLayers[id]
            ?? {
                let c = CAShapeLayer()
                c.actions = NodeLayer.noActions
                edgesLayer.addSublayer(c)
                capLayers[id] = c
                return c
            }()
        cap.isHidden = false
        // End point and incoming direction, on the child's near edge.
        let dir = CGFloat(cf.side.rawValue)
        let end: CGPoint
        let angle: CGFloat
        if cf.side == .down {
            end = CGPoint(x: cf.center.x, y: cf.center.y - cf.size.height / 2)
            angle = .pi / 2
        } else {
            end = CGPoint(
                x: cf.center.x - dir * cf.size.width / 2,
                y: e.childBaseline ? cf.center.y + cf.size.height / 2 : cf.center.y)
            angle = dir > 0 ? 0 : .pi
        }
        let w = max(e.line.width, 1.5)
        let p = CGMutablePath()
        switch e.line.endCap {
        case "arrow":
            let len = w * 3.2
            let half = w * 2.2
            p.move(to: end)
            p.addLine(
                to: CGPoint(
                    x: end.x - len * cos(angle) - half * sin(angle), y: end.y - len * sin(angle) + half * cos(angle)))
            p.addLine(
                to: CGPoint(
                    x: end.x - len * cos(angle) + half * sin(angle), y: end.y - len * sin(angle) - half * cos(angle)))
            p.closeSubpath()
        case "dot":
            let r = w * 1.6
            p.addEllipse(
                in: CGRect(x: end.x - r - r * cos(angle), y: end.y - r - r * sin(angle), width: 2 * r, height: 2 * r))
        default:  // bar
            let half = w * 2.4
            p.move(to: CGPoint(x: end.x - half * sin(angle), y: end.y + half * cos(angle)))
            p.addLine(to: CGPoint(x: end.x + half * sin(angle), y: end.y - half * cos(angle)))
        }
        cap.path = p
        cap.fillColor = e.line.endCap == "bar" ? nil : e.line.color.cgColor
        cap.strokeColor = e.line.endCap == "bar" ? e.line.color.cgColor : nil
        cap.lineWidth = w
    }

    // MARK: Springs

    /// Snaps every running spring to its target.
    package func settle() {
        for id in moving {
            springs[id]?.snap()
            scales[id] = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFrames(all: true)
        CATransaction.commit()
        moving.removeAll()
    }

    /// Advances the springs by `dt` seconds (inside the host's transaction) and moves the
    /// layers, lines and elements with them. Returns whether any are still running.
    package func step(_ dt: Double, morph: Bool, selected: ElementRef?, connect: ConnectState?) -> Bool {
        var settled = Set<NodeID>()
        for id in moving {
            springs[id]?.step(dt, spring: morph ? Motion.morph : Motion.snap)
            scales[id]?.step(dt, spring: Motion.snap)
            if scales[id]?.isSettled == true { scales[id] = nil }
            if springs[id]?.isSettled ?? true, scales[id] == nil { settled.insert(id) }
        }
        applyFrames(all: false)
        elements.updateGeometry(
            selected: selected, connect: connect, frame: { [weak self] in self?.animatedFrame($0)?.rect })
        decorRenderer.updateGeometry(frame: { [weak self] in self?.animatedFrame($0)?.rect })
        moving.subtract(settled)
        return !moving.isEmpty
    }

    // MARK: Camera

    /// The scale topic text rasterises at: the backing scale, times the zoom in quarter
    /// steps once past 1×.
    package var textScale: CGFloat {
        backingScale * max(1, (camera.zoom * 4).rounded(.up) / 4)
    }

    /// Places the world under `c`. With `parallax`, the grid drifts a little slower than
    /// the map (depth when zoomed out).
    package func place(_ c: Camera, parallax: Bool = false) {
        camera = c
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.position = c.offset
        world.transform = CATransform3DMakeScale(c.zoom, c.zoom, 1)
        if parallax {
            grid.camera = Camera(offset: CGPoint(x: c.offset.x * 0.85, y: c.offset.y * 0.85), zoom: c.zoom)
        } else {
            grid.camera = c
        }
        grid.place(in: viewBounds)
        CATransaction.commit()
        cull()
    }

    /// At zoom 1, the scene's centre in `bounds` when it fits with a margin, else the
    /// root's; nil for an empty scene or bounds.
    package static func centered(_ scene: Scene, root: NodeID, in bounds: CGRect) -> Camera? {
        let b = scene.bounds
        guard !b.isNull, bounds.width > 0 else { return nil }
        let r = scene.nodes[root]?.frame.center ?? .zero
        let fits = b.width + 80 < bounds.width && b.height + 80 < bounds.height
        let focus = fits ? CGPoint(x: b.midX, y: b.midY) : r
        return Camera(offset: CGPoint(x: bounds.midX - focus.x, y: bounds.midY - focus.y), zoom: 1)
    }

    /// Places the grid for a new view size.
    package func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.place(in: viewBounds, force: true)
        CATransaction.commit()
    }

    /// Viewport culling (M10): topics outside the view (plus a margin of a quarter view
    /// each side) are hidden, so the compositor skips them and zooming doesn't
    /// re-rasterise their text; a topic catches up on its text scale when it comes back
    /// into view. Offscreen renders draw everything.
    package func cull() {
        let s = textScale
        guard onScreen, viewSize.width > 0, cullingEnabled else {
            for l in nodeLayers.values {
                if l.isHidden { l.isHidden = false }
                l.textScale = s
            }
            return
        }
        let size = CGSize(width: viewSize.width / camera.zoom, height: viewSize.height / camera.zoom)
        let visible = CGRect(origin: camera.toWorld(.zero), size: size)
            .insetBy(dx: -size.width / 4, dy: -size.height / 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var shown = 0
        for l in nodeLayers.values {
            let show = visible.intersects(l.frame)
            if l.isHidden == show { l.isHidden = !show }
            if show {
                shown += 1
                if l.textScale != s { l.textScale = s }
            }
        }
        CATransaction.commit()
        visibleNodeLayers = shown
    }

    // MARK: Assets

    package func image(for asset: String) -> CGImage? {
        if let c = imageCache[asset] { return c }
        guard let data = self.asset(asset), let img = Graphics.platform.image(data) else { return nil }
        imageCache[asset] = img
        return img
    }

    // MARK: Offscreen

    /// Draws the layer tree into `ctx` (y up, `viewSize` points), as the window would
    /// composite it. `background` replaces the canvas colour (nil leaves it transparent).
    package func render(in ctx: CGContext, background: RGBA?) {
        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(origin: .zero, size: viewSize))
        }
        // The background is ours to paint (or leave transparent).
        let rootBackground = rootLayer.backgroundColor
        rootLayer.backgroundColor = nil
        defer { rootLayer.backgroundColor = rootBackground }
        render(in: ctx)
    }

    /// Draws the layer tree, canvas colour and all, into `ctx` (y up, `viewSize` points).
    package func render(in ctx: CGContext) {
        rootLayer.layoutIfNeeded()
        Self.redrawText(rootLayer)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: viewSize.height)
        ctx.scaleBy(x: 1, y: -1)
        rootLayer.render(in: ctx)
        ctx.restoreGState()
    }

    /// Text and decor draw on demand; `render(in:)` only draws contents already there.
    package static func redrawText(_ l: CALayer) {
        if l is TextLayer || l is DecorLayer {
            l.setNeedsDisplay()
            l.displayIfNeeded()
        }
        l.sublayers?.forEach(redrawText)
    }
}

/// Dot or line grid in world space, drawn for the visible rect only.
package final class GridLayer: CALayer {
    package var pattern: Theme.Grid = Theme.classic.grid
    package var camera = Camera()
    /// Off for offscreen export, whatever the pattern.
    package var suppressed = false
    /// What the drawn contents were made for: redraw only when it changes.
    private var drawn: (step: CGFloat, size: CGSize, pattern: Theme.Grid)?

    /// The grid pattern's cell size on screen, or nil when there's no grid to draw.
    package var step: CGFloat? {
        let spacing: CGFloat
        switch pattern {
        case .none: return nil
        case .dots(_, let s), .lines(_, let s): spacing = s
        }
        let step = spacing * camera.zoom
        // Denser than this the grid is only noise (and costly to draw at 5k-topic zoom levels).
        return step >= 12 ? step : nil
    }

    /// Covers `viewBounds` plus one cell each side, shifted by the camera's offset modulo
    /// the cell, so panning only moves the layer (M10: no redraw per scroll step).
    package func place(in viewBounds: CGRect, force: Bool = false) {
        guard let step, !suppressed else {
            if !isHidden { isHidden = true }
            return
        }
        if isHidden { isHidden = false }
        func phase(_ v: CGFloat) -> CGFloat {
            let r = v.truncatingRemainder(dividingBy: step)
            return r < 0 ? r + step : r
        }
        let size = CGSize(width: viewBounds.width + 2 * step, height: viewBounds.height + 2 * step)
        frame = CGRect(
            x: viewBounds.minX + phase(camera.offset.x) - step, y: viewBounds.minY + phase(camera.offset.y) - step,
            width: size.width, height: size.height)
        if force || drawn?.step != step || drawn?.size != size || drawn?.pattern != pattern {
            drawn = (step, size, pattern)
            setNeedsDisplay()
        }
    }

    package override func draw(in ctx: CGContext) {
        let color: RGBA
        let lines: Bool
        switch pattern {
        case .none: return
        case .dots(let c, _): (color, lines) = (c, false)
        case .lines(let c, _): (color, lines) = (c, true)
        }
        guard let step else { return }
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        if lines {
            ctx.setLineWidth(1)
            var x: CGFloat = 0
            while x <= bounds.maxX {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
                x += step
            }
            var y: CGFloat = 0
            while y <= bounds.maxY {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += step
            }
            ctx.strokePath()
        } else {
            // Dots this small read the same as squares; one fill call for all of them.
            let r = max(0.9, min(1.3, camera.zoom))
            var rects: [CGRect] = []
            rects.reserveCapacity(Int((bounds.width / step + 1) * (bounds.height / step + 1)))
            var y: CGFloat = 0
            while y <= bounds.maxY {
                var x: CGFloat = 0
                while x <= bounds.maxX {
                    rects.append(CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r))
                    x += step
                }
                y += step
            }
            ctx.setShouldAntialias(false)
            ctx.fill(rects)
        }
    }
}
