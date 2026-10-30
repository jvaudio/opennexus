#if os(iOS)
import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import UIKit

/// Touch, Apple Pencil, the pointer and the hardware keyboard (M47b, D390, D391):
///
/// - tap selects (with ⇧ or ⌘ held on a keyboard, adds), double-tap edits;
/// - drag a topic to move or reparent it with the Mac's drop hints, drag on empty canvas
///   for a selection band;
/// - two fingers pan and pinch zooms; a trackpad's scroll pans;
/// - long-press (or a secondary click) opens the context menu built from the registry;
/// - a hovering pointer or Pencil shows the fold controls;
/// - Scribble writes into the topic under the Pencil.
extension TouchCanvasView: UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.allowedScrollTypesMask = []
        drag.delegate = self
        drag.name = "drag"
        addGestureRecognizer(drag)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        pan.name = "pan"
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)

        addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(UIIndirectScribbleInteraction(delegate: self))
    }

    /// The keyboard's modifiers held during a touch (a Magic Keyboard with a finger).
    func modifiers(_ g: UIGestureRecognizer) -> PointerModifiers {
        var m: PointerModifiers = []
        let f = g.modifierFlags
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.alternate) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }

    public func gestureRecognizer(
        _ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Two fingers pinch and pan together.
        (g is UIPinchGestureRecognizer && other.name == "pan") || (g.name == "pan" && other is UIPinchGestureRecognizer)
    }

    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The editor takes its own touches (placing the caret, selecting text).
        !(touch.view is UITextView)
    }

    // MARK: Taps

    @objc func tapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let p = g.location(in: self)
        tap(at: p, count: 1, modifiers: modifiers(g))
    }

    @objc func doubleTapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        tap(at: g.location(in: self), count: 2, modifiers: modifiers(g))
    }

    /// A click at a point: what the Mac's mouse down and up do there.
    func tap(at p: CGPoint, count: Int, modifiers m: PointerModifiers) {
        controller.stopFollowing()
        touched()
        // The editor keeps its own touches, so a tap here is elsewhere: taking first
        // responder back ends the edit, as a click does on the Mac.
        if !isFirstResponder { _ = becomeFirstResponder() }
        // Present: a tap advances, as a click does.
        if controller.present != nil {
            controller.presentClick()
            return
        }
        pointer.down(at: p, clickCount: count, modifiers: m, emptyDrag: PointerSurfaceEmptyDrag.none)
        pointer.up(at: p, modifiers: m)
    }

    // MARK: Drags

    @objc func dragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let start = CGPoint(x: p.x - g.translation(in: self).x, y: p.y - g.translation(in: self).y)
        drag(g.state, from: start, to: p, modifiers: modifiers(g))
    }

    /// One finger's drag (a band from empty canvas, a move from a topic), at each phase.
    func drag(_ phase: UIGestureRecognizer.State, from start: CGPoint, to p: CGPoint, modifiers m: PointerModifiers) {
        switch phase {
        case .began:
            controller.stopFollowing()
            touched()
            if controller.present != nil { return }
            pointer.down(at: start, clickCount: 1, modifiers: m, emptyDrag: .band)
            pointer.dragged(to: p, modifiers: m)
        case .changed:
            pointer.dragged(to: p, modifiers: m)
        case .ended:
            pointer.up(at: p, modifiers: m)
        default:
            pointer.cancel()
            update(animated: true)
        }
    }

    @objc func panned(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed || g.state == .began else { return }
        if g.state == .began { touched() }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        pan(by: t)
    }

    /// Two fingers move the canvas.
    func pan(by t: CGPoint) {
        var c = camera
        c.offset = CGPoint(x: c.offset.x + t.x, y: c.offset.y + t.y)
        panCamera(to: c)
    }

    @objc func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed || g.state == .began else { return }
        if g.state == .began { touched() }
        zoom(by: g.scale, around: g.location(in: self))
        g.scale = 1
    }

    @objc func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: hover(at: g.location(in: self))
        default: hover(at: nil)
        }
    }

    /// The Pencil or pointer over the canvas (nil when it leaves): a topic's fold control shows.
    func hover(at p: CGPoint?) {
        if let p { pointer.updateFoldHover(p) } else { pointer.setFoldHover(nil) }
    }

    /// The topic showing its fold control under the hover.
    var foldHover: NodeID? { pointer.foldHover }

    /// A drag's drop target is showing: the halo for "as child", or the line before or after.
    var showsDropTarget: Bool { !pointer.dropIndicator.isHidden }

    // MARK: Context menus (M17)

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard controller.mode != .edit, let target = pointer.menuTarget(at: location) else { return nil }
        // A long press on something selects it first, as a right-click does (D176).
        controller.prepareContextMenu(target)
        let entries = controller.contextMenu(for: target)
        guard !entries.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: self.menuElements(entries))
        }
    }

    /// Menu entries as UIKit's: commands run as the keyboard would run them; other items
    /// (Add Floating Topic here, Paste here, Edit Label…) through the controller.
    func menuElements(_ entries: [CanvasMenuEntry]) -> [UIMenuElement] {
        TouchMenus.elements(entries) { [weak self] in self?.runMenuAction($0) }
    }

    func runMenuAction(_ action: CanvasMenuAction) {
        if case .command(let id) = action {
            controller.noteMouseUse(id)
            if !controller.perform(id) { _ = onWindowCommand?(id) }
        } else {
            _ = controller.runMenuAction(action)
        }
    }

    /// A touch on the canvas: the keyboard no longer drives it, so a parked editor hands
    /// the focus back (the on-screen keyboard only shows for an edit).
    func touched() {
        keyboardDriven = false
        if editor.isParked { _ = becomeFirstResponder() }
    }

    // MARK: Keyboard

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keyboardDriven = true
        guard let key = presses.first?.key, let chord = KeyChord(key: key) else {
            super.pressesBegan(presses, with: event)
            return
        }
        // A special key's characters are its name ("UIKeyInputEscape"), never text to type.
        let typed = key.characters.hasPrefix("UIKeyInput") ? nil : key.characters
        if !handle(chord, characters: typed) { super.pressesBegan(presses, with: event) }
    }

    /// A chord as the Mac's `keyDown` handles it. False when nothing took it.
    @discardableResult
    func handle(_ chord: KeyChord, characters: String?) -> Bool {
        let chord = chord.escapeAlias
        switch controller.handleKey(chord, characters: characters) {
        case .handled:
            return true
        case .beginTyping:
            pendingTyping = characters
            if controller.typingAppends {
                controller.beginEditing()
            } else {
                controller.beginEditing(replacingWith: "")
            }
            return true
        case .ignored:
            if let id = controller.command(for: chord), onWindowCommand?(id) == true { return true }
            return false
        }
    }

    /// Every registered command with a key, for the ⌘-hold list and the menu bar (D390).
    /// They run through `handle`, as the keys would. While a topic is being edited the
    /// editor takes the keys itself.
    public override var keyCommands: [UIKeyCommand]? {
        guard controller.mode != .edit else { return [] }
        return Self.keyCommands(for: controller, action: #selector(runKeyCommand(_:)))
    }

    /// Every registered command's chords as `UIKeyCommand`s (A7), each calling `action`
    /// with the chord's spec as its property list.
    static func keyCommands(for controller: CanvasController, action: Selector) -> [UIKeyCommand] {
        var out: [UIKeyCommand] = []
        var seen = Set<KeyChord>()
        for c in controller.registry.commands {
            for chord in controller.bindings(for: c.id) where seen.insert(chord).inserted {
                guard let input = chord.key.keyCommandInput else { continue }
                let k = UIKeyCommand(
                    title: Loc.t(c.title), action: action, input: input,
                    modifierFlags: chord.modifiers.keyModifierFlags, propertyList: chord.spec)
                k.wantsPriorityOverSystemBehavior = true
                // Only the first binding is listed; the others still work.
                if chord != controller.bindings(for: c.id).first { k.attributes = .hidden }
                out.append(k)
            }
        }
        return out
    }

    @objc func runKeyCommand(_ sender: UIKeyCommand) {
        keyboardDriven = true
        guard let spec = sender.propertyList as? String, let chord = KeyChord(spec) else { return }
        handle(chord, characters: sender.input)
    }
}

