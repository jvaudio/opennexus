import CoreGraphics
import CoreText
import Foundation
import ImageIO
import NexusCore
import NexusLayout
import NexusScene
import NexusTheme
import UniformTypeIdentifiers

/// SVG export (artboard 30), written from the laid-out scene in the canvas's layer order:
/// swimlane bands, zones, boundaries, structure decor, branch lines, summaries,
/// relationships, callout tails, topics (shape, markers, images, technical decor, text,
/// +N badge, caption) and the legend (M43 brought the SVG level with the layers).
/// Text is live `<text>` (editable; uses the viewer's installed fonts) or outlined glyph
/// paths (exact everywhere). Metadata adds `data-nexus-*` attributes.
@MainActor
public enum SVGExporter {
    public struct Options: Equatable, Sendable {
        public var outlineText = false
        public var metadata = true
        /// With metadata: custom fields, markers and labels as attributes too (the
        /// interactive viewer needs only the topic ids).
        public var fields = true
        /// Prefixes every id, so several SVGs can share one page.
        public var idPrefix = ""
        /// Outlined text writes each glyph once in `<defs>` and places it with `<use>`.
        public var reuseGlyphs = false
        /// Images as `data:` URLs; off, they're named by `data-nexus-asset` for the host
        /// (the interactive viewer) to fill in from its assets.
        public var embedImages = true
        public init() {}
    }

    public static func export(
        _ model: DocumentModel, canvas id: CanvasID, _ io: ImageExporter.Options, _ o: Options = Options()
    ) -> String {
        let controller = ImageExporter.controller(model, canvas: id, io)
        return export(controller, assets: model.assets, io, o)
    }

    /// The SVG of a controller's scene (the viewer bundle draws both of its layouts this way).
    static func export(
        _ controller: CanvasController, assets: [String: Data], _ io: ImageExporter.Options, _ o: Options
    ) -> String {
        MathEngine.waiting { write(controller, assets: assets, io, o) }
    }

