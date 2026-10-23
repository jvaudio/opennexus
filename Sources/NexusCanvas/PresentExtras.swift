import AppKit
import NexusCore
import NexusTheme
import SwiftUI

// Present's legend, task lines and Timeline slides (M21). The screen and the slide
// exports draw the same pieces: the legend through `LegendLayer.draw`, the Timeline
// through `GanttRenderer`. M28: the legend lists only the slide's markers, and the
// framing keeps the slide's topics clear of it.

@MainActor
extension CanvasController {
    /// The legend in a corner of the slide (D200): the canvas shows one, the deck's Legend
    /// setting is on, and the slide isn't a Timeline (which has no markers). It lists only
    /// the markers and labels on the slide's topics, and a slide without any has none
    /// (D233).
    public func presentLegend(for slide: Slide?) -> SceneLegend? {
        guard let l = canvas.legend, l.visible, canvas.presentation.legend, let slide, slide.timeline == nil else {
            return nil
        }
        let legend = SceneLegend.make(l, canvas: canvas, content: .zero, among: slideTopics(slide))
        return legend.rows.isEmpty ? nil : legend
    }

    /// The topics a slide frames (the rest dims or is out of shot), less those hidden
    /// from slides and those under a fold (D233).
    func slideTopics(_ s: Slide) -> Set<NodeID> {
        let shown = Set(canvas.visibleNodes())
        let ids = s.focus.isEmpty ? Array(shown) : s.focus.filter(shown.contains)
        return Set(ids.filter { canvas.nodes[$0].map { !$0.presentHidden } ?? false })
    }

    /// The slide's own topic: the main topic of a branch, a flow's target, the central
    /// topic on the title slide.
    func slideTopic(_ s: Slide) -> NodeID? {
        if let t = s.timeline { return t }
        if let h = s.highlight.last { return h }
        return s.id == "title" ? canvas.root : nil
    }

    /// The task line under the slide's title, as topics show it (D201), honouring Settings ›
    /// Show task details on topics.
    public func slideTaskLine(_ s: Slide) -> String? {
        guard prefs.bool("editing.taskDetails"), s.timeline == nil, let id = slideTopic(s) else { return nil }
        return TaskFormat.line(canvas, id, today: todayDate)
    }

    /// "Build · Timeline" for a Timeline slide, else the slide's title.
    public func slideTitle(_ s: Slide) -> String {
        s.timeline != nil ? Loc.f("%@ · Timeline", s.title) : s.title
    }

    /// L in Present, or the strip's Legend chip: the corner legend on or off (one undo step).
    public func togglePresentLegend() {
        guard canvas.legend?.visible == true else {
            showToast(Loc.t("This canvas has no legend · ⌥⌘L shows one"))
            return
        }
        setPresentation(Loc.t("Legend on Slides")) { $0.legend.toggle() }
    }

    /// T in Present, or the strip's chip: Timeline slides after branches with dated tasks.
    public func togglePresentTimeline() {
        guard canvasHasScheduledTasks || canvas.presentation.timeline else {
            showToast(Loc.t("No dated tasks on this canvas"))
            return
        }
        // Keep the current slide when the deck grows or shrinks.
        let current = present.flatMap { p in p.index < slides.count ? slides[p.index].id : nil }
        setPresentation(Loc.t("Timeline Slides")) { $0.timeline.toggle() }
        if let current, let i = slides.firstIndex(where: { $0.id == current }) { goToSlide(i) }
    }

    /// The canvas has a dated task (the Timeline chip shows only then).
    var canvasHasScheduledTasks: Bool { canvas.nodes.values.contains { $0.todo?.isScheduled == true } }

    /// The topics a Timeline slide charts: its branch, or every topic for a diagram's
    /// Timeline, which is filed under the central topic (D235).
    func timelineTopics(_ top: NodeID) -> [NodeID] {
        top == canvas.root
            ? canvas.tops.flatMap { canvas.subtree($0, includeFolded: true) } : canvas.subtree(top, includeFolded: true)
    }

