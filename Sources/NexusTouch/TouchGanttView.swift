#if os(iOS)
import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import UIKit

/// The Gantt view (⌘4) on the iPad (M47b): the Mac's chart drawn by the same
/// `GanttRenderer`. The surface covers only the visible part of the scroll view and draws
/// with the table and the date header pinned, so a long schedule costs no more than a
/// short one. Tap selects, double-tap edits the task, dragging a bar moves it, dragging an
/// end resizes it, dragging past its end links it, and a long press opens the row's menu.
@MainActor
public final class TouchGanttView: UIScrollView, UIScrollViewDelegate {
    let controller: CanvasController
    let surface = GanttDrawing()
    private(set) var layout: GanttLayout?
    private var didScrollOnce = false
    private var drag: Drag?
    private var lastPrimary: NodeID?
    private let press = UILongPressGestureRecognizer()

    struct Drag {
        enum Kind { case move, start, finish, link }
        var kind: Kind
        var id: NodeID
        var origin: CGPoint
        var span: TaskSpan
        var current: CGPoint
    }

    public init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .systemBackground
        surface.gantt = self
        addSubview(surface)
        accessibilityLabel = Loc.t("Gantt chart")
        accessibilityIdentifier = "gantt"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        addGestureRecognizer(tap)
        addGestureRecognizer(double)
        press.addTarget(self, action: #selector(barDrag(_:)))
        press.minimumPressDuration = 0.12
        addGestureRecognizer(press)
        addInteraction(UIContextMenuInteraction(delegate: surface))
        controller.onGanttScroll = { [weak self] day in self?.scroll(to: day) }
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var canBecomeFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { controller.ganttFocused = true }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        controller.ganttFocused = false
        return super.resignFirstResponder()
    }

