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
/// The overlay, the framing and the exported slides all place it from here.
struct PresentLegendPlacement: Equatable {
    var leading: CGFloat
    /// From the bottom of the view or slide to the bottom of the box.
    var bottom: CGFloat
    var base: CGFloat
    var maxHeight: CGFloat

    /// On screen: 1.2×, 28 pt above the slide strip, or above the window's edge when the
    /// stage is alone.
    static func screen(stageOnly: Bool) -> Self {
        Self(leading: 56, bottom: 28 + (stageOnly ? 0 : SlideStripView.height), base: 1.2, maxHeight: 320)
    }

    /// On an exported slide (1920 × 1080): 2×, at the title's margin.
    static func export(_ size: CGSize) -> Self {
        Self(leading: 84, bottom: 64, base: 2, maxHeight: size.height * 0.42)
    }

    func scale(_ l: SceneLegend) -> CGFloat { min(base, maxHeight / max(l.rect.height, 1)) }

    /// The box in a view or slide of `size` (flipped: y grows down).
    func rect(_ l: SceneLegend, in size: CGSize) -> CGRect {
        let k = scale(l)
        let h = l.rect.height * k
        return CGRect(x: leading, y: size.height - bottom - h, width: l.rect.width * k, height: h)
    }
}

/// Fitting a slide's topics to the stage around the corner legend (D232).
enum SlideFit {
    static let maxZoom: CGFloat = 1.4
    /// The clear space kept between the legend and the nearest topic.
    static let gap: CGFloat = 12

    /// `content` (world) centred in `target` (view), as large as fits.
    static func camera(_ content: CGRect, in target: CGRect) -> Camera {
        let z = min(
            maxZoom, max(0.1, min(target.width / max(content.width, 1), target.height / max(content.height, 1))))
        return Camera(offset: CGPoint(x: target.midX - content.midX * z, y: target.midY - content.midY * z), zoom: z)
    }

    /// The whole-stage fit, unless it puts one of `topics` (world rects) under `legend`
    /// (view). Then the content fits the stage above the legend or beside it, whichever
    /// is larger, and moves from the centre only as far as that space asks.
    static func camera(_ content: CGRect, topics: [CGRect], stage: CGRect, legend: CGRect?) -> Camera {
        let full = camera(content, in: stage)
        guard let legend else { return full }
        let keepOut = legend.insetBy(dx: -gap, dy: -gap)
        // A topic may touch the edge of the kept-out space, so the test leaves it half the gap.
        let near = legend.insetBy(dx: -gap / 2, dy: -gap / 2)
        func clear(_ c: Camera) -> Bool { !topics.contains { c.toView($0).intersects(near) } }
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
        let placement = slideLegendPlacement ?? .screen(stageOnly: p.stageOnly)
        return placement.rect(l, in: bounds.size)
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

    /// Scaled to fit `target` (never above `maxScale`), centred, into the current flipped
    /// graphics context. Returns the rectangle drawn.
    @discardableResult
    func draw(in target: CGRect, maxScale: CGFloat) -> CGRect {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return .null }
        let s = size
        let k = min(target.width / s.width, target.height / s.height, maxScale)
        let drawn = CGRect(
            x: target.minX + (target.width - s.width * k) / 2, y: target.minY, width: s.width * k, height: s.height * k)
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

/// A Timeline slide's chart, filling the stage under the title (D202).
struct TimelineCard: View {
    let chart: TimelineChart
    let spoken: String

    var body: some View {
        Drawing(chart: chart)
            .accessibilityElement()
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(.isImage)
    }

    struct Drawing: NSViewRepresentable {
        let chart: TimelineChart
        func makeNSView(context: Context) -> Surface { Surface() }
        func updateNSView(_ v: Surface, context: Context) {
            v.chart = chart
            v.needsDisplay = true
        }

        final class Surface: NSView {
            var chart: TimelineChart?
            override var isFlipped: Bool { true }
            override func draw(_ dirtyRect: NSRect) {
                guard let chart else { return }
                let drawn = chart.draw(in: bounds, maxScale: 1.6)
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
        var y = titleBottom
        if let line = c.slideTaskLine(slide) {
            let s = NSAttributedString(
                string: line,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                    .foregroundColor: ink.withAlphaComponent(0.72),
                ])
            s.draw(at: CGPoint(x: 84, y: y + 8))
            y += 8 + ceil(s.size().height)
        }
        if let chart = c.timelineChart(for: slide) {
            let target = CGRect(x: 84, y: y + 40, width: size.width - 168, height: size.height - y - 40 - 72)
            let drawn = chart.draw(in: target, maxScale: 2.4)
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
