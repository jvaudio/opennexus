import AppKit
import NexusCore
import NexusKeys
import NexusTheme
import SwiftUI

// MARK: Marker names

extension MarkerLibrary {
    /// A marker's own name, shown in the legend unless the canvas describes it (M14).
    public static func name(_ id: String) -> String {
        if id.hasPrefix("priority-"), let n = Int(id.dropFirst(9)) { return Loc.f("Priority %lld", n) }
        switch id {
        case "progress-0": return Loc.t("Not started")
        case "progress-25": return Loc.t("Quarter done")
        case "progress-50": return Loc.t("Half done")
        case "progress-75": return Loc.t("Three quarters done")
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
    static func order(_ ids: [String]) -> [String] {
        let all = groups.flatMap(\.markers).map(\.id)
        let known = all.filter(ids.contains)
        return known + ids.filter { !all.contains($0) }
    }
}

// MARK: Scene

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

    static let padding: CGFloat = 12
    static let titleHeight: CGFloat = 24
    static let rowHeight: CGFloat = 22
    static let glyph: CGFloat = 26
    static var font: NSFont { .systemFont(ofSize: 12) }
    static var titleFont: NSFont { .systemFont(ofSize: 12, weight: .semibold) }
    static var labelFont: NSFont { .systemFont(ofSize: 11, weight: .medium) }

    /// Lays the legend out beside `content` (the rest of the scene), or at its position.
    /// `among` keeps only the markers and labels those topics carry, in the canvas
    /// legend's order and with its names, and leaves an empty legend empty (a slide's
    /// corner legend, D233).
    @MainActor
    static func make(
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
        func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
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

// MARK: Drawing

/// Draws the legend box in world coordinates, above the topics.
final class LegendLayer: CALayer {
    var legend: SceneLegend? {
        didSet { if legend != oldValue { refresh() } }
    }
    var theme: Theme = .classic
    var canvasColor = Theme.classic.canvas
    /// Selected from the keyboard or a click (M21): drawn with the selection ring.
    var selected = false {
        didSet { if selected != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
        actions = NodeLayer.noActions
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        isHidden = legend == nil
        if let l = legend { frame = l.rect }
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let l = legend else { return }
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        Self.draw(l, theme: theme, canvas: canvasColor, origin: l.rect.origin)
        if selected {
            let ring = NSBezierPath(
                roundedRect: CGRect(origin: .zero, size: l.rect.size).insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
            ring.lineWidth = 3
            (NSColor(cgColor: theme.ring.cgColor) ?? .controlAccentColor).setStroke()
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws into the current (flipped) graphics context, offset so `origin` is (0, 0).
    static func draw(_ l: SceneLegend, theme: Theme, canvas: RGBA, origin: CGPoint) {
        let box = CGRect(origin: .zero, size: l.rect.size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        // An opaque card in the slide's (or canvas's) own colour: whatever passes under it
        // is covered, never drawn through the rows (D263).
        (NSColor(cgColor: canvas.alpha(1).cgColor) ?? .white).setFill()
        path.fill()
        (NSColor(cgColor: theme.ink.alpha(0.06).cgColor) ?? .clear).setFill()
        path.fill()
        (NSColor(cgColor: theme.ink.alpha(0.22).cgColor) ?? .gray).setStroke()
        path.lineWidth = 1
        path.stroke()
        let ink = NSColor(cgColor: theme.ink.cgColor) ?? .labelColor
        let ink2 = NSColor(cgColor: theme.ink2.cgColor) ?? .secondaryLabelColor
        NSAttributedString(
            string: Loc.t("Legend"), attributes: [.font: SceneLegend.titleFont, .foregroundColor: ink]
        ).draw(at: CGPoint(x: SceneLegend.padding, y: SceneLegend.padding + 2))
        for r in l.rows {
            let rr = r.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            if let label = r.label {
                let s = NSAttributedString(
                    string: label, attributes: [.font: SceneLegend.labelFont, .foregroundColor: ink])
                let pill = CGRect(x: rr.minX, y: rr.midY - 9, width: ceil(s.size().width) + 16, height: 18)
                (NSColor(cgColor: theme.ink.alpha(0.1).cgColor) ?? .gray).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
                s.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 2))
                continue
            }
            var x = rr.minX
            if let m = r.marker {
                drawMarker(m, in: CGRect(x: x, y: rr.midY - 9, width: 18, height: 18))
                x += SceneLegend.glyph
            }
            NSAttributedString(
                string: r.text, attributes: [.font: SceneLegend.font, .foregroundColor: r.marker == nil ? ink2 : ink]
            ).draw(at: CGPoint(x: x, y: rr.midY - 8))
        }
    }

    /// A marker as topics draw it: a coloured disc with its glyph.
    static func drawMarker(_ id: String, in r: CGRect) {
        if id.hasPrefix("priority-"), let n = Int(id.dropFirst(9)) {
            NodeLayer.priorityImage(n).draw(in: r)
            return
        }
        let mk = MarkerLibrary.marker(id)
        (NSColor(cgColor: RGBA(hex: mk?.color ?? "#8A8A96").cgColor) ?? .gray).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSAttributedString(
            string: mk?.glyph ?? "•",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: NSColor.white,
                .paragraphStyle: NodeLayer.centered,
            ]
        ).draw(in: r.offsetBy(dx: 0, dy: 2))
    }
}

// MARK: Editing (one undo step each)

@MainActor
extension CanvasController {
    /// View › Legend: shows or hides the legend, making one the first time.
    public func toggleLegend() {
        let show = !(canvas.legend?.visible ?? false)
        perform(show ? Loc.t("Show Legend") : Loc.t("Hide Legend")) { e in
            e.updateMeta { c in
                if c.legend == nil { c.legend = Legend() } else { c.legend?.visible = show }
            }
        }
        showToast(show ? Loc.t("Legend shown · ⌥⌘L hides it") : Loc.t("Legend hidden"))
    }

    public func setLegendVisible(_ on: Bool) {
        guard (canvas.legend?.visible ?? false) != on else { return }
        toggleLegend()
    }

    /// A marker's description; empty restores the marker's own name.
    public func setLegendDescription(_ text: String, for marker: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = canvas.legend?.markers[marker] ?? ""
        guard t != current, !(t.isEmpty && current.isEmpty) else { return }
        perform(Loc.t("Legend Description")) { e in
            e.updateMeta { c in
                var l = c.legend ?? Legend()
                l.markers[marker] = t.isEmpty ? nil : t
                c.legend = l
            }
        }
    }

    /// Where the legend's top-left corner goes (nil: back beside the map).
    public func moveLegend(to p: CanvasPoint?) {
        guard canvas.legend != nil, canvas.legend?.position != p else { return }
        perform(Loc.t("Move Legend")) { e in e.updateMeta { $0.legend?.position = p } }
    }

    /// Edit Legend…: the legend's descriptions and visibility.
    public func editLegend() {
        if mode == .edit { commitEdit() }
        onRequest?(.legend)
    }
}

// MARK: Editor

/// Edit Legend…: show or hide it, describe each marker, put it back beside the map.
struct LegendPopover: View {
    var controller: CanvasController
    var close: () -> Void
    @State private var drafts: [String: String] = [:]

    var markers: [String] { MarkerLibrary.order(controller.canvas.legendContents.markers) }
    var labels: [String] { controller.canvas.legendContents.labels }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Legend").font(.headline)
                Spacer()
                Button("Done") {
                    save()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            Toggle(
                "Show the legend on the canvas",
                isOn: Binding(
                    get: { controller.canvas.legend?.visible ?? false }, set: { controller.setLegendVisible($0) })
            )
            .toggleStyle(.checkbox)
            Text("MARKERS").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if markers.isEmpty { Text("No markers on this canvas yet.").foregroundStyle(.secondary) }
                    ForEach(markers, id: \.self) { m in
                        HStack(spacing: 8) {
                            MarkerDisc(id: m).frame(width: 18, height: 18).accessibilityHidden(true)
                            TextField(
                                MarkerLibrary.name(m),
                                text: Binding(get: { drafts[m] ?? "" }, set: { drafts[m] = $0 })
                            )
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                            .accessibilityLabel(Loc.f("Description for %@", MarkerLibrary.name(m)))
                        }
                    }
                }
            }
            .accessibilityLabel(Loc.t("Marker descriptions"))
            if !labels.isEmpty {
                Text("LABELS").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
                Text(labels.joined(separator: " · ")).font(.chrome(12.5)).lineLimit(3)
            }
            HStack {
                Text("An empty description shows the marker's own name. Drag the legend to move it.")
                    .font(.chrome(11)).foregroundStyle(.secondary)
                Spacer()
                if controller.canvas.legend?.position != nil {
                    Button("Reset Position") { controller.moveLegend(to: nil) }
                }
            }
        }
        .padding(14)
        .onAppear { drafts = controller.canvas.legend?.markers ?? [:] }
        .onDisappear(perform: save)
    }

    func save() {
        for m in markers where (drafts[m] ?? "") != (controller.canvas.legend?.markers[m] ?? "") {
            controller.setLegendDescription(drafts[m] ?? "", for: m)
        }
    }
}

/// A marker drawn as on topics, for SwiftUI.
struct MarkerDisc: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView { DiscView(id: id) }
    func updateNSView(_ v: NSView, context: Context) {}

    final class DiscView: NSView {
        let id: String
        init(id: String) {
            self.id = id
            super.init(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { LegendLayer.drawMarker(id, in: bounds) }
    }
}
