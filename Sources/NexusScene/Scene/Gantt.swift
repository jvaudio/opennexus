import CoreGraphics
import CoreText
import Foundation
import ImageIO
import NexusCore
import NexusInterchange

/// The Gantt's geometry: a table of tasks on the left and a timeline on the right, in
/// points, top-left origin. Pure, so the view, the exports and the tests share it (D147).
public struct GanttLayout {
    public enum Kind: Equatable, Sendable { case task, milestone, summary, undated }

    public struct Row: Equatable {
        public var id: NodeID
        public var depth: Int
        public var kind: Kind
        public var hasChildren: Bool
        public var collapsed: Bool
        /// The row's band.
        public var frame: CGRect
        /// The bar (or the milestone's diamond box), in timeline coordinates.
        public var bar: CGRect?
        public var progress: Int
        public var done: Bool
        public var late: Bool
        /// Part of a dependency loop.
        public var inCycle: Bool
        public var cells: [String]
    }

    public struct Arrow: Equatable {
        public var from: NodeID
        public var to: NodeID
        public var points: [CGPoint]
        /// The successor starts or finishes before the dependency allows.
        public var violated: Bool
    }

    public struct Column: Equatable {
        public var title: String
        public var width: CGFloat
        public var alignRight: Bool
    }

    public static let rowHeight: CGFloat = 30
    public static let headerHeight: CGFloat = 46
    public static let barHeight: CGFloat = 16
    /// Room under the last row (the status pill sits there on screen).
    public static let bottomPad: CGFloat = 64

    public static var columns: [Column] {
        [
            Column(title: Loc.t("Task"), width: 230, alignRight: false),
            Column(title: Loc.t("Owner"), width: 96, alignRight: false),
            Column(title: Loc.t("Start"), width: 70, alignRight: false),
            Column(title: Loc.t("Due"), width: 70, alignRight: false),
            Column(title: Loc.t("Days"), width: 44, alignRight: true),
            Column(title: "%", width: 44, alignRight: true),
        ]
    }

    public let schedule: TaskSchedule
    public let columns: [Column]
    public let tableWidth: CGFloat
    public let rows: [Row]
    public let arrows: [Arrow]
    /// First day drawn on the timeline (a Monday).
    public let origin: TaskDate
    public let days: Int
    public let dayWidth: CGFloat
    public let today: TaskDate
    public let scale: GanttScale
    public let calendar: WorkCalendar

    public var size: CGSize {
        CGSize(
            width: tableWidth + CGFloat(days) * dayWidth,
            height: Self.headerHeight + CGFloat(rows.count) * Self.rowHeight + Self.bottomPad)
    }

