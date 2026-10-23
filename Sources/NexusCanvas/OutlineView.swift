import AppKit
import NexusCore
import NexusKeys
import NexusTheme
import SwiftUI

/// Outline view (⌘2, and the left pane of Split ⌘3; artboard 26). Drawn from the same
/// tree and driven by the same controller, so selection and typing are live-linked with
/// the canvas. Keys use the Outline scope: ↩ sibling, ⇥ indent, ⇧⇥ outdent, ⌥⌘↑↓ reorder.
@MainActor
public final class OutlineView: NSView {
    let scroll = NSScrollView()
    let document: OutlineDocumentView
    let hints: NSHostingView<OutlineHints>

    public init(controller: CanvasController) {
        document = OutlineDocumentView(controller: controller)
        hints = NSHostingView(rootView: OutlineHints())
        super.init(frame: .zero)
        wantsLayer = true
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        hints.translatesAutoresizingMaskIntoConstraints = false
        hints.sizingOptions = [.intrinsicContentSize]
        addSubview(scroll)
        addSubview(hints)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            hints.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            hints.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
        setAccessibilityRole(.outline)
        setAccessibilityLabel(Loc.t("Outline"))
        syncAppearance(controller)
    }

    /// The outline matches the canvas theme's light or dark appearance.
    private func syncAppearance(_ controller: CanvasController) {
        let dark = withObservationTracking {
            controller.theme.isDark
        } onChange: { [weak self, weak controller] in
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                self.syncAppearance(controller)
            }
        }
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        document.needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Gives the outline keyboard focus.
    public func focus() { window?.makeFirstResponder(document) }

    public override func layout() {
        super.layout()
        document.relayout(width: scroll.contentSize.width)
    }
}

struct OutlineHints: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([("↩", "sibling"), ("⇥", "indent"), ("⇧⇥", "outdent"), ("⌥⌘↑↓", "reorder")], id: \.0) { k, v in
                HStack(spacing: 5) {
                    Keycap(text: k)
                    Text(v).foregroundStyle(.secondary)
                }
            }
            Text("Notes edit inline").foregroundStyle(.secondary)
        }
        .font(.chrome(12.5))
    }
}

@MainActor
final class OutlineDocumentView: NSView, NSTextViewDelegate, ContextMenuTarget, NSMenuItemValidation {
    let controller: CanvasController
    let editor = NodeTextView()
    let noteEditor = NSTextView()
    private var noteNode: NodeID?
    private var pendingTypingEvent: NSEvent?

    struct Row {
        enum Kind { case title, topic, note, link, folded }
        var id: NodeID
        var kind: Kind
        var depth: Int
        var rect: CGRect
        var textRect: CGRect
        var text: NSAttributedString
    }
    private(set) var rows: [Row] = []
    private var width: CGFloat = 600