    /// The compact Gantt for a Timeline slide (D202): the branch's rows, over its own dates.
    func timelineChart(for s: Slide) -> TimelineChart? {
        guard let top = s.timeline, canvas.nodes[top] != nil else { return nil }
        let only = Set(timelineTopics(top))
        func layout(_ scale: GanttScale) -> GanttLayout {
            GanttLayout(canvas: canvas, collapsed: [], scale: scale, today: todayDate, only: only)
        }
        var l = layout(.day)
        var bars = l.rows.compactMap(\.bar).reduce(CGRect.null) { $0.union($1) }
        guard !bars.isNull else { return nil }
        // Long branches step out to weeks so the bars stay readable.
        if bars.width / l.dayWidth > 45 {
            l = layout(.week)
            bars = l.rows.compactMap(\.bar).reduce(CGRect.null) { $0.union($1) }
        }
        let pad = l.dayWidth * (l.scale == .day ? 2 : 7)
        let minX = max(l.tableWidth, bars.minX - pad)
        let maxX = min(l.size.width, bars.maxX + pad)
        var r = GanttRenderer(layout: l)
        r.palette = scene.theme.isDark ? .dark : .light
        r.colors = ganttColors
        r.title = canvas.nodes[top]?.text
        return TimelineChart(renderer: r, from: minX, to: maxX)
    }

    /// What VoiceOver reads for a Timeline slide's chart.
    func timelineSpoken(_ s: Slide) -> String {
        guard let top = s.timeline else { return "" }
        let rows = timelineTopics(top).compactMap { id -> String? in
            guard let n = canvas.nodes[id], n.todo != nil else { return nil }
            return [n.text, TaskFormat.line(canvas, id, today: todayDate)].compactMap { $0 }.joined(separator: ", ")
        }
        return Loc.f("Timeline for %@", s.title) + ": " + rows.joined(separator: "; ")
    }
}

/// Where the corner legend sits on a slide (D200, D232): bottom-left, on the progress
/// dots' line, a little larger than on the canvas and never taller than `maxHeight`.
/// The overlay, the framing and the exported slides all place it from here. On screen
/// it is also never wider than leaves room for the slide counter (D265).
struct PresentLegendPlacement: Equatable {
    var leading: CGFloat
    /// From the bottom of the view or slide to the bottom of the box.
    var bottom: CGFloat
    var base: CGFloat
    var maxHeight: CGFloat
    var maxWidth: CGFloat = .infinity

    /// On screen: 1.2×, 28 pt above the slide strip, or above the window's edge when the
    /// stage is alone. In a view `viewWidth` wide with `slides` slides, the box leaves
    /// room right of it for the progress dots' narrowest form, the counter (D265).
    @MainActor
    static func screen(stageOnly: Bool, viewWidth: CGFloat = .infinity, slides: Int = 0) -> Self {
        let room =
            viewWidth - 56 - PresentProgress.trailing - PresentProgress.gap - PresentProgress.counterWidth(slides)
        return Self(
            leading: 56, bottom: 28 + (stageOnly ? 0 : SlideStripView.height), base: 1.2, maxHeight: 320,
            maxWidth: max(room, 120))
    }

    /// On an exported slide (1920 × 1080): 2×, at the title's margin. Exports have no
    /// progress dots.
    static func export(_ size: CGSize) -> Self {
        Self(leading: 84, bottom: 64, base: 2, maxHeight: size.height * 0.42)
    }

    func scale(_ l: SceneLegend) -> CGFloat {
        min(base, maxHeight / max(l.rect.height, 1), maxWidth / max(l.rect.width, 1))
    }

    /// The box in a view or slide of `size` (flipped: y grows down).
    func rect(_ l: SceneLegend, in size: CGSize) -> CGRect {
        let k = scale(l)
        let h = l.rect.height * k
        return CGRect(x: leading, y: size.height - bottom - h, width: l.rect.width * k, height: h)
    }
}

/// The progress dots on the legend's line, right-aligned, 56 pt in (D236, D265). They
/// take the room right of the legend, 24 pt clear of it: full size if they fit, then
/// condensed, then as a counter ("Slide 12 of 60"), so they never meet the legend.
@MainActor
enum PresentProgress {
    static let trailing: CGFloat = 56
    /// The clear space between the legend and the dots.
    static let gap: CGFloat = 24

    enum Style: Equatable {
        /// `size`-pt dots `spacing` apart; the current one is `current` wide.
        case dots(size: CGFloat, spacing: CGFloat, current: CGFloat)
        case counter
    }