    public init(
        canvas c: Canvas, collapsed: Set<NodeID> = [], scale: GanttScale = .day, today: TaskDate,
        only: Set<NodeID>? = nil
    ) {
        let s = TaskSchedule(c)
        schedule = s
        self.today = today
        self.scale = scale
        calendar = s.calendar
        dayWidth = scale.dayWidth
        columns = Self.columns
        tableWidth = columns.reduce(0) { $0 + $1.width }
        // The span: every bar plus today, padded, from a Monday.
        let lo = min(s.range?.start ?? today, today).adding(days: -7)
        let hi = max(s.range?.finish ?? today.adding(days: 21), today).adding(days: scale == .month ? 60 : 21)
        origin = lo.adding(days: -(lo.weekday - 1))
        days = hi.day - origin.day + 1
        var out: [Row] = []
        let visible = s.visibleRows(collapsed: collapsed).filter { only?.contains($0.id) ?? true }
        let origin = origin
        let dayWidth = dayWidth
        let tableWidth = tableWidth
        func x(_ d: TaskDate) -> CGFloat { tableWidth + CGFloat(d.day - origin.day) * dayWidth }
        for (i, r) in visible.enumerated() {
            let y = Self.headerHeight + CGFloat(i) * Self.rowHeight
            let frame = CGRect(x: 0, y: y, width: tableWidth + CGFloat(days) * dayWidth, height: Self.rowHeight)
            let n = c.nodes[r.id]
            let span = s.displaySpan(r.id)
            let kind: Kind =
                r.isSummary ? .summary : span == nil ? .undated : span!.milestone ? .milestone : .task
            var bar: CGRect?
            if let span {
                let mid = y + Self.rowHeight / 2
                switch kind {
                case .milestone:
                    let cx = x(span.finish) + dayWidth / 2
                    bar = CGRect(x: cx - 8, y: mid - 8, width: 16, height: 16)
                case .summary:
                    bar = CGRect(
                        x: x(span.start), y: mid - 4, width: x(span.finish.adding(days: 1)) - x(span.start), height: 8)
                default:
                    bar = CGRect(
                        x: x(span.start), y: mid - Self.barHeight / 2,
                        width: max(dayWidth, x(span.finish.adding(days: 1)) - x(span.start)), height: Self.barHeight)
                }
            }
            let t = n?.todo
            let late = t.map { !$0.done } == true && (span?.finish).map { $0 < today } == true && kind != .summary
            let progress = r.isSummary ? Self.summaryProgress(r.id, c, s) : c.progress(of: r.id)
            var cells = [n?.text ?? "", t?.owner ?? ""]
            cells.append(span.map { TaskFormat.day($0.start, today: today) } ?? "")
            cells.append(span.map { TaskFormat.day($0.finish, today: today) } ?? "")
            cells.append(span.map { $0.milestone ? "◆" : "\($0.workingDays)" } ?? "")
            cells.append(t != nil || span != nil ? "\(progress)%" : "")
            out.append(
                Row(
                    id: r.id, depth: r.depth, kind: kind, hasChildren: r.hasChildren,
                    collapsed: collapsed.contains(r.id), frame: frame, bar: bar, progress: progress,
                    done: t?.done == true, late: late, inCycle: s.cycle.contains(r.id), cells: cells))
        }
        rows = out
        // Dependency arrows between drawn bars, from the side the kind names.
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        var arrows: [Arrow] = []
        for e in s.edges {
            guard let a = byID[e.from]?.bar, let b = byID[e.to]?.bar else { continue }
            let fromEnd = e.type == .finishToStart || e.type == .finishToFinish
            let toStart = e.type == .finishToStart || e.type == .startToStart
            let p0 = CGPoint(x: fromEnd ? a.maxX : a.minX, y: a.midY)
            let p1 = CGPoint(x: toStart ? b.minX : b.maxX, y: b.midY)
            let out0: CGFloat = fromEnd ? 8 : -8
            let in1: CGFloat = toStart ? -8 : 8
            var pts = [p0, CGPoint(x: p0.x + out0, y: p0.y)]
            if (toStart && p0.x + out0 <= p1.x + in1) || (!toStart && p0.x + out0 >= p1.x + in1) {
                pts.append(CGPoint(x: p0.x + out0, y: p1.y))
            } else {
                let between = b.midY > a.midY ? b.midY - Self.rowHeight / 2 : b.midY + Self.rowHeight / 2
                pts += [
                    CGPoint(x: p0.x + out0, y: between), CGPoint(x: p1.x + in1, y: between),
                    CGPoint(x: p1.x + in1, y: p1.y),
                ]
            }
            pts.append(p1)
            arrows.append(Arrow(from: e.from, to: e.to, points: pts, violated: s.violations.contains(e)))
        }
        self.arrows = arrows
    }

    package static func summaryProgress(_ id: NodeID, _ c: Canvas, _ s: TaskSchedule) -> Int {
        // Weighted by working days over the tasks below.
        var total = 0
        var done = 0
        for top in [id] {
            c.walk(from: top) { d, n, depth in
                guard depth > 0, n.todo != nil else { return }
                let w = max(1, s.spans[d]?.workingDays ?? 1)
                total += w
                done += w * c.progress(of: d)
            }
        }
        return total == 0 ? 0 : done / total
    }

    public func x(for d: TaskDate) -> CGFloat { tableWidth + CGFloat(d.day - origin.day) * dayWidth }

    /// The day under a timeline x.
    public func date(atX x: CGFloat) -> TaskDate {
        origin.adding(days: Int(((x - tableWidth) / dayWidth).rounded(.down)))
    }

    public func row(atY y: CGFloat) -> Row? {
        let i = Int(((y - Self.headerHeight) / Self.rowHeight).rounded(.down))
        return rows.indices.contains(i) && y >= Self.headerHeight ? rows[i] : nil
    }
}

/// Draws a `GanttLayout` into any context: the screen, a bitmap or a PDF page (D147).
public struct GanttRenderer {
    public struct Palette {
        package var background, header, grid, weekend, text, secondary, bar, barDone, progress, summary, milestone,
            arrow,
            violation, today, selection, late: CGColor

