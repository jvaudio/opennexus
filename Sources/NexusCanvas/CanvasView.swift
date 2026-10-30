#if os(macOS)
import AppKit
import NexusCore
import NexusKeys
import NexusLayout
import NexusScene
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
public final class CanvasView: NSView, RegistryCommandTarget, ContextMenuTarget, NSMenuItemValidation, PointerSurface {
    public let controller: CanvasController

    private let host = FlippedView()
    /// The layer tree: topics, lines, elements, the grid and the camera.
    let renderer = SceneRenderer()
    /// Other people's marks in a live session (M46).
    let presence = PresenceLayer()

    /// Present (M42): the slide whose builds have run, and the topic Showtime enlarged.
    private var builtSlide: String?
    private var showtimeFocus: NodeID?
    /// Present's laser pointer (hold ⇧, M42).
    private var laser: CALayer?
    /// Set before an update that should morph node looks (⌥⌘S).
    public var morphNextUpdate = false
    /// Offscreen export: no selection ring, no grid.
    public var exportMode: Bool {
        get { renderer.exportMode }
        set { renderer.exportMode = newValue }
    }

    public var camera: Camera { renderer.camera }
    var elements: ElementRenderer { renderer.elements }
    var decorRenderer: DecorRenderer { renderer.decorRenderer }
    var legendLayer: LegendLayer { renderer.legendLayer }
    private var cameraTween: CameraTween?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var hasPlacedCamera = false

    let editor = NodeTextView()
    /// Clicks and drags (shared with the iPad's touches, M47b).
    private(set) var pointer: CanvasPointer!
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
    /// Whether the pointing hand is showing over a fold control.
    private var foldCursor = false
    private var aidsTracking: NSTrackingArea?
    private var hintsHost: NSHostingView<EmptyCanvasHints>?
    private var morphUntil: CFTimeInterval = 0
    private var lastMorphSerial = 0
    private(set) var popovers: CanvasPopovers?

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

        host.layer = renderer.rootLayer
        host.wantsLayer = true
        // Focus blurs the rest of the map (Core Image filters on node layers).
        host.layerUsesCoreImageFilters = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        renderer.asset = { [weak controller] in controller?.store.model.assets[$0] }
        // The view's own marks: presence over the topics; the pointer adds the rubber band
        // under the element overlay and the drop indicator on top.
        let world = renderer.world
        world.insertSublayer(presence, above: renderer.nodesLayer)
        pointer = CanvasPointer(controller: controller, renderer: renderer, surface: self)

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
        controller.onPresence = { [weak self] in self?.presenceChanged() }
        controller.onAnnounce = { [weak self] text in
            guard let self else { return }
            NSAccessibility.post(
                element: self, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        popovers = CanvasPopovers(view: self)
        controller.onRequest = { [weak self] r in self?.popovers?.handle(r) }
        // Code files open in the editor chosen in Settings › Integrations (M9).
        controller.onOpenURL = { [weak controller] url in CodeLinks.open(url, prefs: controller?.prefs ?? .shared) }
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The root of the canvas layer tree (offscreen rendering, snapshots, export).
    var sceneLayer: CALayer { renderer.rootLayer }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        controller.outlineFocused = false
        return super.becomeFirstResponder()
    }
    public override var canBecomeKeyView: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer.viewSize = bounds.size
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderer.onScreen = window != nil
        renderer.backingScale = window?.backingScaleFactor ?? 2
    }

