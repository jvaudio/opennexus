import AppKit
import CoreText
import NexusCore
import NexusLayout
import NexusTheme

/// SVG export (artboard 30), written from the laid-out scene: shapes, branch lines,
/// relationships, boundaries, summaries, zones, markers, labels and text.
/// Text is live `<text>` (editable; uses the viewer's installed fonts) or outlined glyph
/// paths (exact everywhere). Metadata adds `data-nexus-*` attributes.
@MainActor
public enum SVGExporter {
    public struct Options: Equatable, Sendable {
        public var outlineText = false
        public var metadata = true
        public init() {}
    }

    public static func export(
        _ model: DocumentModel, canvas id: CanvasID, _ io: ImageExporter.Options, _ o: Options = Options()
    ) -> String {
        let controller = ImageExporter.controller(model, canvas: id, io)
        let scene = controller.scene
        let canvas = controller.canvas
        let b = scene.bounds
        let rect =
            b.isNull
            ? CGRect(x: 0, y: 0, width: 200, height: 120) : b.insetBy(dx: -io.padding, dy: -io.padding).integral
        var w = Writer(outline: o.outlineText)
        w.line(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(n(rect.minX)) \(n(rect.minY)) \(n(rect.width)) \(n(rect.height))\" width=\"\(n(rect.width))\" height=\"\(n(rect.height))\">"
        )
        w.indent += 1
        w.line("<title>\(esc(canvas.title.isEmpty ? canvas.nodes[canvas.root]?.text ?? "" : canvas.title))</title>")
        switch io.background {
        case .theme:
            w.line(
                "<rect x=\"\(n(rect.minX))\" y=\"\(n(rect.minY))\" width=\"\(n(rect.width))\" height=\"\(n(rect.height))\" fill=\"\(hex(scene.canvasColor))\"/>"
            )
        case .white:
            w.line(
                "<rect x=\"\(n(rect.minX))\" y=\"\(n(rect.minY))\" width=\"\(n(rect.width))\" height=\"\(n(rect.height))\" fill=\"#FFFFFF\"/>"
            )
        case .transparent: break
        }
        // Zones and boundaries sit behind everything.
        for z in scene.zones {
            w.line(
                "<g class=\"zone\"><rect x=\"\(n(z.rect.minX))\" y=\"\(n(z.rect.minY))\" width=\"\(n(z.rect.width))\" height=\"\(n(z.rect.height))\" rx=\"14\" fill=\"\(hex(z.color))\" fill-opacity=\"0.06\" stroke=\"\(hex(z.color))\" stroke-width=\"1.5\"/>"
            )
            w.text(
                z.zone.title, at: CGPoint(x: z.rect.minX + 14, y: z.rect.minY + 22),
                font: .systemFont(ofSize: 12, weight: .semibold), color: z.color)
            w.line("</g>")
        }
        for bd in scene.boundaries {
            let r = bd.rect
            let dash =
                bd.boundary.dash.map { $0 == "solid" ? "" : " stroke-dasharray=\"6 4\"" } ?? " stroke-dasharray=\"6 4\""
            w.line(
                "<g class=\"boundary\"><rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" rx=\"12\" fill=\"\(hex(bd.color))\" fill-opacity=\"\(n(bd.boundary.fillOpacity))\" stroke=\"\(hex(bd.color))\" stroke-width=\"\(n(bd.boundary.width))\"\(dash)/>"
            )
            if !bd.boundary.title.isEmpty {
                w.text(
                    bd.boundary.title, at: CGPoint(x: r.minX + 12, y: r.minY + 18),
                    font: .systemFont(ofSize: 12, weight: .semibold), color: bd.color)
            }
            w.line("</g>")
        }
        // Branch lines.
        w.line("<g class=\"branches\" fill=\"none\" stroke-linecap=\"round\">")
        w.indent += 1
        for e in scene.edges {
            guard let pf = scene.nodes[e.parent]?.frame, let cf = scene.nodes[e.child]?.frame else { continue }
            let path = BranchLines.path(
                from: pf, to: cf, family: e.family, shape: BranchLineShape(name: e.line.shape),
                parentBaseline: e.parentBaseline, childBaseline: e.childBaseline)
            if e.line.taper {
                let t = BranchLines.tapered(path, startWidth: e.line.width * 1.8, endWidth: max(1, e.line.width * 0.5))
                w.line("<path d=\"\(d(t))\" fill=\"\(hex(e.color))\" stroke=\"none\"\(opacity(e.opacity))/>")
            } else {
                let dash =
                    e.line.dash == "dashed"
                    ? " stroke-dasharray=\"6 5\"" : e.line.dash == "dotted" ? " stroke-dasharray=\"1.5 4\"" : ""
                w.line(
                    "<path d=\"\(d(path))\" stroke=\"\(hex(e.color))\" stroke-width=\"\(n(e.width))\"\(dash)\(opacity(e.opacity))/>"
                )
            }
        }
        w.indent -= 1
        w.line("</g>")
        // Summaries: a bracket beside the range.
        for s in scene.summaries {
            let r = s.bracket
            let p = CGMutablePath()
            let right = s.side != .left
            let x0 = right ? r.minX : r.maxX
            let x1 = right ? r.maxX : r.minX
            p.move(to: CGPoint(x: x0, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: x1, y: r.midY), control: CGPoint(x: x1, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: x0, y: r.maxY), control: CGPoint(x: x1, y: r.maxY))
            w.line(
                "<path class=\"summary\" d=\"\(d(p))\" fill=\"none\" stroke=\"\(hex(s.color))\" stroke-width=\"\(n(s.summary.width))\"/>"
            )
        }
        // Relationships.
        for r in scene.relationships {
            guard let a = scene.rect(of: r.relationship.from), let bb = scene.rect(of: r.relationship.to) else {
                continue
            }
            let g =
                r.points.map { RelationshipGeometry.polyline($0) }
                ?? RelationshipGeometry.make(r.relationship, from: a, to: bb)
            let dash =
                r.relationship.dash == "dashed"
                ? " stroke-dasharray=\"6 5\"" : r.relationship.dash == "dotted" ? " stroke-dasharray=\"1.5 4\"" : ""
            w.line(
                "<g class=\"relationship\"\(o.metadata ? " data-nexus-from=\"\(esc(r.relationship.from.rawValue))\" data-nexus-to=\"\(esc(r.relationship.to.rawValue))\"\(r.relationship.from.zone != nil ? " data-nexus-from-kind=\"zone\"" : "")\(r.relationship.to.zone != nil ? " data-nexus-to-kind=\"zone\"" : "")" : "")\(opacity(r.opacity))>"
            )
            w.indent += 1
            w.line(
                "<path d=\"\(d(g.path))\" fill=\"none\" stroke=\"\(hex(r.color))\" stroke-width=\"\(n(r.relationship.width))\"\(dash)/>"
            )
            for (i, kind) in r.relationship.ends.enumerated() where kind != "none" {
                let tip = i == 0 ? g.start : g.end
                let angle = i == 0 ? g.startAngle + .pi : g.endAngle
                let (cap, filled) = RelationshipGeometry.cap(
                    kind, at: tip, angle: angle, width: CGFloat(r.relationship.width))
                if let cap {
                    w.line(
                        "<path d=\"\(d(cap))\" fill=\"\(filled ? hex(r.color) : "none")\" stroke=\"\(hex(r.color))\" stroke-width=\"\(n(r.relationship.width))\"/>"
                    )
                }
            }
            if !r.relationship.label.isEmpty {
                let mid = g.point(at: 0.5)
                let font = NSFont.systemFont(ofSize: 12, weight: .medium)
                let size = (r.relationship.label as NSString).size(withAttributes: [.font: font])
                let pill = CGRect(x: mid.x - size.width / 2 - 8, y: mid.y - 11, width: size.width + 16, height: 22)
                w.line(
                    "<rect x=\"\(n(pill.minX))\" y=\"\(n(pill.minY))\" width=\"\(n(pill.width))\" height=\"\(n(pill.height))\" rx=\"11\" fill=\"\(hex(scene.canvasColor))\" stroke=\"\(hex(r.color))\"/>"
                )
                w.text(r.relationship.label, at: CGPoint(x: pill.minX + 8, y: mid.y + 4), font: font, color: r.color)
            }
            w.indent -= 1
            w.line("</g>")
        }
        // Topics in drawing order.
        let order = scene.order.isEmpty ? Array(scene.nodes.keys).sorted() : scene.order
        for id in order {
            guard let sn = scene.nodes[id], let node = canvas.nodes[id] else { continue }
            topic(sn, node, &w, metadata: o.metadata, theme: scene.theme)
        }
        w.indent -= 1
        w.line("</svg>")
        return w.out
    }

    static func topic(_ sn: SceneNode, _ node: Node, _ w: inout Writer, metadata: Bool, theme: Theme) {
        let a = sn.appearance
        let r = sn.frame.rect
        var attrs = "class=\"topic\""
        if metadata {
            attrs += " data-nexus-id=\"\(sn.id.rawValue)\""
            if let t = node.nodeType { attrs += " data-nexus-type=\"\(esc(t.rawValue))\"" }
            for f in node.metadata { attrs += " data-\(attrName(f.key))=\"\(esc(f.value))\"" }
            if !node.markers.isEmpty { attrs += " data-nexus-markers=\"\(esc(node.markers.joined(separator: " ")))\"" }
            if !node.labels.isEmpty { attrs += " data-nexus-labels=\"\(esc(node.labels.joined(separator: ", ")))\"" }
        }
        w.line("<g \(attrs) transform=\"translate(\(n(r.minX)) \(n(r.minY)))\"\(opacity(sn.opacity))>")
        w.indent += 1
        let bw = CGFloat(a.borderWidth)
        let box = CGRect(origin: .zero, size: r.size).insetBy(dx: bw / 2, dy: bw / 2)
        let open = ShapeLibrary.openShapes.contains(a.shape)
        if a.isUnderline {
            w.line(
                "<path d=\"M0 \(n(r.height - bw / 2)) H\(n(r.width))\" stroke=\"\(hex(a.borderColor))\" stroke-width=\"\(n(max(bw, 2)))\" fill=\"none\"/>"
            )
        } else {
            let outline = ShapeLibrary.path(a.shape, in: box, radius: max(0, CGFloat(a.cornerRadius) - bw / 2))
            var fill = "fill=\"none\""
            switch a.fill {
            case .solid(let c) where !open:
                fill = "fill=\"\(hex(c))\"" + (c.a < 1 ? " fill-opacity=\"\(n(c.a))\"" : "")
            case .gradient(let c1, let c2) where !open:
                let gid = "g\(sn.id.rawValue)"
                w.line(
                    "<defs><linearGradient id=\"\(gid)\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(hex(c2))\"/><stop offset=\"1\" stop-color=\"\(hex(c1))\"/></linearGradient></defs>"
                )
                fill = "fill=\"url(#\(gid))\""
            default: break
            }
            var stroke = ""
            if a.border != .none && bw > 0 {
                stroke = " stroke=\"\(hex(a.borderColor))\" stroke-width=\"\(n(bw))\""
                if a.border == .dashed { stroke += " stroke-dasharray=\"6 4\"" }
                if a.border == .dotted { stroke += " stroke-dasharray=\"1.5 3\" stroke-linecap=\"round\"" }
            }
            w.line("<path d=\"\(d(outline))\" \(fill)\(stroke)/>")
        }
        // Leading markers: priority, to-do, others.
        var x = sn.leadRect.minX
        let cy = sn.leadRect.midY
        if sn.progress != nil { x += SceneBuilder.markerWidth }
        if let p = sn.priority {
            let c = MarkerLibrary.marker("priority-\(p)").map { RGBA(hex: $0.color) } ?? RGBA(hex: "#4A4A55")
            w.line("<circle cx=\"\(n(x + 9))\" cy=\"\(n(cy))\" r=\"9\" fill=\"\(hex(c))\"/>")
            w.text(
                "\(p)", at: CGPoint(x: x + 9, y: cy + 3.8), font: .systemFont(ofSize: 10.5, weight: .bold),
                color: .white, anchor: "middle")
            x += SceneBuilder.priorityWidth
        }
        if let t = sn.todo {
            w.line(
                "<rect x=\"\(n(x + 1))\" y=\"\(n(cy - 7))\" width=\"14\" height=\"14\" rx=\"3.5\" fill=\"\(t.done ? hex(theme.ai) : "none")\" stroke=\"\(hex(t.done ? theme.ai : a.text))\" stroke-width=\"1.5\"/>"
            )
            if t.done {
                w.line(
                    "<path d=\"M\(n(x + 4.5)) \(n(cy)) l3 3 l5 -6\" fill=\"none\" stroke=\"#FFFFFF\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
                )
            }
            x += SceneBuilder.todoWidth
        }
        for m in sn.otherMarkers {
            if let mk = MarkerLibrary.marker(m) {
                w.line("<circle cx=\"\(n(x + 9))\" cy=\"\(n(cy))\" r=\"9\" fill=\"\(mk.color)\"/>")
                w.text(
                    mk.glyph, at: CGPoint(x: x + 9, y: cy + 3.8), font: .systemFont(ofSize: 10.5, weight: .bold),
                    color: .white, anchor: "middle")
            }
            x += SceneBuilder.markerWidth
        }
        // Title.
        w.block(sn.displayText, style: sn.textStyle, marks: sn.marks, in: sn.textRect, color: a.text)
        // Indicators and labels.
        for (i, ind) in sn.indicators.enumerated() where i < sn.indicatorRects.count {
            let ir = sn.indicatorRects[i]
            w.text(
                ind.glyph, at: CGPoint(x: ir.midX, y: ir.midY + 4.5), font: .systemFont(ofSize: 12, weight: .semibold),
                color: ind == .ai ? theme.ai : a.text.alpha(0.6), anchor: "middle")
        }
        for (i, l) in sn.labels.enumerated() where i < sn.labelRects.count {
            let lr = sn.labelRects[i]
            w.line(
                "<rect x=\"\(n(lr.minX))\" y=\"\(n(lr.minY))\" width=\"\(n(lr.width))\" height=\"\(n(lr.height))\" rx=\"\(n(lr.height / 2))\" fill=\"\(hex(sn.branchColor))\" fill-opacity=\"0.16\"/>"
            )
            w.text(
                l, at: CGPoint(x: lr.midX, y: lr.midY + 4), font: .systemFont(ofSize: 11, weight: .medium),
                color: sn.branchColor, anchor: "middle")
        }
        w.indent -= 1
        w.line("</g>")
    }

    // MARK: Writing

    @MainActor struct Writer {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        var indent = 0
        let outline: Bool

        init(outline: Bool) { self.outline = outline }

        mutating func line(_ s: String) { out += String(repeating: "  ", count: indent) + s + "\n" }

        /// One line of text at a baseline.
        mutating func text(_ s: String, at p: CGPoint, font: NSFont, color: RGBA, anchor: String = "start") {
            if outline {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let x = anchor == "middle" ? p.x - width / 2 : anchor == "end" ? p.x - width : p.x
                self.line("<path d=\"\(glyphs(line, origin: CGPoint(x: x, y: p.y)))\" fill=\"\(hex(color))\"/>")
            } else {
                self.line(
                    "<text x=\"\(n(p.x))\" y=\"\(n(p.y))\" font-family=\"\(SVGExporter.family(font))\" font-size=\"\(n(font.pointSize))\" font-weight=\"\(SVGExporter.weight(font))\" fill=\"\(hex(color))\"\(anchor == "start" ? "" : " text-anchor=\"\(anchor)\"")>\(esc(s))</text>"
                )
            }
        }

        /// A wrapped text block laid out by Core Text exactly as the canvas lays it out.
        mutating func block(_ s: String, style: NodeTextStyle, marks: [TextMark], in r: CGRect, color: RGBA) {
            guard !s.isEmpty, r.width > 0 else { return }
            let attr = style.attributed(s, marks: marks, color: NSColor(cgColor: color.cgColor) ?? .black)
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let frame = CTFramesetterCreateFrame(
                setter, CFRange(location: 0, length: 0),
                CGPath(rect: CGRect(x: 0, y: 0, width: r.width + 1, height: r.height + 400), transform: nil), nil)
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let total = r.height + 400
            for (line, o) in zip(lines, origins) {
                let base = CGPoint(x: r.minX + o.x, y: r.minY + (total - o.y))
                if outline {
                    self.line("<path d=\"\(glyphs(line, origin: base))\" fill=\"\(hex(color))\"/>")
                    continue
                }
                // The first run's position and font go on <text> itself (some renderers ignore
                // tspan positions); further runs (bold, links) follow as tspans.
                var head = ""
                var spans = ""
                for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                    let range = CTRunGetStringRange(run)
                    let text = (attr.string as NSString).substring(
                        with: NSRange(location: range.location, length: range.length)
                    )
                    .trimmingCharacters(in: .newlines)
                    guard !text.isEmpty else { continue }
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    let font = attrs[NSAttributedString.Key.font] as? NSFont ?? style.font
                    var pos = CGPoint.zero
                    CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
                    let shift = (attrs[NSAttributedString.Key.baselineOffset] as? CGFloat) ?? 0
                    var deco = ""
                    if attrs[NSAttributedString.Key.underlineStyle] != nil { deco = " text-decoration=\"underline\"" }
                    if attrs[NSAttributedString.Key.strikethroughStyle] != nil {
                        deco = " text-decoration=\"line-through\""
                    }
                    let italic = font.fontDescriptor.symbolicTraits.contains(.italic) ? " font-style=\"italic\"" : ""
                    let at = "x=\"\(n(base.x + pos.x))\" y=\"\(n(base.y - shift))\""
                    let face =
                        "font-family=\"\(SVGExporter.family(font))\" font-size=\"\(n(font.pointSize))\" font-weight=\"\(SVGExporter.weight(font))\"\(italic)\(deco)"
                    if head.isEmpty {
                        head = "<text \(at) \(face) fill=\"\(hex(color))\" xml:space=\"preserve\">\(esc(text))"
                    } else {
                        spans += "<tspan \(at) \(face)>\(esc(text))</tspan>"
                    }
                }
                if !head.isEmpty { self.line(head + spans + "</text>") }
            }
        }

        func glyphs(_ line: CTLine, origin: CGPoint) -> String {
            var out = ""
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = (attrs[kCTFontAttributeName] as! CTFont?) ?? (NSFont.systemFont(ofSize: 12) as CTFont)
                let shift = (attrs[NSAttributedString.Key.baselineOffset] as? CGFloat) ?? 0
                let count = CTRunGetGlyphCount(run)
                var gl = [CGGlyph](repeating: 0, count: count)
                var pos = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gl)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
                for i in 0..<count {
                    // Glyph outlines are y-up; SVG is y-down.
                    var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x + pos[i].x, ty: origin.y - shift)
                    if let p = CTFontCreatePathForGlyph(font, gl[i], &t) { out += SVGExporter.d(p) }
                }
            }
            return out
        }
    }

    // MARK: Helpers

    nonisolated static func family(_ f: NSFont) -> String {
        let name = f.familyName ?? ""
        if name.hasPrefix(".") || name.hasPrefix("SF Pro") || name == "System Font" {
            return f.fontDescriptor.symbolicTraits.contains(.monoSpace)
                ? "ui-monospace, 'SF Mono', Menlo, monospace"
                : "-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"
        }
        if f.fontDescriptor.symbolicTraits.contains(.monoSpace) { return "'\(name)', ui-monospace, Menlo, monospace" }
        return "'\(name)', -apple-system, sans-serif"
    }

    nonisolated static func weight(_ f: NSFont) -> Int {
        let w =
            (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        // NSFont weights run -1…1; CSS 100…900.
        return Int((max(100, min(900, 400 + w * 600)) / 100).rounded()) * 100
    }

    nonisolated static func n(_ v: CGFloat) -> String { n(Double(v)) }
    nonisolated static func n(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    nonisolated static func hex(_ c: RGBA) -> String {
        String(
            format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    nonisolated static func opacity(_ o: Double) -> String { o < 1 ? " opacity=\"\(n(o))\"" : "" }

    nonisolated static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated static func attrName(_ key: String) -> String {
        let s = key.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return s.isEmpty ? "field" : s
    }

    /// CGPath → SVG path data.
    nonisolated static func d(_ p: CGPath) -> String {
        var out = ""
        p.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: out += "M\(n(pts[0].x)) \(n(pts[0].y))"
            case .addLineToPoint: out += "L\(n(pts[0].x)) \(n(pts[0].y))"
            case .addQuadCurveToPoint: out += "Q\(n(pts[0].x)) \(n(pts[0].y)) \(n(pts[1].x)) \(n(pts[1].y))"
            case .addCurveToPoint:
                out += "C\(n(pts[0].x)) \(n(pts[0].y)) \(n(pts[1].x)) \(n(pts[1].y)) \(n(pts[2].x)) \(n(pts[2].y))"
            case .closeSubpath: out += "Z"
            @unknown default: break
            }
        }
        return out
    }
}

extension RGBA {
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
}
