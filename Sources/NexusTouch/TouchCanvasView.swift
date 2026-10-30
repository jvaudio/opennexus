#if os(iOS)
import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import NexusTheme
import UIKit

/// The iPad's canvas (M47b): the Mac's `SceneRenderer` in a `UIView`, driven by touch,
/// Apple Pencil, a pointer and a hardware keyboard. Clicks and drags go through the same
/// `CanvasPointer` as the Mac's mouse, keys through `controller.handleKey`.
@MainActor
public final class TouchCanvasView: UIView, PointerSurface {
    public let controller: CanvasController
    package let renderer = SceneRenderer()
    package private(set) var pointer: CanvasPointer!
    let editor = TouchTextEditor()

    public var camera: Camera { renderer.camera }
    private var cameraTween: CameraTween?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var hasPlacedCamera = false
    private var morphUntil: CFTimeInterval = 0
    private var lastMorphSerial = 0
    /// Set before an update that should morph node looks (⌥⌘S).
    public var morphNextUpdate = false
    /// A key that started typing on a selected topic, fed to the editor once it opens.
    var pendingTyping: String?
    /// A hardware keyboard drives the canvas (its last input was a key, not a touch). The
    /// editor then stays first responder between edits, hidden, and passes keys back here,
    /// so a new topic's caret is live without UIKit's input session starting again (D394).
    public var keyboardDriven = false
    /// Commands the canvas doesn't run (Export…, the Format panel, view modes): the
    /// document screen's.
    public var onWindowCommand: ((CommandID) -> Bool)?
    /// The camera moved (the minimap and the presenter view follow it).
    public var onCameraMoved: (() -> Void)?
    /// Hint label for drops ("Drop to attach under …").
    private var dropHint: UILabel?
    /// The iPhone's touch (M47c, D416): a one-finger drag pans unless it starts on a
    /// selected topic, which it moves.
    public var compactTouch = false
    /// The last point of a one-finger pan (compact touch).
    var oneFingerPan: CGPoint?
    /// Technical diagrams on the iPhone (M47c): the camera fits the map when the view first
    /// lays out and whenever its size changes (the phone turns).
    public var fitsOnResize = false
    private var fittedWidth: CGFloat = 0
    /// The margins Fit to Window leaves; the iPhone's keep the map clear of the chrome at
    /// the canvas's foot.
    public var fitInsets = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)

    /// The elements VoiceOver walks (TouchAccessibility.swift).
    lazy var accessibilityTree = TouchAccessibility(view: self)
    var announced = Announced()
    /// Tests stand in for a running assistive app.
    public var assistiveAppOverride: Bool?
    var assistiveAppRunning: Bool {
        assistiveAppOverride ?? (UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning)
    }

    /// Forces Reduce Motion (tests).
    public var reduceMotionOverride: Bool?
    var reduceMotion: Bool {
        reduceMotionOverride ?? controller.reduceMotionPreference ?? UIAccessibility.isReduceMotionEnabled
    }

    public init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        layer.addSublayer(renderer.rootLayer)
        renderer.asset = { [weak controller] in controller?.store.model.assets[$0] }
        pointer = CanvasPointer(controller: controller, renderer: renderer, surface: self)

        editor.controller = controller
        editor.keyTarget = self
        editor.isHidden = true
        addSubview(editor)

        accessibilityIdentifier = "canvas"
        wireController()
        installGestures()
        installAccessibility()
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in self.traitsChanged() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func wireController() {
        controller.onSceneChange = { [weak self] animated in self?.update(animated: animated) }
        controller.onReveal = { [weak self] id in self?.reveal(id) }
        controller.onFrame = { [weak self] ids, aspect in self?.frame(ids, aspect: aspect) }
        controller.onRestoreFocus = { [weak self] in self?.takeKeyboard() }
        controller.onEditChange = { [weak self] session in self?.editChanged(session) }
        controller.onEditorReplaceText = { [weak self] text in
            guard let self else { return }
            self.editor.text = text
            self.positionEditor()
        }
        controller.viewCommandHandler = { [weak self] id in self?.performViewCommand(id) ?? false }
        controller.viewCommandValidator = { id in Self.viewCommands.contains(id) }
        controller.floatingPlacement = { [weak self] in self?.defaultFloatingPoint() ?? .zero }
        controller.onMorph = { [weak self] in self?.morphNextUpdate = true }
        controller.onAnnounce = { text in
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    public override var canBecomeFirstResponder: Bool { true }

    /// Taking the keyboard moves focus off the outline, first, so the outline's editor
    /// resigning doesn't take it back. A canvas off screen or hidden can't take it, and leaves
    /// the focus alone (the iPhone's Outline, where the canvas's deferred `takeKeyboard` came
    /// after the Outline showed, M47c).
    public override func becomeFirstResponder() -> Bool {
        guard window != nil, !isHidden else { return false }
        controller.outlineFocused = false
        return super.becomeFirstResponder()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        renderer.onScreen = window != nil
        renderer.backingScale = window?.screen.scale ?? traitCollection.displayScale
        if window != nil { takeKeyboard() }
    }

    /// The keyboard goes to the editor while a topic is being edited (a new document's
    /// central topic begins before the canvas is in a window), else to the canvas; a
    /// parked editor keeps it (D394).
    public func takeKeyboard() {
        if controller.edit != nil, !editor.isHidden {
            if !editor.isFirstResponder { _ = editor.becomeFirstResponder() }
        } else if !isFirstResponder, !editor.isParked {
            _ = becomeFirstResponder()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.rootLayer.frame = bounds
        renderer.viewSize = bounds.size
        renderer.layout()
        CATransaction.commit()
        if !hasPlacedCamera, bounds.width > 0 {
            hasPlacedCamera = true
            centerScene()
            update(animated: false)
        }
        // The width: turning the phone refits, the keyboard coming up doesn't.
        if fitsOnResize, bounds.width > 0, bounds.width != fittedWidth {
            fittedWidth = bounds.width
            fitToWindow(animated: false)
        }
    }

    private func traitsChanged() {
        renderer.backingScale = window?.screen.scale ?? traitCollection.displayScale
        renderer.cull()
    }

    // MARK: Rendering

    /// Rebuilds layers from the controller's scene. Typing never waits on this: the
    /// editor is already live when a create command calls here.
    public func update(animated: Bool) {
        let animate = animated && !reduceMotion && window != nil && controller.animateReflow
        let morph = morphNextUpdate && animate
        morphNextUpdate = false
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
        if controller.morphSerial != lastMorphSerial {
            lastMorphSerial = controller.morphSerial
            morphUntil = CACurrentMediaTime() + Motion.convert + 0.15
        }
        if controller.edit != nil { positionEditor() }
        accessibilityChanged()
        if running { startTicking() }
    }

    private func startTicking() {
        guard displayLink == nil, window != nil else {
            if window == nil { renderer.settle() }
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // ProMotion: up to 120 Hz while something moves.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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
            renderer.cull()
        }
    }

    // MARK: Camera

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.place(c, parallax: controller.prefs.bool("appearance.parallax") && c.zoom < 0.6 && !reduceMotion)
        CATransaction.commit()
        if bounds.width > 0 {
            controller.viewport = CGRect(
                origin: c.toWorld(.zero), size: CGSize(width: bounds.width / c.zoom, height: bounds.height / c.zoom))
        }
        if controller.edit != nil { positionEditor() }
        onCameraMoved?()
    }

    package func panCamera(to c: Camera) {
        cameraTween = nil
        setCamera(c, animated: false)
    }

    public func centerScene() {
        let b = controller.scene.bounds
        guard !b.isNull else { return }
        setCamera(Camera(offset: CGPoint(x: bounds.midX - b.midX, y: bounds.midY - b.midY), zoom: 1), animated: false)
    }

    func reveal(_ id: NodeID) {
        guard let n = controller.scene.nodes[id] else { return }
        let target = cameraTween?.to ?? camera
        let r = target.toView(n.frame.rect).insetBy(dx: -48, dy: -48)
        let visible = bounds.inset(by: safeAreaInsets)
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

    /// Zooms by `factor` keeping the world point under `viewPoint` where it is.
    public func zoom(by factor: CGFloat, around viewPoint: CGPoint? = nil) {
        let p = viewPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let z = min(4, max(0.1, camera.zoom * factor))
        let w = camera.toWorld(p)
        setCamera(Camera(offset: CGPoint(x: p.x - w.x * z, y: p.y - w.y * z), zoom: z), animated: false)
    }

    /// Flies the camera so `ids` fill the view (or the slide stage at `aspect`).
    func frame(_ ids: [NodeID], aspect: Double?) {
        guard let cam = SlideStage(controller: controller, bounds: bounds).camera(framing: ids, aspect: aspect)
        else { return }
        let move = controller.present == nil ? "glide" : controller.canvas.presentation.cameraMove
        setCamera(cam, animated: move != "cut", fly: move == "fly")
    }

    /// Zooms to `z` around the view's centre (Settings › Editing › Default zoom).
    public func setZoom(_ z: CGFloat) { zoom(by: z / max(camera.zoom, 0.01)) }

    public func fitToWindow() { fitToWindow(animated: true) }

    public func fitToWindow(animated: Bool) {
        let b = controller.scene.bounds
        guard !b.isNull, bounds.width > 0 else { return }
        let r = bounds.inset(by: fitInsets)
        let z = min(1, max(0.1, min(r.width / b.width, r.height / b.height)))
        setCamera(Camera(offset: CGPoint(x: r.midX - b.midX * z, y: r.midY - b.midY * z), zoom: z), animated: animated)
    }

    /// Fits the map now and again whenever the view's size changes.
    public func fitOnResize() {
        fitsOnResize = true
        fittedWidth = 0
        setNeedsLayout()
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

    /// A topic's rect in view coordinates (popover anchors).
    public func viewRect(of id: NodeID) -> CGRect? {
        renderer.animatedFrame(id).map { camera.toView($0.rect) }
    }

    /// The scene as drawn, offscreen at `scale` (the iPad's goldens, M47b): the same
    /// layers the screen shows, with every text layer redrawn first.
    public func renderImage(scale: CGFloat = 1) -> UIImage {
        layoutIfNeeded()
        let root = renderer.rootLayer
        root.layoutIfNeeded()
        func redraw(_ l: CALayer) {
            if l is TextLayer { l.setNeedsDisplay(); l.displayIfNeeded() }
            l.sublayers?.forEach(redraw)
        }
        redraw(root)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            root.render(in: ctx.cgContext)
        }
    }

    // MARK: Pointer surface

    package func showDropHint(_ text: String?, below v: CGRect) {
        dropHint?.removeFromSuperview()
        dropHint = nil
        guard let text else { return }
        let label = PaddedLabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor(cgColor: controller.theme.ring.cgColor)
        label.layer.cornerRadius = 5
        label.layer.masksToBounds = true
        label.sizeToFit()
        label.frame.origin = CGPoint(x: v.maxX + 6, y: v.maxY + 4)
        addSubview(label)
        dropHint = label
    }

    package func pointerChangedSelection() {}
    package func pointerClickedSelectedTopic(_ id: NodeID) {}

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
            var st = NodeTextStyle(typography: NodeTypography.for(.sub), monospaced: false)
            st.fontSize = 13
            st.lineHeight = 18
            st.weight = .semibold
            st.maxWidth = 400
            editor.begin(session, style: st, color: UIColor(cgColor: controller.theme.ink.cgColor))
            editor.isHidden = false
            positionEditor()
            if !editor.isFirstResponder { _ = editor.becomeFirstResponder() }
            return
        }
        guard let session, let n = controller.scene.nodes[session.node] else {
            if !editor.isHidden {
                editor.end()
                editor.isHidden = true
                if editor.isFirstResponder, !keyboardDriven { _ = becomeFirstResponder() }
            }
            if controller.mode == .select, !isFirstResponder, !editor.isParked { _ = becomeFirstResponder() }
            return
        }
        editor.begin(session, style: n.textStyle, color: UIColor(cgColor: n.appearance.text.cgColor))
        let prefs = controller.prefs
        let code = controller.canvas.nodes[session.node]?.textFormat == "code"
        editor.applyWriting(
            spelling: prefs.bool("general.spelling") && !code, autocorrect: prefs.bool("general.autocorrect") && !code,
            smartQuotes: prefs.bool("general.smartQuotes") && !code)
        editor.isHidden = false
        positionEditor()
        if !editor.isFirstResponder { _ = editor.becomeFirstResponder() }
        if let typed = pendingTyping {
            pendingTyping = nil
            editor.insertText(typed)
        } else if let input = session.pendingInput {
            editor.insertText(input)
        }
    }

    /// The editor sits over the topic's text at its final frame, at the topic's own size,
    /// scaled with the camera.
    func positionEditor() {
        var local: CGRect
        if let session = controller.edit, let ref = session.element {
            guard let r = renderer.elements.editorRect(for: ref) else { return }
            let measured = NodeMeasurer.measure(
                editor.text,
                style: editor.style ?? NodeTextStyle(typography: NodeTypography.for(.sub), monospaced: false))
            local = r
            local.size.width = max(r.width, measured.width + 8)
            local.origin.x = r.midX - local.width / 2
            if case .relationship = ref {} else { local.origin.x = r.minX }
            local.size.height = 18
            local.origin.y = r.midY - 9
        } else {
            guard let session = controller.edit, let n = controller.scene.nodes[session.node] else { return }
            let origin = CGPoint(
                x: n.frame.center.x - n.frame.size.width / 2, y: n.frame.center.y - n.frame.size.height / 2)
            local = n.textRect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0)
        }
        let view = camera.toView(local)
        editor.transform = .identity
        if editor.bounds.size != local.size { editor.bounds = CGRect(origin: .zero, size: local.size) }
        editor.transform = CGAffineTransform(scaleX: camera.zoom, y: camera.zoom)
        editor.center = CGPoint(x: view.midX, y: view.midY)
    }
}

/// A label with room around its text.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(size)
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}
#endif
