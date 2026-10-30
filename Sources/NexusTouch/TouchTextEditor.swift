#if os(iOS)
import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import UIKit

/// The in-topic text editor on the iPad (Edit mode), as `NodeTextView` is on the Mac: it
/// sits over the topic, scaled with the camera, and routes Return, Esc, Tab, ⇧Tab, ⌘↩,
/// ⇧↩, ⌘B, ⌘I and ⌘K through the command registry. Keys are never intercepted while an
/// input method has marked text.
final class TouchTextEditor: UITextView, UITextViewDelegate {
    weak var controller: CanvasController?
    private(set) var node: NodeID?
    private(set) var style: NodeTextStyle?
    private var baseColor: UIColor = .label
    /// Set while the editor commits or cancels itself, so resigning doesn't commit twice.
    private var ending = false
    /// The canvas: while the editor is parked (first responder between edits, D394) its
    /// keys and edit actions go there.
    weak var keyTarget: UIResponder?
    var isParked: Bool { node == nil && keyTarget != nil && isFirstResponder }
    /// Return and Tab pressed on a hardware keyboard, waiting for the "\n" or "\t" the keyboard
    /// inserts (D403).
    private var pendingKeys: [(text: String, id: CommandID)] = []
    /// Set while ⇧↩ (or its rebinding) inserts a line break, which isn't Return's commit.
    private var insertingLineBreak = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        clipsToBounds = false
        smartInsertDeleteType = .no
        smartQuotesType = .no
        smartDashesType = .no
        autocapitalizationType = .sentences
        delegate = self
        accessibilityIdentifier = "node-editor"
        accessibilityLabel = Loc.t("Topic text")
        installShortcutsBar()
    }

    /// The on-screen keyboard has no Tab: its shortcuts bar adds a child or a sibling, as
    /// Tab and Return do (the same registry commands), so a map can be built by touch (D397).
    /// When the bar is short of room (a hardware keyboard's floating bar showing predictions),
    /// the two collapse into one "+" with both in its menu.
    private func installShortcutsBar() {
        let actions = [
            ("arrow.turn.down.right", Loc.t("Add child topic"), true),
            ("arrow.down.to.line", Loc.t("Add sibling topic"), false),
        ].map { symbol, label, child in
            UIAction(title: label, image: UIImage(systemName: symbol)) { [weak self] _ in self?.addTopic(child: child) }
        }
        let items = actions.map { a in
            let b = UIBarButtonItem(image: a.image, primaryAction: a)
            b.accessibilityLabel = a.title
            return b
        }
        let collapsed = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: actions))
        collapsed.accessibilityLabel = Loc.t("Add topic")
        inputAssistantItem.trailingBarButtonGroups = [
            UIBarButtonItemGroup(barButtonItems: items, representativeItem: collapsed)
        ]
        // The iPhone's keyboard has no shortcuts bar, and it covers the bottom toolbar: the
        // two ride above it instead, with Done to commit and put the keyboard away (M47c, D416).
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let done = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in _ = self?.resignFirstResponder() })
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items =
            actions.map { a in
                let b = UIBarButtonItem(image: a.image, primaryAction: a)
                b.accessibilityLabel = a.title
                return b
            } + [.flexibleSpace(), done]
        bar.sizeToFit()
        inputAccessoryView = bar
    }

    /// The shortcuts bar: while editing, Tab (commit and add a child) or Return then Return
    /// (commit, then add a sibling); while parked, the canvas's Tab or Return.
    func addTopic(child: Bool) {
        if child {
            if !perform(.commitAndAddChild) { controller?.perform(.addChild) }
        } else {
            perform(.commitEdit)
            controller?.perform(.addSiblingAfter)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// ⇧↩ (a constant, so the string catalog's scan doesn't take it for UI text).
    static let lineBreak = "\n"

    func begin(_ session: EditSession, style: NodeTextStyle, color: UIColor) {
        quiet?.cancel()
        quiet = nil
        node = session.node
        pendingKeys = []
        // The editor always shows source: LaTeX and code are typeset only when committed.
        var style = style
        style.format = nil
        self.style = style
        baseColor = color
        typingAttributes = style.uiAttributes(color: color)
        tintColor = color
        attributedText = style.uiAttributed(session.text, marks: session.marks, color: color)
        typingAttributes = style.uiAttributes(color: color)
        let length = (text as NSString).length
        selectedRange = session.selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        undoManager?.removeAllActions()
    }

    func end() {
        node = nil
        pendingKeys = []
        undoManager?.removeAllActions()
        // Parked, it predicts nothing, so the keyboard's bar shows no empty suggestions; but
        // only once typing pauses. Switching reloads the keyboard's input views, which in a
        // run of new topics would cost each one ~60 ms (D394).
        quiet?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.node == nil else { return }
            self.setChecking(spelling: false, autocorrect: false)
        }
        quiet = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Turns spelling and predictions off once the editor has been parked a moment.
    private var quiet: DispatchWorkItem?

    /// Settings › General › Writing (smart quotes stay off inside code).
    func applyWriting(spelling: Bool, autocorrect: Bool, smartQuotes: Bool) {
        smartQuotesType = smartQuotes ? .yes : .no
        smartDashesType = smartQuotes ? .yes : .no
        setChecking(spelling: spelling, autocorrect: autocorrect)
    }

    private func setChecking(spelling: Bool, autocorrect: Bool) {
        let s: UITextSpellCheckingType = spelling ? .yes : .no
        let a: UITextAutocorrectionType = autocorrect ? .yes : .no
        guard s != spellCheckingType || a != autocorrectionType else { return }
        spellCheckingType = s
        autocorrectionType = a
        inlinePredictionType = autocorrect ? .default : .no
        if isFirstResponder { reloadInputViews() }
    }

    // MARK: Keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isParked {
            keyTarget?.pressesBegan(presses, with: event)
            return
        }
        guard markedTextRange == nil, let controller, let key = presses.first?.key,
            let chord = KeyChord(key: key)?.escapeAlias
        else {
            super.pressesBegan(presses, with: event)
            return
        }
        if controller.handleEditorSlashKey(chord) || controller.handleSuggestionKey(chord) { return }
        if let id = controller.command(for: chord) {
            // The keyboard inserts typed text a moment after the keys go down, so Return or
            // Tab run from here could end the edit before the last letters arrive. They go to
            // the keyboard too, and run when their "\n" or "\t" is inserted, in order (D403).
            if let text = Self.insertedText(chord) {
                pendingKeys.append((text, id))
                super.pressesBegan(presses, with: event)
                return
            }
            switch id {
            case .lineBreak:
                insertingLineBreak = true
                insertText(Self.lineBreak)
                insertingLineBreak = false
                return
            case .bold, .italic:
                toggleTrait(id == .bold ? .traitBold : .traitItalic)
                return
            case .undo, .redo:
                // While editing, ⌘Z and ⇧⌘Z undo the typing, as in the Mac's field editor.
                if id == .undo { undoManager?.undo() } else { undoManager?.redo() }
                return
            case .editorLink:
                promptLink()
                return
            default:
                if perform(id) { return }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !isParked { super.pressesEnded(presses, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !isParked { super.pressesChanged(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !isParked { super.pressesCancelled(presses, with: event) }
    }

    /// Parked, copy, paste, undo and the rest are the canvas's.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        isParked ? false : super.canPerformAction(action, withSender: sender)
    }

    /// Runs a registry command that ends the edit without committing twice on resign.
    @discardableResult
    func perform(_ id: CommandID) -> Bool {
        ending = true
        defer { ending = false }
        return controller?.perform(id) ?? false
    }

    /// Return and Tab, from either keyboard, run their commands once the keyboard inserts
    /// them; ⇧↩ inserts its line break.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n" || text == "\t", markedTextRange == nil, !insertingLineBreak else { return true }
        let id: CommandID?
        if let i = pendingKeys.firstIndex(where: { $0.text == text }) {
            id = pendingKeys.remove(at: i).id
        } else {
            // The on-screen keyboard's Return and Tab, as the hardware keys.
            id = controller?.command(for: KeyChord([], text == "\n" ? .return : .tab))
        }
        guard let id, id != .lineBreak else { return true }
        perform(id)
        return false
    }

    /// What the keyboard inserts for `chord`, when its command waits for it: Return (⇧↩
    /// too) and Tab.
    static func insertedText(_ chord: KeyChord) -> String? {
        switch chord.key {
        case .return where chord.modifiers.isEmpty || chord.modifiers == [.shift]: "\n"
        case .tab where chord.modifiers.isEmpty: "\t"
        default: nil
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        controller?.editorTextDidChange(text, marks: currentMarks())
    }

    /// Tapping elsewhere commits, as Return does.
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, !ending, let controller, let node, controller.edit?.node == node {
            controller.commitEdit()
        }
        return ok
    }

    /// Keep pasted text in the topic's own style (plain text in, rich runs kept).
    override func paste(_ sender: Any?) {
        guard let s = UIPasteboard.general.string else { return }
        insertText(s)
    }

    // MARK: Emphasis and links

    static func traits(_ f: UIFont) -> UIFontDescriptor.SymbolicTraits { f.fontDescriptor.symbolicTraits }

    static func converting(_ f: UIFont, _ trait: UIFontDescriptor.SymbolicTraits, on: Bool) -> UIFont {
        var t = traits(f)
        if on { t.insert(trait) } else { t.remove(trait) }
        guard let d = f.fontDescriptor.withSymbolicTraits(t) else { return f }
        return UIFont(descriptor: d, size: f.pointSize)
    }

    /// ⌘B / ⌘I on the selection (or the typing attributes when nothing is selected).
    func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let style else { return }
        let storage = textStorage
        let range = selectedRange
        // Marks only add emphasis on top of the topic's style; a topic that is already
        // bold (main topics) is restyled from the Format panel instead.
        guard !Self.traits(style.uiFont).contains(trait) else { return }
        if range.length == 0 {
            let f = (typingAttributes[.font] as? UIFont) ?? style.uiFont
            typingAttributes[.font] = Self.converting(f, trait, on: !Self.traits(f).contains(trait))
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { v, _, _ in
            if let f = v as? UIFont, !Self.traits(f).contains(trait) { allHave = false }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { v, r, _ in
            let f = (v as? UIFont) ?? style.uiFont
            storage.addAttribute(.font, value: Self.converting(f, trait, on: !allHave), range: r)
        }
        storage.endEditing()
        controller?.editorTextDidChange(text, marks: currentMarks())
    }

    /// ⌘K: link the selected text.
    func promptLink() {
        let range = selectedRange
        guard range.length > 0, let presenter = window?.rootViewController?.topmost else { return }
        let alert = UIAlertController(
            title: Loc.t("Link"), message: Loc.t("Web address for the selected text."), preferredStyle: .alert)
        alert.addTextField { [weak self] f in
            f.placeholder = "https://"
            f.keyboardType = .URL
            f.text = self?.textStorage.attribute(.link, at: range.location, effectiveRange: nil) as? String
        }
        alert.addAction(
            UIAlertAction(title: Loc.t("Link"), style: .default) { [weak self, weak alert] _ in
                guard let self, let s = alert?.textFields?.first?.text, !s.isEmpty else { return }
                self.textStorage.addAttribute(.link, value: s, range: range)
                self.controller?.editorTextDidChange(self.text, marks: self.currentMarks())
            })
        alert.addAction(
            UIAlertAction(title: Loc.t("Remove Link"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.textStorage.removeAttribute(.link, range: range)
                self.controller?.editorTextDidChange(self.text, marks: self.currentMarks())
            })
        alert.addAction(UIAlertAction(title: Loc.t("Cancel"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// Rich-text runs relative to the topic's base style.
    func currentMarks() -> [TextMark] {
        guard let style else { return [] }
        let baseTraits = Self.traits(style.uiFont)
        var out: [TextMark] = []
        let storage = textStorage
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, r, _ in
            let traits = (attrs[.font] as? UIFont).map(Self.traits) ?? baseTraits
            let link: String? =
                switch attrs[.link] {
                case let s as String: s
                case let u as URL: u.absoluteString
                default: nil
                }
            var m = TextMark(start: r.location, length: r.length)
            m.bold = traits.contains(.traitBold) && !baseTraits.contains(.traitBold)
            m.italic = traits.contains(.traitItalic) && !baseTraits.contains(.traitItalic)
            m.underline = (attrs[.underlineStyle] as? Int ?? 0) != 0 && link == nil && !style.underline
            m.strikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0 && !style.strikethrough
            m.link = link
            if !m.isPlain { out.append(m) }
        }
        return out
    }
}

extension UIViewController {
    /// The view controller showing on top of this one.
    var topmost: UIViewController { presentedViewController?.topmost ?? self }
}
#endif
