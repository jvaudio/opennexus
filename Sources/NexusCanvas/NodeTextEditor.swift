import AppKit
import NexusCore
import NexusKeys

/// The in-node text editor (Edit mode). Sits over the node, scaled with the camera, and
/// routes Return / Esc / Tab / ⇧Tab / ⌘↩ / ⇧↩ through the command registry. Keys are
/// never intercepted while an input method has marked text.
final class NodeTextView: NSTextView {
    weak var controller: CanvasController?
    /// Typing undo for this session only; model undo stays on the document.
    private let sessionUndo = UndoManager()
    private(set) var node: NodeID?

    convenience init() {
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(layoutManager)
        self.init(frame: .zero, textContainer: container)
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = false
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        usesFindBar = false
        setAccessibilityIdentifier("node-editor")
    }

    override var undoManager: UndoManager? { sessionUndo }

    func begin(_ session: EditSession, style: NodeTextStyle, color: NSColor) {
        node = session.node
        sessionUndo.removeAllActions()
        let attrs = style.attributes(color: color)
        typingAttributes = attrs
        defaultParagraphStyle = style.paragraphStyle
        insertionPointColor = color
        textStorage?.setAttributedString(NSAttributedString(string: session.text, attributes: attrs))
        if session.selectAll {
            setSelectedRange(NSRange(location: 0, length: (string as NSString).length))
        } else {
            setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
    }

    func end() {
        node = nil
        sessionUndo.removeAllActions()
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText(), let controller, let chord = KeyChord(event: event) else {
            super.keyDown(with: event)
            return
        }
        if let id = controller.command(for: chord) {
            if id == .lineBreak {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if controller.perform(id) { return }
        }
        super.keyDown(with: event)
    }

    /// Clicking elsewhere commits, as Return does.
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let controller, let node, controller.edit?.node == node {
            controller.commitEdit()
        }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        controller?.editorTextDidChange(string)
    }

    // Single-line commit behaviour for the standard editing selectors.
    override func insertNewline(_ sender: Any?) { controller?.perform(.commitEdit) }
    override func insertTab(_ sender: Any?) { controller?.perform(.commitAndAddChild) }
    override func insertBacktab(_ sender: Any?) { controller?.perform(.commitAndPromote) }
    override func cancelOperation(_ sender: Any?) { controller?.perform(.commitEdit) }
}
