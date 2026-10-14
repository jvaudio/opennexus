import AppKit
import NexusCore
import NexusKeys
import NexusLayout
import NexusTheme
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu items generated from the registry send this action down the responder chain,
/// with the command id as the item's `representedObject`.
@MainActor @objc public protocol RegistryCommandTarget {
    func performRegistryCommand(_ sender: Any?)
}

/// The canvas: an opaque, layer-backed surface with one layer per node and per branch
/// line, a spring animator, a camera, and the in-node text editor.
public final class CanvasView: NSView, RegistryCommandTarget, NSMenuItemValidation {
    public let controller: CanvasController

    private let host = FlippedView()
    private let rootLayer = CALayer()
    private let grid = GridLayer()
    private let world = CALayer()
    private let edgesLayer = CALayer()
    private let nodesLayer = CALayer()

    private var nodeLayers: [NodeID: NodeLayer] = [:]
    private var edgeLayers: [NodeID: CAShapeLayer] = [:]
    private var springs: [NodeID: SpringValue] = [:]
    private var scales: [NodeID: SpringScalar] = [:]
    private var moving = Set<NodeID>()
    private var edgesByNode: [NodeID: [NodeID]] = [:]
    private var edgeInfo: [NodeID: SceneEdge] = [:]
    private var capLayers: [NodeID: CAShapeLayer] = [:]
    private var lastBackground: (RGBA, Theme.Grid)?
    /// Set before an update that should morph node looks (⌥⌘S).
    public var morphNextUpdate = false

    public private(set) var camera = Camera()
    private var cameraTween: CameraTween?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var hasPlacedCamera = false

    let editor = NodeTextView()
    let elements = ElementRenderer()
    let decorRenderer = DecorRenderer()
    private let rubberBand = CAShapeLayer()
    private let dropIndicator = CAShapeLayer()
    private var connectField: NSView?
    private var slashHost: NSHostingView<SlashMenuView>?
    private var suggestHost: NSHostingView<ProtocolSuggestionsView>?
    private var ghostHost: NSHostingView<GhostHintsView>?
    private var promptHost: NSHostingView<PromptBarView>?
    private var ghostBadge: NSHostingView<GhostBadgeView>?
    private var noticeHost: NSHostingView<AINoticeView>?
    private var morphUntil: CFTimeInterval = 0
    private var lastMorphSerial = 0
    private var imageCache: [String: CGImage] = [:]
    private var popovers: CanvasPopovers?

    /// A topic's rect in view coordinates (popover anchors).
    func viewRect(of id: NodeID) -> CGRect? {
        animatedFrame(id).map { camera.toView($0.rect) }
    }

