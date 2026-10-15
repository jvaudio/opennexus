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
    private(set) var style: NodeTextStyle?
    private var baseColor: NSColor = .labelColor

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
        isRichText = true
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
        setAccessibilityLabel(Loc.t("Topic text"))
    }

    override var undoManager: UndoManager? { sessionUndo }

    func begin(_ session: EditSession, style: NodeTextStyle, color: NSColor) {
        node = session.node
        // The editor always shows source: LaTeX and code are typeset only when committed.
        var style = style
        style.format = nil
        self.style = style
        sessionUndo.removeAllActions()
        let attrs = style.attributes(color: color)
        typingAttributes = attrs
        defaultParagraphStyle = style.paragraphStyle
        insertionPointColor = color
        baseColor = color
        textStorage?.setAttributedString(style.attributed(session.text, marks: session.marks, color: color))
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
        if controller.handleEditorSlashKey(chord) || controller.handleSuggestionKey(chord) { return }
        if let id = controller.command(for: chord) {
            if id == .lineBreak {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if id == .bold || id == .italic {
                toggleTrait(id == .bold ? .boldFontMask : .italicFontMask)
                return
            }
            if id == .editorLink {
                promptLink()
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
        controller?.editorTextDidChange(string, marks: currentMarks())
    }

    /// Keep pasted or typed text in the node's own style (plain text in, rich runs kept).
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    /// ⌘B / ⌘I on the selection (or the typing attributes when nothing is selected).
    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let storage = textStorage, let style else { return }
        let range = selectedRange()
        let fm = NSFontManager.shared
        // Marks only add emphasis on top of the topic's style; a topic that is already
        // bold (main topics) is restyled from the Format panel instead.
        guard !fm.traits(of: style.font).contains(trait) else {
            NSSound.beep()
            return
        }
        if range.length == 0 {
            let f = (typingAttributes[.font] as? NSFont) ?? style.font
            let has = fm.traits(of: f).contains(trait)
            typingAttributes[.font] = has ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { v, _, _ in
            if let f = v as? NSFont, !fm.traits(of: f).contains(trait) { allHave = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { v, r, _ in
            let f = (v as? NSFont) ?? style.font
            storage.addAttribute(
                .font, value: allHave ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait),
                range: r)
        }
        storage.endEditing()
        controller?.editorTextDidChange(string, marks: currentMarks())
    }

    /// ⌘K: link the selected text.
    func promptLink() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Link"
        alert.informativeText = "Web address for the selected text."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://"
        field.stringValue = (storage.attribute(.link, at: range.location, effectiveRange: nil) as? String) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: "Remove Link")
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal()
        if r == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            storage.addAttribute(.link, value: field.stringValue, range: range)
        } else if r == .alertSecondButtonReturn {
            storage.removeAttribute(.link, range: range)
        }
        controller?.editorTextDidChange(string, marks: currentMarks())
    }

    /// Rich-text runs relative to the node's base style.
    func currentMarks() -> [TextMark] {
        guard let storage = textStorage, let style else { return [] }
        let fm = NSFontManager.shared
        let baseTraits = fm.traits(of: style.font)
        var out: [TextMark] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, r, _ in
            let f = attrs[.font] as? NSFont
            let traits = f.map { fm.traits(of: $0) } ?? baseTraits
            let link: String? =
                switch attrs[.link] {
                case let s as String: s
                case let u as URL: u.absoluteString
                default: nil
                }
            var m = TextMark(start: r.location, length: r.length)
            m.bold = traits.contains(.boldFontMask) && !baseTraits.contains(.boldFontMask)
            m.italic = traits.contains(.italicFontMask) && !baseTraits.contains(.italicFontMask)
            m.underline = (attrs[.underlineStyle] as? Int ?? 0) != 0 && link == nil && !style.underline
            m.strikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0 && !style.strikethrough
            m.link = link
            if !m.isPlain { out.append(m) }
        }
        return out
    }

    // Single-line commit behaviour for the standard editing selectors.
    override func insertNewline(_ sender: Any?) { controller?.perform(.commitEdit) }
    override func insertTab(_ sender: Any?) { controller?.perform(.commitAndAddChild) }
    override func insertBacktab(_ sender: Any?) { controller?.perform(.commitAndPromote) }
    override func cancelOperation(_ sender: Any?) { controller?.perform(.commitEdit) }
}