    static let full = Style.dots(size: 7, spacing: 6, current: 22)
    static let condensed = Style.dots(size: 5, spacing: 3, current: 14)

    static var counterFont: NSFont {
        .monospacedSystemFont(ofSize: (13 * ChromeText.shared.scale).rounded(.toNearestOrEven), weight: .medium)
    }

    /// "Slide 3 of 60", as the counter and VoiceOver read it.
    static func counter(_ index: Int, of count: Int) -> String { Loc.f("Slide %lld of %lld", index + 1, count) }

    /// The widest the counter gets for a deck of `count` slides.
    static func counterWidth(_ count: Int) -> CGFloat {
        let n = max(count, 1)
        let s = NSAttributedString(string: counter(n - 1, of: n), attributes: [.font: counterFont])
        return ceil(s.size().width) + 4
    }

    static func width(_ style: Style, count: Int) -> CGFloat {
        switch style {
        case .dots(let size, let spacing, let current):
            count < 1 ? 0 : current + CGFloat(count - 1) * (size + spacing)
        case .counter: counterWidth(count)
        }
    }

    /// The room right of the legend (or of the 56 pt margin when there is none).
    static func room(viewWidth: CGFloat, legend: CGRect?) -> CGFloat {
        viewWidth - trailing - (legend.map { $0.maxX + gap } ?? 56)
    }

    static func style(count: Int, room: CGFloat) -> Style {
        if width(full, count: count) <= room { return full }
        if width(condensed, count: count) <= room { return condensed }
        return .counter
    }

    /// Where the dots (or the counter) go in a view of `size`, with their bottom
    /// `bottom` above its lower edge.
    static func rect(count: Int, viewSize size: CGSize, legend: CGRect?, bottom: CGFloat) -> CGRect {
        let s = style(count: count, room: room(viewWidth: size.width, legend: legend))
        let w = width(s, count: count)
        let h: CGFloat =
            switch s {
            case .dots(let d, _, _): d
            case .counter: ceil(counterFont.ascender - counterFont.descender)
            }
        return CGRect(x: size.width - trailing - w, y: size.height - bottom - h, width: w, height: h)
    }
}

/// Where a slide's title ends, measured as the overlay and the exported slide set it,
/// so a Timeline chart can sit under it (D264).
@MainActor
enum SlideTitleMetrics {
    /// On screen: the kicker and up to two lines of title, 36 pt from the top and 56 pt in.
    static func screen(_ c: CanvasController, _ s: Slide, width: CGFloat) -> CGFloat {
        let k = ChromeText.shared.scale
        func font(_ size: CGFloat, _ weight: NSFont.Weight, mono: Bool = false) -> NSFont {
            let pt = (size * k).rounded(.toNearestOrEven)
            return mono ? .monospacedSystemFont(ofSize: pt, weight: weight) : .systemFont(ofSize: pt, weight: weight)
        }
        let lm = NSLayoutManager()
        let title = font(40, .bold)
        let text = NSAttributedString(string: c.slideTitle(s), attributes: [.font: title])
        let h = text.boundingRect(
            with: CGSize(width: max(width - 56, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        var y = 36 + lm.defaultLineHeight(for: font(13, .medium, mono: true)) + 6
        y += min(ceil(h), ceil(lm.defaultLineHeight(for: title) * 2))
        if c.slideTaskLine(s) != nil { y += 6 + lm.defaultLineHeight(for: font(16, .regular, mono: true)) }
        return y
    }

    /// On an exported slide: the title's text in its box from 92 pt down, then the task line.
    static func export(_ c: CanvasController, _ s: Slide, size: CGSize) -> CGFloat {
        let title = NSAttributedString(
            string: c.slideTitle(s), attributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold)])
        let box = titleBox(size)
        let h = ceil(title.boundingRect(with: box.size, options: [.usesLineFragmentOrigin]).height)
        var y = box.minY + min(h, box.height)
        if let line = c.slideTaskLine(s) { y += 8 + ceil(taskLine(line).size().height) }
        return y
    }

    /// The exported slide's title box.
    static func titleBox(_ size: CGSize) -> CGRect { CGRect(x: 84, y: 92, width: size.width - 168, height: 160) }

    /// The exported slide's task line.
    static func taskLine(_ line: String, ink: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                .foregroundColor: ink.withAlphaComponent(0.72),
            ])
    }
}

