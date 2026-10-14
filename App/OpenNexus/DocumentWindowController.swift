import AppKit

/// The document window. M1 replaces the placeholder content with the canvas.
final class DocumentWindowController: NSWindowController {
    convenience init(document: NexusDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        self.init(window: window)
    }
}
