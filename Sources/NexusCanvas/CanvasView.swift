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
    /// Offscreen export: no selection ring, no grid.
    public var exportMode = false {
        didSet {
            grid.suppressed = exportMode
            grid.isHidden = exportMode
        }
    }

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
    private var mapShotView: MapShotFrameView?
    /// Set by the host (bottom-right of the canvas).
    weak var minimap: MinimapView?
    private var coachHost: NSHostingView<TourCoachView>?
    private var toolbarHost: NSHostingView<FloatingToolbarView>?
    private var addChildHost: NSHostingView<AddTopicButton>?
    private var addSiblingHost: NSHostingView<AddTopicButton>?
    /// The topic the floating toolbar shows for (after the pointer rests, or a second click).
    var toolbarFor: NodeID?
    private var restTimer: Timer?
    private var aidsTracking: NSTrackingArea?
    private var hintsHost: NSHostingView<EmptyCanvasHints>?
    private var morphUntil: CFTimeInterval = 0
    private var lastMorphSerial = 0
    private var imageCache: [String: CGImage] = [:]
    private var popovers: CanvasPopovers?

    /// A topic's rect in view coordinates (popover anchors).
    func viewRect(of id: NodeID) -> CGRect? {
        animatedFrame(id).map { camera.toView($0.rect) }
    }

    // MARK: Drop files on topics (attachments, images) or on empty canvas (image to map)

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }
        guard let id = node(at: p) else {
            // A picture dropped on empty canvas becomes a map (M12).
            let images = urls.filter { ImageToMap.isImage(name: $0.lastPathComponent) }
            for url in images {
                if let data = try? Data(contentsOf: url) { controller.importImage(data, name: url.lastPathComponent) }
            }
            return !images.isEmpty
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                controller.canvas.nodes[id]?.image == nil
            {
                controller.setImage(data, ext: url.pathExtension, size: NSImage(data: data)?.size, on: id, source: url)
            } else {
                controller.addAttachment(data, name: url.lastPathComponent, on: id)
            }
        }
        return true
    }
    private var pendingTypingEvent: NSEvent?
    private var cheatTimer: Timer?
    private var rightPan: (start: CGPoint, offset: CGPoint, moved: Bool)?
    // Hyper key (Settings › Shortcuts): Right Option held, or Caps Lock / sticky taps.
    var hyperHeld = false
    var hyperSticky = false
    private var hyperUsed = false
    private var hyperTapTimer: Timer?
    /// The minimap shows while the camera moves (Settings › Appearance › Minimap).
    public var onCameraMoved: (() -> Void)?

    func noteCameraMoved() { onCameraMoved?() }

    /// Forces Reduce Motion (Settings › Accessibility override, and tests).
    public var reduceMotionOverride: Bool?
    var reduceMotion: Bool {
        reduceMotionOverride ?? controller.reduceMotionPreference
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        world.addSublayer(legendLayer)
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
        setAccessibilityLabel(Loc.t("Canvas"))
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
        // Code files open in the editor chosen in Settings › Integrations (M9).
        controller.onOpenURL = { [weak controller] url in CodeLinks.open(url, prefs: controller?.prefs ?? .shared) }
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
        grid.place(in: bounds, force: true)
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
        let animate = animated && !reduceMotion && window != nil && controller.animateReflow
        NodeLayer.ringWidth = controller.ringWidth
        elements.glowTrail = controller.prefs.bool("appearance.glowTrail")
        elements.flowDots = controller.prefs.bool("appearance.flowDots") && !reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if lastBackground.map({ $0.0 != scene.canvasColor || $0.1 != scene.grid }) ?? true {
            rootLayer.backgroundColor = scene.canvasColor.cgColor
            grid.pattern = scene.grid
            grid.place(in: bounds, force: true)
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
                selected: selected.contains(id) && controller.present == nil && !exportMode,
                primary: controller.selection.primary == id, editing: editing == id, morph: morph,
                image: n.image.flatMap { image(for: $0.asset) },
                sticker: n.sticker.flatMap { $0.hasPrefix("emoji:") ? nil : image(for: $0) })
            layer.connectState(
                controller.connect.map { c in
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
        elements.editingElement = controller.edit?.element
        elements.update(
            scene: scene, selected: controller.selectedElement, connect: controller.connect,
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
        legendLayer.selected = controller.legendActive
        CATransaction.commit()
        cull()
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
            cull()
        }
    }

    // MARK: Camera

    private var textScale: CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        return backing * max(1, (camera.zoom * 4).rounded(.up) / 4)
    }

    private func updateTextScale() { cull() }

    /// Viewport culling (M10): topics outside the view (plus a margin of a quarter view
    /// each side) are hidden, so the compositor skips them and zooming doesn't
    /// re-rasterise their text; a topic catches up on its text scale when it comes back
    /// into view. Views without a window (offscreen export) draw everything.
    func cull() {
        let s = textScale
        guard window != nil, bounds.width > 0, cullingEnabled else {
            for l in nodeLayers.values {
                if l.isHidden { l.isHidden = false }
                l.textScale = s
            }
            return
        }
        let size = CGSize(width: bounds.width / camera.zoom, height: bounds.height / camera.zoom)
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

    /// Off only for tests and tools that need every layer live.
    var cullingEnabled = true
    /// How many topic layers the last cull left on screen.
    private(set) var visibleNodeLayers = 0

    func setCamera(_ c: Camera, animated: Bool, via: Camera? = nil) {
        if animated && !reduceMotion && window != nil {
            cameraTween = CameraTween(
                from: camera, to: c, start: CACurrentMediaTime(), duration: Motion.focus * (via == nil ? 1 : 2.5),
                via: via)
            startTicking()
            return
        }
        let zoomChanged = c.zoom != camera.zoom
        if zoomChanged { controller.zoom = Double(c.zoom) }
        camera = c
        minimap?.refresh(panning: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.position = c.offset
        world.transform = CATransform3DMakeScale(c.zoom, c.zoom, 1)
        // Depth parallax when zoomed out: the grid drifts a little slower than the map.
        if controller.prefs.bool("appearance.parallax"), c.zoom < 0.6, !reduceMotion {
            grid.camera = Camera(offset: CGPoint(x: c.offset.x * 0.85, y: c.offset.y * 0.85), zoom: c.zoom)
        } else {
            grid.camera = c
        }
        grid.place(in: bounds)
        CATransaction.commit()
        cull()
        // Overlays pinned to a topic (Add Topic +, the floating toolbar) follow the camera.
        positionMouseAids()
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
        let transition = controller.present == nil ? "glide" : controller.canvas.presentation.transition
        // Zoom pulls out to show both slides, then pushes in; Glide flies straight; Cut jumps.
        let via = transition == "zoom" ? CameraTween.overview(from: camera, to: cam, in: bounds) : nil
        setCamera(cam, animated: transition != "cut", via: via)
    }

    /// Zooms to `z` around the view's centre (Settings › Editing › Default zoom).
    public func setZoom(_ z: CGFloat) {
        zoom(by: z / max(camera.zoom, 0.01))
    }

    public func fitToWindow() {
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
        refreshMouseAids()
        // The tour's keycap coach floats 16 pt beside the selection, never over the editor.
        let sel =
            controller.tour != nil ? animatedFrame(controller.selection.primary).map { camera.toView($0.rect) } : nil
        if let r = sel {
            let h =
                coachHost
                ?? {
                    let h = NSHostingView(rootView: TourCoachView(controller: controller))
                    h.sizingOptions = [.intrinsicContentSize]
                    addSubview(h)
                    return h
                }()
            coachHost = h
            let size = h.fittingSize
            let x = r.maxX + 16 + size.width < bounds.width - 8 ? r.maxX + 16 : max(8, r.minX - 16 - size.width)
            h.frame = CGRect(x: x, y: r.midY - size.height / 2, width: size.width, height: size.height)
            h.isHidden = size.width < 2
        } else {
            coachHost?.isHidden = true
        }
        // Empty-canvas hints sit under the central topic.
        let root =
            controller.showsEmptyHints ? animatedFrame(controller.canvas.root).map { camera.toView($0.rect) } : nil
        if let r = root {
            let h =
                hintsHost
                ?? {
                    let h = NSHostingView(rootView: EmptyCanvasHints(controller: controller))
                    h.sizingOptions = [.intrinsicContentSize]
                    addSubview(h)
                    return h
                }()
            hintsHost = h
            let size = h.fittingSize
            h.frame = CGRect(x: r.midX - size.width / 2, y: r.maxY + 28, width: size.width, height: size.height)
            h.isHidden = false
        } else {
            hintsHost?.isHidden = true
        }
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
        if let s = controller.mapShot {
            let v =
                mapShotView
                ?? {
                    let v = MapShotFrameView()
                    v.canvas = self
                    addSubview(v)
                    return v
                }()
            mapShotView = v
            v.frame = bounds
            v.state = s
            v.needsDisplay = true
            window?.invalidateCursorRects(for: v)
        } else if mapShotView != nil {
            mapShotView?.removeFromSuperview()
            mapShotView = nil
        }
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
        guard let c = controller.connect,
            let src = c.source.topic.flatMap({ animatedFrame($0)?.rect }) ?? controller.scene.rect(of: c.source)
        else {
            connectField?.removeFromSuperview()
            connectField = nil
            return
        }
        let host: NSHostingView<ConnectFieldView>
        if let existing = connectField as? NSHostingView<ConnectFieldView> {
            host = existing
            host.rootView = ConnectFieldView(state: c, texts: controller.connectTexts, theme: controller.theme)
        } else {
            host = NSHostingView(
                rootView: ConnectFieldView(state: c, texts: controller.connectTexts, theme: controller.theme))
            host.sizingOptions = [.intrinsicContentSize]
            addSubview(host)
            connectField = host
        }
        let r = camera.toView(src)
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
        // Settings › General › Writing (smart quotes stay off inside code).
        let prefs = controller.prefs
        let code = controller.canvas.nodes[session.node]?.textFormat == "code"
        editor.isContinuousSpellCheckingEnabled = prefs.bool("general.spelling") && !code
        editor.isAutomaticSpellingCorrectionEnabled = prefs.bool("general.autocorrect") && !code
        editor.isAutomaticQuoteSubstitutionEnabled = prefs.bool("general.smartQuotes") && !code
        editor.isAutomaticDashSubstitutionEnabled = prefs.bool("general.smartQuotes") && !code
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
        toolbarFor = nil
        if hyperHeld || hyperSticky, let chord = KeyChord(event: event) {
            hyperUsed = true
            hyperSticky = false
            hyperTapTimer?.invalidate()
            _ = controller.handleKey(KeyChord(.hyper, chord.key), characters: nil)
            refreshOverlays()
            return
        }
        guard let chord = KeyChord(event: event) else {
            super.keyDown(with: event)
            return
        }
        switch controller.handleKey(chord, characters: event.characters) {
        case .handled:
            refreshOverlays()
        case .beginTyping:
            pendingTypingEvent = event
            if controller.typingAppends {
                controller.beginEditing()
            } else {
                controller.beginEditing(replacingWith: "")
            }
        case .ignored:
            super.keyDown(with: event)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        if handleHyperFlags(event) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            cheatTimer?.invalidate()
            cheatTimer = Timer.scheduledTimer(withTimeInterval: controller.cheatSheetDelay, repeats: false) {
                [weak self] _ in
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
        let id = CommandID(rawValue: raw)
        // A menu item chosen with the mouse counts towards a key tip (Settings › General).
        if let t = NSApp.currentEvent?.type, [.leftMouseUp, .leftMouseDown, .rightMouseUp, .otherMouseUp].contains(t) {
            controller.noteMouseUse(id)
        }
        if controller.perform(id) { return }
        nextHandler()?.performRegistryCommand(sender)
    }

    // MARK: Effects (Settings › Appearance › Motion & effects, Accessibility)

    /// Branches whose to-dos are all checked (a new one sparkles once).
    private var completed: Set<NodeID>?

    func applyEffects() {
        let scene = controller.scene
        let prefs = controller.prefs
        // Done sparkle.
        let now = Set(
            scene.nodes.compactMap { id, n in n.progress.map { $0.total > 0 && $0.done == $0.total } == true ? id : nil
            })
        if let before = completed, prefs.bool("appearance.sparkle"), !reduceMotion, !exportMode {
            for id in now.subtracting(before) { sparkle(at: id) }
        }
        completed = now
        // Ghost shimmer (paused by the setting or Reduce Motion).
        let shimmer = !prefs.bool("accessibility.pauseShimmer") && !reduceMotion
        for (id, l) in nodeLayers where CanvasController.ghostIndex(id) != nil {
            if shimmer, l.animation(forKey: "shimmer") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0.55
                a.duration = 1.1
                a.autoreverses = true
                a.repeatCount = .infinity
                l.add(a, forKey: "shimmer")
            } else if !shimmer {
                l.removeAnimation(forKey: "shimmer")
            }
        }
    }

    func sparkle(at id: NodeID) {
        guard let f = animatedFrame(id) else { return }
        let center = CGPoint(x: f.rect.maxX - 6, y: f.rect.minY + 6)
        for i in 0..<8 {
            let star = CATextLayer()
            star.string = "✦"
            star.fontSize = 11
            star.foregroundColor = controller.theme.ai.cgColor
            star.alignmentMode = .center
            star.contentsScale = window?.backingScaleFactor ?? 2
            star.frame = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
            world.addSublayer(star)
            let angle = CGFloat(i) / 8 * 2 * .pi
            let move = CABasicAnimation(keyPath: "position")
            move.toValue = CGPoint(x: center.x + cos(angle) * 26, y: center.y + sin(angle) * 26)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [move, fade]
            g.duration = 0.7
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.isRemovedOnCompletion = false
            g.fillMode = .forwards
            star.add(g, forKey: "burst")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { star.removeFromSuperlayer() }
        }
    }

    // MARK: Hyper key

    /// Right Option acts as ⌃⌥⇧⌘ while held (no permission needed). Caps Lock can only be
    /// seen as a tap, so a tap arms Hyper for the next key. A tap with no key sends Esc
    /// (Settings › Tap Hyper alone); Sticky Hyper keeps Right Option armed after release.
    func handleHyperFlags(_ e: NSEvent) -> Bool {
        let prefs = controller.prefs
        guard prefs.bool("shortcuts.hyper") else { return false }
        let source = prefs.string("shortcuts.hyperKey")
        if source == "rightOption", e.keyCode == 61 {
            let down = e.modifierFlags.contains(.option)
            if down {
                hyperHeld = true
                hyperUsed = false
            } else {
                hyperHeld = false
                if !hyperUsed {
                    if prefs.bool("accessibility.stickyHyper") {
                        armSticky()
                    } else if prefs.string("shortcuts.hyperTap") == "esc" {
                        sendEscape()
                    }
                }
            }
            return true
        }
        if source == "capsLock", e.keyCode == 57 {
            armSticky()
            return true
        }
        return false
    }

    func armSticky() {
        hyperSticky = true
        hyperUsed = false
        hyperTapTimer?.invalidate()
        hyperTapTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hyperSticky else { return }
                self.hyperSticky = false
                if self.controller.prefs.string("shortcuts.hyperTap") == "esc" { self.sendEscape() }
            }
        }
    }

    func sendEscape() {
        _ = controller.handleKey(KeyChord([], .escape), characters: "\u{1B}")
        refreshOverlays()
    }

    // MARK: Mouse aids (Settings › Editing › Mouse & trackpad)

    func anchoredView<V: View>(_ host: inout NSHostingView<V>?, _ make: () -> V, at place: (CGSize) -> CGPoint?) {
        guard let origin = place(host?.fittingSize ?? .zero) else {
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
        let o = place(size) ?? origin
        h.frame = CGRect(origin: o, size: size)
        h.isHidden = false
    }

    func refreshMouseAids() {
        minimap?.refresh(panning: false)
        applyEffects()
        positionMouseAids()
    }

    /// Places the Add Topic + buttons and the floating toolbar beside the selection (also
    /// on every camera move, so they stay with their topic).
    func positionMouseAids() {
        let c = controller
        let showAids =
            c.mode == .select && c.selection.nodes.count == 1 && c.edit == nil && c.present == nil && c.mapShot == nil
            && c.selectedElement == nil && c.slash == nil && !exportMode
        let r = showAids ? animatedFrame(c.selection.primary).map { camera.toView($0.rect) } : nil
        let plus =
            r != nil && c.prefs.bool("editing.addButtons") && CanvasController.ghostIndex(c.selection.primary) == nil
        anchoredView(&addChildHost, { AddTopicButton(controller: c, child: true) }) { _ in
            plus ? CGPoint(x: r!.maxX + 8, y: r!.midY - 10) : nil
        }
        anchoredView(&addSiblingHost, { AddTopicButton(controller: c, child: false) }) { _ in
            plus && c.selection.primary != c.canvas.root ? CGPoint(x: r!.midX - 10, y: r!.maxY + 8) : nil
        }
        let bar = r != nil && toolbarFor == c.selection.primary && c.prefs.string("editing.floatingToolbar") != "never"
        anchoredView(&toolbarHost, { FloatingToolbarView(controller: c) }) { size in
            bar ? CGPoint(x: max(8, r!.minX), y: max(8, r!.minY - size.height - 10)) : nil
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = aidsTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        aidsTracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard controller.prefs.string("editing.floatingToolbar") == "rest", controller.mode == .select else { return }
        let p = convert(event.locationInWindow, from: nil)
        let over = node(at: p)
        restTimer?.invalidate()
        guard let over, over == controller.selection.primary, controller.selection.nodes.count == 1 else { return }
        restTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toolbarFor = over
                self?.refreshMouseAids()
            }
        }
    }

    // Edit › Cut, Copy, Paste on topics (the text editor handles them while editing).
    @objc public func copy(_ sender: Any?) { controller.copySelection() }
    @objc public func cut(_ sender: Any?) {
        controller.cutSelection()
        refreshOverlays()
    }
    @objc public func paste(_ sender: Any?) {
        controller.paste()
        refreshOverlays()
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)) {
            return controller.mode == .select
                && !(item.action == #selector(cut(_:)) && controller.selection.nodes == [controller.canvas.root])
        }
        if item.action == #selector(paste(_:)) { return controller.mode == .select }
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
        /// The legend (M14), moved by its top-left corner.
        case legend(start: CGPoint, origin: CGPoint, active: Bool)
    }

    /// The legend box, above the topics (M14).
    let legendLayer = LegendLayer()

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
        // The legend sits above the topics: drag to move it, double-click to edit it.
        if let l = controller.scene.legend, l.rect.contains(w), controller.mode != .edit {
            if event.clickCount == 2 {
                controller.editLegend()
            } else {
                controller.selectLegend()
                drag = .legend(start: w, origin: l.rect.origin, active: false)
            }
            return
        }
        controller.deselectLegend()
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
                toolbarFor = nil
            } else if controller.prefs.string("editing.floatingToolbar") == "click",
                controller.selection.nodes.count == 1
            {
                // Click again on the selected topic: the floating toolbar.
                toolbarFor = id
                refreshMouseAids()
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
            switch controller.doubleClickAction {
            case "fit": fitToWindow()
            case "nothing": break
            default: controller.addFloating(at: w)
            }
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
                if !event.modifierFlags.contains(.shift), let t = treeNode(at: w, excluding: excluded),
                    let tf = controller.scene.nodes[t]?.frame
                {
                    let rel = (w.y - tf.rect.minY) / max(tf.size.height, 1)
                    let hasParent = controller.canvas.parent(of: t) != nil
                    target = hasParent && rel < 0.28 ? .before(t) : hasParent && rel > 0.72 ? .after(t) : .child(t)
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
            elements.updateGeometry(
                selected: controller.selectedElement, connect: nil,
                frame: { [weak self] in self?.animatedFrame($0)?.rect })
        case .legend(let start, let origin, var active)?:
            let dx = w.x - start.x
            let dy = w.y - start.y
            if !active && hypot(dx, dy) * camera.zoom < 4 { return }
            active = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            legendLayer.frame.origin = CGPoint(x: origin.x + dx, y: origin.y + dy)
            CATransaction.commit()
            drag = .legend(start: start, origin: origin, active: active)
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
                showDropHint(Loc.f("Drop to attach under %@", text), below: r)
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
            } else if controller.dragToFloat, hypot(dx, dy) > 80 {
                // Dragged well off its branch onto empty canvas: it floats there.
                controller.detachTopic(id, at: springs[id]?.value ?? w)
            } else {
                // Dropped on empty canvas: settle back.
                update(animated: true)
            }
        case .zone(let zid, _, _, _, let active)?:
            guard active else { return }
            elements.offsetZone(zid, by: .zero)
            controller.moveZone(zid, by: zoneDragOffset)
        case .legend(let start, let origin, let active)?:
            guard active else { return }
            controller.moveLegend(to: CanvasPoint(x: origin.x + w.x - start.x, y: origin.y + w.y - start.y))
        default:
            break
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard controller.rightDragPans else { return super.rightMouseDown(with: event) }
        rightPan = (convert(event.locationInWindow, from: nil), camera.offset, false)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard let (start, offset, moved) = rightPan else { return super.rightMouseDragged(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        rightPan = (start, offset, moved || hypot(p.x - start.x, p.y - start.y) > 3)
        var c = camera
        c.offset = CGPoint(x: offset.x + p.x - start.x, y: offset.y + p.y - start.y)
        setCamera(c, animated: false)
        noteCameraMoved()
    }

    public override func rightMouseUp(with event: NSEvent) {
        let moved = rightPan?.moved ?? false
        rightPan = nil
        // A right-click without a drag still opens the context menu.
        if !moved, let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    /// A zone's context menu: Export Zone… and Print Zone… (D155). Elsewhere the canvas has
    /// no context menu yet.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let w = camera.toWorld(convert(event.locationInWindow, from: nil))
        guard node(at: convert(event.locationInWindow, from: nil)) == nil, case .zone(let id)? = elements.hitTest(w)
        else { return super.menu(for: event) }
        controller.selectElement(.zone(id))
        let menu = NSMenu()
        for (title, command) in [(Loc.t("Export Zone…"), CommandID.exportZone), (Loc.t("Print Zone…"), .printZone)] {
            let item = NSMenuItem(title: title, action: #selector(performRegistryCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            menu.addItem(item)
        }
        return menu
    }

    public override func scrollWheel(with event: NSEvent) {
        cameraTween = nil
        noteCameraMoved()
        // Settings › Editing › Scroll wheel: zoom (⌘ or ⌥ pans), or pan (⌘ or ⌥ zooms).
        // Trackpads always pan (pinch zooms); a mouse wheel follows the setting.
        let modified = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
        let wheelZooms = controller.scrollZooms && !event.hasPreciseScrollingDeltas
        if wheelZooms != modified {
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

    private var announcedConnect = false

    /// What VoiceOver reads for the selection (Settings › Accessibility › VoiceOver), and
    /// the Connect-mode targets by hint letter.
    /// The topic tree VoiceOver walks (CanvasAccessibility.swift).
    lazy var accessibilityTree = CanvasAccessibility(view: self)
    /// The last selection VoiceOver was told about.
    private var announcedPrimary: NodeID?
    private var announcedLegend = false
    /// Tests stand in for a running assistive app.
    var assistiveAppOverride: Bool?
    var assistiveAppRunning: Bool {
        assistiveAppOverride ?? (NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled)
    }

    /// The topic tree, then the canvas's real subviews (the text editor while typing, the
    /// Add Topic buttons, the floating toolbar), so each one's parent lists it as a child.
    public override func accessibilityChildren() -> [Any]? {
        accessibilityTree.roots() + (super.accessibilityChildren() ?? [])
    }
    /// The canvas is always usable (otherwise VoiceOver reads it as dimmed).
    public override func isAccessibilityEnabled() -> Bool { true }
    public override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] { accessibilityTree.rotors() }
    /// Read when asked (not on every edit): the selection's description.
    public override func accessibilityValue() -> Any? { accessibilityTree.label(controller.selection.primary) }

    public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        onMain {
            guard let w = window else { return self }
            let p = convert(w.convertPoint(fromScreen: point), from: nil)
            if let id = node(at: p), let e = accessibilityTree.element(id) { return e }
            return self
        }
    }

    private func updateAccessibility() {
        let c = controller.canvas
        guard c.nodes[controller.selection.primary] != nil else { return }
        // VoiceOver follows the selection (only work done when an assistive app is running).
        // The selected legend takes VoiceOver's focus; deselecting returns it to the topic (M21).
        if assistiveAppRunning, controller.legendActive != announcedLegend {
            announcedLegend = controller.legendActive
            if announcedLegend, let e = accessibilityTree.legendItem() {
                NSAccessibility.post(element: e, notification: .focusedUIElementChanged)
            } else {
                announcedPrimary = nil
            }
        }
        if assistiveAppRunning, !announcedLegend, announcedPrimary != controller.selection.primary {
            announcedPrimary = controller.selection.primary
            if let e = accessibilityTree.element(controller.selection.primary) {
                NSAccessibility.post(element: e, notification: .focusedUIElementChanged)
                NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
            }
        }
        if let s = controller.connect, !announcedConnect {
            announcedConnect = true
            if controller.prefs.bool("accessibility.announceConnect") {
                let texts = controller.connectTexts
                let targets = s.candidates.prefix(6).compactMap { cand in
                    texts[cand.end].map { "\(cand.hint.uppercased()), \($0)" }
                }
                NSAccessibility.post(
                    element: self, notification: .announcementRequested,
                    userInfo: [
                        .announcement: Loc.t("Connect mode. ") + targets.joined(separator: "; "),
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
            }
        } else if controller.connect == nil {
            announcedConnect = false
        }
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
    /// Off for offscreen export, whatever the pattern.
    var suppressed = false
    /// What the drawn contents were made for: redraw only when it changes.
    private var drawn: (step: CGFloat, size: CGSize, pattern: Theme.Grid)?

    /// The grid pattern's cell size on screen, or nil when there's no grid to draw.
    var step: CGFloat? {
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
    func place(in viewBounds: CGRect, force: Bool = false) {
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

    override func draw(in ctx: CGContext) {
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