/// Where a Timeline slide's chart goes (D264): under the title, across the slide, and
/// never taller than `share` of the height down to the bottom margin, so the slide's
/// topics keep room below it. The overlay, the framing and the export place it from here.
struct TimelinePlacement: Equatable {
    /// The box the chart is fitted into; it is drawn at its top, centred across.
    var target: CGRect
    var maxScale: CGFloat
    static let share: CGFloat = 0.6

    static func make(top: CGFloat, inset: CGFloat, bottom: CGFloat, size: CGSize, maxScale: CGFloat) -> Self {
        let room = max(size.height - bottom - top, 1)
        return Self(
            target: CGRect(x: inset, y: top, width: max(size.width - 2 * inset, 1), height: room * share),
            maxScale: maxScale)
    }

    /// On screen: 30 pt under the title, 56 pt in, above the strip (or the window's edge).
    @MainActor
    static func screen(_ c: CanvasController, _ s: Slide, size: CGSize, stageOnly: Bool) -> Self {
        let top = SlideTitleMetrics.screen(c, s, width: size.width) + 30
        return make(top: top, inset: 56, bottom: stageOnly ? 64 : 304, size: size, maxScale: 1.6)
    }

    /// On a 1920 × 1080 slide: 40 pt under the title, 84 pt in, 72 pt from the bottom.
    @MainActor
    static func export(_ c: CanvasController, _ s: Slide, size: CGSize) -> Self {
        make(top: SlideTitleMetrics.export(c, s, size: size) + 40, inset: 84, bottom: 72, size: size, maxScale: 2.4)
    }

    /// The chart's own rectangle.
    func drawn(_ chart: TimelineChart) -> CGRect { chart.rect(in: target, maxScale: maxScale) }
}

/// Fitting a slide's topics to the stage around the corner legend (D232, D263) and under
/// a Timeline slide's chart (D264).
enum SlideFit {
    static let maxZoom: CGFloat = 1.4
    /// The clear space kept between the legend and the nearest topic.
    static let gap: CGFloat = 12
    /// Between a Timeline chart and the topics below it: room for a flow step's kind
    /// label ("START") over its box.
    static let chartGap: CGFloat = 24

    /// `content` (world) centred in `target` (view), as large as fits.
    static func camera(_ content: CGRect, in target: CGRect) -> Camera {
        let z = min(
            maxZoom, max(0.1, min(target.width / max(content.width, 1), target.height / max(content.height, 1))))
        return Camera(offset: CGPoint(x: target.midX - content.midX * z, y: target.midY - content.midY * z), zoom: z)
    }

    /// The whole-stage fit, unless it puts one of `topics` (world rects: the slide's topics
    /// and the outlines framed with them) or `lines` (world paths: the branch lines
    /// between them) under `legend` (view). Then the content fits the stage above the
    /// legend or beside it, whichever is larger, and moves from the centre only as far as
    /// that space asks. With a Timeline `chart` (view), the stage is what lies below it.
    static func camera(
        _ content: CGRect, topics: [CGRect], lines: [CGPath] = [], stage: CGRect, legend: CGRect?,
        chart: CGRect? = nil
    ) -> Camera {
        var stage = stage
        if let chart {
            let top = max(stage.minY, chart.maxY + chartGap)
            if stage.maxY - top >= 40 {
                stage = CGRect(x: stage.minX, y: top, width: stage.width, height: stage.maxY - top)
            }
        }
        let full = camera(content, in: stage)
        guard let legend else { return full }
        let keepOut = legend.insetBy(dx: -gap, dy: -gap)
        // A topic may touch the edge of the kept-out space, so the test leaves it half the gap.
        let near = legend.insetBy(dx: -gap / 2, dy: -gap / 2)
        let box = CGPath(rect: near, transform: nil)
        func clear(_ c: Camera) -> Bool {
            if topics.contains(where: { c.toView($0).intersects(near) }) { return false }
            var t = CGAffineTransform(a: c.zoom, b: 0, c: 0, d: c.zoom, tx: c.offset.x, ty: c.offset.y)
            return !lines.contains { l in
                guard let v = l.copy(using: &t), v.boundingBoxOfPath.insetBy(dx: -1, dy: -1).intersects(near) else {
                    return false
                }
                return v.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10).intersects(box)
            }
        }
        if clear(full) { return full }
        func placed(in r: CGRect) -> Camera {
            var c = camera(content, in: r)
            let w = content.width * c.zoom
            let h = content.height * c.zoom
            let x = min(max(stage.midX - w / 2, r.minX), r.maxX - w)
            let y = min(max(stage.midY - h / 2, r.minY), r.maxY - h)
            c.offset = CGPoint(x: x - content.minX * c.zoom, y: y - content.minY * c.zoom)
            return c
        }
        let above = CGRect(x: stage.minX, y: stage.minY, width: stage.width, height: keepOut.minY - stage.minY)
        let beside = CGRect(x: keepOut.maxX, y: stage.minY, width: stage.maxX - keepOut.maxX, height: stage.height)
        let fits = [above, beside].filter { $0.width >= 80 && $0.height >= 80 }.map(placed).filter(clear)
        func moved(_ c: Camera) -> CGFloat { hypot(c.offset.x - full.offset.x, c.offset.y - full.offset.y) }
        // The larger zoom wins; at the same zoom, the smaller move.
        return fits.min { a, b in
            abs(a.zoom - b.zoom) > 0.001 ? a.zoom > b.zoom : moved(a) < moved(b)
        } ?? full
    }
}

