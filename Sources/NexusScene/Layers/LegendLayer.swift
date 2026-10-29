import CoreGraphics
import CoreText
import Foundation
import NexusCore
import NexusTheme
import QuartzCore

extension MarkerLibrary {
    /// A marker's own name, shown in the legend unless the canvas describes it (M14).
    public static func name(_ id: String) -> String {
        if id.hasPrefix("priority-"), let n = Int(id.dropFirst(9)) { return Loc.f("Priority %lld", n) }
        switch id {
        case "progress-0": return Loc.t("Not started")
        case "progress-13": return Loc.t("One eighth done")
        case "progress-25": return Loc.t("Quarter done")
        case "progress-38": return Loc.t("Three eighths done")
        case "progress-50": return Loc.t("Half done")
        case "progress-63": return Loc.t("Five eighths done")
        case "progress-75": return Loc.t("Three quarters done")
        case "progress-88": return Loc.t("Seven eighths done")
        case "progress-100": return Loc.t("Done")
        case "flag-red": return Loc.t("Red flag")
        case "flag-orange": return Loc.t("Orange flag")
        case "flag-green": return Loc.t("Green flag")
        case "flag-blue": return Loc.t("Blue flag")
        case "star-gold": return Loc.t("Gold star")
        case "star-red": return Loc.t("Red star")
        case "star-blue": return Loc.t("Blue star")
        case "symbol-question": return Loc.t("Question")
        case "symbol-exclaim": return Loc.t("Important")
        case "symbol-check": return Loc.t("Yes")
        case "symbol-cross": return Loc.t("No")
        case "symbol-arrow": return Loc.t("Next")
        case "people-me": return Loc.t("Me")
        case "people-team": return Loc.t("Team")
        case "people-external": return Loc.t("External")
        default: return id
        }
    }

    /// Library order (priority, progress, flags, stars, symbols, people), then the rest.
    package static func order(_ ids: [String]) -> [String] {
        let all = groups.flatMap(\.markers).map(\.id)
        let known = all.filter(ids.contains)
        return known + ids.filter { !all.contains($0) }
    }
}

/// The legend as drawn (M14): a box beside the map, or where it was dragged.
public struct SceneLegend: Equatable {
    public struct Row: Equatable {
        /// A marker id, or nil for a label row.
        public var marker: String?
        public var label: String?
        /// The marker's description (its own name unless the canvas gives one).
        public var text: String
        /// World coordinates.
        public var rect: CGRect
    }
    public var rect: CGRect
    public var rows: [Row]
    /// No stored position: placed beside the map, and it follows the map's edge.
    public var automatic: Bool

    package static let padding: CGFloat = 12
    package static let titleHeight: CGFloat = 24
    package static let rowHeight: CGFloat = 22
    package static let glyph: CGFloat = 26
    package static var font: CTFont { Fonts.system(12) }
    package static var titleFont: CTFont { Fonts.system(12, .semibold) }
    package static var labelFont: CTFont { Fonts.system(11, .medium) }

    /// Lays the legend out beside `content` (the rest of the scene), or at its position.
    /// `among` keeps only the markers and labels those topics carry, in the canvas
    /// legend's order and with its names, and leaves an empty legend empty (a slide's
    /// corner legend, D233).
    @MainActor
    package static func make(
        _ legend: Legend, canvas: NexusCore.Canvas, content: CGRect, among: Set<NodeID>? = nil
    ) -> SceneLegend {
        var used = canvas.legendContents
        if let among {
            let on = among.compactMap { canvas.nodes[$0] }
            let markers = Set(on.flatMap(\.markers))
            let labels = Set(on.flatMap(\.labels))
            used = (used.markers.filter(markers.contains), used.labels.filter(labels.contains))
        }
        var rows: [Row] = []
        for m in MarkerLibrary.order(used.markers) {
            rows.append(Row(marker: m, text: legend.markers[m] ?? MarkerLibrary.name(m), rect: .zero))
        }
        for l in used.labels { rows.append(Row(label: l, text: l, rect: .zero)) }
        if rows.isEmpty, among == nil { rows.append(Row(text: Loc.t("No markers or labels yet"), rect: .zero)) }
        func width(_ s: String, _ f: CTFont) -> CGFloat { ceil(s.width(in: f)) }
        var w = max(140, width(Loc.t("Legend"), titleFont))
        for r in rows {
            w = max(
                w, r.label != nil ? width(r.text, labelFont) + 16 : (r.marker != nil ? glyph : 0) + width(r.text, font))
        }
        w += padding * 2
        let h = padding * 2 + titleHeight + CGFloat(rows.count) * rowHeight
        let auto = legend.position == nil
        let origin =
            legend.position.map { CGPoint(x: $0.x, y: $0.y) }
            ?? (content.isNull ? .zero : CGPoint(x: content.maxX + 48, y: content.minY))
        for i in rows.indices {
            rows[i].rect = CGRect(
                x: origin.x + padding, y: origin.y + padding + titleHeight + CGFloat(i) * rowHeight,
                width: w - padding * 2, height: rowHeight)
        }
        return SceneLegend(rect: CGRect(x: origin.x, y: origin.y, width: w, height: h), rows: rows, automatic: auto)
    }

    /// "Legend: Priority 1, Urgent. Red flag. Label Q4." for VoiceOver.
    public var spoken: String {
        let parts = rows.map { r -> String in
            if let l = r.label { return Loc.f("Label %@", l) }
            if let m = r.marker, r.text != MarkerLibrary.name(m) { return MarkerLibrary.name(m) + ", " + r.text }
            return r.text
        }
        return Loc.t("Legend") + ": " + parts.joined(separator: ". ") + "."
    }
}