    // MARK: Drop files on topics (attachments, images)

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        guard let id = node(at: p),
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        else { return false }
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                controller.canvas.nodes[id]?.image == nil
            {
                controller.setImage(data, ext: url.pathExtension, size: NSImage(data: data)?.size, on: id)
            } else {
                controller.addAttachment(data, name: url.lastPathComponent, on: id)
            }
        }
        return true
    }
    private var pendingTypingEvent: NSEvent?
    private var cheatTimer: Timer?

    /// Forces Reduce Motion (Settings › Accessibility override, and tests).
    public var reduceMotionOverride: Bool?
    var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Third-time-you-mouse tips and other hooks.
    public var onCheatSheet: ((Bool) -> Void)?

    public init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        rootLayer.isGeometryFlipped = true
        rootLayer.actions = NodeLayer.noActions
        host.layer = rootLayer
        host.wantsLayer = true
        // Focus blurs the rest of the map (Core Image filters on node layers).
        host.layerUsesCoreImageFilters = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)

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
        world.addSublayer(rubberBand)
        world.addSublayer(elements.overlayLayer)
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
        rootLayer.addSublayer(world)

        editor.controller = controller
        editor.isHidden = true
        addSubview(editor)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Canvas")
        setAccessibilityIdentifier("canvas")

        controller.onSceneChange = { [weak self] animated in self?.update(animated: animated) }
        controller.onReveal = { [weak self] id in self?.reveal(id) }
        controller.onFrame = { [weak self] ids, aspect in self?.frame(ids, aspect: aspect) }
        controller.onRestoreFocus = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        controller.onEditChange = { [weak self] session in self?.editChanged(session) }
        controller.onEditorReplaceText = { [weak self] text in
            guard let self else { return }
            self.editor.string = text
            self.positionEditor()
        }
        controller.viewCommandHandler = { [weak self] id in self?.performViewCommand(id) ?? false }
        controller.viewCommandValidator = { id in Self.viewCommands.contains(id) }
        controller.floatingPlacement = { [weak self] in self?.defaultFloatingPoint() ?? .zero }
        controller.onMorph = { [weak self] in self?.morphNextUpdate = true }
        popovers = CanvasPopovers(view: self)
        controller.onRequest = { [weak self] r in self?.popovers?.handle(r) }
        controller.onOpenURL = { NSWorkspace.shared.open($0) }
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The root of the canvas layer tree (offscreen rendering, snapshots, export).
    var sceneLayer: CALayer { rootLayer }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        controller.outlineFocused = false
        return super.becomeFirstResponder()
    }
    public override var canBecomeKeyView: Bool { true }

    public override func layout() {
        super.layout()
        host.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.frame = bounds
        grid.setNeedsDisplay()
        CATransaction.commit()
        if !hasPlacedCamera, bounds.width > 0 {
            hasPlacedCamera = true
            centerScene()
            update(animated: false)
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rootLayer.contentsScale = window?.backingScaleFactor ?? 2
        grid.contentsScale = rootLayer.contentsScale
        updateTextScale()
    }

    // MARK: Rendering

    /// Rebuilds layers from the controller's scene. Typing never waits on this: the
    /// editor is already live when a create command calls here.
    public func update(animated: Bool) {
        let scene = controller.scene
        let theme = scene.theme
        let canvas = controller.canvas
        let animate = animated && !reduceMotion && window != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if lastBackground.map({ $0.0 != scene.canvasColor || $0.1 != scene.grid }) ?? true {
            rootLayer.backgroundColor = scene.canvasColor.cgColor
            grid.pattern = scene.grid
            grid.setNeedsDisplay()
            lastBackground = (scene.canvasColor, scene.grid)
        }
        let morph = morphNextUpdate && animate
        morphNextUpdate = false
        if animated && reduceMotion && window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.reducedCrossFade
            world.add(fade, forKey: "reduce-motion-fade")
        }

        let parents = canvas.parentMap()
        let selected = Set(controller.selection.nodes)
        let editing = controller.edit.flatMap { $0.element == nil ? $0.node : nil }

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
            // Slides show no selection ring (the step glow says what matters).
            layer.apply(
                n, theme: theme, canvas: scene.canvasColor,
                selected: selected.contains(id) && controller.present == nil,
                primary: controller.selection.primary == id, editing: editing == id, morph: morph,
                image: n.image.flatMap { image(for: $0.asset) },
                sticker: n.sticker.flatMap { $0.hasPrefix("emoji:") ? nil : image(for: $0) })
            layer.connectState(
                controller.connect.map { c in
                    c.source == id
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
        elements.editingElement = controller.edit?.element
        elements.update(
            scene: scene, selected: controller.selectedElement, connect: controller.connect,
            frame: { [weak self] in self?.animatedFrame($0)?.rect }, animated: animate)
        decorRenderer.textScale = textScale
        decorRenderer.update(scene: scene, frame: { [weak self] in self?.animatedFrame($0)?.rect })
        CATransaction.commit()
        updateConnectField()
        if controller.morphSerial != lastMorphSerial {
            lastMorphSerial = controller.morphSerial
            morphUntil = CACurrentMediaTime() + Motion.convert + 0.15
        }
        refreshOverlays()
        if editing != nil || controller.edit != nil { positionEditor() }
        updateAccessibility()
        if moving.contains(where: { !(springs[$0]?.isSettled ?? true) || !(scales[$0]?.isSettled ?? true) }) {
            startTicking()
        } else {
            moving.removeAll()
        }
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
            move.toValue = NSValue(point: point)
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
    private func animatedFrame(_ id: NodeID) -> NodeFrame? {
        guard let n = controller.scene.nodes[id], let s = springs[id] else { return nil }
        let k = scales[id]?.value ?? 1
        return NodeFrame(
            center: s.value, size: CGSize(width: n.frame.size.width * k, height: n.frame.size.height * k),
            side: n.frame.side, depth: n.frame.depth)
    }

    private func applyFrames(all: Bool) {
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

    // MARK: Animation loop

    private func startTicking() {
        guard displayLink == nil, window != nil else {
            if window == nil { settleImmediately() }
            return
        }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = CACurrentMediaTime()
    }

    private func settleImmediately() {
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

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240), 1.0 / 30)
        lastTick = now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var settled = Set<NodeID>()
        for id in moving {
            springs[id]?.step(dt, spring: now < morphUntil ? Motion.morph : Motion.snap)
            scales[id]?.step(dt, spring: Motion.snap)
            if scales[id]?.isSettled == true { scales[id] = nil }
            if springs[id]?.isSettled ?? true, scales[id] == nil { settled.insert(id) }
        }
        applyFrames(all: false)
        elements.updateGeometry(
            selected: controller.selectedElement, connect: controller.connect,
            frame: { [weak self] in self?.animatedFrame($0)?.rect })
        decorRenderer.updateGeometry(frame: { [weak self] in self?.animatedFrame($0)?.rect })
        moving.subtract(settled)
        var cameraDone = true
        if let tween = cameraTween {
            let (c, done) = tween.value(at: now)
            setCamera(c, animated: false)
            if done { cameraTween = nil } else { cameraDone = false }
        }
        CATransaction.commit()
        if controller.edit != nil { positionEditor() }
        if moving.isEmpty && cameraDone {
            link.invalidate()
            displayLink = nil
        }
    }

    // MARK: Camera

    private var textScale: CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        return backing * max(1, (camera.zoom * 4).rounded(.up) / 4)
    }

    private func updateTextScale() {
        let s = textScale
        for l in nodeLayers.values { l.textScale = s }
    }

    func setCamera(_ c: Camera, animated: Bool) {
        if animated && !reduceMotion && window != nil {
            cameraTween = CameraTween(from: camera, to: c, start: CACurrentMediaTime(), duration: Motion.focus)
            startTicking()
            return
        }
        let zoomChanged = c.zoom != camera.zoom
        if zoomChanged { controller.zoom = Double(c.zoom) }
        camera = c
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.position = c.offset
        world.transform = CATransform3DMakeScale(c.zoom, c.zoom, 1)
        grid.camera = c
        grid.setNeedsDisplay()
        CATransaction.commit()
        if zoomChanged { updateTextScale() }
        if controller.edit != nil { positionEditor() }
    }

    public func centerScene() {
        let b = controller.scene.bounds
        guard !b.isNull, bounds.width > 0 else { return }
        let root = controller.scene.nodes[controller.canvas.root]?.frame.center ?? .zero
        let fits = b.width + 80 < bounds.width && b.height + 80 < bounds.height
        let focus = fits ? CGPoint(x: b.midX, y: b.midY) : root
        setCamera(Camera(offset: CGPoint(x: bounds.midX - focus.x, y: bounds.midY - focus.y), zoom: 1), animated: false)
    }

    /// Glides the camera just enough to show a node with a margin.
    func reveal(_ id: NodeID) {
        guard let n = controller.scene.nodes[id], bounds.width > 0 else { return }
        let target = cameraTween?.to ?? camera
        let r = target.toView(n.frame.rect).insetBy(dx: -48, dy: -48)
        let visible = bounds.insetBy(dx: 0, dy: 0)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if r.width > visible.width {
            dx = visible.midX - r.midX
        } else if r.minX < visible.minX {
            dx = visible.minX - r.minX
        } else if r.maxX > visible.maxX {
            dx = visible.maxX - r.maxX
        }
        if r.height > visible.height {
            dy = visible.midY - r.midY
        } else if r.minY < visible.minY {
            dy = visible.minY - r.minY
        } else if r.maxY > visible.maxY {
            dy = visible.maxY - r.maxY
        }
        guard dx != 0 || dy != 0 else { return }
        var c = target
        c.offset.x += dx
        c.offset.y += dy
        setCamera(c, animated: true)
    }

    func zoom(by factor: CGFloat, around viewPoint: CGPoint? = nil) {
        let p = viewPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let z = min(4, max(0.1, camera.zoom * factor))
        let w = camera.toWorld(p)
        setCamera(Camera(offset: CGPoint(x: p.x - w.x * z, y: p.y - w.y * z), zoom: z), animated: false)
    }

    /// The slide stage: the largest rect of `aspect` that fits under the title and above
    /// the slide strip.
    public func stageRect(aspect: Double) -> CGRect {
        let stripH: CGFloat = controller.present?.stageOnly == false ? 250 : 0
        let area = CGRect(x: 40, y: 150, width: bounds.width - 80, height: max(100, bounds.height - 190 - stripH))
        var w = area.width
        var h = w / aspect
        if h > area.height {
            h = area.height
            w = h * aspect
        }
        return CGRect(x: area.midX - w / 2, y: area.minY + (area.height - h) / 2, width: w, height: h)
    }

    /// Flies the camera so `ids` fill the view (or the slide stage at `aspect`).
    func frame(_ ids: [NodeID], aspect: Double?) {
        let rects = ids.compactMap { controller.scene.nodes[$0]?.frame.rect }
        guard bounds.width > 0, !rects.isEmpty else { return }
        var b = rects.reduce(CGRect.null) { $0.union($1) }
        for bd in controller.scene.boundaries where rects.contains(where: { bd.rect.intersects($0) }) {
            b = b.union(bd.rect)
        }
        let target = aspect.map { stageRect(aspect: $0) } ?? bounds.insetBy(dx: 60, dy: 60)
        let z = min(1.4, max(0.1, min(target.width / max(b.width, 1), target.height / max(b.height, 1))))
        let cam = Camera(
            offset: CGPoint(x: target.midX - b.midX * z, y: target.midY - b.midY * z), zoom: z)
        let cut = controller.present != nil && controller.canvas.presentation.transition == "cut"
        setCamera(cam, animated: !cut)
    }

    func fitToWindow() {
        let b = controller.scene.bounds
        guard !b.isNull, bounds.width > 0 else { return }
        let z = min(1, max(0.1, min((bounds.width - 80) / b.width, (bounds.height - 80) / b.height)))
        setCamera(
            Camera(offset: CGPoint(x: bounds.midX - b.midX * z, y: bounds.midY - b.midY * z), zoom: z), animated: true)
    }

    private func defaultFloatingPoint() -> CGPoint {
        let b = controller.scene.bounds
        let visible = camera.toWorld(CGPoint(x: bounds.midX, y: bounds.maxY - 120))
        guard !b.isNull else { return visible }
        return CGPoint(x: min(max(b.minX + 80, visible.x - 200), visible.x), y: min(b.maxY + 70, visible.y))
    }

    static let viewCommands: Set<CommandID> = [.zoomIn, .zoomOut, .actualSize, .fitToWindow]

    func performViewCommand(_ id: CommandID) -> Bool {
        switch id {
        case .zoomIn: zoom(by: 1.25)
        case .zoomOut: zoom(by: 0.8)
        case .actualSize:
            let w = camera.toWorld(CGPoint(x: bounds.midX, y: bounds.midY))
            setCamera(Camera(offset: CGPoint(x: bounds.midX - w.x, y: bounds.midY - w.y), zoom: 1), animated: true)
        case .fitToWindow: fitToWindow()
        default: return false
        }
        return true
    }

    // MARK: Assets

    func image(for asset: String) -> CGImage? {
        if let c = imageCache[asset] { return c }
        guard let data = controller.store.model.assets[asset], let img = NSImage(data: data),
            let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        imageCache[asset] = cg
        return cg
    }

    // MARK: Connect field

    /// "Connect to …" below the source: the query, up to five matches, or Create new node.
    private func anchored<V: View>(
        _ host: inout NSHostingView<V>?, _ make: () -> V, below rect: CGRect?, dx: CGFloat = 0
    ) {
        guard let rect else {
            host?.isHidden = true
            return
        }
        let h =
            host
            ?? {
                let h = NSHostingView(rootView: make())
                h.sizingOptions = [.intrinsicContentSize]
                addSubview(h)
                return h
            }()
        host = h
        let size = h.fittingSize
        let x = min(max(8, rect.minX + dx), max(8, bounds.width - size.width - 8))
        let y = min(rect.maxY + 12, max(8, bounds.height - size.height - 70))
        h.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        h.isHidden = size.width < 2
    }

    /// Ghost hints sit under the last ghost; the prompt bar and AI notice under their topic.
    func refreshAIOverlays() {
        var ghostRect: CGRect?
        if let g = controller.ghosts {
            let ids = g.ideas.indices.map { CanvasController.ghostID($0) }
            let rects = ids.compactMap { animatedFrame($0) }.map { camera.toView($0.rect) }
            ghostRect = rects.reduce(CGRect.null) { $0.union($1) }
            if ghostRect?.isNull ?? true { ghostRect = animatedFrame(g.anchor).map { camera.toView($0.rect) } }
        }
        anchored(&ghostHost, { GhostHintsView(controller: controller) }, below: ghostRect)
        // ⌃↩ beside the highlighted ghost.
        let highlighted = controller.ghosts.flatMap { g in
            g.ideas.isEmpty
                ? nil : animatedFrame(CanvasController.ghostID(g.highlighted)).map { camera.toView($0.rect) }
        }
        if let r = highlighted {
            let b =
                ghostBadge
                ?? {
                    let h = NSHostingView(rootView: GhostBadgeView(color: controller.aiColor))
                    h.sizingOptions = [.intrinsicContentSize]
                    addSubview(h)
                    return h
                }()
            ghostBadge = b
            let size = b.fittingSize
            // On the ghost's outer side, away from its edge.
            let anchor = controller.ghosts.flatMap { animatedFrame($0.anchor) }.map { camera.toView($0.rect) }
            let left = anchor.map { r.midX < $0.midX } ?? false
            let x = left ? r.minX - 14 - size.width : r.maxX + 14
            b.frame = CGRect(x: x, y: r.midY - size.height / 2, width: size.width, height: size.height)
            b.isHidden = false
        } else {
            ghostBadge?.isHidden = true
        }
        let promptRect = controller.promptBar.flatMap { animatedFrame($0.anchor) }.map { camera.toView($0.rect) }
        anchored(&promptHost, { PromptBarView(controller: controller) }, below: promptRect, dx: -120)
        let noticeRect =
            controller.aiNotice != nil
            ? animatedFrame(controller.selection.primary).map { camera.toView($0.rect) } : nil
        anchored(&noticeHost, { AINoticeView(controller: controller) }, below: noticeRect, dx: -20)
    }

    /// The slash menu and protocol suggestions sit under what they belong to.
    func refreshOverlays() {
        refreshAIOverlays()
        if let s = controller.slash {
            let host =
                slashHost
                ?? {
                    let h = NSHostingView(rootView: SlashMenuView(controller: controller))
                    h.sizingOptions = [.intrinsicContentSize]
                    addSubview(h)
                    slashHost = h
                    return h
                }()
            let anchor: CGRect? =
                s.inEditor && !editor.isHidden ? editor.frame : animatedFrame(s.node).map { camera.toView($0.rect) }
            if let r = anchor {
                let size = host.fittingSize
                host.frame = CGRect(x: r.minX, y: r.maxY + 8, width: size.width, height: size.height)
            }
            host.isHidden = false
        } else {
            slashHost?.isHidden = true
        }
        if controller.edit?.element != nil, !controller.protocolSuggestions.isEmpty {
            let host =
                suggestHost
                ?? {
                    let h = NSHostingView(rootView: ProtocolSuggestionsView(controller: controller))
                    h.sizingOptions = [.intrinsicContentSize]
                    addSubview(h)
                    suggestHost = h
                    return h
                }()
            let size = host.fittingSize
            host.frame = CGRect(
                x: editor.frame.minX - 8, y: editor.frame.maxY + 6, width: size.width, height: size.height)
            host.isHidden = false
        } else {
            suggestHost?.isHidden = true
        }
    }

    private func updateConnectField() {
        guard let c = controller.connect, let src = animatedFrame(c.source) else {
            connectField?.removeFromSuperview()
            connectField = nil
            return
        }
        let host: NSHostingView<ConnectFieldView>
        if let existing = connectField as? NSHostingView<ConnectFieldView> {
            host = existing
            host.rootView = ConnectFieldView(state: c, texts: controller.nodeTexts, theme: controller.theme)
        } else {
            host = NSHostingView(
                rootView: ConnectFieldView(state: c, texts: controller.nodeTexts, theme: controller.theme))
            host.sizingOptions = [.intrinsicContentSize]
            addSubview(host)
            connectField = host
        }
        let r = camera.toView(src.rect)
        let size = host.fittingSize
        host.frame = CGRect(x: r.midX - 40, y: r.maxY + 12, width: max(280, size.width), height: size.height)
    }

    // MARK: Editing

    private func editChanged(_ session: EditSession?) {
        // The outline edits its own rows (live-linked: the canvas still reflows).
        if controller.outlineFocused, session?.element == nil {
            if !editor.isHidden {
                editor.end()
                editor.isHidden = true
            }
            controller.onOutlineEditChange?(session)
            return
        }
        if let session, session.element != nil {
            let style = NodeTextStyle(typography: NodeTypography.for(.sub), monospaced: false)
            var st = style
            st.fontSize = 13
            st.lineHeight = 18
            st.weight = .semibold
            st.maxWidth = 400
            editor.begin(session, style: st, color: NSColor(cgColor: controller.theme.ink.cgColor) ?? .labelColor)
            editor.isHidden = false
            positionEditor()
            window?.makeFirstResponder(editor)
            return
        }
        guard let session, let n = controller.scene.nodes[session.node] else {
            if !editor.isHidden {
                editor.end()
                editor.isHidden = true
                if window?.firstResponder === editor { window?.makeFirstResponder(self) }
            }
            if controller.mode == .select, window?.firstResponder !== self { window?.makeFirstResponder(self) }
            return
        }
        editor.begin(session, style: n.textStyle, color: NSColor(cgColor: n.appearance.text.cgColor) ?? .labelColor)
        editor.isHidden = false
        positionEditor()
        window?.makeFirstResponder(editor)
        if let e = pendingTypingEvent {
            pendingTypingEvent = nil
            editor.keyDown(with: e)
        } else if let input = session.pendingInput {
            editor.insertText(input, replacementRange: editor.selectedRange())
        }
    }

    private func positionEditor() {
        if let session = controller.edit, let ref = session.element {
            guard let r = elements.editorRect(for: ref) else { return }
            let measured = NodeMeasurer.measure(
                editor.string,
                style: editor.style ?? NodeTextStyle(typography: NodeTypography.for(.sub), monospaced: false))
            var local = r
            local.size.width = max(r.width, measured.width + 8)
            local.origin.x = r.midX - local.width / 2
            if case .relationship = ref {} else { local.origin.x = r.minX }
            local.size.height = 18
            local.origin.y = r.midY - 9
            let frame = camera.toView(local)
            if editor.frame != frame { editor.frame = frame }
            if editor.bounds.size != local.size { editor.setBoundsSize(local.size) }
            editor.textContainer?.size = CGSize(width: local.width, height: .greatestFiniteMagnitude)
            return
        }
        guard let session = controller.edit, let n = controller.scene.nodes[session.node], let s = springs[session.node]
        else { return }
        // The editor sits at the node's final frame from the first frame: the caret is
        // live at 0 ms while the node's shape grows in behind it.
        let origin = CGPoint(
            x: n.frame.center.x - n.frame.size.width / 2, y: n.frame.center.y - n.frame.size.height / 2)
        _ = s
        let local = n.textRect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0)
        let frame = camera.toView(local)
        if editor.frame != frame { editor.frame = frame }
        let size = local.size
        if editor.bounds.size != size { editor.setBoundsSize(size) }
        editor.textContainer?.size = CGSize(width: size.width, height: .greatestFiniteMagnitude)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        cancelCheatSheet()
        guard let chord = KeyChord(event: event) else {
            super.keyDown(with: event)
            return
        }
        switch controller.handleKey(chord, characters: event.characters) {
        case .handled:
            refreshOverlays()
        case .beginTyping:
            pendingTypingEvent = event
            controller.beginEditing(replacingWith: "")
        case .ignored:
            super.keyDown(with: event)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            cheatTimer?.invalidate()
            cheatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.controller.cheatSheetVisible = true
                    self?.onCheatSheet?(true)
                }
            }
        } else {
            cancelCheatSheet()
        }
        super.flagsChanged(with: event)
    }

    private func cancelCheatSheet() {
        cheatTimer?.invalidate()
        cheatTimer = nil
        if controller.cheatSheetVisible {
            controller.cheatSheetVisible = false
            onCheatSheet?(false)
        }
    }

    // MARK: Menus

    /// Runs the command here if the canvas handles it; otherwise passes it up the
    /// responder chain (window-level commands such as New Canvas or Export).
    public func performRegistryCommand(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        if controller.perform(CommandID(rawValue: raw)) { return }
        nextHandler()?.performRegistryCommand(sender)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performRegistryCommand(_:)), let raw = item.representedObject as? String {
            if controller.canPerform(CommandID(rawValue: raw)) { return true }
            return (nextHandler() as? any NSMenuItemValidation)?.validateMenuItem(item) ?? false
        }
        return true
    }

    private func nextHandler() -> (any RegistryCommandTarget)? {
        var r = nextResponder
        while let cur = r {
            if let t = cur as? any RegistryCommandTarget { return t }
            r = cur.nextResponder
        }
        return nil
    }

    // MARK: Mouse and trackpad

    public func node(at viewPoint: CGPoint) -> NodeID? {
        let p = camera.toWorld(viewPoint)
        for id in controller.scene.order.reversed() {
            if let f = animatedFrame(id), f.rect.contains(p) { return id }
        }
        return nil
    }

    private enum DropTarget: Equatable {
        case child(NodeID)
        case before(NodeID)
        case after(NodeID)
    }

    private enum Drag {
        case pan(start: CGPoint, offset: CGPoint)
        case rubber(start: CGPoint, extend: Bool)
        case node(
            id: NodeID, start: CGPoint, subtree: [NodeID], origins: [NodeID: CGPoint], floating: Bool,
            active: Bool, target: DropTarget?)
        case zone(id: String, start: CGPoint, members: [NodeID], origins: [NodeID: CGPoint], active: Bool)
    }

    private var drag: Drag?

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let w = camera.toWorld(p)
        window?.makeFirstResponder(self)
        if controller.mode == .connect { controller.cancelConnect() }
        // Clicking a ghost accepts it (one undo), like ⌃↩.
        if let id = node(at: p), let i = CanvasController.ghostIndex(id) {
            if controller.ghosts != nil { controller.acceptGhost(i) } else { controller.previewPlan(nil) }
            return
        }
        if let id = node(at: p), let n = controller.scene.nodes[id], let f = animatedFrame(id) {
            let local = CGPoint(x: w.x - f.rect.minX, y: w.y - f.rect.minY)
            if event.clickCount == 1, handleDecorationClick(id, n, local) { return }
            if event.clickCount == 2 {
                controller.beginEditing(id)
                return
            }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
                controller.select(id, extend: true)
            } else if !controller.selection.contains(id) || controller.selectedElement != nil {
                controller.select(id)
            }
            let floating = controller.canvas.floating.contains(id)
            let sub = controller.canvas.subtree(id, includeFolded: false)
            var origins: [NodeID: CGPoint] = [:]
            for d in sub { origins[d] = springs[d]?.value }
            drag = .node(
                id: id, start: w, subtree: sub, origins: origins, floating: floating, active: false, target: nil)
            return
        }
        if let el = elements.hitTest(w) {
            if event.clickCount == 2 {
                controller.selectElement(el)
                controller.beginEditingElement(el)
                return
            }
            controller.selectElement(el)
            if case .zone(let zid) = el, let z = controller.canvas.zones.first(where: { $0.id == zid }) {
                if w.y - (controller.scene.zones.first { $0.zone.id == zid }?.rect.minY ?? 0) < 30,
                    w.x - (controller.scene.zones.first { $0.zone.id == zid }?.rect.minX ?? 0) < 30
                {
                    controller.updateZone(zid) { $0.collapsed.toggle() }
                    return
                }
                var members: [NodeID] = []
                for m in z.members { members += controller.canvas.subtree(m) }
                var origins: [NodeID: CGPoint] = [:]
                for d in members { origins[d] = springs[d]?.value }
                drag = .zone(id: zid, start: w, members: members, origins: origins, active: false)
            }
            return
        }
        if event.clickCount == 2 {
            controller.addFloating(at: w)
            return
        }
        if controller.selectedElement != nil { controller.selectElement(nil) }
        if event.modifierFlags.contains(.option) {
            drag = .pan(start: p, offset: camera.offset)
        } else {
            drag = .rubber(start: w, extend: event.modifierFlags.contains(.shift))
        }
    }

    /// Clicks on a topic's indicators, progress ring or to-do box.
    private func handleDecorationClick(_ id: NodeID, _ n: SceneNode, _ local: CGPoint) -> Bool {
        for (i, r) in n.indicatorRects.enumerated() where r.insetBy(dx: -2, dy: -2).contains(local) {
            switch n.indicators[i] {
            case .note: controller.onRequest?(.note(id))
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

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let w = camera.toWorld(p)
        switch drag {
        case .pan(let start, let offset)?:
            var c = camera
            c.offset = CGPoint(x: offset.x + p.x - start.x, y: offset.y + p.y - start.y)
            cameraTween = nil
            setCamera(c, animated: false)
        case .rubber(let start, _)?:
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
                let snap: CGFloat = 6 / camera.zoom
                for (nid, n) in controller.scene.nodes where !excluded.contains(nid) {
                    let c = n.frame.center
                    if abs(c.x - moved.x) < snap {
                        offset.width += c.x - moved.x
                        guideLines.append(
                            (CGPoint(x: c.x, y: min(c.y, moved.y) - 40), CGPoint(x: c.x, y: max(c.y, moved.y) + 40)))
                        let gap = abs(c.y - moved.y) - (n.frame.size.height + f.size.height) / 2
                        if gap > 0 {
                            guideLabel = ("\(Int(gap.rounded())) pt", CGPoint(x: c.x + 24, y: (c.y + moved.y) / 2))
                        }
                    }
                    if abs(c.y - moved.y) < snap {
                        offset.height += c.y - moved.y
                        guideLines.append(
                            (CGPoint(x: min(c.x, moved.x) - 40, y: c.y), CGPoint(x: max(c.x, moved.x) + 40, y: c.y)))
                        guideLabel = guideLabel ?? ("aligned centre", CGPoint(x: (c.x + moved.x) / 2, y: c.y - 12))
                    }
                }
                if controller.canvas.layout.flexibleFloating, let t = treeNode(at: w, excluding: excluded) {
                    target = .child(t)
                }
            } else if !event.modifierFlags.contains(.shift), let t = treeNode(at: w, excluding: excluded),
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
                springs[d] = SpringValue(moved)
                nodeLayers[d]?.zPosition = 10
                if d == id {
                    nodeLayers[d]?.shadowOpacity = 1
                    nodeLayers[d]?.shadowColor = RGBA.black.alpha(0.18).cgColor
                    nodeLayers[d]?.shadowRadius = 12
                    nodeLayers[d]?.shadowOffset = CGSize(width: 0, height: 6)
                }
            }
            applyFrames(all: false)
            for d in sub { moving.insert(d) }
            applyFrames(all: true)
            showDrop(target, floatingLabel: floating)
            elements.showGuides(guideLines, label: guideLabel?.0, at: guideLabel?.1)
            elements.updateGeometry(
                selected: controller.selectedElement, connect: nil,
                frame: { [weak self] in self?.animatedFrame($0)?.rect })
            decorRenderer.updateGeometry(frame: { [weak self] in self?.animatedFrame($0)?.rect })
            CATransaction.commit()
            moving.removeAll()
            drag = .node(
                id: id, start: start, subtree: sub, origins: origins, floating: floating, active: active, target: target
            )
        case .zone(let zid, let start, let members, let origins, var active)?:
            let dx = w.x - start.x
            let dy = w.y - start.y
            if !active && hypot(dx, dy) * camera.zoom < 4 { return }
            active = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for d in members {
                guard let o = origins[d] else { continue }
                springs[d] = SpringValue(CGPoint(x: o.x + dx, y: o.y + dy))
            }
            applyFrames(all: true)
            elements.zonesLayer.sublayers?.forEach { _ in }
            CATransaction.commit()
            drag = .zone(id: zid, start: start, members: members, origins: origins, active: active)
            zoneDragOffset = CGSize(width: dx, height: dy)
            elements.offsetZone(zid, by: zoneDragOffset)
        case nil:
            break
        }
    }

    private var zoneDragOffset = CGSize.zero

    private func treeNode(at w: CGPoint, excluding: Set<NodeID>) -> NodeID? {
        for id in controller.scene.order.reversed() where !excluding.contains(id) {
            if let f = controller.scene.nodes[id]?.frame, f.rect.insetBy(dx: -6, dy: -6).contains(w) { return id }
        }
        return nil
    }

    /// Drop targets (S3): a glowing line for before / after, a halo for "as child".
    private func showDrop(_ t: DropTarget?, floatingLabel: Bool) {
        guard let t else {
            dropIndicator.isHidden = true
            dropHint?.removeFromSuperview()
            dropHint = nil
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
                showDropHint("Drop to attach under \(text)", below: r)
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

    private var dropHint: NSView?

    private func showDropHint(_ text: String, below r: CGRect) {
        dropHint?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor(cgColor: controller.theme.ring.cgColor)
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.sizeToFit()
        let v = camera.toView(r)
        label.frame.origin = CGPoint(x: v.maxX + 6, y: v.maxY + 4)
        label.frame.size.width += 10
        addSubview(label)
        dropHint = label
    }

    public override func mouseUp(with event: NSEvent) {
        let w = camera.toWorld(convert(event.locationInWindow, from: nil))
        defer {
            drag = nil
            rubberBand.isHidden = true
            dropIndicator.isHidden = true
            dropHint?.removeFromSuperview()
            dropHint = nil
            elements.showGuides([], label: nil, at: nil)
            for l in nodeLayers.values where l.zPosition != 0 {
                l.zPosition = 0
                l.shadowOpacity = l.node.map { $0.appearance.shadow == nil ? 0 : 1 } ?? 0
            }
        }
        switch drag {
        case .rubber(let start, let extend)?:
            let r = CGRect(
                x: min(start.x, w.x), y: min(start.y, w.y), width: abs(w.x - start.x), height: abs(w.y - start.y))
            guard r.width > 3 || r.height > 3 else { return }
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
                } else if let pos = controller.canvas.nodes[id]?.position, let s = springs[id] {
                    _ = pos
                    controller.moveFloating(id, to: s.value)
                } else {
                    controller.moveFloating(id, to: CGPoint(x: dx, y: dy))
                }
            } else if event.modifierFlags.contains(.shift) {
                controller.detachTopic(id, at: springs[id]?.value ?? w)
            } else if let target {
                let dup = event.modifierFlags.contains(.option)
                switch target {
                case .child(let t): controller.moveTopic(id, toParent: t, at: nil, duplicate: dup)
                case .before(let t), .after(let t):
                    guard let p = controller.canvas.parent(of: t),
                        let i = controller.canvas.nodes[p]?.children.firstIndex(of: t)
                    else { break }
                    let isAfter: Bool = { if case .after = target { return true } else { return false } }()
                    controller.moveTopic(id, toParent: p, at: isAfter ? i + 1 : i, duplicate: dup)
                }
            } else {
                // Dropped on empty canvas: settle back.
                update(animated: true)
            }
        case .zone(let zid, _, _, _, let active)?:
            guard active else { return }
            elements.offsetZone(zid, by: .zero)
            controller.moveZone(zid, by: zoneDragOffset)
        default:
            break
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        cameraTween = nil
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            zoom(by: 1 + delta, around: convert(event.locationInWindow, from: nil))
            return
        }
        var c = camera
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        c.offset.x += event.scrollingDeltaX * k
        c.offset.y += event.scrollingDeltaY * k
        setCamera(c, animated: false)
    }

    public override func magnify(with event: NSEvent) {
        cameraTween = nil
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    // MARK: Accessibility (expanded in M10)

    private func updateAccessibility() {
        let c = controller.canvas
        guard let n = c.nodes[controller.selection.primary] else { return }
        let depth = c.depth(of: controller.selection.primary)
        let kids = n.children.count
        var label = "\(n.text.isEmpty ? "Topic" : n.text), level \(depth + 1), \(kids) children"
        if n.folded { label += ", collapsed" }
        setAccessibilityValue(label)
    }
}

