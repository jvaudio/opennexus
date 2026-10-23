import AppKit
import NexusCore
import NexusKeys

/// The Gantt view (⌘4): the canvas's tasks on a timeline, another view of the same model
/// (D146). It scrolls; the table and the date header stay pinned.
public final class GanttView: NSView {
    let controller: CanvasController
    public let scrollView = NSScrollView()
    let surface: GanttSurface

    public init(controller: CanvasController) {
        self.controller = controller
        surface = GanttSurface(controller: controller)
        super.init(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = surface
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityLabel(Loc.t("Gantt chart"))
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        controller.onGanttScroll = { [weak self] day in self?.scroll(to: day) }
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func scrolled() { surface.needsDisplay = true }

    /// Re-lays out when the document, selection or Gantt state changes.
    private func observe() {
        withObservationTracking {
            _ = controller.store.revision
            _ = controller.selection
            _ = controller.ganttCollapsed
            _ = controller.ganttScale
            _ = controller.canvasID
            _ = controller.scene
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.isHidden { self.surface.reload() }
                self.observe()
            }
        }
    }

    public override var isHidden: Bool {
        didSet {
            if !isHidden {
                surface.reload()
                if !surface.didScrollOnce {
                    surface.didScrollOnce = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.scroll(to: self.surface.layout?.schedule.range?.start ?? self.controller.todayDate)
                    }
                }
            }
        }
    }

    public func focus() { window?.makeFirstResponder(surface) }