    init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        editor.controller = controller
        editor.isHidden = true
        addSubview(editor)
        noteEditor.isHidden = true
        noteEditor.isRichText = false
        noteEditor.font = .systemFont(ofSize: 14.5)
        noteEditor.textColor = .secondaryLabelColor
        noteEditor.drawsBackground = false
        noteEditor.delegate = self
        noteEditor.textContainerInset = .zero
        noteEditor.textContainer?.lineFragmentPadding = 0
        addSubview(noteEditor)
        controller.onOutlineEditChange = { [weak self] s in self?.editChanged(s) }
        controller.outlineAnchor = { [weak self] id in self?.popoverAnchor(id) }
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        controller.outlineFocused = true
        needsDisplay = true
        return true
    }

    /// Re-render whenever the document, selection or edit text changes.
    private func observe() {
        withObservationTracking {
            _ = controller.store.revision
            _ = controller.selection
            _ = controller.edit?.text
            _ = controller.canvasID
            _ = controller.mode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.relayout(width: self.width)
                self.observe()
            }
        }
    }

    // MARK: Layout

    static let left: CGFloat = 56
    static let indent: CGFloat = 32

    func font(_ depth: Int) -> NSFont {
        depth == 0
            ? (NSFont.systemFont(ofSize: 34, weight: .bold).fontDescriptor.withDesign(.serif).flatMap {
                NSFont(descriptor: $0, size: 34)
            } ?? .systemFont(ofSize: 34, weight: .bold))
            : depth == 1 ? .systemFont(ofSize: 17, weight: .semibold) : .systemFont(ofSize: 16)
    }

    func relayout(width w: CGFloat) {
        width = max(w, 300)
        let c = controller.canvas
        let mains = c.nodes[c.root]?.children ?? []
        let parents = c.parentMap()
        var out: [Row] = []
        var y: CGFloat = 40
        let ink = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        for id in controller.outlineOrder {
            guard let n = c.nodes[id] else { continue }
            let depth = id == c.root ? 0 : max(1, c.path(to: id, parents: parents).count)
            let x = depth == 0 ? 56 : Self.left + 40 + CGFloat(depth - 1) * Self.indent
            let maxW = width - x - 56
            let a = NSAttributedString(
                string: n.text.isEmpty ? " " : n.text, attributes: [.font: font(depth), .foregroundColor: ink])
            let h = ceil(
                a.boundingRect(with: CGSize(width: maxW, height: 10_000), options: [.usesLineFragmentOrigin]).height)
            let textRect = CGRect(x: x, y: y + 8, width: maxW, height: h)
            out.append(
                Row(
                    id: id, kind: depth == 0 ? .title : .topic, depth: depth,
                    rect: CGRect(x: x - 36, y: y, width: width - x - 20, height: h + 16), textRect: textRect, text: a))
            y += h + 16
            func line(_ s: String, _ kind: Row.Kind) {
                let la = NSAttributedString(
                    string: s, attributes: [.font: NSFont.systemFont(ofSize: 14.5), .foregroundColor: secondary])
                let lh = ceil(
                    la.boundingRect(with: CGSize(width: maxW, height: 10_000), options: [.usesLineFragmentOrigin])
                        .height)
                out.append(
                    Row(
                        id: id, kind: kind, depth: depth,
                        rect: CGRect(x: x - 36, y: y - 8, width: width - x - 20, height: lh + 8),
                        textRect: CGRect(x: x, y: y - 6, width: maxW, height: lh), text: la))
                y += lh + 6
            }
            if let note = n.note?.text, !note.isEmpty || noteNode == id { line(Loc.f("Note · %@", note), .note) }
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
            _ = mains
        }
        rows = out
        let height = max(y + 120, superview?.bounds.height ?? 0)
        if frame.size != CGSize(width: width, height: height) { setFrameSize(CGSize(width: width, height: height)) }
        positionEditors()
        needsDisplay = true
        setAccessibilityChildren(nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let c = controller.canvas
        let mains = c.nodes[c.root]?.children ?? []
        let parents = c.parentMap()
        let palette = controller.theme.palette
        let selected = Set(controller.selection.nodes)
        // Selection: the topic row and its note in one rounded box.
        for id in selected {
            let mine = rows.filter { $0.id == id && $0.kind != .title }
            guard let first = mine.first else { continue }
            let box = mine.reduce(first.rect) { $0.union($1.rect) }.insetBy(dx: 0, dy: -2)
            let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(controller.outlineFocused ? 1 : 0.5).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        for r in rows {
            if r.kind == .topic {
                let main = c.mainBranch(of: r.id, parents: parents)
                let color =
                    main.flatMap { mains.firstIndex(of: $0) }.map { palette[$0 % palette.count] }
                    ?? controller.theme.ink2
                let d: CGFloat = r.depth == 1 ? 9 : 6
                let cy = r.textRect.minY + font(r.depth).ascender / 2 + 4
                NSColor(cgColor: color.cgColor)?.setFill()
                NSBezierPath(
                    ovalIn: CGRect(x: r.textRect.minX - (r.depth == 1 ? 22 : 18), y: cy - d / 2, width: d, height: d)
                )
                .fill()
            }
            if r.kind == .title && controller.mode == .edit && controller.edit?.node == r.id
                && controller.outlineFocused
            {
                continue
            }
            if r.kind == .topic && controller.mode == .edit && controller.edit?.node == r.id
                && controller.outlineFocused
                && controller.edit?.element == nil
            {
                continue
            }
            if r.kind == .note && noteNode == r.id { continue }
            r.text.draw(with: r.textRect, options: [.usesLineFragmentOrigin])
        }
    }

    // MARK: Editing

    private func editChanged(_ session: EditSession?) {
        // A new topic's row may not exist yet: lay out before looking for it.
        relayout(width: width)
        guard let session,
            let row = rows.first(where: { $0.id == session.node && ($0.kind == .topic || $0.kind == .title) })
        else {
            if !editor.isHidden {
                editor.end()
                editor.isHidden = true
                if window?.firstResponder === editor { window?.makeFirstResponder(self) }
            }
            if controller.mode == .select, controller.outlineFocused, window?.firstResponder !== self {
                window?.makeFirstResponder(self)
            }
            needsDisplay = true
            return
        }
        var style = NodeTextStyle(typography: NodeTypography.for(.sub), monospaced: false)
        style.fontSize = Double(font(row.depth).pointSize)
        style.weight = row.depth == 0 ? .bold : row.depth == 1 ? .semibold : .regular
        style.family = row.depth == 0 ? "serif" : "system"
        style.align = "leading"
        style.lineHeight = Double(ceil(font(row.depth).ascender - font(row.depth).descender + 4))
        style.maxWidth = Double(row.textRect.width)
        editor.begin(session, style: style, color: .labelColor)
        editor.isHidden = false
        positionEditors()
        window?.makeFirstResponder(editor)
        if let e = pendingTypingEvent {
            pendingTypingEvent = nil
            editor.keyDown(with: e)
        } else if let input = session.pendingInput {
            editor.insertText(input, replacementRange: editor.selectedRange())
        }
        needsDisplay = true
    }

    private func positionEditors() {
        if let e = controller.edit, controller.outlineFocused, e.element == nil,
            let row = rows.first(where: { $0.id == e.node && ($0.kind == .topic || $0.kind == .title) })
        {
            let f = row.textRect.insetBy(dx: -1, dy: -2)
            if editor.frame != f { editor.frame = f }
            editor.textContainer?.size = CGSize(width: f.width, height: .greatestFiniteMagnitude)
        }
        if let n = noteNode, let row = rows.first(where: { $0.id == n && $0.kind == .note }) {
            noteEditor.frame = row.textRect.insetBy(dx: -1, dy: -1).offsetBy(dx: 0, dy: 0)
        }
    }

    /// Notes edit inline: click the note line; Esc or ⌘↩ commits.
    func beginNote(_ id: NodeID) {
        noteNode = id
        noteEditor.string = controller.canvas.nodes[id]?.note?.text ?? ""
        noteEditor.isHidden = false
        relayout(width: width)
        window?.makeFirstResponder(noteEditor)
    }

    func commitNote() {
        guard let id = noteNode else { return }
        let text = noteEditor.string
        noteNode = nil
        noteEditor.isHidden = true
        if text != controller.canvas.nodes[id]?.note?.text { controller.setNote(text, on: id) }
        window?.makeFirstResponder(self)
        relayout(width: width)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === noteEditor else { return false }
        if selector == #selector(cancelOperation(_:)) || selector == #selector(insertNewlineIgnoringFieldEditor(_:)) {
            commitNote()
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextView) === noteEditor, noteNode != nil { commitNote() }
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        guard let chord = KeyChord(event: event) else {
            super.keyDown(with: event)
            return
        }
        controller.outlineFocused = true
        switch controller.handleKey(chord, characters: event.characters) {
        case .handled: break
        case .beginTyping:
            pendingTypingEvent = event
            controller.beginEditing(replacingWith: "")
        case .ignored: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Control-click opens the context menu, as a right-click does.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .control,
            let menu = menu(for: event)
        {
            presentContextMenu(menu, event)
            return
        }
        window?.makeFirstResponder(self)
        if noteNode != nil { commitNote() }
        guard let row = rows.last(where: { $0.rect.contains(p) }) else { return }
        if row.kind == .note {
            controller.select(row.id)
            beginNote(row.id)
            return
        }
        if event.modifierFlags.contains(.shift) {
            var nodes = controller.selection.nodes
            if !nodes.contains(row.id) { nodes.append(row.id) }
            controller.setSelection(Selection(primary: row.id, nodes: nodes))
        } else {
            controller.select(row.id)
        }
        controller.onReveal?(row.id)
        if event.clickCount == 2 { controller.beginEditing(row.id) }
    }

    // MARK: Context menu (M26, D225)

    /// Shows a context menu at the pointer (tests record it instead: the real one runs a
    /// modal tracking loop).
    lazy var presentContextMenu: (NSMenu, NSEvent) -> Void = { [unowned self] menu, event in
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    /// Shows a row's menu below it (Show Menu); tests record it instead.
    lazy var popUpMenu: (NSMenu, CGPoint) -> Void = { [unowned self] menu, p in
        _ = menu.popUp(positioning: nil, at: p, in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { presentContextMenu(menu, event) }
    }

    /// The row under the pointer's menu: a topic's, or its note's, link's or fold line's.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let row = rows.last(where: { $0.rect.contains(p) }) else { return nil }
        return prepareMenu(row.id)
    }

    /// Selects the row as a click would (D176) and builds its menu.
    func prepareMenu(_ id: NodeID) -> NSMenu? {
        window?.makeFirstResponder(self)
        if noteNode != nil { commitNote() }
        controller.prepareRowMenu(id)
        let entries = controller.outlineContextMenu()
        return entries.isEmpty ? nil : ContextMenus.make(entries, target: self)
    }

    /// Show Menu on a row (VoiceOver), below the row's text.
    func showMenu(for id: NodeID) -> Bool {
        guard let row = rows.first(where: { $0.id == id && ($0.kind == .topic || $0.kind == .title) }),
            let menu = prepareMenu(id)
        else { return false }
        popUpMenu(menu, CGPoint(x: row.textRect.minX, y: row.rect.maxY))
        return true
    }

    /// The outline's own menu items run here; anything else (the menu bar's items, whose
    /// keys the outline scope reads differently) goes up the responder chain as before.
    func performRegistryCommand(_ sender: Any?) {
        guard (sender as? NSMenuItem)?.target === self else {
            ContextMenus.nextHandler(after: self)?.performRegistryCommand(sender)
            return
        }
        ContextMenus.performCommand(sender, controller: controller, from: self)
    }

    @objc func performMenuAction(_ sender: Any?) { ContextMenus.performAction(sender, controller: controller) }

    /// A topic's row as a popover's anchor (D254): its text, scrolled into view, while the
    /// outline is on screen. Nil when the outline is hidden or the row isn't shown (folded).
    func popoverAnchor(_ id: NodeID) -> (NSView, CGRect)? {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
        // The rows follow edits a turn later: lay out now, as the command may have just run.
        relayout(width: width)
        guard let r = rows.first(where: { $0.id == id && ($0.kind == .topic || $0.kind == .title) }) else {
            return nil
        }
        scrollToVisible(r.rect)
        let text = r.text.boundingRect(
            with: CGSize(width: r.textRect.width, height: 10_000), options: [.usesLineFragmentOrigin])
        let w = min(max(ceil(text.width), 1), r.textRect.width)
        return (self, CGRect(x: r.textRect.minX, y: r.textRect.minY, width: w, height: r.textRect.height))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.target === self else {
            return (ContextMenus.nextHandler(after: self) as? any NSMenuItemValidation)?.validateMenuItem(item) ?? false
        }
        return ContextMenus.validate(item, controller: controller, from: self)
    }

    // MARK: Accessibility

    /// Rows VoiceOver reads; Show Menu opens a row's menu (D226).
    override func accessibilityChildren() -> [Any]? {
        rows.filter { $0.kind == .topic || $0.kind == .title }.map { r in
            let e = MenuRowElement()
            e.setAccessibilityRole(.row)
            e.setAccessibilityLabel(r.text.string)
            e.setAccessibilityParent(self)
            if let w = window { e.setAccessibilityFrame(w.convertToScreen(convert(r.rect, to: nil))) }
            let id = r.id
            e.showMenu = { [weak self] in self?.showMenu(for: id) ?? false }
            e.customActions = { [weak self] in self?.rowActions(id) ?? [] }
            return e
        }
    }

    /// A row's custom actions (D256): a canvas topic's own (Edit, Add child, Add sibling,
    /// Comments, Fold or Unfold) where the row's menu offers them, then the rest of that
    /// menu, Insert and Export Branch flattened. Each selects its row first.
    func rowActions(_ id: NodeID) -> [NSAccessibilityCustomAction] {
        let entries = controller.outlineContextMenu(previewing: id)
        let offered = Set(entries.flatMap(\.items).compactMap(\.action.command))
        let folded = controller.canvas.nodes[id]?.folded ?? false
        let own: [(CommandID, String)] = [
            (.editKeepText, Loc.t("Edit")), (.addChild, Loc.t("Add child")), (.addSiblingAfter, Loc.t("Add sibling")),
            (.comment, Loc.t("Comments")), (.fold, folded ? Loc.t("Unfold") : Loc.t("Fold")),
        ]
        let run: @MainActor (CanvasMenuAction) -> Bool = { [weak self] action in
            self?.runRowAction(action, on: id) ?? false
        }
        let first = own.filter { offered.contains($0.0) }.map { command, name in
            NSAccessibilityCustomAction(name: name) { run(.command(command)) }
        }
        return first + ContextMenus.customActions(entries, skipping: TopicElement.ownActions, run: run)
    }

    /// Runs a row's item as its menu would, on that row alone, with the outline focused.
    func runRowAction(_ action: CanvasMenuAction, on id: NodeID) -> Bool {
        guard controller.canvas.nodes[id] != nil else { return false }
        window?.makeFirstResponder(self)
        if noteNode != nil { commitNote() }
        if controller.mode == .connect { controller.cancelConnect() }
        if controller.mode == .edit { controller.commitEdit() }
        controller.select(id)
        return ContextMenus.run(action, controller: controller, from: self)
    }

    /// Show Menu on the outline itself: the selected row's menu.
    override func accessibilityPerformShowMenu() -> Bool { showMenu(for: controller.selection.primary) }
}