/// `CanvasPointer.EmptyDrag.none`, spelled so it isn't read as Optional's `none`.
let PointerSurfaceEmptyDrag = CanvasPointer.EmptyDrag.self

extension Key {
    /// The `UIKeyCommand` input for this key, or nil for keys it can't name.
    var keyCommandInput: String? {
        switch self {
        case .character(let c): String(c).lowercased()
        case .tab: "\t"
        case .return: "\r"
        case .escape: UIKeyCommand.inputEscape
        case .space: " "
        case .delete: UIKeyCommand.inputDelete
        case .forwardDelete: nil
        case .up: UIKeyCommand.inputUpArrow
        case .down: UIKeyCommand.inputDownArrow
        case .left: UIKeyCommand.inputLeftArrow
        case .right: UIKeyCommand.inputRightArrow
        case .home: UIKeyCommand.inputHome
        case .end: UIKeyCommand.inputEnd
        case .pageUp: UIKeyCommand.inputPageUp
        case .pageDown: UIKeyCommand.inputPageDown
        case .function(let n): (1...12).contains(n) ? "UIKeyInputF\(n)" : nil
        }
    }
}

extension KeyChord {
    /// ⌘. cancels as Esc does, as on the Mac (D406).
    var escapeAlias: KeyChord { self == KeyChord([.command], .character(".")) ? KeyChord([], .escape) : self }
}