    func scroll(to day: TaskDate) {
        guard let L = surface.layout else { return }
        let x = max(0, L.x(for: day) - L.tableWidth - 60)
        scrollView.contentView.scroll(to: CGPoint(x: x, y: scrollView.contentView.bounds.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Keeps the selected row in view.
    func reveal(_ id: NodeID) {
        guard let r = surface.layout?.rows.first(where: { $0.id == id }) else { return }
        let vis = scrollView.contentView.bounds
        var target = r.frame
        target.origin.x = vis.minX
        target.size.width = 1
        target.origin.y -= GanttLayout.headerHeight
        target.size.height += GanttLayout.headerHeight
        surface.scrollToVisible(target)
    }
}

/// The drawn and interactive surface inside the Gantt's scroll view.
final class GanttSurface: NSView, ContextMenuTarget, NSMenuItemValidation {
    let controller: CanvasController
    private(set) var layout: GanttLayout?
    var didScrollOnce = false
    private var drag: Drag?
    private var lastPrimary: NodeID?

    struct Drag {
        enum Kind { case move, start, finish, progress, link }
        var kind: Kind
        var id: NodeID
        var origin: CGPoint
        var span: TaskSpan
        var current: CGPoint
    }

    init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.outline)
        setAccessibilityLabel(Loc.t("Tasks"))
        controller.ganttAnchor = { [weak self] id in self?.popoverAnchor(id) }
    }

    /// A task's row as a popover's anchor: its name column, scrolled into view, while the
    /// Gantt is on screen. Nil when it's hidden or the topic has no row (folded away).
    func popoverAnchor(_ id: NodeID) -> (NSView, CGRect)? {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
        reload()
        guard let L = layout, let r = L.rows.first(where: { $0.id == id }) else { return nil }
        let name = CGRect(x: r.frame.minX, y: r.frame.minY, width: max(L.tableWidth, 1), height: r.frame.height)
        scrollToVisible(name)
        return (self, name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        controller.ganttFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        controller.ganttFocused = false
        return true
    }

    func reload() {
        let L = GanttLayout(
            canvas: controller.canvas, collapsed: controller.ganttCollapsed, scale: controller.ganttScale,
            today: controller.todayDate)
        layout = L
        let clip = enclosingScrollView?.contentView.bounds.size ?? .zero
        setFrameSize(CGSize(width: max(L.size.width, clip.width), height: max(L.size.height, clip.height)))
        needsDisplay = true
        rebuildAccessibility()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        if controller.selection.primary != lastPrimary {
            lastPrimary = controller.selection.primary
            (superview?.superview?.superview as? GanttView)?.reveal(controller.selection.primary)
        }
    }

    var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        guard var L = layout else { return }
        if let d = drag, let preview = previewDates(d) {
            // Draw the dragged bar where it would land.
            var c = controller.canvas
            if d.kind == .progress {
                c.nodes[d.id]?.todo?.progress = preview.progress
            } else {
                c.nodes[d.id]?.todo?.start = preview.start
                c.nodes[d.id]?.todo?.due = preview.due
            }
            L = GanttLayout(
                canvas: c, collapsed: controller.ganttCollapsed, scale: controller.ganttScale,
                today: controller.todayDate)
        }
        var r = GanttRenderer(layout: L)
        r.palette = dark ? .dark : .light
        r.selection = Set(controller.selection.nodes).union([controller.selection.primary])
        r.colors = controller.ganttColors
        let vis = visibleRect
        r.draw(dirty: vis, pin: vis.origin)
        if let d = drag, d.kind == .link {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath()
            path.move(to: d.origin)
            path.line(to: d.current)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
        }
        if L.rows.isEmpty {
            let s = Loc.t("No tasks yet. Select a topic and press ⌃⌘T to give it dates, or ⌃0 to make it a to-do.")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (s as NSString).draw(
                in: CGRect(x: vis.minX + 24, y: vis.minY + GanttLayout.headerHeight + 24, width: 520, height: 40),
                withAttributes: attrs)
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let chord = KeyChord(event: event) else {
            super.keyDown(with: event)
            return
        }
        controller.ganttFocused = true
        if controller.handleKey(chord, characters: event.characters) != .handled { super.keyDown(with: event) }
    }

    /// The Gantt's own chords (⌘D, ⌘L, ⇧⌘L, ⌥⌘←/→…) win over menu items that share them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let chord = KeyChord(event: event),
            controller.ganttCommand(for: chord) != nil
        else { return super.performKeyEquivalent(with: event) }
        controller.ganttFocused = true
        return controller.handleKey(chord, characters: event.characters) == .handled
    }

    // MARK: Menus

    func performRegistryCommand(_ sender: Any?) {
        ContextMenus.performCommand(sender, controller: controller, from: self)
    }

    /// The context menu's items that aren't plain commands.
    @objc func performMenuAction(_ sender: Any?) { ContextMenus.performAction(sender, controller: controller) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        ContextMenus.validate(item, controller: controller, from: self)
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

    /// A row's task menu, or Go to Today and Export Gantt… below the rows. The date
    /// header has none.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let L = layout else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard p.y > visibleRect.minY + GanttLayout.headerHeight else { return nil }
        return prepareMenu(L.row(atY: p.y)?.id)
    }

    /// Selects the row as a click would (D176) and builds its menu.
    func prepareMenu(_ id: NodeID?) -> NSMenu? {
        window?.makeFirstResponder(self)
        controller.prepareRowMenu(id)
        let entries = controller.ganttContextMenu(onRow: id != nil)
        return entries.isEmpty ? nil : ContextMenus.make(entries, target: self)
    }

    /// Show Menu on a row (VoiceOver), below the row's name.
    func showMenu(for id: NodeID) -> Bool {
        guard let r = layout?.rows.first(where: { $0.id == id }), let menu = prepareMenu(id) else { return false }
        popUpMenu(menu, CGPoint(x: visibleRect.minX + 8, y: r.frame.maxY))
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // Control-click opens the context menu, as a right-click does.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .control,
            let menu = menu(for: event)
        {
            presentContextMenu(menu, event)
            return
        }
        window?.makeFirstResponder(self)
        guard let L = layout else { return }
        let p = convert(event.locationInWindow, from: nil)
        let vis = visibleRect
        guard let row = L.row(atY: p.y), p.y > vis.minY + GanttLayout.headerHeight else { return }
        // The disclosure triangle.
        if p.x < vis.minX + L.tableWidth {
            let indent = vis.minX + 8 + CGFloat(row.depth) * 14
            if row.hasChildren, p.x >= indent, p.x <= indent + 14 {
                controller.toggleGanttRow(row.id)
                return
            }
            selectRow(row.id, event)
            if event.clickCount == 2 { controller.openTaskEditor(row.id) }
            return
        }
        selectRow(row.id, event)
        guard let bar = row.bar, let span = controller.canvas.span(of: row.id), row.kind != .summary else {
            if event.clickCount == 2 { controller.openTaskEditor(row.id) }
            return
        }
        let kind: Drag.Kind
        if row.kind == .task, p.x > bar.maxX + 1, p.x < bar.maxX + 12, abs(p.y - bar.midY) < 8 {
            kind = .link
        } else if row.kind == .task, abs(p.x - bar.maxX) < 5 {
            kind = .finish
        } else if row.kind == .task, abs(p.x - bar.minX) < 5 {
            kind = .start
        } else if row.kind == .task, event.modifierFlags.contains(.option), bar.contains(p) {
            kind = .progress
        } else if bar.insetBy(dx: -4, dy: -4).contains(p) {
            kind = .move
        } else {
            if event.clickCount == 2 { controller.openTaskEditor(row.id) }
            return
        }
        if event.clickCount == 2 && kind == .move {
            controller.openTaskEditor(row.id)
            return
        }
        drag = Drag(
            kind: kind, id: row.id, origin: kind == .link ? CGPoint(x: bar.maxX + 6, y: bar.midY) : p, span: span,
            current: p)
    }

    private func selectRow(_ id: NodeID, _ event: NSEvent) {
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
            controller.select(id, extend: true)
        } else if !controller.selection.nodes.contains(id) {
            controller.select(id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        drag?.current = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        defer { needsDisplay = true }
        if d.kind == .link {
            if let target = layout?.row(atY: d.current.y), target.id != d.id, target.kind != .summary {
                controller.linkTasks(d.id, target.id)
            }
            return
        }
        guard let p = previewDates(d) else { return }
        switch d.kind {
        case .progress: controller.setProgress(d.id, p.progress)
        case .move: controller.dragTask(d.id, start: p.start, due: p.due, name: Loc.t("Move Task"))
        default: controller.dragTask(d.id, start: p.start, due: p.due, name: Loc.t("Resize Task"))
        }
    }

    /// Where the dragged task would land (dates snap to working days).
    private func previewDates(_ d: Drag) -> (start: TaskDate?, due: TaskDate?, progress: Int)? {
        guard let L = layout, let t = controller.canvas.nodes[d.id]?.todo else { return nil }
        let cal = L.calendar
        let days = Int(((d.current.x - d.origin.x) / L.dayWidth).rounded())
        let s = d.span
        switch d.kind {
        case .progress:
            guard let bar = L.rows.first(where: { $0.id == d.id })?.bar else { return nil }
            let p = Int(((d.current.x - bar.minX) / max(bar.width, 1) * 100).rounded())
            return (t.start, t.due, max(0, min(100, (p + 2) / 5 * 5)))
        case .move:
            guard days != 0 else { return nil }
            if s.milestone { return (nil, cal.snapForward(s.finish.adding(days: days)), 0) }
            let start = cal.snapForward(s.start.adding(days: days))
            return (start, t.due == nil ? nil : cal.finish(start: start, days: s.workingDays), 0)
        case .start:
            guard days != 0 else { return nil }
            return (min(s.finish, cal.snapForward(s.start.adding(days: days))), s.finish, 0)
        case .finish:
            guard days != 0 else { return nil }
            return (s.start, max(s.start, cal.snapBack(s.finish.adding(days: days))), 0)
        case .link:
            return nil
        }
    }

    // MARK: Accessibility

    /// Row elements, kept (and reused per topic) so assistive apps can read them after
    /// this call returns; frames are in this view's space, so scrolling keeps them right.
    private var axRows: [MenuRowElement] = []
    private var axCache: [NodeID: MenuRowElement] = [:]

    private func rebuildAccessibility() {
        guard let L = layout else { return }
        let c = controller.canvas
        let today = controller.todayDate
        var cache: [NodeID: MenuRowElement] = [:]
        axRows = L.rows.map { r in
            let e = axCache[r.id] ?? MenuRowElement()
            cache[r.id] = e
            var label = c.nodes[r.id]?.text ?? ""
            if r.kind == .summary {
                label += ", " + Loc.t("Summary")
            } else if let spoken = TaskFormat.spoken(c, r.id, today: today) {
                label += ", " + spoken
            } else {
                label += ", " + Loc.t("No dates")
            }
            e.setAccessibilityRole(.row)
            e.setAccessibilityLabel(label)
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(r.frame)
            e.setAccessibilitySelected(controller.selection.nodes.contains(r.id))
            e.setAccessibilityDisclosureLevel(r.depth)
            let id = r.id
            // Show Menu opens the row's context menu (D226).
            e.showMenu = { [weak self] in self?.showMenu(for: id) ?? false }
            e.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: Loc.t("Move a working day earlier")) { [weak self] in
                    self?.controller.select(id)
                    return self?.controller.perform(.ganttEarlier) ?? false
                },
                NSAccessibilityCustomAction(name: Loc.t("Move a working day later")) { [weak self] in
                    self?.controller.select(id)
                    return self?.controller.perform(.ganttLater) ?? false
                },
                NSAccessibilityCustomAction(name: Loc.t("Edit task")) { [weak self] in
                    self?.controller.openTaskEditor(id)
                    return true
                },
            ])
            return e
        }
        axCache = cache
    }

    override func accessibilityChildren() -> [Any]? { axRows }

    /// Show Menu on the chart itself: the selected row's menu.
    override func accessibilityPerformShowMenu() -> Bool { showMenu(for: controller.selection.primary) }

    override func accessibilitySelectedRows() -> [Any]? {
        axRows.filter { $0.isAccessibilitySelected() }
    }
}

@MainActor
extension CanvasController {
    /// Bar colours: each task's branch colour from the map.
    public var ganttColors: [NodeID: NSColor] {
        var out: [NodeID: NSColor] = [:]
        let c = canvas
        for r in taskSchedule.rows {
            var cur = r.id
            while scene.nodes[cur] == nil, let p = c.parent(of: cur) { cur = p }
            if cur == c.root, r.id != c.root, let main = c.path(to: r.id).dropFirst().first { cur = main }
            if let b = scene.nodes[cur]?.branchColor {
                out[r.id] = NSColor(srgbRed: b.r, green: b.g, blue: b.b, alpha: 1)
            }
        }
        return out
    }
}
