import AppKit
import NexusCore
import NexusTheme
import SwiftUI

// Present's legend, task lines and Timeline slides (M21). The screen and the slide
// exports draw the same pieces: the legend through `LegendLayer.draw`, the Timeline
// through `GanttRenderer`.

@MainActor
extension CanvasController {
    /// The legend in a corner of the slide (D200): the canvas shows one, the deck's Legend
    /// setting is on, and the slide isn't a Timeline (which has no markers).
    public func presentLegend(for slide: Slide?) -> SceneLegend? {
        guard let l = canvas.legend, l.visible, canvas.presentation.legend, slide?.timeline == nil else { return nil }
        return SceneLegend.make(l, canvas: canvas, content: .zero)
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

    /// The compact Gantt for a Timeline slide (D202): the branch's rows, over its own dates.
    func timelineChart(for s: Slide) -> TimelineChart? {
        guard let top = s.timeline, canvas.nodes[top] != nil else { return nil }
        let only = Set(canvas.subtree(top, includeFolded: true))
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
        let rows = canvas.subtree(top, includeFolded: true).compactMap { id -> String? in
            guard let n = canvas.nodes[id], n.todo != nil else { return nil }
            return [n.text, TaskFormat.line(canvas, id, today: todayDate)].compactMap { $0 }.joined(separator: ", ")
        }
        return Loc.f("Timeline for %@", s.title) + ": " + rows.joined(separator: "; ")
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

    /// A little larger than on the canvas, and never taller than `maxHeight`.
    static func scale(_ l: SceneLegend, base: CGFloat, maxHeight: CGFloat) -> CGFloat {
        min(base, maxHeight / max(l.rect.height, 1))
    }

    var body: some View {
        let k = Self.scale(legend, base: 1.2, maxHeight: 320)
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
            let k = PresentLegendCorner.scale(l, base: 2, maxHeight: size.height * 0.42)
            ctx.saveGState()
            ctx.translateBy(x: 84, y: size.height - 64 - l.rect.height * k)
            ctx.scaleBy(x: k, y: k)
            LegendLayer.draw(l, theme: theme, canvas: c.scene.canvasColor, origin: l.rect.origin)
            ctx.restoreGState()
        }
    }
}