    public override func layout() {
        super.layout()
        host.frame = bounds
        renderer.viewSize = bounds.size
        renderer.layout()
        if !hasPlacedCamera, bounds.width > 0 {
            hasPlacedCamera = true
            centerScene()
            update(animated: false)
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.backingScale = window?.backingScaleFactor ?? 2
        updateTextScale()
    }

    // MARK: Rendering

    /// Rebuilds layers from the controller's scene. Typing never waits on this: the
    /// editor is already live when a create command calls here.
    public func update(animated: Bool) {
        let animate = animated && !reduceMotion && window != nil && controller.animateReflow
        let morph = morphNextUpdate && animate
        morphNextUpdate = false
        let editing = controller.edit.flatMap { $0.element == nil ? $0.node : nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated && reduceMotion && window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.reducedCrossFade
            renderer.world.add(fade, forKey: "reduce-motion-fade")
        }
        let running = renderer.update(
            controller.scene, state: controller.renderState(reduceMotion: reduceMotion), animated: animate,
            morph: morph)
        CATransaction.commit()
        updateConnectField()
        if controller.morphSerial != lastMorphSerial {
            lastMorphSerial = controller.morphSerial
            morphUntil = CACurrentMediaTime() + Motion.convert + 0.15
        }
        refreshOverlays()
        if editing != nil || controller.edit != nil { positionEditor() }
        updateAccessibility()
        if running { startTicking() }
    }

    /// The animated frame of a node (spring position, grow-in scale).
    private func animatedFrame(_ id: NodeID) -> NodeFrame? { renderer.animatedFrame(id) }

    // MARK: Animation loop

    private func startTicking() {
        guard displayLink == nil, window != nil else {
            if window == nil { renderer.settle() }
            return
        }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240), 1.0 / 30)
        lastTick = now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let running = renderer.step(
            dt, morph: now < morphUntil, selected: controller.selectedElement, connect: controller.connect)
        if !presence.isEmpty { refreshPresence() }
        var cameraDone = true
        if let tween = cameraTween {
            let (c, done) = tween.value(at: now)
            setCamera(c, animated: false)
            if done { cameraTween = nil } else { cameraDone = false }
        }
        CATransaction.commit()
        if controller.edit != nil { positionEditor() }
        if !running && cameraDone {
            link.invalidate()
            displayLink = nil
            cull()
        }
    }

    // MARK: Camera

    private var textScale: CGFloat { renderer.textScale }

    private func updateTextScale() { cull() }

    /// Viewport culling (M10): topics outside the view are hidden (`SceneRenderer.cull`).
    /// Views without a window (offscreen export) draw everything.
    func cull() { renderer.cull() }

    /// Off only for tests and tools that need every layer live.
    var cullingEnabled: Bool {
        get { renderer.cullingEnabled }
        set { renderer.cullingEnabled = newValue }
    }
    /// How many topic layers the last cull left on screen.
    var visibleNodeLayers: Int { renderer.visibleNodeLayers }

    func setCamera(_ c: Camera, animated: Bool, via: Camera? = nil, fly: Bool = false) {
        if animated && !reduceMotion && window != nil {
            cameraTween = CameraTween(
                from: camera, to: c, start: CACurrentMediaTime(),
                duration: fly ? Motion.fly : Motion.focus * (via == nil ? 1 : 2.5), via: via,
                fly: fly ? (FlyPath(from: camera, to: c, in: bounds), bounds) : nil)
            startTicking()
            return
        }
        let zoomChanged = c.zoom != camera.zoom
        if zoomChanged { controller.zoom = Double(c.zoom) }
        // Depth parallax when zoomed out: the grid drifts a little slower than the map.
        renderer.place(c, parallax: controller.prefs.bool("appearance.parallax") && c.zoom < 0.6 && !reduceMotion)
        minimap?.refresh(panning: true)
        if zoomChanged, !presence.isEmpty { refreshPresence() }
        if bounds.width > 0 {
            controller.viewport = CGRect(
                origin: c.toWorld(.zero), size: CGSize(width: bounds.width / c.zoom, height: bounds.height / c.zoom))
        }
        // Overlays pinned to a topic (Add Topic +, the floating toolbar) follow the camera.
        positionMouseAids()
        if controller.edit != nil { positionEditor() }
    }

    public func centerScene() {
        guard let c = SceneRenderer.centered(controller.scene, root: controller.canvas.root, in: bounds) else { return }
        setCamera(c, animated: false)
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

    /// Where slides go in this view (the stage, the corner legend, a Timeline chart).
    var slideStage: SlideStage { SlideStage(controller: controller, bounds: bounds) }

    /// The slide stage: the largest rect of `aspect` that fits under the title and above
    /// the slide strip.
    public func stageRect(aspect: Double) -> CGRect { slideStage.stageRect(aspect: aspect) }

    /// The corner legend's box on the current slide, in view coordinates, or nil when the
    /// slide has none (D232).
    func presentLegendRect() -> CGRect? { slideStage.presentLegendRect() }

    /// A Timeline slide's chart, in view coordinates, or nil on other slides (D264).
    func presentChartRect() -> CGRect? { slideStage.presentChartRect() }

    /// Flies the camera so `ids` fill the view (or the slide stage at `aspect`).
    func frame(_ ids: [NodeID], aspect: Double?) {
        guard let cam = slideStage.camera(framing: ids, aspect: aspect) else { return }
        // Glide moves straight; the fly-to rises over the map as far as the move needs
        // (Dynamic, Showtime and Zoom, M42); Cut jumps. Reduce Motion cuts.
        let move = controller.present == nil ? "glide" : controller.canvas.presentation.cameraMove
        setCamera(cam, animated: move != "cut", fly: move == "fly")
        if controller.present != nil { slideDidFrame() } else { endSlideMotion() }
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

    func image(for asset: String) -> CGImage? { renderer.image(for: asset) }

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

    /// Other people's marks (M46), redrawn where their topics are now.
    func refreshPresence() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presence.update(
            exportMode ? [] : controller.presenceMarks, frame: { [weak self] in self?.animatedFrame($0)?.rect },
            zoom: camera.zoom, scale: window?.backingScaleFactor ?? 2)
        CATransaction.commit()
    }

    /// Someone's presence changed: marks redraw, and a followed view moves with theirs.
    func presenceChanged() {
        refreshPresence()
        guard let r = controller.followedViewport, bounds.width > 0 else { return }
        let zoom = min(max(min(bounds.width / r.width, bounds.height / r.height), 0.1), 4)
        let c = Camera(
            offset: CGPoint(x: bounds.midX - r.midX * zoom, y: bounds.midY - r.midY * zoom), zoom: zoom)
        setCamera(c, animated: true)
    }

    /// The slash menu and protocol suggestions sit under what they belong to.
    func refreshOverlays() {
        refreshAIOverlays()
        refreshPresence()
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
        guard let session = controller.edit, let n = controller.scene.nodes[session.node],
            let s = renderer.springs[session.node]
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
        // Present: hold ⇧ for a laser pointer (M42).
        if controller.present != nil {
            if event.modifierFlags.contains(.shift), let w = window {
                showLaser(at: convert(w.mouseLocationOutsideOfEventStream, from: nil))
            } else {
                hideLaser()
            }
        }
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
        for (id, l) in renderer.nodeLayers where CanvasController.ghostIndex(id) != nil {
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
            renderer.world.addSublayer(star)
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
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        aidsTracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if controller.present != nil, event.modifierFlags.contains(.shift) {
            showLaser(at: convert(event.locationInWindow, from: nil))
        }
        updateFoldHover(convert(event.locationInWindow, from: nil))
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

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointer.setFoldHover(nil)
        setFoldCursor(false)
    }

    // MARK: Fold control (D215)

    /// The topic showing its "−" fold control.
    var foldHover: NodeID? { pointer.foldHover }

    func offersFoldButton(_ id: NodeID) -> Bool { pointer.offersFoldButton(id) }

    /// Shows the "−" on the topic under the pointer, and keeps it while the pointer is on it.
    func updateFoldHover(_ p: CGPoint) { setFoldCursor(pointer.updateFoldHover(p)) }

    private func setFoldCursor(_ on: Bool) {
        guard on != foldCursor else { return }
        foldCursor = on
        (on ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    func foldControl(_ id: NodeID) -> CGRect? { pointer.foldControl(id) }
    func foldTarget(atWorld w: CGPoint) -> NodeID? { pointer.foldTarget(atWorld: w) }
    func toggleFoldFromControl(_ id: NodeID) { pointer.toggleFoldFromControl(id) }

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
                && !(item.action == #selector(cut(_:)) && controller.selection.nodes == [controller.canvas.root]
                    && controller.targetZone == nil)
        }
        if item.action == #selector(paste(_:)) { return controller.mode == .select }
        if item.action == #selector(performMenuAction(_:)) { return controller.mode != .connect }
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

    public func node(at viewPoint: CGPoint) -> NodeID? { pointer.node(at: viewPoint) }

    public override func mouseDown(with event: NSEvent) {
        controller.stopFollowing()
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        // Present: a click advances, as in Keynote (M42); with the laser out it only points.
        if controller.present != nil {
            if !event.modifierFlags.contains(.shift) { controller.presentClick() }
            return
        }
        // Control-click opens the context menu, as a right-click does.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .control,
            let menu = menu(for: event)
        {
            presentContextMenu(menu, event)
            return
        }
        pointer.down(at: p, clickCount: event.clickCount, modifiers: PointerModifiers(event.modifierFlags))
    }

    public override func mouseDragged(with event: NSEvent) {
        pointer.dragged(
            to: convert(event.locationInWindow, from: nil), modifiers: PointerModifiers(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        pointer.up(at: convert(event.locationInWindow, from: nil), modifiers: PointerModifiers(event.modifierFlags))
    }

    func bandZones(_ band: CGRect) -> [String] { pointer.bandZones(band) }

    private var dropHint: NSView?

    package func showDropHint(_ text: String?, below v: CGRect) {
        dropHint?.removeFromSuperview()
        dropHint = nil
        guard let text else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor(cgColor: controller.theme.ring.cgColor)
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.sizeToFit()
        label.frame.origin = CGPoint(x: v.maxX + 6, y: v.maxY + 4)
        label.frame.size.width += 10
        addSubview(label)
        dropHint = label
    }

    package func pointerChangedSelection() { toolbarFor = nil }

    package func pointerClickedSelectedTopic(_ id: NodeID) {
        // Click again on the selected topic: the floating toolbar.
        guard controller.prefs.string("editing.floatingToolbar") == "click" else { return }
        toolbarFor = id
        refreshMouseAids()
    }

    package func panCamera(to c: Camera) {
        cameraTween = nil
        setCamera(c, animated: false)
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
        if !moved, let menu = menu(for: event) { presentContextMenu(menu, event) }
    }

    /// Shows a context menu at the pointer (tests record it instead: the real one runs a
    /// modal tracking loop).
    lazy var presentContextMenu: (NSMenu, NSEvent) -> Void = { [unowned self] menu, event in
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// What a right-click at a point in the view lands on (M17), or nil for no menu (AI
    /// suggestions, Present, Map Shot).
    func menuTarget(at p: CGPoint) -> CanvasMenuTarget? { pointer.menuTarget(at: p) }

    /// The context menu for whatever is under the pointer (M17): topics, images,
    /// relationships, boundaries, summaries, callouts, zones, the legend and empty canvas.
    /// Right-clicking selects first, as a click would (D176).
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let target = menuTarget(at: convert(event.locationInWindow, from: nil)) else { return nil }
        controller.prepareContextMenu(target)
        refreshOverlays()
        let entries = controller.contextMenu(for: target)
        return entries.isEmpty ? nil : makeMenu(entries)
    }

    /// Entries as an `NSMenu`. Commands go through `performRegistryCommand` (window
    /// commands such as Export… and Format Panel continue up the responder chain); the
    /// few other items through `performMenuAction` (D173, D174).
    func makeMenu(_ entries: [CanvasMenuEntry], title: String = "") -> NSMenu {
        ContextMenus.make(entries, title: title, target: self)
    }

    /// Context-menu items that aren't plain commands (Add Floating Topic, Paste and Zone at
    /// the pointer, Edit Label, Collapse Zone, Remove Image, Sticker…).
    @objc func performMenuAction(_ sender: Any?) {
        ContextMenus.performAction(sender, controller: controller)
        refreshOverlays()
    }

    /// Shows the menu for a target at a rectangle in the view (VoiceOver's Show Menu).
    func showContextMenu(_ target: CanvasMenuTarget, at rect: CGRect) -> Bool {
        controller.prepareContextMenu(target)
        refreshOverlays()
        let entries = controller.contextMenu(for: target)
        guard !entries.isEmpty else { return false }
        makeMenu(entries).popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY), in: self)
        return true
    }

    public override func scrollWheel(with event: NSEvent) {
        cameraTween = nil
        controller.stopFollowing()
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
        controller.stopFollowing()
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
    /// The selected zones VoiceOver was last told about.
    private var announcedZones: [String] = []
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
    /// The empty-canvas menu's items (paste, a floating topic, a zone, select all, fit,
    /// export and print), and Show Menu opens that menu (M17, D179).
    public override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        accessibilityTree.menuActions(.canvas(camera.toWorld(CGPoint(x: bounds.midX, y: bounds.midY))))
    }
    public override func accessibilityPerformShowMenu() -> Bool {
        let p = CGPoint(x: bounds.midX, y: bounds.midY)
        return showContextMenu(.canvas(camera.toWorld(p)), at: CGRect(origin: p, size: .zero))
    }
    /// Read when asked (not on every edit): the selection's description, or the selected
    /// zone's with its place among the selected zones (D262).
    public override func accessibilityValue() -> Any? {
        if case .zone(let id)? = controller.selectedElement { return accessibilityTree.zoneLabel(id) }
        return accessibilityTree.label(controller.selection.primary)
    }

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
        // A selected zone takes VoiceOver's focus, read with the group (D262); a change to
        // the group is announced again.
        let zones = controller.selectedZones
        if assistiveAppRunning, !announcedLegend, zones != announcedZones {
            announcedZones = zones
            if case .zone(let id)? = controller.selectedElement, let e = accessibilityTree.zoneItem(id) {
                NSAccessibility.post(element: e, notification: .focusedUIElementChanged)
                NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
            } else {
                announcedPrimary = nil
            }
        }
        if assistiveAppRunning, !announcedLegend, zones.isEmpty, announcedPrimary != controller.selection.primary {
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

/// Carries a context-menu action on an `NSMenuItem`.
final class MenuActionBox: NSObject {
    let action: CanvasMenuAction
    init(_ action: CanvasMenuAction) { self.action = action }
}

/// A flipped layer-hosting view: AppKit keeps the hosted layer's geometry in step with
/// the view, so world coordinates run top-down like the model.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: Present motion (M42)

extension CanvasView {
    /// After a slide is framed: Dynamic and Showtime build its topics in (each scales and
    /// fades in a stagger after the one before, its branch line drawing on) as the camera
    /// lands, and a flow slide draws its flow on. Showtime is quicker, enlarges and lights the
    /// focus topic, and sparkles one with a marker. Calm builds nothing; Reduce Motion
    /// cross-fades the same topics in.
    func slideDidFrame() {
        guard let p = controller.present else { return }
        let slides = controller.slides
        guard p.index < slides.count, !p.overview else { return }
        let slide = slides[p.index]
        guard slide.id != builtSlide else { return }
        builtSlide = slide.id
        clearShowtime()
        let style = controller.canvas.presentation.style
        guard style != "calm", !exportMode, window != nil else { return }
        let showtime = style == "showtime"
        let builds = Deck.builds(slide, in: controller.canvas)
        let start = CACurrentMediaTime() + (reduceMotion ? 0 : Motion.fly * 0.55)
        // A long list still builds in about a second.
        let stagger = min(showtime ? Motion.showtimeStagger : Motion.buildStagger, 1.0 / Double(max(builds.count, 1)))
        for (i, id) in builds.enumerated() {
            guard let l = renderer.nodeLayers[id] else { continue }
            let begin = start + (reduceMotion ? 0 : Double(i) * stagger)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = l.opacity
            fade.beginTime = begin
            fade.fillMode = .backwards
            fade.duration = reduceMotion ? Motion.reducedCrossFade : Motion.presentStep * 0.5
            l.add(fade, forKey: "present.fade")
            guard !reduceMotion else { continue }
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.6
            pop.toValue = 1
            pop.stiffness = Motion.snap.stiffness
            pop.damping = Motion.snap.damping
            pop.beginTime = begin
            pop.fillMode = .backwards
            pop.duration = pop.settlingDuration
            l.add(pop, forKey: "present.pop")
            if let e = renderer.edgeLayers[id] {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.beginTime = begin
                draw.fillMode = .backwards
                draw.duration = Motion.connectDraw
                e.add(draw, forKey: "present.draw")
            }
        }
        if let flow = slide.flow, !reduceMotion {
            if flow.hasPrefix("t:"), let e = renderer.edgeLayers[NodeID(String(flow.dropFirst(2)))] {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.beginTime = start
                draw.fillMode = .backwards
                draw.duration = Motion.connectDraw
                e.add(draw, forKey: "present.draw")
            } else {
                elements.drawOn(relationship: flow, at: start)
            }
        }
        if showtime, let focus = controller.showtimeFocus(slide), let l = renderer.nodeLayers[focus] {
            showtimeFocus = focus
            if !reduceMotion {
                let grow = CASpringAnimation(keyPath: "transform.scale")
                grow.fromValue = 1
                grow.toValue = Motion.showtimeFocusScale
                grow.stiffness = Motion.settle.stiffness
                grow.damping = Motion.settle.damping
                grow.beginTime = start
                grow.duration = grow.settlingDuration
                grow.fillMode = .both
                grow.isRemovedOnCompletion = false
                l.add(grow, forKey: "present.showtime")
                if controller.prefs.bool("appearance.sparkle"), controller.canvas.nodes[focus]?.markers.isEmpty == false
                {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Motion.fly * 0.8) { [weak self] in
                        MainActor.assumeIsolated { self?.sparkle(at: focus) }
                    }
                }
            } else {
                l.transform = CATransform3DMakeScale(Motion.showtimeFocusScale, Motion.showtimeFocusScale, 1)
            }
        }
    }

    /// Present ended: no builds pending, and the Showtime focus back to size.
    func endSlideMotion() {
        builtSlide = nil
        clearShowtime()
        hideLaser()
    }

    private func clearShowtime() {
        guard let id = showtimeFocus else { return }
        showtimeFocus = nil
        renderer.nodeLayers[id]?.removeAnimation(forKey: "present.showtime")
        renderer.nodeLayers[id]?.transform = CATransform3DIdentity
    }

    /// The slide a build last ran for, and a topic's layer (tests).
    var builtSlideID: String? { builtSlide }
    func nodeLayer(_ id: NodeID) -> NodeLayer? { renderer.nodeLayers[id] }
    var showtimeFocusID: NodeID? { showtimeFocus }

    // MARK: Laser pointer (hold ⇧)

    /// A red dot with a glow that follows the pointer while ⇧ is held in Present.
    func showLaser(at viewPoint: CGPoint) {
        let l =
            laser
            ?? {
                let d = CALayer()
                d.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
                d.cornerRadius = 7
                d.backgroundColor = NSColor(red: 1, green: 0.17, blue: 0.2, alpha: 0.95).cgColor
                d.shadowColor = d.backgroundColor
                d.shadowOpacity = 0.9
                d.shadowRadius = 8
                d.shadowOffset = .zero
                d.zPosition = 10_000
                layer?.addSublayer(d)
                laser = d
                return d
            }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.position = viewPoint
        l.isHidden = false
        CATransaction.commit()
    }

    func hideLaser() {
        laser?.isHidden = true
    }

    var laserVisible: Bool { laser.map { !$0.isHidden } ?? false }
}
extension PointerModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}
#endif
