#if os(iOS)
import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import NexusTheme
import UIKit

/// The Outline (⌘2, and Split's left pane) on the iPad (M47b): the Mac's `OutlineView`
/// drawn in UIKit. The same rows from the same controller, so selection and typing are
/// live-linked with the canvas. Tap selects, double-tap edits, tapping a note edits it,
/// a long press opens the row's menu; a hardware keyboard uses the Outline scope.
@MainActor
public final class TouchOutlineView: UIScrollView, UITextViewDelegate {
    let controller: CanvasController
    let content = OutlineContent()
    let editor = TouchTextEditor()
    let noteEditor = UITextView()
    private var noteNode: NodeID?
    private var pendingTyping: String?

    struct Row {
        enum Kind { case title, topic, note, comments, link, folded }
        var id: NodeID
        var kind: Kind
        var depth: Int
        var rect: CGRect
        var textRect: CGRect
        var text: NSAttributedString
    }
    private(set) var rows: [Row] = []

    public init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        content.outline = self
        addSubview(content)
        editor.controller = controller
        editor.isHidden = true
        content.addSubview(editor)
        noteEditor.isHidden = true
        noteEditor.font = .preferredFont(forTextStyle: .callout)
        noteEditor.textColor = .secondaryLabel
        noteEditor.backgroundColor = .clear
        noteEditor.textContainerInset = .zero
        noteEditor.textContainer.lineFragmentPadding = 0
        noteEditor.delegate = self
        content.addSubview(noteEditor)
        accessibilityLabel = Loc.t("Outline")
        accessibilityIdentifier = "outline"
        controller.onOutlineEditChange = { [weak self] s in self?.editChanged(s) }

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        content.addGestureRecognizer(tap)
        content.addGestureRecognizer(double)
        content.addInteraction(UIContextMenuInteraction(delegate: content))
        observe()
        syncAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var canBecomeFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { controller.outlineFocused = true }
        content.setNeedsDisplay()
        return ok
    }

    /// The outline matches the canvas theme's light or dark appearance.
    private func syncAppearance() {
        let dark = withObservationTracking {
            controller.theme.isDark
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.syncAppearance() }
        }
        overrideUserInterfaceStyle = dark ? .dark : .light
        relayout()
    }

    /// Re-lays out whenever the document, selection or edit text changes.
    private func observe() {
        withObservationTracking {
            _ = controller.store.revision
            _ = controller.selection
            _ = controller.edit?.text
            _ = controller.canvasID
            _ = controller.mode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.relayout()
                self?.observe()
            }
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if content.bounds.width != bounds.width { relayout() }
    }

    // MARK: Layout

    /// The iPhone's margins (M47c): narrower, so a third level keeps most of the width, and
    /// the central topic a size smaller.
    public var compact = false {
        didSet { if compact != oldValue { relayout() } }
    }

    /// Where a row's text starts at `depth`, and the margin after it.
    func textX(_ depth: Int) -> CGFloat {
        if compact { return depth == 0 ? 16 : 44 + CGFloat(depth - 1) * 20 }
        return depth == 0 ? 56 : 96 + CGFloat(depth - 1) * 32
    }

    var trailing: CGFloat { compact ? 16 : 56 }

    /// Where a row's highlight ends.
    func rowRight(_ width: CGFloat) -> CGFloat { width - (compact ? 8 : 56) }

    func font(_ depth: Int) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: depth == 0 ? .largeTitle : .body)
        let size: CGFloat = compact ? 28 : 34
        let base: UIFont =
            depth == 0
            ? (UIFont.systemFont(ofSize: size, weight: .bold).fontDescriptor.withDesign(.serif).map {
                UIFont(descriptor: $0, size: size)
            } ?? .systemFont(ofSize: size, weight: .bold))
            : depth == 1 ? .systemFont(ofSize: 17, weight: .semibold) : .systemFont(ofSize: 16)
        return metrics.scaledFont(for: base)
    }

    var lineFont: UIFont { UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 14.5)) }

    func relayout() {
        let width = max(bounds.width, compact ? 240 : 300)
        let c = controller.canvas
        let parents = c.parentMap()
        var out: [Row] = []
        var y: CGFloat = compact ? 20 : 40
        func height(_ a: NSAttributedString, _ w: CGFloat) -> CGFloat {
            ceil(
                a.boundingRect(with: CGSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin], context: nil)
                    .height)
        }
        for id in controller.outlineOrder {
            guard let n = c.nodes[id] else { continue }
            let depth = id == c.root ? 0 : max(1, c.path(to: id, parents: parents).count)
            let x = textX(depth)
            let maxW = width - x - trailing
            let a = NSAttributedString(
                string: n.text.isEmpty ? " " : n.text,
                attributes: [.font: font(depth), .foregroundColor: UIColor.label])
            let h = height(a, maxW)
            out.append(
                Row(
                    id: id, kind: depth == 0 ? .title : .topic, depth: depth,
                    rect: CGRect(x: x - 36, y: y, width: rowRight(width) - x + 36, height: h + 16),
                    textRect: CGRect(x: x, y: y + 8, width: maxW, height: h), text: a))
            y += h + 16
            func line(_ s: String, _ kind: Row.Kind) {
                let la = NSAttributedString(
                    string: s, attributes: [.font: lineFont, .foregroundColor: UIColor.secondaryLabel])
                let lh = height(la, maxW)
                out.append(
                    Row(
                        id: id, kind: kind, depth: depth,
                        rect: CGRect(x: x - 36, y: y - 8, width: rowRight(width) - x + 36, height: lh + 8),
                        textRect: CGRect(x: x, y: y - 6, width: maxW, height: lh), text: la))
                y += lh + 6
            }
            if let note = n.note?.text, !note.isEmpty || noteNode == id { line(Loc.f("Note · %@", note), .note) }
            if let last = n.comments.last {
                // Reading and commenting (M47c): the thread's size and its latest comment;
                // tapping the line opens the thread.
                let latest = last.text.split(separator: "\n").first.map(String.init) ?? ""
                line(
                    Loc.n("%lld comment", "%lld comments", n.comments.count) + " · "
                        + (last.author.isEmpty ? latest : Loc.f("%@: %@", last.author, latest)), .comments)
            }
            for r in c.relationships where r.from == .topic(id) {
                let target = c.spokenName(r.to)
                line(
                    r.label.isEmpty
                        ? Loc.f("→ links to %@", target) : Loc.f("→ links to %@ (“%@”)", target, r.label), .link)
            }
            if n.folded, !n.children.isEmpty {
                let hidden = c.subtree(id).count - 1
                line(Loc.n("%lld hidden child · folded", "%lld hidden children · folded", hidden), .folded)
            }
            if depth == 0 { y += 10 }
        }
        rows = out
        let size = CGSize(width: width, height: max(y + 120, bounds.height))
        if content.frame.size != size { content.frame = CGRect(origin: .zero, size: size) }
        contentSize = size
        positionEditors()
        content.setNeedsDisplay()
        accessibilityRows = nil
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    // MARK: Drawing

    func drawRows() {
        let c = controller.canvas
        let mains = c.nodes[c.root]?.children ?? []
        let parents = c.parentMap()
        let palette = controller.theme.palette
        let tint = tintColor ?? .systemBlue
        // Selection: the topic row and its note in one rounded box.
        for id in Set(controller.selection.nodes) {
            let mine = rows.filter { $0.id == id && $0.kind != .title }
            guard let first = mine.first else { continue }
            let box = mine.reduce(first.rect) { $0.union($1.rect) }.insetBy(dx: 0, dy: -2)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 8)
            tint.withAlphaComponent(0.07).setFill()
            path.fill()
            tint.withAlphaComponent(controller.outlineFocused ? 1 : 0.5).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        let editing = controller.mode == .edit && controller.outlineFocused ? controller.edit : nil
        for r in rows {
            if r.kind == .topic {
                let main = c.mainBranch(of: r.id, parents: parents)
                let color =
                    main.flatMap { mains.firstIndex(of: $0) }.map { palette[$0 % palette.count] }
                    ?? controller.theme.ink2
                let d: CGFloat = r.depth == 1 ? 9 : 6
                let cy = r.textRect.minY + font(r.depth).ascender / 2 + 4
                UIColor(cgColor: color.cgColor).setFill()
                UIBezierPath(
                    ovalIn: CGRect(x: r.textRect.minX - (r.depth == 1 ? 22 : 18), y: cy - d / 2, width: d, height: d)
                )
                .fill()
            }
            if (r.kind == .title || r.kind == .topic), let e = editing, e.node == r.id, e.element == nil { continue }
            if r.kind == .note && noteNode == r.id { continue }
            r.text.draw(with: r.textRect, options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    // MARK: Editing

    private func editChanged(_ session: EditSession?) {
        // A new topic's row may not exist yet: lay out before looking for it.
        relayout()
        guard let session,
            let row = rows.first(where: { $0.id == session.node && ($0.kind == .topic || $0.kind == .title) })
        else {
            if !editor.isHidden {
                editor.end()
                editor.isHidden = true
            }
            if controller.mode == .select, controller.outlineFocused, !isFirstResponder { _ = becomeFirstResponder() }
            content.setNeedsDisplay()
            return
        }
        let f = font(row.depth)
        var style = NodeTextStyle(typography: NodeTypography.for(.sub), monospaced: false)
        style.fontSize = Double(f.pointSize)
        style.weight = row.depth == 0 ? .bold : row.depth == 1 ? .semibold : .regular
        style.family = row.depth == 0 ? "serif" : "system"
        style.align = "leading"
        style.lineHeight = Double(ceil(f.ascender - f.descender + 4))
        style.maxWidth = Double(row.textRect.width)
        editor.begin(session, style: style, color: .label)
        editor.isHidden = false
        positionEditors()
        _ = editor.becomeFirstResponder()
        if let typed = pendingTyping {
            pendingTyping = nil
            editor.insertText(typed)
        } else if let input = session.pendingInput {
            editor.insertText(input)
        }
        content.setNeedsDisplay()
    }

    private func positionEditors() {
        if let e = controller.edit, controller.outlineFocused, e.element == nil,
            let row = rows.first(where: { $0.id == e.node && ($0.kind == .topic || $0.kind == .title) })
        {
            let f = row.textRect.insetBy(dx: -1, dy: -2)
            if editor.frame != f { editor.frame = f }
            scrollRectToVisible(row.rect, animated: false)
        }
        if let n = noteNode, let row = rows.first(where: { $0.id == n && $0.kind == .note }) {
            noteEditor.frame = row.textRect.insetBy(dx: -1, dy: -1)
        }
    }

    /// Notes edit inline: tap the note line; Esc, Return or tapping elsewhere commits.
    func beginNote(_ id: NodeID) {
        noteNode = id
        noteEditor.text = controller.canvas.nodes[id]?.note?.text ?? ""
        noteEditor.isHidden = false
        relayout()
        _ = noteEditor.becomeFirstResponder()
    }

    func commitNote() {
        guard let id = noteNode else { return }
        let text = noteEditor.text ?? ""
        noteNode = nil
        noteEditor.isHidden = true
        if text != controller.canvas.nodes[id]?.note?.text { controller.setNote(text, on: id) }
        _ = becomeFirstResponder()
        relayout()
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        if textView === noteEditor, noteNode != nil { commitNote() }
    }

    // MARK: Input

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key, let chord = KeyChord(key: key) else {
            super.pressesBegan(presses, with: event)
            return
        }
        controller.outlineFocused = true
        switch controller.handleKey(chord, characters: key.characters) {
        case .handled: break
        case .beginTyping:
            pendingTyping = key.characters
            controller.beginEditing(replacingWith: "")
        case .ignored: super.pressesBegan(presses, with: event)
        }
    }

    /// The registry's commands as `UIKeyCommand`s while the outline has focus.
    public override var keyCommands: [UIKeyCommand]? {
        controller.mode == .edit
            ? [] : TouchCanvasView.keyCommands(for: controller, action: #selector(runKeyCommand(_:)))
    }

    @objc func runKeyCommand(_ sender: UIKeyCommand) {
        guard let spec = sender.propertyList as? String, let chord = KeyChord(spec) else { return }
        controller.outlineFocused = true
        _ = controller.handleKey(chord, characters: sender.input)
    }

    func row(at p: CGPoint) -> Row? { rows.last { $0.rect.contains(p) } }

    @objc func tapped(_ g: UITapGestureRecognizer) {
        tap(at: g.location(in: content), shift: g.modifierFlags.contains(.shift))
    }

    /// A tap at a point in the rows: selects the row, edits a note, opens comments.
    func tap(at p: CGPoint, shift: Bool = false) {
        _ = becomeFirstResponder()
        if noteNode != nil { commitNote() }
        if controller.mode == .edit { controller.commitEdit() }
        guard let row = row(at: p) else { return }
        if row.kind == .note {
            controller.select(row.id)
            beginNote(row.id)
            return
        }
        if row.kind == .comments {
            controller.outlineFocused = true
            controller.select(row.id)
            controller.perform(.comment)
            return
        }
        if shift {
            var nodes = controller.selection.nodes
            if !nodes.contains(row.id) { nodes.append(row.id) }
            controller.setSelection(Selection(primary: row.id, nodes: nodes))
        } else {
            controller.select(row.id)
        }
        controller.onReveal?(row.id)
    }

    @objc func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let row = row(at: g.location(in: content)), row.kind == .topic || row.kind == .title else { return }
        _ = becomeFirstResponder()
        controller.outlineFocused = true
        controller.select(row.id)
        controller.beginEditing(row.id)
    }

    /// Selects the row as a click would (D176) and builds its menu.
    func menu(at p: CGPoint) -> UIMenu? {
        guard controller.mode != .edit, let row = row(at: p) else { return nil }
        _ = becomeFirstResponder()
        if noteNode != nil { commitNote() }
        controller.prepareRowMenu(row.id)
        let entries = controller.outlineContextMenu()
        guard !entries.isEmpty else { return nil }
        return UIMenu(children: TouchMenus.elements(entries) { [weak self] in self?.run($0) })
    }

    func run(_ action: CanvasMenuAction) {
        controller.outlineFocused = true
        if case .command(let id) = action {
            controller.noteMouseUse(id)
            _ = controller.perform(id)
        } else {
            _ = controller.runMenuAction(action)
        }
    }

    /// A topic's row as a popover's anchor: its text, scrolled into view.
    public func anchor(of id: NodeID) -> CGRect? {
        guard window != nil, !isHidden else { return nil }
        relayout()
        guard let r = rows.first(where: { $0.id == id && ($0.kind == .topic || $0.kind == .title) }) else {
            return nil
        }
        scrollRectToVisible(r.rect, animated: false)
        return content.convert(r.textRect, to: self)
    }

    // MARK: Accessibility

    private var accessibilityRows: [UIAccessibilityElement]?

    /// Rows VoiceOver reads, each with its row's actions (D256).
    public override var accessibilityElements: [Any]? {
        get {
            if let accessibilityRows { return accessibilityRows + (editor.isHidden ? [] : [editor]) }
            // Every row: a topic, and the lines under it (M47c) — a note or the comments,
            // which a tap edits or opens, and a link or a folded count, which it reads.
            let made = rows.map { r in
                let e = UIAccessibilityElement(accessibilityContainer: self)
                e.accessibilityLabel = r.text.string
                switch r.kind {
                case .title, .topic:
                    e.accessibilityTraits = controller.selection.nodes.contains(r.id) ? [.button, .selected] : .button
                    e.accessibilityCustomActions = rowActions(r.id)
                case .note, .comments: e.accessibilityTraits = .button
                case .link, .folded: e.accessibilityTraits = .staticText
                }
                e.accessibilityFrameInContainerSpace = content.convert(r.rect, to: self)
                return e
            }
            accessibilityRows = made
            return made + (editor.isHidden ? [] : [editor])
        }
        set {}
    }

    /// A row's own actions (Edit, Add child, Add sibling, Comments, Fold) where its menu
    /// offers them, then the rest of that menu. Each selects its row first.
    func rowActions(_ id: NodeID) -> [UIAccessibilityCustomAction] {
        let entries = controller.outlineContextMenu(previewing: id)
        let offered = Set(entries.flatMap(\.items).compactMap(\.action.command))
        let folded = controller.canvas.nodes[id]?.folded ?? false
        let own: [(CommandID, String)] = [
            (.editKeepText, Loc.t("Edit")), (.addChild, Loc.t("Add child")), (.addSiblingAfter, Loc.t("Add sibling")),
            (.comment, Loc.t("Comments")), (.fold, folded ? Loc.t("Unfold") : Loc.t("Fold")),
        ]
        let run: (CanvasMenuAction) -> Bool = { [weak self] action in
            guard let self, self.controller.canvas.nodes[id] != nil else { return false }
            if self.controller.mode == .edit { self.controller.commitEdit() }
            self.controller.outlineFocused = true
            self.controller.select(id)
            self.run(action)
            return true
        }
        let first = own.filter { offered.contains($0.0) }.map { command, name in
            UIAccessibilityCustomAction(name: name) { _ in run(.command(command)) }
        }
        let ownIDs = Set(own.map(\.0))
        let rest = entries.flatMap(\.items).filter { item in
            item.action.command.map { !ownIDs.contains($0) } ?? true
        }
        return first + rest.map { item in UIAccessibilityCustomAction(name: item.title) { _ in run(item.action) } }
    }
}

/// The outline's drawn rows (inside the scroll view).
final class OutlineContent: UIView, UIContextMenuInteractionDelegate {
    weak var outline: TouchOutlineView?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) { outline?.drawRows() }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = outline?.menu(at: location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
#endif
