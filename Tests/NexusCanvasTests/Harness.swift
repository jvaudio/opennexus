import AppKit
import Carbon.HIToolbox
import NexusCore
import NexusKeys

@testable import NexusCanvas

/// A real canvas in an offscreen window, driven by synthesized key events through the
/// same `keyDown` path the app uses (minus the menu bar, so the registry fallback is
/// exercised too).
@MainActor
final class CanvasHarness {
    let store: DocumentStore
    let undo = StackUndoRegistrar()
    let controller: CanvasController
    let host: CanvasHostView
    let window: NSWindow

    init(model: DocumentModel = .blank(), width: CGFloat = 1440, height: CGFloat = 860) {
        store = DocumentStore(model: model)
        store.undoRegistrar = undo
        controller = CanvasController(store: store)
        host = CanvasHostView(controller: controller)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        host.canvasView.reduceMotionOverride = true
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.makeFirstResponder(host.canvasView)
    }

    var canvas: Canvas { controller.canvas }

    func text(_ id: NodeID) -> String { canvas.nodes[id]?.text ?? "∅" }

    /// Sends one chord, e.g. `"tab"`, `"shift+return"`, `"opt+cmd+up"`.
    func press(_ spec: String) {
        guard let chord = KeyChord(spec), let code = chord.keyCode else { fatalError("bad key \(spec)") }
        let chars: String =
            switch chord.key {
            case .character(let c): String(c)
            case .tab: "\t"
            case .return: "\r"
            case .escape: "\u{1B}"
            case .space: " "
            case .delete: "\u{7F}"
            case .up: "\u{F700}"
            case .down: "\u{F701}"
            case .left: "\u{F702}"
            case .right: "\u{F703}"
            default: ""
            }
        send(chars: chars, keyCode: code, flags: chord.eventModifierFlags)
    }

    /// Types printable text one key at a time.
    func type(_ text: String) {
        for ch in text {
            let s = String(ch)
            let lower = s.lowercased()
            let code = KeyChord.ansi.first { String($0.value) == lower }?.key ?? kVK_Space
            let flags: NSEvent.ModifierFlags = s != lower ? [.shift] : []
            send(chars: s, keyCode: UInt16(code), flags: flags)
        }
    }

    private func send(chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard
            let e = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)
        else { return }
        (window.firstResponder as? NSResponder ?? host.canvasView).keyDown(with: e)
    }

    /// Captures the window as the compositor draws it (for visual review). Shows the
    /// window briefly, lets Core Animation commit, then uses `screencapture`.
    func snapshot(to url: URL) {
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? p.run()
        p.waitUntilExit()
    }

    /// Renders the canvas layer tree offscreen (no window server needed), at `scale`.
    func renderOffscreen(scale: CGFloat = 1) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        let size = host.canvasView.bounds.size
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        let cg = ctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        // Offscreen, AppKit has not flipped the hosted layer tree; flip it so text and
        // shadows render as they do on screen, then flip the bitmap to match.
        let root = host.canvasView.sceneLayer
        root.isGeometryFlipped = true
        root.layoutIfNeeded()
        func redraw(_ l: CALayer) {
            if l is TextLayer { l.setNeedsDisplay(); l.displayIfNeeded() }
            l.sublayers?.forEach(redraw)
        }
        redraw(root)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        host.canvasView.sceneLayer.render(in: cg)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