extension Modifiers {
    var keyModifierFlags: UIKeyModifierFlags {
        var f: UIKeyModifierFlags = []
        if contains(.control) { f.insert(.control) }
        if contains(.option) { f.insert(.alternate) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.command) { f.insert(.command) }
        return f
    }
}

// MARK: Scribble

/// Writing with Apple Pencil over a topic starts editing it and writes there.
extension TouchCanvasView: @preconcurrency UIIndirectScribbleInteractionDelegate {
    public typealias ElementIdentifier = NodeID

    public func indirectScribbleInteraction(
        _ interaction: any UIInteraction, requestElementsIn rect: CGRect,
        completion: @escaping ([NodeID]) -> Void
    ) {
        let world = CGRect(
            origin: camera.toWorld(rect.origin),
            size: CGSize(width: rect.width / camera.zoom, height: rect.height / camera.zoom))
        completion(controller.scene.order.filter { controller.scene.nodes[$0]?.frame.rect.intersects(world) == true })
    }

    public func indirectScribbleInteraction(_ interaction: any UIInteraction, isElementFocused id: NodeID) -> Bool {
        controller.edit?.node == id && controller.edit?.element == nil
    }

    public func indirectScribbleInteraction(_ interaction: any UIInteraction, frameForElement id: NodeID) -> CGRect {
        viewRect(of: id) ?? .zero
    }

    public func indirectScribbleInteraction(
        _ interaction: any UIInteraction, focusElementIfNeeded id: NodeID, referencePoint: CGPoint,
        completion: @escaping ((any UIResponder & UITextInput)?) -> Void
    ) {
        if controller.edit?.node != id {
            controller.select(id)
            controller.beginEditing(id)
        }
        completion(editor.isHidden ? nil : editor)
    }
}
/// A canvas menu as UIKit's, shared by the canvas, the outline and the Gantt.
@MainActor
enum TouchMenus {
    static func elements(_ entries: [CanvasMenuEntry], run: @escaping @MainActor (CanvasMenuAction) -> Void)
        -> [UIMenuElement]
    {
        var out: [UIMenuElement] = []
        var group: [UIMenuElement] = []
        func flush() {
            if !group.isEmpty { out.append(UIMenu(options: .displayInline, children: group)) }
            group = []
        }
        for e in entries {
            switch e {
            case .separator: flush()
            case .submenu(let title, let children):
                group.append(UIMenu(title: title, children: elements(children, run: run)))
            case .item(let i):
                let action = UIAction(title: i.title, state: i.checked ? .on : .off) { _ in run(i.action) }
                if let chord = i.key { action.discoverabilityTitle = chord.glyphs }
                group.append(action)
            }
        }
        flush()
        return out
    }
}
#endif