    private static func write(
        _ controller: CanvasController, assets: [String: Data], _ io: ImageExporter.Options, _ o: Options
    ) -> String {
        let scene = controller.scene
        let canvas = controller.canvas
        let rect = viewBox(scene, io)
        var w = Writer(o, assets: assets)
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
        let frame: (NodeID) -> CGRect? = { scene.nodes[$0]?.frame.rect }
        // Swimlane bands sit below everything.
        var band = 0
        for d in scene.decor {
            guard case .band(let r, let title, let color) = d else { continue }
            w.line(
                "<rect class=\"band\" x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" \(paint(color.alpha(band % 2 == 0 ? 0.05 : 0.08), "fill")) \(paint(color.alpha(0.25), "stroke"))/>"
            )
            let font = Fonts.mono(11.5, .semibold)
            w.text(
                title, at: CGPoint(x: r.minX + 16, y: r.minY + 12 + CTFontGetAscent(font)), font: font, color: color,
                kern: 1.2)
            band += 1
        }
        // Zones and boundaries.
        for z in scene.zones {
            w.line(
                "<g class=\"zone\"><rect x=\"\(n(z.rect.minX))\" y=\"\(n(z.rect.minY))\" width=\"\(n(z.rect.width))\" height=\"\(n(z.rect.height))\" rx=\"14\" fill=\"\(hex(z.color))\" fill-opacity=\"0.06\" stroke=\"\(hex(z.color))\" stroke-width=\"1.5\"/>"
            )
            w.text(
                z.zone.title, at: CGPoint(x: z.rect.minX + 14, y: z.rect.minY + 22),
                font: Fonts.system(12, .semibold), color: z.color)
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
                    font: Fonts.system(12, .semibold), color: bd.color)
            }
            w.line("</g>")
        }
        // Structure decor: cells, braces, lifelines, activation bars.
        for item in scene.decor {
            if case .band = item { continue }
            guard let p = DecorRenderer.path(item, frame: frame) else { continue }
            let s = DecorRenderer.paint(item, theme: scene.theme)
            var attrs = s.fill.map { paint($0, "fill") } ?? "fill=\"none\""
            if let c = s.stroke { attrs += " " + paint(c, "stroke") + " stroke-width=\"\(n(s.width))\"" }
            if let dash = s.dash { attrs += " stroke-dasharray=\"\(dash.map { n($0) }.joined(separator: " "))\"" }
            w.line("<path class=\"decor\" d=\"\(d(p))\" \(attrs) stroke-linecap=\"round\" stroke-linejoin=\"round\"/>")
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
        relationships(scene, o, &w)
        // Callout tails, from the bubble's edge to its host (under the topics).
        for k in scene.callouts {
            guard let host = frame(k.callout.host), let bubble = frame(k.callout.topic),
                let sn = scene.nodes[k.callout.topic]
            else { continue }
            let p = ElementRenderer.calloutTail(host: host, bubble: bubble)
            let fill = sn.appearance.fill.representative ?? RGBA(hex: "#FFF6D6")
            w.line(
                "<path class=\"callout\" d=\"\(d(p))\" \(paint(fill, "fill")) \(paint(sn.appearance.borderColor, "stroke")) stroke-width=\"\(n(sn.appearance.borderWidth))\" stroke-linejoin=\"round\"/>"
            )
        }
        // Topics in drawing order.
        let order = scene.order.isEmpty ? Array(scene.nodes.keys).sorted() : scene.order
        for id in order {
            guard let sn = scene.nodes[id], let node = canvas.nodes[id] else { continue }
            topic(sn, node, &w, scene: scene)
        }
        if let l = scene.legend { legend(l, &w, theme: scene.theme, canvas: scene.canvasColor) }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out +=
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(n(rect.minX)) \(n(rect.minY)) \(n(rect.width)) \(n(rect.height))\" width=\"\(n(rect.width))\" height=\"\(n(rect.height))\">\n"
        if !w.defs.isEmpty { out += "  <defs>\n" + w.defs + "  </defs>\n" }
        out += w.out
        out += "</svg>\n"
        return out
    }

    /// The exported area in world points: the scene with the export's padding.
    static func viewBox(_ scene: Scene, _ io: ImageExporter.Options) -> CGRect {
        let b = scene.bounds
        return b.isNull
            ? CGRect(x: 0, y: 0, width: 200, height: 120) : b.insetBy(dx: -io.padding, dy: -io.padding).integral
    }

    static func relationships(_ scene: Scene, _ o: Options, _ w: inout Writer) {
        for r in scene.relationships {
            guard let a = scene.rect(of: r.relationship.from), let bb = scene.rect(of: r.relationship.to) else {
                continue
            }
            let g = scene.geometry(of: r, from: a, to: bb)
            let dash =
                r.relationship.dash == "dashed"
                ? " stroke-dasharray=\"6 5\"" : r.relationship.dash == "dotted" ? " stroke-dasharray=\"1.5 4\"" : ""
            w.line(
                "<g class=\"relationship\"\(o.metadata ? " data-nexus-from=\"\(esc(r.relationship.from.rawValue))\" data-nexus-to=\"\(esc(r.relationship.to.rawValue))\"\(r.relationship.from.topic == nil ? " data-nexus-from-kind=\"\(r.relationship.from.kind)\"" : "")\(r.relationship.to.topic == nil ? " data-nexus-to-kind=\"\(r.relationship.to.kind)\"" : "")" : "")\(opacity(r.opacity))>"
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
                // The canvas's chip, where the canvas puts it.
                let font = Scene.labelFont(r.relationship)
                let pill = scene.labelRect(of: r, g, size: Scene.labelSize(r.relationship))
                let textWidth = r.relationship.label.width(in: font)
                w.line(
                    "<rect x=\"\(n(pill.minX))\" y=\"\(n(pill.minY))\" width=\"\(n(pill.width))\" height=\"\(n(pill.height))\" rx=\"11\" fill=\"\(hex(scene.canvasColor))\" stroke=\"\(hex(r.color))\"/>"
                )
                w.text(
                    r.relationship.label, at: CGPoint(x: pill.midX - textWidth / 2, y: pill.midY + 4), font: font,
                    color: r.color)
            }
            w.indent -= 1
            w.line("</g>")
        }
    }

    /// The legend box (M14), above the topics as on the canvas.
    static func legend(_ l: SceneLegend, _ w: inout Writer, theme: Theme, canvas: RGBA) {
        let r = l.rect
        w.line("<g class=\"legend\">")
        w.indent += 1
        w.line(
            "<rect x=\"\(n(r.minX + 0.5))\" y=\"\(n(r.minY + 0.5))\" width=\"\(n(r.width - 1))\" height=\"\(n(r.height - 1))\" rx=\"10\" fill=\"\(hex(canvas))\" stroke=\"\(hex(theme.ink))\" stroke-opacity=\"0.22\"/>"
        )
        w.text(
            Loc.t("Legend"), at: CGPoint(x: r.minX + SceneLegend.padding, y: r.minY + SceneLegend.padding + 15),
            font: SceneLegend.titleFont, color: theme.ink)
        for row in l.rows {
            let rr = row.rect
            if let label = row.label {
                let width = ceil(label.width(in: SceneLegend.labelFont)) + 16
                w.line(
                    "<rect x=\"\(n(rr.minX))\" y=\"\(n(rr.midY - 9))\" width=\"\(n(width))\" height=\"18\" rx=\"9\" fill=\"\(hex(theme.ink))\" fill-opacity=\"0.1\"/>"
                )
                w.text(
                    label, at: CGPoint(x: rr.minX + 8, y: rr.midY + 4), font: SceneLegend.labelFont, color: theme.ink)
                continue
            }
            var x = rr.minX
            if let m = row.marker {
                marker(m, in: CGRect(x: x, y: rr.midY - 9, width: 18, height: 18), &w)
                x += SceneLegend.glyph
            }
            w.text(
                row.text, at: CGPoint(x: x, y: rr.midY + 4), font: SceneLegend.font,
                color: row.marker == nil ? theme.ink2 : theme.ink)
        }
        w.indent -= 1
        w.line("</g>")
    }

    /// A marker as topics and the legend draw it: a disc with its glyph, a numbered
    /// priority disc, or an eighths pie (D247).
    static func marker(_ id: String, in r: CGRect, _ w: inout Writer) {
        let c = CGPoint(x: r.midX, y: r.midY)
        let glyphFont = Fonts.system(10.5, .bold)
        if id.hasPrefix("priority-"), let p = Int(id.dropFirst(9)) {
            let color = Tokens.priorityColors[max(0, min(8, p - 1))]
            w.line("<circle cx=\"\(n(c.x))\" cy=\"\(n(c.y))\" r=\"\(n(r.width / 2))\" fill=\"\(hex(color))\"/>")
            w.text(
                "\(p)", at: CGPoint(x: c.x, y: r.minY + 3 + CTFontGetAscent(glyphFont)), font: glyphFont, color: .white,
                anchor: "middle")
            return
        }
        let mk = MarkerLibrary.marker(id)
        w.line(
            "<circle cx=\"\(n(c.x))\" cy=\"\(n(c.y))\" r=\"\(n(r.width / 2))\" fill=\"\(hex(RGBA(hex: mk?.color ?? "#8A8A96")))\"/>"
        )
        if let pie = mk?.pie {
            pieMarker(pie, at: c, &w)
        } else {
            w.text(
                mk?.glyph ?? "•", at: CGPoint(x: c.x, y: r.minY + 2 + CTFontGetAscent(glyphFont)), font: glyphFont,
                color: .white, anchor: "middle")
        }
    }

    /// A progress marker's pie on its 18 pt disc, as the canvas draws it (D247).
    static func pieMarker(_ fraction: Double, at c: CGPoint, _ w: inout Writer) {
        let r = 18 * LegendLayer.pieRadius
        let a = (-90 + 360 * fraction) * .pi / 180
        let end = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        w.line(
            "<circle cx=\"\(n(c.x))\" cy=\"\(n(c.y))\" r=\"\(n(r))\" fill=\"none\" stroke=\"#FFFFFF\" stroke-width=\"\(n(18 * LegendLayer.pieLine))\"/>"
        )
        w.line(
            "<path d=\"M\(n(c.x)) \(n(c.y)) V\(n(c.y - r)) A\(n(r)) \(n(r)) 0 \(fraction > 0.5 ? 1 : 0) 1 \(n(end.x)) \(n(end.y)) Z\" fill=\"#FFFFFF\"/>"
        )
    }

    static func topic(_ sn: SceneNode, _ node: Node, _ w: inout Writer, scene: Scene) {
        let theme = scene.theme
        let a = sn.appearance
        let r = sn.frame.rect
        let o = w.options
        var attrs = "class=\"topic\""
        if o.metadata {
            attrs += " data-nexus-id=\"\(esc(sn.id.rawValue))\""
            if o.fields {
                if let t = node.nodeType { attrs += " data-nexus-type=\"\(esc(t.rawValue))\"" }
                for f in node.metadata { attrs += " data-\(attrName(f.key))=\"\(esc(f.value))\"" }
                if !node.markers.isEmpty {
                    attrs += " data-nexus-markers=\"\(esc(node.markers.joined(separator: " ")))\""
                }
                if !node.labels.isEmpty {
                    attrs += " data-nexus-labels=\"\(esc(node.labels.joined(separator: ", ")))\""
                }
            }
        }
        w.line("<g \(attrs) transform=\"translate(\(n(r.minX)) \(n(r.minY)))\"\(opacity(sn.opacity))>")
        w.indent += 1
        let bw = CGFloat(a.borderWidth)
        let box = CGRect(origin: .zero, size: r.size).insetBy(dx: bw / 2, dy: bw / 2)
        let radius = max(0, CGFloat(a.cornerRadius) - bw / 2)
        let open = ShapeLibrary.openShapes.contains(a.shape)
        let shadow = a.shadow.map { w.shadow($0) }.map { " filter=\"url(#\($0))\"" } ?? ""
        if a.isUnderline {
            w.line(
                "<path d=\"M0 \(n(r.height - bw / 2)) H\(n(r.width))\" stroke=\"\(hex(a.borderColor))\" stroke-width=\"\(n(max(bw, 2)))\" fill=\"none\"/>"
            )
        } else {
            let outline = ShapeLibrary.path(a.shape, in: box, radius: radius)
            var fill = "fill=\"none\""
            switch a.fill {
            case .solid(let c) where !open:
                fill = paint(c, "fill")
            case .gradient(let c1, let c2) where !open:
                let gid = "\(o.idPrefix)g\(sn.id.rawValue)"
                w.line(
                    "<defs><linearGradient id=\"\(gid)\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(hex(c2))\"/><stop offset=\"1\" stop-color=\"\(hex(c1))\"/></linearGradient></defs>"
                )
                fill = "fill=\"url(#\(gid))\""
            default: break
            }
            var stroke = ""
            if a.border != .none && bw > 0 {
                stroke = " " + paint(a.borderColor, "stroke") + " stroke-width=\"\(n(bw))\""
                if a.border == .dashed { stroke += " stroke-dasharray=\"\(n(bw * 3)) \(n(bw * 2))\"" }
                if a.border == .dotted {
                    stroke += " stroke-dasharray=\"0.01 \(n(bw * 2.2))\" stroke-linecap=\"round\""
                }
            }
            w.line("<path d=\"\(d(outline))\" \(fill)\(stroke)\(shadow)/>")
            if a.border == .double, bw > 0 {
                let inner = ShapeLibrary.path(
                    a.shape, in: box.insetBy(dx: bw * 2, dy: bw * 2), radius: max(0, radius - bw * 2))
                w.line(
                    "<path d=\"\(d(inner))\" fill=\"none\" \(paint(a.borderColor, "stroke")) stroke-width=\"\(n(max(1, bw / 2)))\"/>"
                )
            }
        }
        // The topic's image, under its decorations and text, as the layers stack them.
        if let ref = sn.image, !sn.imageRect.isEmpty { w.image(ref.asset, in: sn.imageRect) }
        // Leading slots: progress ring, priority, to-do, other markers.
        var x = sn.leadRect.minX
        let cy = sn.leadRect.midY
        if let p = sn.progress {
            let rr = CGRect(x: x + 1, y: cy - 8, width: 16, height: 16)
            let c = CGPoint(x: rr.midX, y: rr.midY)
            w.line(
                "<circle cx=\"\(n(c.x))\" cy=\"\(n(c.y))\" r=\"7\" fill=\"none\" \(paint(a.text.alpha(0.2), "stroke")) stroke-width=\"2\"/>"
            )
            if p.done > 0 {
                let frac = Double(p.done) / Double(max(p.total, 1))
                let arc = CGMutablePath()
                arc.addArc(
                    center: c, radius: 7, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * frac, clockwise: false)
                w.line(
                    "<path d=\"\(d(arc))\" fill=\"none\" stroke=\"\(hex(theme.ai))\" stroke-width=\"2.4\" stroke-linecap=\"round\"/>"
                )
            }
            x += SceneBuilder.markerWidth
        }
        if let p = sn.priority {
            marker("priority-\(p)", in: CGRect(x: x, y: cy - 9, width: 18, height: 18), &w)
            x += SceneBuilder.priorityWidth
        }
        if let t = sn.todo {
            let b = CGRect(x: x + 1, y: cy - 7, width: 14, height: 14)
            if t.done {
                w.line(
                    "<rect x=\"\(n(b.minX))\" y=\"\(n(b.minY))\" width=\"14\" height=\"14\" rx=\"4\" fill=\"\(hex(theme.ai))\"/>"
                )
                w.line(
                    "<path d=\"M\(n(x + 4)) \(n(cy - 0.5)) L\(n(x + 7)) \(n(cy + 2.5)) L\(n(x + 12)) \(n(cy - 3))\" fill=\"none\" stroke=\"#FFFFFF\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
                )
            } else {
                w.line(
                    "<rect x=\"\(n(b.minX))\" y=\"\(n(b.minY))\" width=\"14\" height=\"14\" rx=\"4\" fill=\"none\" \(paint(theme.ink2, "stroke")) stroke-width=\"1.5\"/>"
                )
            }
            x += SceneBuilder.todoWidth
        }
        for m in sn.otherMarkers {
            if MarkerLibrary.marker(m) != nil { marker(m, in: CGRect(x: x, y: cy - 9, width: 18, height: 18), &w) }
            x += SceneBuilder.markerWidth
        }
        tech(sn, &w, theme: theme)
        // Sticker: an Image Playground image, or an emoji or symbol.
        if let st = sn.sticker, !sn.stickerRect.isEmpty {
            if !st.hasPrefix("emoji:"), w.assets[st] != nil {
                w.image(st, in: sn.stickerRect.insetBy(dx: 1, dy: 1))
            } else {
                let glyph = st.hasPrefix("emoji:") ? String(st.dropFirst(6)) : st.contains("/") ? "★" : st
                let font = Fonts.system(20)
                w.text(
                    glyph, at: CGPoint(x: sn.stickerRect.minX + 2, y: sn.stickerRect.minY + CTFontGetAscent(font)),
                    font: font,
                    color: a.text)
            }
        }
        // Indicators.
        let indicatorFont = Fonts.system(12, .semibold)
        for (i, ind) in sn.indicators.enumerated() where i < sn.indicatorRects.count {
            let ir = sn.indicatorRects[i]
            let color = ind == .ai ? theme.ai : a.text.alpha(0.6)
            w.text(
                ind.glyph, at: CGPoint(x: ir.midX, y: ir.minY + 1 + CTFontGetAscent(indicatorFont)),
                font: indicatorFont,
                color: color, anchor: "middle")
            if ind == .comment, sn.commentCount > 1 {
                let f = Fonts.system(7.5, .bold)
                w.text(
                    "\(min(sn.commentCount, 99))", at: CGPoint(x: ir.maxX - 5, y: ir.minY - 2 + CTFontGetAscent(f)),
                    font: f,
                    color: color)
            }
        }
        // Label pills.
        for (i, l) in sn.labels.enumerated() where i < sn.labelRects.count {
            let lr = sn.labelRects[i]
            w.line(
                "<rect x=\"\(n(lr.minX))\" y=\"\(n(lr.minY))\" width=\"\(n(lr.width))\" height=\"\(n(lr.height))\" rx=\"\(n(lr.height / 2))\" \(paint(sn.branchColor.alpha(0.16), "fill"))/>"
            )
            w.text(
                l, at: CGPoint(x: lr.midX, y: lr.minY + 2 + CTFontGetAscent(SceneBuilder.labelFont)),
                font: SceneBuilder.labelFont, color: a.text.alpha(0.85), anchor: "middle")
        }
        // Pinned metadata.
        if !sn.pinned.isEmpty {
            let font = Fonts.mono(10.5)
            w.text(
                sn.pinned.map { "\($0.key) \($0.value)" }.joined(separator: "  ·  "),
                at: CGPoint(x: sn.pinnedRect.minX, y: sn.pinnedRect.minY + CTFontGetAscent(font)), font: font,
                color: a.text.alpha(0.6))
        }
        // Title, as the text layer draws it: placeholders faint, done tasks struck through.
        var color = a.text
        if sn.isPlaceholder { color = color.alpha(0.4) }
        if sn.todo?.done == true { color = a.text.alpha(0.55) }
        w.block(
            sn.displayText, style: sn.textStyle, marks: sn.marks, in: sn.textRect, color: color, link: theme.ring,
            error: sn.mathErrorColor(theme: theme, canvas: scene.canvasColor), struck: sn.todo?.done == true)
        if sn.hiddenCount > 0 { badge(sn, &w, canvas: scene.canvasColor) }
        if let c = sn.tech.caption {
            let font = Fonts.mono(9.5, .medium)
            w.text(
                c, at: CGPoint(x: r.width / 2, y: -17 + CTFontGetAscent(font)), font: font, color: theme.ink2,
                anchor: "middle",
                kern: 1.2)
        }
        w.indent -= 1
        w.line("</g>")
    }

    /// The "+N" of a folded topic, over the edge where its branch lines leave (D250).
    static func badge(_ sn: SceneNode, _ w: inout Writer, canvas: RGBA) {
        let font = Fonts.system(11, .bold)
        let label = "+\(sn.hiddenCount)"
        let width = max(22, ceil(label.width(in: font)) + 10)
        let b = badgeRect(sn, width: width)
        w.line(
            "<rect class=\"badge\" x=\"\(n(b.minX + 1))\" y=\"\(n(b.minY + 1))\" width=\"\(n(b.width - 2))\" height=\"\(n(b.height - 2))\" rx=\"\(n(b.height / 2 - 1))\" fill=\"\(hex(sn.branchColor))\" stroke=\"\(hex(canvas))\" stroke-width=\"2\"/>"
        )
        w.text(
            label, at: CGPoint(x: b.midX, y: b.minY + 4 + CTFontGetAscent(font)), font: font, color: .white,
            anchor: "middle")
    }

    /// The +N badge's rectangle in the topic's own coordinates (as `NodeLayer` places it).
    static func badgeRect(_ sn: SceneNode, width w: CGFloat) -> CGRect {
        let h: CGFloat = 22
        let j = NodeLayer.junction(sn)
        let origin: CGPoint =
            switch j.edge {
            case .left: CGPoint(x: j.point.x - w + 9, y: j.point.y - h / 2)
            case .right: CGPoint(x: j.point.x - 9, y: j.point.y - h / 2)
            case .top: CGPoint(x: j.point.x - w / 2, y: j.point.y - h + 9)
            case .bottom: CGPoint(x: j.point.x - w / 2, y: j.point.y - 9)
            }
        return CGRect(origin: origin, size: CGSize(width: w, height: h))
    }

    /// Technical decorations: data-store accent, icon, kicker, lead text, risk badge and
    /// the rule-check flag (as `DecorLayer.drawTech`).
    static func tech(_ sn: SceneNode, _ w: inout Writer, theme: Theme) {
        let t = sn.tech
        let size = sn.frame.rect.size
        let tint = t.tint ?? sn.appearance.text
        if let a = t.accent {
            w.line("<rect x=\"0\" y=\"0\" width=\"6\" height=\"\(n(size.height))\" \(paint(a, "fill"))/>")
            w.line(
                "<path d=\"M0 1 H\(n(size.width)) M0 \(n(size.height - 1)) H\(n(size.width))\" fill=\"none\" \(paint(a, "stroke")) stroke-width=\"2\"/>"
            )
        }
        if let icon = t.icon, let p = TechIcons.path(icon, in: t.iconRect) {
            w.line(
                "<path d=\"\(d(p))\" fill=\"none\" \(paint(tint, "stroke")) stroke-width=\"\(n(1.6 * t.iconRect.width / 24))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
            )
        }
        let small = SceneBuilder.kickerFont
        if let k = t.kicker {
            w.text(
                k, at: CGPoint(x: t.kickerRect.minX, y: t.kickerRect.minY + CTFontGetAscent(small)), font: small,
                color: tint,
                kern: 0.6)
        }
        if let l = t.leadText {
            w.text(
                l, at: CGPoint(x: t.leadTextRect.minX, y: t.leadTextRect.minY + CTFontGetAscent(small)), font: small,
                color: tint, kern: 0.6)
        }
        if let b = t.badge {
            let r = t.badgeRect
            let c = t.badgeColor ?? sn.branchColor
            let filled = b.count == 1
            w.line(
                "<rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" rx=\"4\" \(filled ? paint(c, "fill") : "fill=\"none\" " + paint(c, "stroke") + " stroke-width=\"1\"")/>"
            )
            w.text(
                b, at: CGPoint(x: r.midX, y: r.minY + 2 + CTFontGetAscent(SceneBuilder.badgeFont)),
                font: SceneBuilder.badgeFont,
                color: filled ? .white : c, anchor: "middle")
        }
        if t.flagged {
            let r = CGRect(x: size.width - 17, y: 3, width: 14, height: 14)
            w.line("<circle cx=\"\(n(r.midX))\" cy=\"\(n(r.midY))\" r=\"7\" fill=\"\(hex(theme.critical))\"/>")
            let f = Fonts.system(10, .heavy)
            w.text(
                "!", at: CGPoint(x: r.midX, y: r.minY + 1 + CTFontGetAscent(f)), font: f, color: .white,
                anchor: "middle")
        }
    }

    // MARK: Writing

    @MainActor struct Writer {
        var out = ""
        var defs = ""
        var indent = 1
        let options: Options
        let assets: [String: Data]
        private var glyphIDs: [GlyphKey: String] = [:]
        private var filters: [String: String] = [:]
        private var images: [String: (type: String, data: Data)?] = [:]

        struct GlyphKey: Hashable {
            var font: String
            var size: CGFloat
            var glyph: CGGlyph
        }

        init(_ options: Options, assets: [String: Data]) {
            self.options = options
            self.assets = assets
        }

        var outline: Bool { options.outlineText }

        mutating func line(_ s: String) {
            out += String(repeating: "  ", count: indent)
            out += s
            out += "\n"
        }

        /// One line of text at a baseline.
        mutating func text(
            _ s: String, at p: CGPoint, font: CTFont, color: RGBA, anchor: String = "start", kern: CGFloat = 0
        ) {
            guard !s.isEmpty else { return }
            if outline {
                var attrs: [NSAttributedString.Key: Any] = [TextKey.font: font]
                if kern != 0 { attrs[TextKey.kern] = kern }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let x = anchor == "middle" ? p.x - width / 2 : anchor == "end" ? p.x - width : p.x
                glyphs(
                    line, origin: CGPoint(x: x, y: p.y), color: color,
                    source: NSAttributedString(string: s, attributes: attrs))
            } else {
                self.line(
                    "<text x=\"\(n(p.x))\" y=\"\(n(p.y))\" font-family=\"\(SVGExporter.family(font))\" font-size=\"\(n(CTFontGetSize(font)))\" font-weight=\"\(SVGExporter.weight(font))\" \(SVGExporter.paint(color, "fill"))\(anchor == "start" ? "" : " text-anchor=\"\(anchor)\"")\(kern != 0 ? " letter-spacing=\"\(n(kern))\"" : "")>\(esc(s))</text>"
                )
            }
        }

        /// A wrapped text block laid out by Core Text exactly as the canvas lays it out.
        mutating func block(
            _ s: String, style: NodeTextStyle, marks: [TextMark], in r: CGRect, color: RGBA, link: RGBA? = nil,
            error: RGBA? = nil, struck: Bool = false
        ) {
            guard !s.isEmpty, r.width > 0 else { return }
            let attr = NSMutableAttributedString(
                attributedString: style.attributed(
                    s, marks: marks, color: .fixed(color.cgColor), linkColor: link.map { .fixed($0.cgColor) },
                    errorColor: .fixed((error ?? RGBA(r: 0.85, g: 0.23, b: 0.25)).cgColor)))
            if struck {
                attr.addAttribute(TextKey.strikethrough, value: 1, range: NSRange(location: 0, length: attr.length))
            }
            if MathText.contains(attr) {
                formulaBlock(attr, in: r, color: color, style: style)
                return
            }
            // Laid out from the attributes the platform's own text system hands CoreText.
            let setter = CTFramesetterCreateWithAttributedString(Graphics.platform.coreTextString(attr))
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
                    glyphs(line, origin: base, color: color, source: attr)
                } else {
                    text(line, origin: base, color: color, source: attr, style: style)
                }
            }
        }

        /// Text with formulas (M48): laid out as `MathLayout` draws it, its words as the rest
        /// of the export writes them, each formula as paths in its run's colour.
        mutating func formulaBlock(_ attr: NSAttributedString, in r: CGRect, color: RGBA, style: NodeTextStyle) {
            // The layout places words on their baselines itself.
            let source = NSMutableAttributedString(attributedString: attr)
            source.removeAttribute(TextKey.baselineOffset, range: NSRange(location: 0, length: source.length))
            let layout = MathLayout(source, width: r.width)
            let shift = max(0, r.width - layout.size.width)
            for l in layout.lines {
                let base = CGPoint(
                    x: r.minX + l.x + MathLayout.alignmentShift(l, text: source, extra: shift), y: r.minY + l.baseline)
                if outline {
                    glyphs(l.line, origin: base, color: color, source: source)
                } else {
                    text(l.line, origin: base, color: color, source: source, style: style)
                }
            }
            for f in layout.placed(in: r, flipped: true) {
                let fill = SVGExporter.runColor(source.attributes(at: f.range.location, effectiveRange: nil)) ?? color
                let t = CGAffineTransform(translationX: f.origin.x, y: f.origin.y).scaledBy(
                    x: f.run.fontSize, y: f.run.fontSize)
                var out = ""
                for p in f.run.glyphs.pieces { out += MathGlyphs.element(p, transform: t, color: fill) }
                self.line("<g class=\"math\">\(out)</g>")
            }
        }

        /// A line as live `<text>`.
        mutating func text(
            _ line: CTLine, origin base: CGPoint, color: RGBA, source attr: NSAttributedString, style: NodeTextStyle
        ) {
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
                // The run's style, from the source text; formulas are written as paths.
                let attrs = attr.attributes(at: range.location, effectiveRange: nil)
                if attrs[TextKey.math] != nil { continue }
                let font = (attrs[TextKey.font] as! CTFont?) ?? style.font
                var pos = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
                let shift = (attrs[TextKey.baselineOffset] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                var deco = ""
                if attrs[TextKey.underline] != nil { deco = " text-decoration=\"underline\"" }
                if attrs[TextKey.strikethrough] != nil {
                    deco = " text-decoration=\"line-through\""
                }
                let italic =
                    SVGExporter.traits(font).contains(.traitItalic) ? " font-style=\"italic\"" : ""
                let at = "x=\"\(n(base.x + pos.x))\" y=\"\(n(base.y - shift))\""
                let face =
                    "font-family=\"\(SVGExporter.family(font))\" font-size=\"\(n(CTFontGetSize(font)))\" font-weight=\"\(SVGExporter.weight(font))\"\(italic)\(deco)"
                let runColor = SVGExporter.runColor(attrs).flatMap { $0 == color ? nil : $0 }
                if head.isEmpty {
                    head =
                        "<text \(at) \(face) \(SVGExporter.paint(runColor ?? color, "fill")) xml:space=\"preserve\">\(esc(text))"
                } else {
                    spans +=
                        "<tspan \(at) \(face)\(runColor.map { " " + SVGExporter.paint($0, "fill") } ?? "")>\(esc(text))</tspan>"
                }
            }
            if !head.isEmpty { self.line(head + spans + "</text>") }
        }

        /// A line's glyphs as outlines in its runs' colours, with underlines and
        /// strikethroughs drawn as bars. Colour glyphs (emoji) have no outline, so they
        /// become a small image.
        mutating func glyphs(_ line: CTLine, origin: CGPoint, color: RGBA, source: NSAttributedString) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                // The run's style, from the source text; its font from the run (fallbacks).
                let at = CTRunGetStringRange(run).location
                let attrs = at < source.length ? source.attributes(at: at, effectiveRange: nil) : [:]
                let font =
                    (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont? ?? Fonts.system(12)
                let shift = (attrs[TextKey.baselineOffset] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                let fill = SVGExporter.runColor(attrs) ?? color
                if let m = attrs[TextKey.math] as? MathRun {
                    // A formula's room: its paths are written by `formulaBlock`; a done task's
                    // strikethrough still crosses it.
                    if attrs[TextKey.strikethrough] != nil {
                        var x = CGPoint.zero
                        CTRunGetPositions(run, CFRange(location: 0, length: 1), &x)
                        bar(
                            x: origin.x + x.x, y: origin.y - m.fontSize * 0.25, width: m.width, thickness: 1,
                            color: fill)
                    }
                    continue
                }
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var gl = [CGGlyph](repeating: 0, count: count)
                var pos = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gl)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
                if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
                    colorRun(run, font: font, origin: CGPoint(x: origin.x, y: origin.y - shift), first: pos[0])
                    continue
                }
                if options.reuseGlyphs {
                    var uses = ""
                    let name = CTFontCopyPostScriptName(font) as String
                    let size = CTFontGetSize(font)
                    for i in 0..<count {
                        let key = GlyphKey(font: name, size: size, glyph: gl[i])
                        let id: String
                        if let known = glyphIDs[key] {
                            id = known
                        } else {
                            id = "\(options.idPrefix)t\(glyphIDs.count)"
                            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
                            let d = CTFontCreatePathForGlyph(font, gl[i], &flip).map(SVGExporter.d) ?? ""
                            defs += "    <path id=\"\(id)\" d=\"\(d)\"/>\n"
                            glyphIDs[key] = id
                        }
                        uses +=
                            "<use href=\"#\(id)\" x=\"\(n(origin.x + pos[i].x))\" y=\"\(n(origin.y - shift))\"/>"
                    }
                    self.line("<g \(SVGExporter.paint(fill, "fill"))>\(uses)</g>")
                } else {
                    var d = ""
                    for i in 0..<count {
                        // Glyph outlines are y-up; SVG is y-down.
                        var t = CGAffineTransform(
                            a: 1, b: 0, c: 0, d: -1, tx: origin.x + pos[i].x, ty: origin.y - shift)
                        if let p = CTFontCreatePathForGlyph(font, gl[i], &t) { d += SVGExporter.d(p) }
                    }
                    if !d.isEmpty { self.line("<path d=\"\(d)\" \(SVGExporter.paint(fill, "fill"))/>") }
                }
                // Underline and strikethrough bars (outlines carry no decorations).
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                let x0 = origin.x + pos[0].x
                let thickness = max(1, CTFontGetUnderlineThickness(font))
                if attrs[TextKey.underline] != nil {
                    let y = origin.y - shift - CTFontGetUnderlinePosition(font)
                    bar(x: x0, y: y, width: width, thickness: thickness, color: fill)
                }
                if attrs[TextKey.strikethrough] != nil {
                    let y = origin.y - shift - CTFontGetXHeight(font) / 2
                    bar(x: x0, y: y, width: width, thickness: thickness, color: fill)
                }
            }
        }

        private mutating func bar(x: CGFloat, y: CGFloat, width: CGFloat, thickness: CGFloat, color: RGBA) {
            line(
                "<rect x=\"\(n(x))\" y=\"\(n(y - thickness / 2))\" width=\"\(n(width))\" height=\"\(n(thickness))\" \(SVGExporter.paint(color, "fill"))/>"
            )
        }

        /// An emoji run, drawn at twice its size into a PNG.
        private mutating func colorRun(_ run: CTRun, font: CTFont, origin: CGPoint, first: CGPoint) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
            let scale: CGFloat = 2
            let pw = Int(ceil(width * scale))
            let ph = Int(ceil((ascent + descent) * scale))
            guard pw > 0, ph > 0,
                let ctx = CGContext(
                    data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = CGPoint(x: -first.x, y: descent)
            CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
            guard let img = ctx.makeImage() else { return }
            let rect = CGRect(x: origin.x + first.x, y: origin.y - ascent, width: width, height: ascent + descent)
            line(
                "<image x=\"\(n(rect.minX))\" y=\"\(n(rect.minY))\" width=\"\(n(rect.width))\" height=\"\(n(rect.height))\" preserveAspectRatio=\"none\" href=\"data:image/png;base64,\(ImageExporter.png(img).base64EncodedString())\"/>"
            )
        }

        /// An asset drawn into `rect`, stretched as the image layer stretches it.
        mutating func image(_ asset: String, in rect: CGRect) {
            let place =
                "x=\"\(n(rect.minX))\" y=\"\(n(rect.minY))\" width=\"\(n(rect.width))\" height=\"\(n(rect.height))\" preserveAspectRatio=\"none\""
            guard options.embedImages else {
                if assets[asset] != nil { line("<image \(place) data-nexus-asset=\"\(esc(asset))\"/>") }
                return
            }
            if images[asset] == nil { images[asset] = assets[asset].flatMap(SVGExporter.browserImage) }
            guard let img = images[asset] ?? nil else { return }
            line("<image \(place) href=\"data:\(img.type);base64,\(img.data.base64EncodedString())\"/>")
        }

        /// A drop-shadow filter for a node shadow, written once per look.
        mutating func shadow(_ s: NodeAppearance.Shadow) -> String {
            let key = "\(hex(s.color))|\(n(s.color.a))|\(n(s.dx))|\(n(s.dy))|\(n(s.radius))"
            if let id = filters[key] { return id }
            let id = "\(options.idPrefix)s\(filters.count)"
            filters[key] = id
            defs +=
                "    <filter id=\"\(id)\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\"><feDropShadow dx=\"\(n(s.dx))\" dy=\"\(n(s.dy))\" stdDeviation=\"\(n(s.radius / 2))\" flood-color=\"\(hex(s.color))\" flood-opacity=\"\(n(s.color.a))\"/></filter>\n"
            return id
        }
    }

    // MARK: Helpers

    /// Bytes a browser can show: PNG, JPEG, GIF and WebP as they are; anything else
    /// (HEIC, TIFF) re-encoded as PNG.
    nonisolated static func browserImage(_ data: Data) -> (type: String, data: Data)? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", data) }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", data) }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("image/gif", data) }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return ("image/webp", data)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ("image/png", out as Data)
    }

    /// A run's own colour (links, marks), when it has one.
    nonisolated static func runColor(_ attrs: [NSAttributedString.Key: Any]) -> RGBA? {
        let color = TextColorValue(attribute: attrs[TextKey.color])?.cgColor
        guard
            let c = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
            let p = c.components, p.count >= 3
        else { return nil }
        return RGBA(r: Double(p[0]), g: Double(p[1]), b: Double(p[2]), a: Double(p.count > 3 ? p[3] : 1))
    }

    /// The symbolic traits the font's descriptor carries (`NSFontDescriptor.symbolicTraits`).
    nonisolated static func traits(_ f: CTFont) -> CTFontSymbolicTraits {
        let t = CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(f), kCTFontTraitsAttribute) as? [CFString: Any]
        return CTFontSymbolicTraits(rawValue: (t?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0)
    }

    nonisolated static func family(_ f: CTFont) -> String {
        let name = CTFontCopyFamilyName(f) as String
        let mono = traits(f).contains(.traitMonoSpace)
        if name.hasPrefix(".") || name.hasPrefix("SF Pro") || name == "System Font" {
            return mono
                ? "ui-monospace, 'SF Mono', Menlo, monospace"
                : "-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"
        }
        if mono { return "'\(name)', ui-monospace, Menlo, monospace" }
        return "'\(name)', -apple-system, sans-serif"
    }

    nonisolated static func weight(_ f: CTFont) -> Int {
        let traits =
            CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(f), kCTFontTraitsAttribute) as? [CFString: Any]
        let w = (traits?[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        // Font weights run -1…1; CSS 100…900.
        return Int((max(100, min(900, 400 + w * 600)) / 100).rounded()) * 100
    }

    nonisolated static func n(_ v: CGFloat) -> String { n(Double(v)) }

    /// A number with at most two decimals and no trailing zeros ("12", "12.5", "-0.25").
    /// Written by hand: exports call this for every coordinate of every glyph.
    nonisolated static func n(_ v: Double) -> String {
        guard v.isFinite, abs(v) < 1e13 else { return v.isFinite ? String(Int(v)) : "0" }
        let c = Int((v * 100).rounded())
        if c % 100 == 0 { return String(c / 100) }
        let a = abs(c)
        let frac = a % 100
        let digits = frac % 10 == 0 ? String(frac / 10) : frac < 10 ? "0\(frac)" : String(frac)
        return (c < 0 ? "-" : "") + String(a / 100) + "." + digits
    }

    nonisolated static func hex(_ c: RGBA) -> String {
        let digits = Array("0123456789ABCDEF")
        var s = "#"
        for v in [c.r, c.g, c.b] {
            let i = max(0, min(255, Int((v * 255).rounded())))
            s.append(digits[i >> 4])
            s.append(digits[i & 15])
        }
        return s
    }

    /// `fill="#…"` (or stroke), with its opacity when the colour has one.
    nonisolated static func paint(_ c: RGBA, _ attribute: String) -> String {
        "\(attribute)=\"\(hex(c))\"" + (c.a < 1 ? " \(attribute)-opacity=\"\(n(c.a))\"" : "")
    }

    nonisolated static func opacity(_ o: Double) -> String { o < 1 ? " opacity=\"\(n(o))\"" : "" }

    nonisolated static func esc(_ s: String) -> String {
        guard s.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" }) else { return s }
        return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
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
            case .moveToPoint:
                out += "M"
                out += n(pts[0].x) + " " + n(pts[0].y)
            case .addLineToPoint:
                out += "L"
                out += n(pts[0].x) + " " + n(pts[0].y)
            case .addQuadCurveToPoint:
                out += "Q"
                out += n(pts[0].x) + " " + n(pts[0].y) + " " + n(pts[1].x) + " " + n(pts[1].y)
            case .addCurveToPoint:
                out += "C"
                out += n(pts[0].x) + " " + n(pts[0].y) + " " + n(pts[1].x) + " " + n(pts[1].y) + " "
                out += n(pts[2].x) + " " + n(pts[2].y)
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