extension CanvasView {
    /// The corner legend's box on the current slide, in view coordinates, or nil when the
    /// slide has none (D232).
    func presentLegendRect() -> CGRect? {
        guard let p = controller.present else { return nil }
        let slides = controller.slides
        guard p.index < slides.count, let l = controller.presentLegend(for: slides[p.index]) else { return nil }
        let placement =
            slideExportSize.map(PresentLegendPlacement.export)
            ?? .screen(stageOnly: p.stageOnly, viewWidth: bounds.width, slides: slides.count)
        return placement.rect(l, in: bounds.size)
    }

    /// A Timeline slide's chart, in view coordinates, or nil on other slides (D264).
    func presentChartRect() -> CGRect? {
        guard let p = controller.present else { return nil }
        let slides = controller.slides
        guard p.index < slides.count, let chart = controller.timelineChart(for: slides[p.index]) else { return nil }
        let s = slides[p.index]
        let placement =
            slideExportSize.map { TimelinePlacement.export(controller, s, size: $0) }
            ?? .screen(controller, s, size: bounds.size, stageOnly: p.stageOnly)
        return placement.drawn(chart)
    }
}

/// A Gantt drawn between two x positions of its layout, with the table pinned at the left.
struct TimelineChart {
    var renderer: GanttRenderer
    var from: CGFloat
    var to: CGFloat

    var size: CGSize {
        let L = renderer.layout
        return CGSize(
            width: L.tableWidth + (to - from),
            height: GanttLayout.headerHeight + CGFloat(L.rows.count) * GanttLayout.rowHeight)
    }

    /// Where `draw(in:maxScale:)` puts the chart: scaled to fit `target` (never above
    /// `maxScale`), centred across it, at its top.
    func rect(in target: CGRect, maxScale: CGFloat) -> CGRect {
        let s = size
        let k = min(target.width / s.width, target.height / s.height, maxScale)
        return CGRect(
            x: target.minX + (target.width - s.width * k) / 2, y: target.minY, width: s.width * k, height: s.height * k)
    }

    /// Scaled to fit `target` (never above `maxScale`), centred, into the current flipped
    /// graphics context. Returns the rectangle drawn.
    @discardableResult
    func draw(in target: CGRect, maxScale: CGFloat) -> CGRect {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return .null }
        let s = size
        let drawn = rect(in: target, maxScale: maxScale)
        let k = drawn.width / s.width
        ctx.saveGState()
        NSBezierPath(roundedRect: drawn, xRadius: 10, yRadius: 10).addClip()
        ctx.translateBy(x: drawn.minX, y: drawn.minY)
        ctx.scaleBy(x: k, y: k)
        let pin = from - renderer.layout.tableWidth
        ctx.translateBy(x: -pin, y: 0)
        let visible = CGRect(x: pin, y: 0, width: s.width, height: s.height)
        ctx.clip(to: visible)
        renderer.draw(dirty: visible, pin: CGPoint(x: pin, y: 0))
        ctx.restoreGState()
        return drawn
    }
}