/// Draws the legend box in world coordinates, above the topics.
package final class LegendLayer: CALayer {
    package var legend: SceneLegend? {
        didSet { if legend != oldValue { refresh() } }
    }
    package var theme: Theme = .classic
    package var canvasColor = Theme.classic.canvas
    /// Selected from the keyboard or a click (M21): drawn with the selection ring.
    package var selected = false {
        didSet { if selected != oldValue { setNeedsDisplay() } }
    }

    package override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
        actions = NodeLayer.noActions
    }

    package override init(layer: Any) { super.init(layer: layer) }
    package required init?(coder: NSCoder) { fatalError() }

    package func refresh() {
        isHidden = legend == nil
        if let l = legend { frame = l.rect }
        setNeedsDisplay()
    }

    package override func draw(in ctx: CGContext) {
        guard let l = legend else { return }
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        Self.draw(l, theme: theme, canvas: canvasColor, origin: l.rect.origin, in: ctx)
        if selected {
            let ring = Shapes.roundedRect(CGRect(origin: .zero, size: l.rect.size).insetBy(dx: 1.5, dy: 1.5), radius: 9)
            Shapes.stroke(ring, theme.ring.cgColor, width: 3, in: ctx)
        }
    }

    /// Draws into a flipped context, offset so `origin` is (0, 0).
    package static func draw(_ l: SceneLegend, theme: Theme, canvas: RGBA, origin: CGPoint, in ctx: CGContext) {
        let box = CGRect(origin: .zero, size: l.rect.size).insetBy(dx: 0.5, dy: 0.5)
        let path = Shapes.roundedRect(box, radius: 10)
        // An opaque card in the slide's (or canvas's) own colour: whatever passes under it
        // is covered, never drawn through the rows (D263).
        Shapes.fill(path, canvas.alpha(1).cgColor, in: ctx)
        Shapes.fill(path, theme.ink.alpha(0.06).cgColor, in: ctx)
        Shapes.stroke(path, theme.ink.alpha(0.22).cgColor, width: 1, in: ctx)
        let ink = TextColorValue.fixed(theme.ink.cgColor)
        let ink2 = TextColorValue.fixed(theme.ink2.cgColor)
        StyledText(Loc.t("Legend"), TextAttributes(font: SceneLegend.titleFont, color: ink))
            .draw(at: CGPoint(x: SceneLegend.padding, y: SceneLegend.padding + 2), in: ctx)
        for r in l.rows {
            let rr = r.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            if let label = r.label {
                let s = StyledText(label, TextAttributes(font: SceneLegend.labelFont, color: ink))
                let pill = CGRect(x: rr.minX, y: rr.midY - 9, width: ceil(s.lineSize.width) + 16, height: 18)
                Shapes.fill(Shapes.roundedRect(pill, radius: 9), theme.ink.alpha(0.1).cgColor, in: ctx)
                s.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 2), in: ctx)
                continue
            }
            var x = rr.minX
            if let m = r.marker {
                drawMarker(m, in: CGRect(x: x, y: rr.midY - 9, width: 18, height: 18), context: ctx)
                x += SceneLegend.glyph
            }
            StyledText(r.text, TextAttributes(font: SceneLegend.font, color: r.marker == nil ? ink2 : ink))
                .draw(at: CGPoint(x: x, y: rr.midY - 8), in: ctx)
        }
    }

    /// A marker as topics draw it: a coloured disc with its glyph. `flipped` says the
    /// context's y axis points down.
    package static func drawMarker(_ id: String, in r: CGRect, context ctx: CGContext, flipped: Bool = true) {
        if id.hasPrefix("priority-"), let n = Int(id.dropFirst(9)) {
            NodeLayer.drawPriority(n, in: r, context: ctx, flipped: flipped)
            return
        }
        let mk = MarkerLibrary.marker(id)
        Shapes.fill(Shapes.oval(in: r), RGBA(hex: mk?.color ?? "#8A8A96").cgColor, in: ctx)
        if let pie = mk?.pie {
            drawPie(pie, in: r, context: ctx)
            return
        }
        StyledText(
            mk?.glyph ?? "•",
            TextAttributes(font: Fonts.system(10.5, .bold), color: .system(.white), paragraph: .centered)
        ).draw(in: r.offsetBy(dx: 0, dy: 2), context: ctx, flipped: flipped)
    }
}

extension LegendLayer {
    /// The pie's radius and ring, as fractions of the marker's disc: the size of ◑.
    package static let pieRadius = 0.24
    package static let pieLine = 1.0 / 16

    /// A progress marker's pie, drawn like the ◑ glyph: a white ring, filled clockwise
    /// from twelve o'clock (D247). The context is flipped.
    package static func drawPie(_ fraction: Double, in r: CGRect, context ctx: CGContext) {
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = r.width * pieRadius
        let white = Graphics.platform.color(.white)
        let ring = Shapes.oval(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        Shapes.stroke(ring, white, width: r.width * pieLine, in: ctx)
        let wedge = CGMutablePath()
        wedge.move(to: c)
        wedge.addArc(
            center: c, radius: radius, startAngle: -.pi / 2, endAngle: (-90 + 360 * CGFloat(fraction)) * .pi / 180,
            clockwise: false)
        wedge.closeSubpath()
        Shapes.fill(wedge, white, in: ctx)
    }
}