    /// Re-lays out when the document, selection or Gantt state changes.
    private func observe() {
        withObservationTracking {
            _ = controller.store.revision
            _ = controller.selection
            _ = controller.ganttCollapsed
            _ = controller.ganttScale
            _ = controller.canvasID
            _ = controller.scene
            _ = controller.theme.isDark
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.isHidden { self.reload() }
                self.observe()
            }
        }
    }

    public override var isHidden: Bool {
        didSet {
            guard !isHidden else { return }
            reload()
            if !didScrollOnce {
                didScrollOnce = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scroll(to: self.layout?.schedule.range?.start ?? self.controller.todayDate)
                }
            }
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        surface.setNeedsDisplay()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) { surface.setNeedsDisplay() }

    func reload() {
        let L = GanttLayout(
            canvas: controller.canvas, collapsed: controller.ganttCollapsed, scale: controller.ganttScale,
            today: controller.todayDate)
        layout = L
        overrideUserInterfaceStyle = controller.theme.isDark ? .dark : .light
        contentSize = CGSize(width: max(L.size.width, bounds.width), height: max(L.size.height, bounds.height))
        surface.setNeedsDisplay()
        axRows = nil
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
        if controller.selection.primary != lastPrimary {
            lastPrimary = controller.selection.primary
            reveal(controller.selection.primary)
        }
    }

    func scroll(to day: TaskDate) {
        guard let L = layout else { return }
        let x = max(0, min(L.x(for: day) - L.tableWidth - 60, contentSize.width - bounds.width))
        setContentOffset(CGPoint(x: x, y: contentOffset.y), animated: false)
    }

    /// Keeps the selected row in view.
    func reveal(_ id: NodeID) {
        guard let r = layout?.rows.first(where: { $0.id == id }) else { return }
        var target = r.frame
        target.origin.x = contentOffset.x
        target.size.width = 1
        target.origin.y -= GanttLayout.headerHeight
        target.size.height += GanttLayout.headerHeight
        scrollRectToVisible(target, animated: false)
    }

    // MARK: Drawing

    func drawChart(in ctx: CGContext) {
        guard var L = layout else { return }
        let vis = CGRect(origin: contentOffset, size: bounds.size)
        ctx.translateBy(x: -vis.minX, y: -vis.minY)
        if let d = drag, let preview = previewDates(d) {
            // Draw the dragged bar where it would land.
            var c = controller.canvas
            c.nodes[d.id]?.todo?.start = preview.start
            c.nodes[d.id]?.todo?.due = preview.due
            L = GanttLayout(
                canvas: c, collapsed: controller.ganttCollapsed, scale: controller.ganttScale,
                today: controller.todayDate)
        }
        var r = GanttRenderer(layout: L)
        r.palette = controller.theme.isDark ? .dark : .light
        r.selection = Set(controller.selection.nodes).union([controller.selection.primary])
        r.colors = controller.ganttColors
        r.draw(in: ctx, dirty: vis, pin: vis.origin)
        if let d = drag, d.kind == .link {
            ctx.setStrokeColor((tintColor ?? .systemBlue).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: d.origin)
            ctx.addLine(to: d.current)
            ctx.strokePath()
        }
        if L.rows.isEmpty {
            let s = Loc.t("No tasks yet. Select a topic and press ⌃⌘T to give it dates, or ⌃0 to make it a to-do.")
            (s as NSString).draw(
                in: CGRect(x: vis.minX + 24, y: vis.minY + GanttLayout.headerHeight + 24, width: 520, height: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel])
        }
    }

    // MARK: Keys

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key, let chord = KeyChord(key: key) else {
            super.pressesBegan(presses, with: event)
            return
        }
        controller.ganttFocused = true
        if controller.handleKey(chord, characters: key.characters) != .handled {
            super.pressesBegan(presses, with: event)
        }
    }

    public override var keyCommands: [UIKeyCommand]? {
        TouchCanvasView.keyCommands(for: controller, action: #selector(runKeyCommand(_:)))
    }

    @objc func runKeyCommand(_ sender: UIKeyCommand) {
        guard let spec = sender.propertyList as? String, let chord = KeyChord(spec) else { return }
        controller.ganttFocused = true
        _ = controller.handleKey(chord, characters: sender.input)
    }

    // MARK: Touch

    func row(at p: CGPoint) -> GanttLayout.Row? {
        guard let L = layout, p.y > contentOffset.y + GanttLayout.headerHeight else { return nil }
        return L.row(atY: p.y)
    }

    @objc func tapped(_ g: UITapGestureRecognizer) {
        _ = becomeFirstResponder()
        let p = g.location(in: self)
        guard let L = layout, let row = row(at: p) else { return }
        // The disclosure triangle.
        if p.x < contentOffset.x + L.tableWidth {
            let indent = contentOffset.x + 8 + CGFloat(row.depth) * 14
            if row.hasChildren, p.x >= indent - 6, p.x <= indent + 20 {
                controller.toggleGanttRow(row.id)
                return
            }
        }
        if g.modifierFlags.contains(.shift) || g.modifierFlags.contains(.command) {
            controller.select(row.id, extend: true)
        } else {
            controller.select(row.id)
        }
    }

    @objc func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let row = row(at: g.location(in: self)) else { return }
        _ = becomeFirstResponder()
        controller.select(row.id)
        controller.openTaskEditor(row.id)
    }

    /// What a press at `p` would drag: a bar's body, either end, or the link handle past it.
    func dragKind(at p: CGPoint) -> (GanttLayout.Row, Drag.Kind)? {
        guard let row = row(at: p), let bar = row.bar, row.kind != .summary,
            p.x > contentOffset.x + (layout?.tableWidth ?? 0)
        else { return nil }
        if row.kind == .task, p.x > bar.maxX + 1, p.x < bar.maxX + 22, abs(p.y - bar.midY) < 12 { return (row, .link) }
        if row.kind == .task, abs(p.x - bar.maxX) < 10 { return (row, .finish) }
        if row.kind == .task, abs(p.x - bar.minX) < 10 { return (row, .start) }
        if bar.insetBy(dx: -6, dy: -8).contains(p) { return (row, .move) }
        return nil
    }

    /// A press drags only when it starts on a bar (elsewhere the scroll view pans).
    public override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === press else { return super.gestureRecognizerShouldBegin(g) }
        return dragKind(at: g.location(in: self)) != nil
    }

    @objc func barDrag(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            guard let (row, kind) = dragKind(at: p), let bar = row.bar,
                let span = controller.canvas.span(of: row.id)
            else { return }
            _ = becomeFirstResponder()
            if !controller.selection.nodes.contains(row.id) { controller.select(row.id) }
            drag = Drag(
                kind: kind, id: row.id, origin: kind == .link ? CGPoint(x: bar.maxX + 6, y: bar.midY) : p, span: span,
                current: p)
            isScrollEnabled = false
        case .changed:
            drag?.current = p
            surface.setNeedsDisplay()
        case .ended:
            finishDrag()
        default:
            drag = nil
            isScrollEnabled = true
            surface.setNeedsDisplay()
        }
    }

    private func finishDrag() {
        isScrollEnabled = true
        guard let d = drag else { return }
        drag = nil
        defer { surface.setNeedsDisplay() }
        if d.kind == .link {
            if let target = layout?.row(atY: d.current.y), target.id != d.id, target.kind != .summary {
                controller.linkTasks(d.id, target.id)
            }
            return
        }
        guard let p = previewDates(d) else { return }
        controller.dragTask(
            d.id, start: p.start, due: p.due, name: d.kind == .move ? Loc.t("Move Task") : Loc.t("Resize Task"))
    }

    /// Where the dragged task would land (dates snap to working days).
    private func previewDates(_ d: Drag) -> (start: TaskDate?, due: TaskDate?)? {
        guard let L = layout, let t = controller.canvas.nodes[d.id]?.todo else { return nil }
        let cal = L.calendar
        let days = Int(((d.current.x - d.origin.x) / L.dayWidth).rounded())
        let s = d.span
        guard days != 0 else { return nil }
        switch d.kind {
        case .move:
            if s.milestone { return (nil, cal.snapForward(s.finish.adding(days: days))) }
            let start = cal.snapForward(s.start.adding(days: days))
            return (start, t.due == nil ? nil : cal.finish(start: start, days: s.workingDays))
        case .start: return (min(s.finish, cal.snapForward(s.start.adding(days: days))), s.finish)
        case .finish: return (s.start, max(s.start, cal.snapBack(s.finish.adding(days: days))))
        case .link: return nil
        }
    }

    /// Selects the row as a tap would (D176) and builds its menu; below the rows, Go to
    /// Today and Export Gantt….
    func menu(at p: CGPoint) -> UIMenu? {
        guard p.y > contentOffset.y + GanttLayout.headerHeight, drag == nil else { return nil }
        _ = becomeFirstResponder()
        let id = row(at: p)?.id
        controller.prepareRowMenu(id)
        let entries = controller.ganttContextMenu(onRow: id != nil)
        guard !entries.isEmpty else { return nil }
        return UIMenu(children: TouchMenus.elements(entries) { [weak self] in self?.run($0) })
    }

    func run(_ action: CanvasMenuAction) {
        controller.ganttFocused = true
        if case .command(let id) = action {
            controller.noteMouseUse(id)
            _ = controller.perform(id)
        } else {
            _ = controller.runMenuAction(action)
        }
    }

    /// A task's row as a popover's anchor: its name column, scrolled into view.
    public func anchor(of id: NodeID) -> CGRect? {
        guard window != nil, !isHidden else { return nil }
        reload()
        guard let L = layout, let r = L.rows.first(where: { $0.id == id }) else { return nil }
        reveal(id)
        return CGRect(x: contentOffset.x, y: r.frame.minY, width: max(L.tableWidth, 1), height: r.frame.height)
    }

    // MARK: Accessibility

    private var axRows: [UIAccessibilityElement]?

    public override var accessibilityElements: [Any]? {
        get {
            if let axRows { return axRows }
            guard let L = layout else { return [] }
            let c = controller.canvas
            let today = controller.todayDate
            let made = L.rows.map { r in
                let e = UIAccessibilityElement(accessibilityContainer: self)
                var label = c.nodes[r.id]?.text ?? ""
                if r.kind == .summary {
                    label += ", " + Loc.t("Summary")
                } else if let spoken = TaskFormat.spoken(c, r.id, today: today) {
                    label += ", " + spoken
                } else {
                    label += ", " + Loc.t("No dates")
                }
                e.accessibilityLabel = label
                e.accessibilityTraits = controller.selection.nodes.contains(r.id) ? [.button, .selected] : .button
                e.accessibilityFrameInContainerSpace = r.frame
                let id = r.id
                e.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: Loc.t("Move a working day earlier")) { [weak self] _ in
                        self?.controller.select(id)
                        return self?.controller.perform(.ganttEarlier) ?? false
                    },
                    UIAccessibilityCustomAction(name: Loc.t("Move a working day later")) { [weak self] _ in
                        self?.controller.select(id)
                        return self?.controller.perform(.ganttLater) ?? false
                    },
                    UIAccessibilityCustomAction(name: Loc.t("Edit task")) { [weak self] _ in
                        self?.controller.openTaskEditor(id)
                        return true
                    },
                ]
                return e
            }
            axRows = made
            return made
        }
        set {}
    }
}

/// The visible part of the chart, redrawn as the scroll view moves.
final class GanttDrawing: UIView, UIContextMenuInteractionDelegate {
    weak var gantt: TouchGanttView?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        // The surface sits at the scroll view's bounds: its origin is the content offset.
        guard let ctx = UIGraphicsGetCurrentContext(), let gantt else { return }
        gantt.drawChart(in: ctx)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = gantt?.menu(at: location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
#endif