        public static var light: Palette {
            Palette(
                background: CGColor.calibratedWhite(1), header: CGColor.calibratedWhite(0.965),
                grid: CGColor.calibratedWhite(0.88),
                weekend: CGColor.calibratedWhite(0.95), text: CGColor.calibratedWhite(0.1),
                secondary: CGColor.calibratedWhite(0.38),
                bar: CGColor(srgbRed: 0.42, green: 0.62, blue: 0.9, alpha: 1),
                barDone: CGColor(srgbRed: 0.55, green: 0.75, blue: 0.6, alpha: 1),
                progress: CGColor(srgbRed: 0.12, green: 0.39, blue: 0.75, alpha: 1),
                summary: CGColor.calibratedWhite(0.25),
                milestone: CGColor(srgbRed: 0.85, green: 0.45, blue: 0.1, alpha: 1),
                arrow: CGColor.calibratedWhite(0.35),
                violation: CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1),
                today: CGColor(srgbRed: 0.85, green: 0.15, blue: 0.2, alpha: 1),
                selection: CGColor(srgbRed: 0.2, green: 0.5, blue: 0.95, alpha: 0.14),
                late: CGColor(srgbRed: 0.72, green: 0.1, blue: 0.1, alpha: 1))
        }

        public static var dark: Palette {
            Palette(
                background: CGColor.calibratedWhite(0.12), header: CGColor.calibratedWhite(0.16),
                grid: CGColor.calibratedWhite(0.26), weekend: CGColor.calibratedWhite(0.15),
                text: CGColor.calibratedWhite(0.93), secondary: CGColor.calibratedWhite(0.66),
                bar: CGColor(srgbRed: 0.33, green: 0.52, blue: 0.82, alpha: 1),
                barDone: CGColor(srgbRed: 0.35, green: 0.6, blue: 0.45, alpha: 1),
                progress: CGColor(srgbRed: 0.6, green: 0.78, blue: 1, alpha: 1), summary: CGColor.calibratedWhite(0.8),
                milestone: CGColor(srgbRed: 0.98, green: 0.6, blue: 0.25, alpha: 1),
                arrow: CGColor.calibratedWhite(0.7),
                violation: CGColor(srgbRed: 1, green: 0.4, blue: 0.4, alpha: 1),
                today: CGColor(srgbRed: 1, green: 0.35, blue: 0.4, alpha: 1),
                selection: CGColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 0.22),
                late: CGColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 1))
        }
    }

    public var layout: GanttLayout
    public var palette: Palette = .light
    public var selection: Set<NodeID> = []
    /// Bar colours by topic (the map's branch colours); others use the palette's bar.
    public var colors: [NodeID: CGColor] = [:]
    public var title: String?

    public init(layout: GanttLayout) { self.layout = layout }

    package static var font: CTFont { Fonts.system(12) }
    package static var bold: CTFont { Fonts.system(12, .semibold) }
    package static var small: CTFont { Fonts.system(10.5) }

    /// Draws into a flipped context. `pin` keeps the header and table in view while
    /// scrolling (the visible rect's origin); `dirty` limits work.
    public func draw(in ctx: CGContext, dirty: CGRect, pin: CGPoint = .zero) {
        let L = layout
        let p = palette
        let size = L.size
        Shapes.fillRect(dirty, p.background, in: ctx)
        // Timeline: weekend shading, week lines, today.
        let first = max(0, Int(((dirty.minX - L.tableWidth) / L.dayWidth).rounded(.down)))
        let last = min(L.days, Int(((dirty.maxX - L.tableWidth) / L.dayWidth).rounded(.up)) + 1)
        if first < last {
            for i in first..<last {
                let d = L.origin.adding(days: i)
                let x = L.x(for: d)
                if !L.calendar.isWorking(d) || (L.scale != .day && d.weekday >= 6) {
                    Shapes.fillRect(
                        CGRect(x: x, y: dirty.minY, width: L.dayWidth, height: dirty.height), p.weekend, in: ctx)
                }
                if d.weekday == 1 || (L.scale == .month && d.components.day == 1) || L.scale == .day {
                    Shapes.fillRect(
                        CGRect(x: x, y: dirty.minY, width: 0.5, height: dirty.height),
                        d.weekday == 1 ? p.grid : p.grid.copy(alpha: 0.45)!, in: ctx)
                }
            }
        }
        // Rows: selection band, grid line, bars.
        for r in L.rows where r.frame.intersects(dirty) {
            if selection.contains(r.id) { Shapes.fillRect(r.frame, p.selection, in: ctx) }
            Shapes.fillRect(
                CGRect(x: 0, y: r.frame.maxY - 0.5, width: size.width, height: 0.5), p.grid.copy(alpha: 0.5)!, in: ctx)
            guard let b = r.bar else { continue }
            let base = colors[r.id] ?? p.bar
            switch r.kind {
            case .milestone:
                let path = CGMutablePath()
                path.move(to: CGPoint(x: b.midX, y: b.minY))
                path.addLine(to: CGPoint(x: b.maxX, y: b.midY))
                path.addLine(to: CGPoint(x: b.midX, y: b.maxY))
                path.addLine(to: CGPoint(x: b.minX, y: b.midY))
                path.closeSubpath()
                Shapes.fill(path, r.done ? p.barDone : p.milestone, in: ctx)
            case .summary:
                Shapes.fill(CGRect(x: b.minX, y: b.minY, width: b.width, height: 4), p.summary, in: ctx)
                for x in [b.minX, b.maxX - 4] {
                    let tip = CGMutablePath()
                    tip.move(to: CGPoint(x: x, y: b.minY))
                    tip.addLine(to: CGPoint(x: x + 4, y: b.minY))
                    tip.addLine(to: CGPoint(x: x + (x == b.minX ? 0 : 4), y: b.maxY + 2))
                    tip.closeSubpath()
                    Shapes.fill(tip, p.summary, in: ctx)
                }
            default:
                let rr = Shapes.roundedRect(b, radius: 4)
                Shapes.fill(rr, r.done ? p.barDone : base.copy(alpha: 0.45)!, in: ctx)
                if r.progress > 0 && !r.done {
                    ctx.saveGState()
                    Shapes.clip(to: rr, in: ctx)
                    Shapes.fillRect(
                        CGRect(x: b.minX, y: b.minY, width: b.width * CGFloat(r.progress) / 100, height: b.height),
                        base,
                        in: ctx)
                    ctx.restoreGState()
                }
                if r.late || r.inCycle {
                    Shapes.stroke(rr, r.inCycle ? p.violation : p.late, width: 1.5, in: ctx)
                }
                // The end dot (drag it onto another bar to link).
                if selection.contains(r.id) {
                    Shapes.fill(
                        Shapes.oval(in: CGRect(x: b.maxX + 3, y: b.midY - 3.5, width: 7, height: 7)), p.progress,
                        in: ctx)
                }
            }
        }
        // Dependency arrows.
        for a in L.arrows {
            let path = CGMutablePath()
            path.move(to: a.points[0])
            for q in a.points.dropFirst() { path.addLine(to: q) }
            Shapes.stroke(path, a.violated ? p.violation : p.arrow, width: 1.2, in: ctx)
            if let tip = a.points.last, let before = a.points.dropLast().last {
                let dir: CGFloat = tip.x >= before.x ? 1 : -1
                let head = CGMutablePath()
                head.move(to: tip)
                head.addLine(to: CGPoint(x: tip.x - 5 * dir, y: tip.y - 3.5))
                head.addLine(to: CGPoint(x: tip.x - 5 * dir, y: tip.y + 3.5))
                head.closeSubpath()
                Shapes.fill(head, a.violated ? p.violation : p.arrow, in: ctx)
            }
        }
        // Today.
        let tx = L.x(for: L.today) + L.dayWidth / 2
        if tx >= L.tableWidth {
            Shapes.fillRect(
                CGRect(x: tx - 0.75, y: GanttLayout.headerHeight, width: 1.5, height: size.height), p.today, in: ctx)
        }
        ctx.saveGState()
        drawHeader(top: pin.y, dirty: dirty, in: ctx)
        drawTable(left: pin.x, dirty: dirty, in: ctx)
        // The corner over both.
        Shapes.fillRect(
            CGRect(x: pin.x, y: pin.y, width: L.tableWidth, height: GanttLayout.headerHeight), p.header, in: ctx)
        var x = pin.x
        for col in L.columns {
            text(
                col.title, in: CGRect(x: x + 8, y: pin.y + 26, width: col.width - 16, height: 16), font: Self.bold,
                color: p.secondary, right: col.alignRight, ctx: ctx)
            x += col.width
        }
        if let title {
            text(
                title, in: CGRect(x: pin.x + 8, y: pin.y + 6, width: L.tableWidth - 16, height: 16), font: Self.bold,
                color: p.text, ctx: ctx)
        }
        Shapes.fillRect(
            CGRect(x: pin.x, y: pin.y + GanttLayout.headerHeight - 0.5, width: size.width, height: 0.5), p.grid, in: ctx
        )
        Shapes.fillRect(
            CGRect(x: pin.x + L.tableWidth - 0.5, y: pin.y, width: 0.5, height: size.height), p.grid, in: ctx)
        ctx.restoreGState()
    }

    private func drawHeader(top: CGFloat, dirty: CGRect, in ctx: CGContext) {
        let L = layout
        let p = palette
        Shapes.fillRect(
            CGRect(x: dirty.minX, y: top, width: dirty.width, height: GanttLayout.headerHeight), p.header, in: ctx)
        let first = max(0, Int(((dirty.minX - L.tableWidth) / L.dayWidth).rounded(.down)) - 31)
        let last = min(L.days, Int(((dirty.maxX - L.tableWidth) / L.dayWidth).rounded(.up)) + 1)
        guard first < last else { return }
        var month = Date.FormatStyle.dateTime.month(.wide).year()
        month.timeZone = TaskFormat.utc
        for i in first..<last {
            let d = L.origin.adding(days: i)
            let x = L.x(for: d)
            let c = d.components
            if c.day == 1 || i == first {
                text(
                    d.date(in: TaskFormat.utc).formatted(month),
                    in: CGRect(x: max(x, L.tableWidth) + 4, y: top + 5, width: 160, height: 16), font: Self.bold,
                    color: p.text, ctx: ctx)
                Shapes.fillRect(CGRect(x: x, y: top, width: 0.5, height: 22), p.grid, in: ctx)
            }
            switch L.scale {
            case .day:
                text(
                    "\(c.day)", in: CGRect(x: x, y: top + 27, width: L.dayWidth, height: 14), font: Self.small,
                    color: L.calendar.isWorking(d) ? p.secondary : p.secondary.copy(alpha: 0.5)!, center: true, ctx: ctx
                )
            case .week where d.weekday == 1:
                text(
                    "\(c.day)", in: CGRect(x: x + 2, y: top + 27, width: L.dayWidth * 7, height: 14),
                    font: Self.small, color: p.secondary, ctx: ctx)
            default: break
            }
        }
    }

    private func drawTable(left: CGFloat, dirty: CGRect, in ctx: CGContext) {
        let L = layout
        let p = palette
        Shapes.fillRect(
            CGRect(x: left, y: dirty.minY, width: L.tableWidth, height: dirty.height), p.background, in: ctx)
        for r in L.rows where r.frame.intersects(dirty) {
            if selection.contains(r.id) {
                Shapes.fillRect(
                    CGRect(x: left, y: r.frame.minY, width: L.tableWidth, height: r.frame.height), p.selection, in: ctx)
            }
            Shapes.fillRect(
                CGRect(x: left, y: r.frame.maxY - 0.5, width: L.tableWidth, height: 0.5), p.grid.copy(alpha: 0.5)!,
                in: ctx)
            var x = left
            for (i, col) in L.columns.enumerated() {
                var cell = CGRect(x: x + 8, y: r.frame.minY + 8, width: col.width - 16, height: 16)
                if i == 0 {
                    let indent = CGFloat(r.depth) * 14
                    if r.hasChildren {
                        text(
                            r.collapsed ? "▸" : "▾",
                            in: CGRect(x: cell.minX + indent, y: cell.minY, width: 12, height: 16),
                            font: Self.small, color: p.secondary, ctx: ctx)
                    }
                    cell.origin.x += indent + 14
                    cell.size.width -= indent + 14
                }
                let color = i == 3 && r.late ? p.late : i == 0 ? p.text : p.secondary
                text(
                    r.cells[i], in: cell, font: i == 0 && r.kind == .summary ? Self.bold : Self.font, color: color,
                    right: col.alignRight, strike: i == 0 && r.done, ctx: ctx)
                x += col.width
            }
        }
    }

    private func text(
        _ s: String, in rect: CGRect, font: CTFont, color: CGColor, right: Bool = false, center: Bool = false,
        strike: Bool = false, ctx: CGContext
    ) {
        guard !s.isEmpty else { return }
        let para = TextParagraph(alignment: right ? .right : center ? .center : .left, lineBreak: .truncateTail)
        StyledText(s, TextAttributes(font: font, color: .fixed(color), paragraph: para, strikethrough: strike))
            .draw(with: rect, options: [.lineFragmentOrigin, .truncatesLastLine], in: ctx)
    }
}