/// A flipped layer-hosting view: AppKit keeps the hosted layer's geometry in step with
/// the view, so world coordinates run top-down like the model.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Dot or line grid in world space, drawn for the visible rect only.
final class GridLayer: CALayer {
    var pattern: Theme.Grid = Theme.classic.grid
    var camera = Camera()

    override func draw(in ctx: CGContext) {
        let spacing: CGFloat
        let color: RGBA
        let lines: Bool
        switch pattern {
        case .none: return
        case .dots(let c, let s):
            (color, spacing, lines) = (c, s, false)
        case .lines(let c, let s):
            (color, spacing, lines) = (c, s, true)
        }
        let step = spacing * camera.zoom
        guard step >= 8 else { return }
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        let startX = camera.offset.x.truncatingRemainder(dividingBy: step) - step
        let startY = camera.offset.y.truncatingRemainder(dividingBy: step) - step
        if lines {
            ctx.setLineWidth(1)
            var x = startX
            while x < bounds.maxX + step {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
                x += step
            }
            var y = startY
            while y < bounds.maxY + step {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += step
            }
            ctx.strokePath()
        } else {
            let r = max(0.8, min(1.3, camera.zoom))
            var y = startY
            while y < bounds.maxY + step {
                var x = startX
                while x < bounds.maxX + step {
                    ctx.addEllipse(in: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r))
                    x += step
                }
                y += step
            }
            ctx.fillPath()
        }
    }
}
