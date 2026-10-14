import AppKit
import NexusCore
import NexusKeys
import NexusLayout
import NexusTheme
import QuartzCore

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
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        grid.actions = NodeLayer.noActions
        rootLayer.addSublayer(grid)
        world.anchorPoint = .zero
        world.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        world.actions = NodeLayer.noActions
        edgesLayer.actions = NodeLayer.noActions
        nodesLayer.actions = NodeLayer.noActions
        world.addSublayer(edgesLayer)
        world.addSublayer(nodesLayer)
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
        controller.onEditChange = { [weak self] session in self?.editChanged(session) }
        controller.viewCommandHandler = { [weak self] id in self?.performViewCommand(id) ?? false }
        controller.viewCommandValidator = { id in Self.viewCommands.contains(id) }
        controller.floatingPlacement = { [weak self] in self?.defaultFloatingPoint() ?? .zero }
        controller.onMorph = { [weak self] in self?.morphNextUpdate = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The root of the canvas layer tree (offscreen rendering, snapshots, export).
    var sceneLayer: CALayer { rootLayer }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
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
        let editing = controller.edit?.node

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
                n, theme: theme, canvas: scene.canvasColor, selected: selected.contains(id),
                primary: controller.selection.primary == id, editing: editing == id, morph: morph)
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
        CATransaction.commit()
        if editing != nil { positionEditor() }
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
            springs[id]?.step(dt, spring: Motion.snap)
            scales[id]?.step(dt, spring: Motion.snap)
            if scales[id]?.isSettled == true { scales[id] = nil }
            if springs[id]?.isSettled ?? true, scales[id] == nil { settled.insert(id) }
        }
        applyFrames(all: false)
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

    // MARK: Editing

    private func editChanged(_ session: EditSession?) {
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
            break
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

    private var dragStart: (point: CGPoint, offset: CGPoint)?

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if let id = node(at: p) {
            if event.clickCount == 2 {
                controller.beginEditing(id)
            } else {
                controller.select(id, extend: event.modifierFlags.contains(.shift))
            }
            dragStart = nil
        } else {
            if event.clickCount == 2 {
                controller.addFloating(at: camera.toWorld(p))
                return
            }
            dragStart = (p, camera.offset)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        var c = camera
        c.offset = CGPoint(x: start.offset.x + p.x - start.point.x, y: start.offset.y + p.y - start.point.y)
        cameraTween = nil
        setCamera(c, animated: false)
    }

    public override func mouseUp(with event: NSEvent) { dragStart = nil }

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