// MARK: On screen

/// The legend in the slide's bottom-left corner (D200).
struct PresentLegendCorner: View {
    let legend: SceneLegend
    let theme: Theme
    let canvas: RGBA
    let placement: PresentLegendPlacement

    var body: some View {
        let k = placement.scale(legend)
        LegendDrawing(legend: legend, theme: theme, canvas: canvas, scale: k)
            .frame(width: legend.rect.width * k, height: legend.rect.height * k)
            .accessibilityElement()
            .accessibilityLabel(legend.spoken)
            .accessibilityAddTraits(.isImage)
    }

    struct LegendDrawing: NSViewRepresentable {
        let legend: SceneLegend
        let theme: Theme
        let canvas: RGBA
        let scale: CGFloat
        func makeNSView(context: Context) -> Surface { Surface() }
        func updateNSView(_ v: Surface, context: Context) {
            v.legend = legend
            v.theme = theme
            v.canvas = canvas
            v.scale = scale
            v.needsDisplay = true
        }

        final class Surface: NSView {
            var legend: SceneLegend?
            var theme = Theme.classic
            var canvas = Theme.classic.canvas
            var scale: CGFloat = 1
            override var isFlipped: Bool { true }
            override func draw(_ dirtyRect: NSRect) {
                guard let l = legend, let ctx = NSGraphicsContext.current?.cgContext else { return }
                ctx.scaleBy(x: scale, y: scale)
                LegendLayer.draw(l, theme: theme, canvas: canvas, origin: l.rect.origin)
            }
        }
    }
}

/// A Timeline slide's chart, under the title in its `TimelinePlacement` box (D202, D264).
struct TimelineCard: View {
    let chart: TimelineChart
    let spoken: String
    let maxScale: CGFloat

    var body: some View {
        Drawing(chart: chart, maxScale: maxScale)
            .accessibilityElement()
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(.isImage)
    }

    struct Drawing: NSViewRepresentable {
        let chart: TimelineChart
        let maxScale: CGFloat
        func makeNSView(context: Context) -> Surface { Surface() }
        func updateNSView(_ v: Surface, context: Context) {
            v.chart = chart
            v.maxScale = maxScale
            v.needsDisplay = true
        }

        final class Surface: NSView {
            var chart: TimelineChart?
            var maxScale: CGFloat = 1.6
            override var isFlipped: Bool { true }
            override func draw(_ dirtyRect: NSRect) {
                guard let chart else { return }
                let drawn = chart.draw(in: bounds, maxScale: maxScale)
                NSColor.separatorColor.setStroke()
                let ring = NSBezierPath(roundedRect: drawn.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                ring.lineWidth = 1
                ring.stroke()
            }
        }
    }
}

// MARK: Slide exports

extension SlideExporter {
    /// The task line, the corner legend and the Timeline chart, drawn into a 1920 × 1080
    /// slide below the title that ends at `titleBottom` (flipped context).
    @MainActor
    static func drawExtras(_ c: CanvasController, slide: Slide, size: CGSize, titleBottom: CGFloat) {
        let theme = c.scene.theme
        let ink = NSColor(cgColor: theme.ink.cgColor) ?? .labelColor
        if let line = c.slideTaskLine(slide) {
            SlideTitleMetrics.taskLine(line, ink: ink).draw(at: CGPoint(x: 84, y: titleBottom + 8))
        }
        if let chart = c.timelineChart(for: slide) {
            // The same rectangle the framing kept the slide's topics below (D264).
            let place = TimelinePlacement.export(c, slide, size: size)
            let drawn = chart.draw(in: place.target, maxScale: place.maxScale)
            (NSColor(cgColor: theme.ink.alpha(0.22).cgColor) ?? .gray).setStroke()
            let ring = NSBezierPath(roundedRect: drawn.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        if let l = c.presentLegend(for: slide), let ctx = NSGraphicsContext.current?.cgContext {
            // The same box the framing kept clear (D232).
            let placement = PresentLegendPlacement.export(size)
            let k = placement.scale(l)
            let box = placement.rect(l, in: size)
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.minY)
            ctx.scaleBy(x: k, y: k)
            LegendLayer.draw(l, theme: theme, canvas: c.scene.canvasColor, origin: l.rect.origin)
            ctx.restoreGState()
        }
    }
}
