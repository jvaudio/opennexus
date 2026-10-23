import CryptoKit
import Foundation
import NexusCore
import NexusFormat
import NexusTheme

/// Xmind's style properties (M18, D185, D186): a topic's `style.properties`, a
/// relationship's, and a sheet's `theme` with one property set per topic class. Keys follow
/// Xmind's own (`svg:fill`, `fo:font-family`, `shape-class`, `line-class` …). The writer
/// turns OpenNexus styles into them and the importer reads the same keys back; anything
/// Xmind can't express is named for the export report.
enum XmindStyle {
    // MARK: Vocabularies (OpenNexus ↔ Xmind)

    /// Topic shapes. The first pair for an Xmind class is the one it imports as.
    static let shapes: [(String, String)] = [
        ("rounded", "org.xmind.topicShape.roundedRect"), ("rectangle", "org.xmind.topicShape.rect"),
        ("pill", "org.xmind.topicShape.ellipserect"), ("ellipse", "org.xmind.topicShape.ellipse"),
        ("circle", "org.xmind.topicShape.circle"), ("diamond", "org.xmind.topicShape.diamond"),
        ("parallelogram", "org.xmind.topicShape.parallelogram"), ("hexagon", "org.xmind.topicShape.hexagon"),
        ("cloud", "org.xmind.topicShape.cloud"), ("underline", "org.xmind.topicShape.underline"),
        // Close enough to write, imported as the shape above.
        ("squircle", "org.xmind.topicShape.roundedRect"), ("ring-pill", "org.xmind.topicShape.ellipserect"),
        ("double", "org.xmind.topicShape.rect"), ("hand", "org.xmind.topicShape.roundedRect"),
    ]
    /// Shapes written as a near equivalent rather than exactly.
    static let approximateShapes: Set<String> = ["squircle", "ring-pill", "double", "hand"]
    static let branchLines: [(String, String)] = [
        ("curved", "org.xmind.branchConnection.curve"), ("straight", "org.xmind.branchConnection.straight"),
        ("elbow", "org.xmind.branchConnection.elbow"), ("rounded", "org.xmind.branchConnection.roundedElbow"),
        // Read, not written: Xmind 2026's rounded fold from the central topic.
        ("curved", "org.xmind.branchConnection.roundedfold"),
    ]
    static let patterns: [(String, String)] = [("solid", "solid"), ("dashed", "dash"), ("dotted", "dot")]
    static let weights: [(String, String)] = [
        ("regular", "normal"), ("medium", "500"), ("semibold", "600"), ("bold", "bold"), ("heavy", "800"),
    ]
    /// OpenNexus's generic font tokens and the family Xmind gets for each.
    static let fonts: [(String, String)] = [
        ("serif", "Georgia"), ("mono", "Menlo"), ("rounded", "SF Pro Rounded"), ("hand", "Chalkboard SE"),
    ]
    static let cases: [(String, String)] = [("upper", "uppercase"), ("lower", "lowercase"), ("title", "capitalize")]
    static let aligns: [(String, String)] = [("leading", "left"), ("center", "center"), ("trailing", "right")]
    static let relationshipLines: [(String, String)] = [
        ("curved", "org.xmind.relationshipShape.curved"), ("straight", "org.xmind.relationshipShape.straight"),
        ("elbow", "org.xmind.relationshipShape.angled"),
    ]
    static let arrows: [(String, String)] = [
        ("none", "org.xmind.arrowShape.none"), ("arrow", "org.xmind.arrowShape.spearhead"),
        ("filled-arrow", "org.xmind.arrowShape.triangle"), ("diamond", "org.xmind.arrowShape.diamond"),
        ("dot", "org.xmind.arrowShape.dot"), ("square", "org.xmind.arrowShape.square"),
        // Written as the nearest Xmind arrow.
        ("triangle", "org.xmind.arrowShape.triangle"), ("filled-diamond", "org.xmind.arrowShape.diamond"),
        ("open-dot", "org.xmind.arrowShape.dot"),
    ]

    static func xmind(_ table: [(String, String)], _ v: String?) -> String? {
        v.flatMap { v in table.first { $0.0 == v }?.1 }
    }

    static func nexus(_ table: [(String, String)], _ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return table.first { $0.1.caseInsensitiveCompare(s) == .orderedSame }?.0
    }

    /// "2pt", "2px", "2" or a number → 2.
    static func points(_ v: Any?) -> Double? {
        if let d = XmindTask.number(v ?? "") { return d }
        guard let s = v as? String else { return nil }
        let digits = s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    static func pt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))pt" : String(format: "%.1fpt", v) }

    /// `#RRGGBB` (or `#RRGGBBAA`) in upper case, or nil.
    static func hex(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#"),
            s.count == 7 || s.count == 9, s.dropFirst().allSatisfy(\.isHexDigit)
        else { return nil }
        return s.uppercased()
    }

    // MARK: Topics

    /// A topic style as Xmind properties. `color` turns a colour token (`branch`, `ink`,
    /// hex) into hex; `lost` names what Xmind can't express.
    static func properties(_ s: TopicStyle, color: (String) -> String?, lost: inout [String]) -> [String: String] {
        var p: [String: String] = [:]
        if let shape = s.shape {
            if let x = xmind(shapes, shape) {
                p["shape-class"] = x
                if approximateShapes.contains(shape) { lost.append("Topic shape “\(shape)” (written as a near shape)") }
            } else {
                lost.append("Topic shape “\(shape)” (no Xmind equivalent)")
            }
        }
        switch s.fill {
        case "none"?: p["fill-pattern"] = "none"
        case "tint"?, "gradient"?: lost.append("Tint and gradient fills (written as solid)")
        default: break
        }
        if s.fill != "none", s.fillColor == "canvas" {
            // The bare map shows through Xmind's unfilled topic: the same look.
            p["fill-pattern"] = "none"
        } else if s.fill != "none", let c = s.fillColor.flatMap(color) {
            p["svg:fill"] = c
            if p["fill-pattern"] == nil { p["fill-pattern"] = "solid" }
        } else if s.fill != "none", s.fillColor?.hasPrefix("branch") == true {
            // Xmind fills a solid topic with no colour of its own in the branch colour.
            p["fill-pattern"] = "solid"
        }
        switch s.border {
        case "none"?: p["border-line-width"] = "0pt"
        case let b?:
            p["border-line-pattern"] = xmind(patterns, b) ?? "solid"
            if !["solid", "dashed", "dotted"].contains(b) { lost.append("Border style “\(b)” (written as solid)") }
        case nil: break
        }
        if s.border != "none", let w = s.borderWidth { p["border-line-width"] = pt(w) }
        if let c = s.borderColor.flatMap(color) { p["border-line-color"] = c }
        if let f = s.font, f != "system" { p["fo:font-family"] = xmind(fonts, f) ?? f }
        if let size = s.fontSize { p["fo:font-size"] = pt(size) }
        if let w = s.fontWeight { p["fo:font-weight"] = xmind(weights, w) ?? "normal" }
        if let i = s.italic { p["fo:font-style"] = i ? "italic" : "normal" }
        if s.underline != nil || s.strikethrough != nil {
            let d = [s.underline == true ? "underline" : nil, s.strikethrough == true ? "line-through" : nil]
            p["fo:text-decoration"] = d.compactMap(\.self).joined(separator: " ").nonEmpty ?? "none"
        }
        if let t = s.textCase { p["fo:text-transform"] = xmind(cases, t) ?? "none" }
        if let a = s.align, let x = xmind(aligns, a) { p["fo:text-align"] = x }
        if let c = s.textColor.flatMap(color) { p["fo:color"] = c }
        if let l = s.line {
            if let shape = l.shape {
                if let x = xmind(branchLines, shape == "tapered" ? "curved" : shape) {
                    p["line-class"] = x
                } else {
                    lost.append("Branch line shape “\(shape)” (no Xmind equivalent)")
                }
            }
            if let c = l.color.flatMap(color) { p["line-color"] = c }
            if let w = l.width { p["line-width"] = pt(w) }
            if let d = l.dash { p["line-pattern"] = xmind(patterns, d) ?? "solid" }
            if l.endCap != nil || l.taper != nil || l.glow != nil || l.inherit != nil || l.shape == "tapered" {
                lost.append("Branch line end caps, tapering, glow and inheritance")
            }
        }
        if s.shadow != nil || s.shadowColor != nil { lost.append("Topic shadow") }
        if s.cornerRadius != nil { lost.append("Corner radius") }
        if s.code != nil || s.lineSpacing != nil || s.autoContrast != nil {
            lost.append("Code style, line spacing and auto contrast")
        }
        if s.width != nil || s.imagePosition != nil || s.siblingGap != nil || s.levelGap != nil {
            lost.append("Topic width, image position and spacing")
        }
        if s.numbering != nil { lost.append("Numbering") }
        return p
    }

    /// Xmind topic properties as an OpenNexus style (nil when nothing maps).
    static func style(_ p: [String: Any]) -> TopicStyle? {
        var s = TopicStyle()
        s.shape = nexus(shapes, p["shape-class"])
        if (p["fill-pattern"] as? String) == "none" {
            s.fill = "none"
        } else if let c = hex(p["svg:fill"]) {
            s.fill = "solid"
            s.fillColor = c
        }
        let width = points(p["border-line-width"])
        if width == 0 {
            s.border = "none"
        } else {
            s.border = nexus(patterns, p["border-line-pattern"])
            s.borderWidth = width
            s.borderColor = hex(p["border-line-color"])
        }
        if let f = (p["fo:font-family"] as? String)?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
            s.font = nexus(fonts, f) ?? f
        }
        s.fontSize = points(p["fo:font-size"])
        if let w = p["fo:font-weight"] {
            s.fontWeight =
                nexus(weights, w)
                ?? points(w).map {
                    $0 >= 750 ? "heavy" : $0 >= 650 ? "bold" : $0 >= 550 ? "semibold" : $0 >= 450 ? "medium" : "regular"
                }
                ?? ((w as? String) == "bold" ? "bold" : nil)
        }
        if let i = p["fo:font-style"] as? String { s.italic = i == "italic" }
        if let d = p["fo:text-decoration"] as? String {
            s.underline = d.contains("underline")
            s.strikethrough = d.contains("line-through")
        }
        if let t = p["fo:text-transform"] as? String { s.textCase = nexus(cases, t) ?? "none" }
        s.align = nexus(aligns, p["fo:text-align"])
        s.textColor = hex(p["fo:color"])
        var l = LineStyle()
        l.shape = nexus(branchLines, p["line-class"])
        l.color = hex(p["line-color"])
        l.width = points(p["line-width"])
        l.dash = nexus(patterns, p["line-pattern"])
        if !l.isEmpty { s.line = l }
        return s.isEmpty ? nil : s
    }

    // MARK: Relationships

    /// A relationship's line, arrows, colour and width as Xmind properties (only what
    /// differs from OpenNexus's defaults).
    static func properties(_ r: Relationship, lost: inout [String]) -> [String: String] {
        var p: [String: String] = [:]
        if r.line != "curved" {
            if let x = xmind(relationshipLines, r.line) {
                p["shape-class"] = x
            } else {
                lost.append("Relationship line “\(r.line)” (written curved)")
            }
        }
        if r.ends != ["none", "arrow"] {
            for (key, cap) in zip(["arrow-begin-class", "arrow-end-class"], r.ends) {
                if let x = xmind(arrows, cap) {
                    p[key] = x
                    if ["triangle", "filled-diamond", "open-dot"].contains(cap) {
                        lost.append("Relationship arrow “\(cap)” (written as a near arrow)")
                    }
                } else {
                    lost.append("Relationship arrow “\(cap)” (no Xmind equivalent)")
                }
            }
        }
        if r.dash != "dashed" { p["line-pattern"] = xmind(patterns, r.dash) ?? "solid" }
        if r.width != 2 { p["line-width"] = pt(r.width) }
        if let c = hex(r.color) {
            p["line-color"] = c
        } else if r.color == "source" {
            lost.append("Relationship colour that follows its source")
        }
        if r.labelPosition != "middle" || r.labelStyle != "pill" || r.kind != nil || r.bend != nil {
            lost.append("Relationship label placement, technical kind and hand-drawn bends")
        }
        return p
    }

    /// Reads a relationship's properties back onto an import link.
    static func apply(_ p: [String: Any], to l: inout ICanvas.Link) {
        l.line = nexus(relationshipLines, p["shape-class"])
        let begin = nexus(arrows, p["arrow-begin-class"])
        let end = nexus(arrows, p["arrow-end-class"])
        if begin != nil || end != nil { l.ends = [begin ?? "none", end ?? "arrow"] }
        l.dash = nexus(patterns, p["line-pattern"])
        l.width = points(p["line-width"])
        l.color = hex(p["line-color"])
    }

    // MARK: Boundaries and summaries

    /// Boundary shapes (D217). The first pair for an Xmind class is the one it imports as.
    static let boundaryShapes: [(String, String)] = [
        ("rounded", "org.xmind.boundaryShape.roundedRect"), ("rectangle", "org.xmind.boundaryShape.rect"),
        ("scallop", "org.xmind.boundaryShape.scallops"), ("wave", "org.xmind.boundaryShape.waves"),
        ("polygon", "org.xmind.boundaryShape.polygon"),
        // Close enough to write, imported as the shape above. A dashed boundary is a
        // rounded one with a dashed line, which Xmind draws the same.
        ("dashed", "org.xmind.boundaryShape.roundedRect"), ("stadium", "org.xmind.boundaryShape.roundedRect"),
        ("ellipse", "org.xmind.boundaryShape.roundedRect"), ("corners", "org.xmind.boundaryShape.rect"),
        // Read, not written: Xmind's pinched rectangle has no OpenNexus shape.
        ("rounded", "org.xmind.boundaryShape.tension"),
    ]
    static let summaryShapes: [(String, String)] = [
        ("curly", "org.xmind.summaryShape.curly"), ("square", "org.xmind.summaryShape.square"),
        ("round", "org.xmind.summaryShape.round"),
        // Written as the nearest Xmind bracket; Xmind's angle bracket reads as curly.
        ("line", "org.xmind.summaryShape.square"), ("curly", "org.xmind.summaryShape.angle"),
    ]

    /// A boundary's colour as the canvas draws it: its own, else its meaning's or the ring.
    static func color(_ b: Boundary, theme t: Theme) -> RGBA {
        b.color.flatMap(RGBA.init(hexString:))
            ?? (b.meaning == "trust" ? t.critical : b.meaning == "vpc" || b.meaning == "subnet" ? t.entityLine : t.ring)
    }

    /// Xmind's fill for a boundary: its colour at its fill opacity, mixed over the canvas.
    static func fill(_ c: RGBA, opacity: Double, canvas: RGBA) -> String {
        c.alpha(c.a * opacity).composited(over: canvas).hex
    }

    /// A boundary as Xmind properties: only what differs from the theme's boundary class,
    /// which holds OpenNexus's defaults (D217).
    static func properties(_ b: Boundary, theme t: Theme, canvas: RGBA, lost: inout [String]) -> [String: String] {
        var p: [String: String] = [:]
        let c = color(b, theme: t)
        let own = b.color != nil || c != t.ring
        if b.fillOpacity <= 0 || b.shape == "corners" {
            p["fill-pattern"] = "none"
        } else if own || b.fillOpacity != 0.06 {
            // The importer finds the opacity from the fill and the line colour together.
            p["svg:fill"] = fill(c, opacity: b.fillOpacity, canvas: canvas)
            p["fill-pattern"] = "solid"
        }
        if own || p["svg:fill"] != nil { p["line-color"] = c.composited(over: canvas).hex }
        let dash =
            b.dash ?? (b.meaning == "trust" || b.meaning == "subnet" || b.shape == "dashed" ? "dashed" : "solid")
        if dash != "solid" { p["line-pattern"] = xmind(patterns, dash) ?? "solid" }
        if b.width != 2 { p["line-width"] = pt(b.width) }
        if b.shape != "rounded" {
            if let x = xmind(boundaryShapes, b.shape) {
                if x != xmind(boundaryShapes, "rounded") { p["shape-class"] = x }
                if ["stadium", "ellipse", "corners"].contains(b.shape) {
                    lost.append("Boundary shape “\(b.shape)” (written as a near shape)")
                }
            } else {
                lost.append("Boundary shape “\(b.shape)” (no Xmind equivalent)")
            }
        }
        if b.meaning != "group" || b.trust != nil { lost.append("Boundary meaning (zone, VPC, subnet, trust level)") }
        if b.titlePosition != "top-left" { lost.append("Boundary title position") }
        return p
    }

    /// Reads boundary properties onto an import group. Xmind has separate line and fill
    /// colours; OpenNexus draws the fill in the line colour, so the fill gives the opacity
    /// that mixes the line colour over `canvas` closest to it.
    static func apply(_ p: [String: Any], canvas: RGBA, to g: inout ICanvas.Group, report: inout ImportReport) {
        let line = hex(p["line-color"]).map(opaque)
        let fill = hex(p["svg:fill"]).map(opaque)
        g.color = line ?? fill
        if (p["fill-pattern"] as? String) == "none" {
            g.fillOpacity = 0
        } else if let line, let fill, let c = RGBA(hexString: line), let f = RGBA(hexString: fill) {
            let d = [
                (f.r - canvas.r, c.r - canvas.r), (f.g - canvas.g, c.g - canvas.g), (f.b - canvas.b, c.b - canvas.b),
            ]
            let den = d.reduce(0) { $0 + $1.1 * $1.1 }
            if den > 0.01 {
                let a = d.reduce(0) { $0 + $1.0 * $1.1 } / den
                g.fillOpacity = (max(0, min(1, a)) * 100).rounded() / 100
            }
        }
        g.dash = nexus(patterns, p["line-pattern"])
        g.width = points(p["line-width"])
        g.shape = nexus(boundaryShapes, p["shape-class"])
        if let s = p["shape-class"] as? String, s.hasSuffix("tension") {
            report.skip("Boundary shape “tension” (drawn rounded)")
        }
    }

    /// A summary's bracket, colour and width as Xmind properties (only what differs from
    /// the theme's summary class).
    static func properties(_ s: Summary, lost: inout [String]) -> [String: String] {
        var p: [String: String] = [:]
        if let c = hex(s.color) { p["line-color"] = opaque(c) }
        if s.width != 2 { p["line-width"] = pt(s.width) }
        if s.bracket != "curly" {
            if let x = xmind(summaryShapes, s.bracket) {
                p["shape-class"] = x
                if s.bracket == "line" { lost.append("Summary bracket “line” (written square)") }
            } else {
                lost.append("Summary bracket “\(s.bracket)” (written curly)")
            }
        }
        return p
    }

    static func apply(_ p: [String: Any], to b: inout ICanvas.Brace) {
        b.color = hex(p["line-color"]).map(opaque)
        b.width = points(p["line-width"])
        b.bracket = nexus(summaryShapes, p["shape-class"])
    }

    // MARK: OpenNexus's own record

    /// The extension provider for OpenNexus-only style data that Xmind keeps but ignores
    /// (D218): on a sheet, its level styles and theme; on a topic, its quick style and its
    /// own style with colour tokens such as `branch` unresolved.
    static let provider = "org.opennexus.style"

    /// The written properties, hashed. A topic's record is used only while its properties
    /// are still the ones written, so a style changed in Xmind wins.
    static func fingerprint(_ p: [String: String]) -> String {
        let text = p.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A topic's record, or nil when reading its properties back already gives its style.
    /// A custom quick style isn't in the importing document's library, so it's written as
    /// part of the topic's own style.
    static func record(quickStyle: String?, own: TopicStyle?, library: [QuickStyle], written p: [String: String])
        -> [String: Any]?
    {
        var own = own.flatMap { $0.isEmpty ? nil : $0 }
        var quick = quickStyle
        if let q = quickStyle, !QuickStyle.builtIn.contains(where: { $0.id == q }) {
            quick = nil
            if let qs = QuickStyle.named(q, custom: library)?.style, !qs.isEmpty {
                own = (own ?? TopicStyle()).merged(over: qs)
            }
        }
        guard quick != nil || own != style(p) else { return nil }
        var o: [String: Any] = ["written": fingerprint(p)]
        if let quick { o["quickStyle"] = quick }
        if let own, let v = any(own.json) { o["style"] = v }
        return o
    }

    /// A topic's quick style and own style from its record, or nil when the record is
    /// stale (the topic's properties were changed after OpenNexus wrote them).
    static func restore(_ record: [String: Any], written p: [String: Any]?) -> (
        quickStyle: String?, style: TopicStyle?
    )? {
        var props: [String: String] = [:]
        for (k, v) in p ?? [:] {
            guard let s = v as? String else { return nil }
            props[k] = s
        }
        guard record["written"] as? String == fingerprint(props) else { return nil }
        let style = record["style"].flatMap(jsonValue).flatMap { try? TopicStyle(json: $0, path: "style") }
        return (record["quickStyle"] as? String, style.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A sheet's record: its level styles, and its theme when the theme id doesn't say it.
    static func record(_ s: CanvasStyle, themeID: String, tagged: Bool) -> [String: Any]? {
        var o: [String: Any] = [:]
        let levels = s.levels.filter { !$0.value.isEmpty }
        if !levels.isEmpty {
            o["levels"] = Dictionary(
                uniqueKeysWithValues: levels.compactMap { k, v in any(v.json).map { ("\(k)", $0) } })
        }
        if !tagged {
            o["theme"] = s.theme
            o["themeId"] = themeID
        }
        return o.isEmpty ? nil : o
    }

    /// The OpenNexus theme a sheet's record names, while the sheet still has the theme
    /// OpenNexus wrote.
    static func recordedTheme(_ record: [String: Any]?, theme: [String: Any]?) -> String? {
        guard let id = record?["themeId"] as? String, id == theme?["id"] as? String else { return nil }
        return record?["theme"] as? String
    }

    static func levels(_ record: [String: Any]?) -> [Int: TopicStyle] {
        var out: [Int: TopicStyle] = [:]
        for (k, v) in (record?["levels"] as? [String: Any]) ?? [:] {
            guard let d = Int(k), let j = jsonValue(v), let s = try? TopicStyle(json: j, path: "levels.\(k)"),
                !s.isEmpty
            else { continue }
            out[d] = s
        }
        return out
    }

    static func any(_ v: JSONValue) -> Any? {
        try? JSONSerialization.jsonObject(with: CanonicalJSON.data(v), options: .fragmentsAllowed)
    }

    static func jsonValue(_ v: Any) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else {
            return nil
        }
        return try? CanonicalJSON.parse(d)
    }

    // MARK: Themes

    /// The theme id prefix that marks a theme OpenNexus wrote, so it imports as that theme.
    static let themePrefix = "opennexus."

    /// A sheet's `theme`: the map's background and branch colours, and the theme's style
    /// for each topic class, boundaries and relationships.
    static func theme(_ env: StyleEnvironment, sheet: String, lost: inout [String]) -> [String: Any] {
        let t = env.theme
        func klass(_ name: String, _ p: [String: String]) -> [String: Any] {
            ["id": "\(sheet)-theme-\(name)", "properties": p]
        }
        func role(_ r: NodeRoleStyle) -> [String: String] {
            // The canvas's base for the role, as `StyleEnvironment` layers it.
            var base = env.nodeStyle.layer(r).merged(
                over: StyleResolver.themeLayer(t, role: r).merged(over: StyleResolver.defaults(r)))
            if let own = env.canvasStyle.roles[r.rawValue] { base = own.merged(over: base) }
            // Branch colours come from the map's line colours in Xmind.
            if base.borderColor == "branch" { base.borderColor = nil }
            base.shadow = nil
            base.cornerRadius = nil
            base.autoContrast = nil
            base.code = nil
            var ignored: [String] = []
            // Xmind wants opaque colours: translucent theme fills are mixed over the canvas.
            let opaque = { (c: String) in RGBA(hexString: c).map { $0.composited(over: env.canvas).hex } }
            var p = properties(base, color: opaque, lost: &ignored)
            if env.canvasStyle.roles[r.rawValue]?.font == nil, let f = env.canvasStyle.font, !f.isEmpty, f != "system" {
                p["fo:font-family"] = xmind(fonts, f) ?? f
            }
            let line = env.canvasStyle.lineShape ?? (env.nodeStyle.line.shape ?? t.lineShape)
            if let x = xmind(branchLines, line == "tapered" ? "curved" : line) { p["line-class"] = x }
            return p
        }
        var map: [String: String] = ["svg:fill": env.canvas.hex]
        let colors =
            env.canvasStyle.coloredBranch
            ? env.palette.map(\.hex)
            : [env.canvasStyle.singleColor.flatMap(hex) ?? t.ink2.hex]
        if !colors.isEmpty { map["multi-line-colors"] = colors.joined(separator: " ") }
        let taper = env.canvasStyle.lineWidth == "taper" || env.theme.lineShape == "tapered"
        map["line-tapered"] = taper ? "tapered" : "none"
        if env.canvasStyle.nodeStyle != "outline" || env.canvasStyle.colorTheme != "rainbow"
            || env.canvasStyle.paletteShift != 0 || env.canvasStyle.pattern != nil
        {
            lost.append("Node style, colour mode and background pattern (Xmind keeps the theme's colours)")
        }
        let sub = role(.sub)
        // A canvas carrying another app's colours or topic styles writes them untagged, so
        // they import back as written rather than as the OpenNexus theme (D211).
        let tagged = env.canvasStyle.roles.isEmpty && env.canvasStyle.palette != "canvas"
        return [
            "id": tagged ? "\(themePrefix)\(t.id)" : "\(sheet)-theme", "title": "\(t.name) (OpenNexus)",
            "map": klass("map", map),
            "centralTopic": klass("centralTopic", role(.root)),
            "mainTopic": klass("mainTopic", role(.main)),
            "subTopic": klass("subTopic", sub),
            "floatingTopic": klass("floatingTopic", role(.floating)),
            "summaryTopic": klass("summaryTopic", sub),
            "calloutTopic": klass("calloutTopic", sub),
            // OpenNexus's defaults for boundaries, summaries and relationships, so each one
            // only writes what it changes (D217).
            "boundary": klass(
                "boundary",
                [
                    "line-color": t.ring.hex, "line-pattern": "solid", "line-width": "2pt",
                    "shape-class": "org.xmind.boundaryShape.roundedRect", "fill-pattern": "solid",
                    "svg:fill": fill(t.ring, opacity: 0.06, canvas: env.canvas),
                ]),
            "summary": klass(
                "summary",
                ["line-color": t.ink2.hex, "line-width": "2pt", "shape-class": "org.xmind.summaryShape.curly"]),
            "relationship": klass(
                "relationship",
                [
                    "line-color": t.relationship.hex, "line-pattern": "dash", "line-width": "2pt",
                    "shape-class": "org.xmind.relationshipShape.curved",
                    "arrow-begin-class": "org.xmind.arrowShape.none",
                    "arrow-end-class": "org.xmind.arrowShape.spearhead",
                ]),
        ]
    }

    /// Whether a sheet's theme is one OpenNexus wrote: tagged with its id, or named by
    /// the sheet's record.
    static func isOwn(_ theme: [String: Any]?, record: [String: Any]?) -> Bool {
        let id = theme?["id"] as? String ?? ""
        return (id.hasPrefix(themePrefix) && id.count > themePrefix.count) || recordedTheme(record, theme: theme) != nil
    }

    /// Another app's theme classes for boundaries, summaries and relationships (D219):
    /// each element imports with its class's properties under its own. A theme OpenNexus
    /// wrote holds only OpenNexus's defaults, so it gives none.
    static func elementClasses(_ theme: [String: Any]?, record: [String: Any]?) -> (
        boundary: [String: Any], summary: [String: Any], relationship: [String: Any]
    ) {
        guard let theme, !isOwn(theme, record: record) else { return ([:], [:], [:]) }
        func props(_ k: String) -> [String: Any] {
            ((theme[k] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        }
        return (props("boundary"), props("summary"), props("relationship"))
    }

    /// The canvas colour an imported canvas style paints, for reading boundary fills.
    static func canvasColor(_ s: CanvasStyle?) -> RGBA {
        s?.background.flatMap(RGBA.init(hexString:)) ?? Theme.named(s?.theme ?? "classic").canvas
    }

    /// What a sheet's theme, style and record set on the canvas (D210, D211, D218):
    /// OpenNexus's own theme when it wrote it; otherwise the theme's background, branch
    /// colours, font, line class and topic-class styles. The sheet's own `style` fill is
    /// the background when set, as in Xmind. Level styles come from the record.
    static func canvasStyle(_ theme: [String: Any], sheetStyle: [String: Any]? = nil, record: [String: Any]? = nil)
        -> CanvasStyle?
    {
        func props(_ k: String) -> [String: Any] {
            ((theme[k] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        }
        var s = CanvasStyle()
        let id = theme["id"] as? String ?? ""
        let ours = id.hasPrefix(themePrefix) && id.count > themePrefix.count
        if ours {
            s.theme = String(id.dropFirst(themePrefix.count))
        } else if let recorded = recordedTheme(record, theme: theme) {
            // An untagged theme OpenNexus wrote (D211) is named by the sheet's record (D218).
            s.theme = recorded
        }
        s.levels = levels(record)
        let base = Theme.named(s.theme)
        if let bg = hex(sheetStyle?["svg:fill"]).map(opaque) ?? hex(props("map")["svg:fill"]), bg != base.canvas.hex {
            s.background = bg
        }
        if let f = (props("centralTopic")["fo:font-family"] as? String).map({ nexus(fonts, $0) ?? $0 }),
            f != base.font
        {
            s.font = f
        }
        // The central topic's line class draws its main branches, the most visible lines.
        let lineClass = props("centralTopic")["line-class"] ?? props("mainTopic")["line-class"]
        if let line = nexus(branchLines, lineClass), line != base.lineShape,
            !(line == "curved" && base.lineShape == "tapered")
        {
            s.lineShape = line
        }
        if !ours {
            // Another app's theme: its branch colours travel with the canvas, and its topic
            // classes become role styles.
            let colors = ((props("map")["multi-line-colors"] as? String) ?? "")
                .split(separator: " ").compactMap { hex(String($0)).map(opaque) }
            if !colors.isEmpty {
                s.colors = colors
                s.palette = "canvas"
            }
            for (klass, role) in [
                ("centralTopic", "root"), ("mainTopic", "main"), ("subTopic", "sub"), ("floatingTopic", "floating"),
            ] {
                guard var r = roleStyle(props(klass), role: role) else { continue }
                if r.font == s.font { r.font = nil }
                if !r.isEmpty { s.roles[role] = r }
            }
        }
        return s == CanvasStyle() ? nil : s
    }

    /// An Xmind topic class as a role style. A solid fill or border with no colour of its
    /// own takes the branch colour, as in Xmind; subtopics get a tint of it.
    static func roleStyle(_ p: [String: Any], role: String) -> TopicStyle? {
        guard var s = style(p) else { return nil }
        // Branch lines keep the branch colours; the canvas carries the line shape.
        s.line = nil
        switch p["fill-pattern"] as? String {
        case "solid"? where hex(p["svg:fill"]) == nil:
            s.fill = "solid"
            s.fillColor = role == "sub" ? "branch@0.2" : "branch"
        case "none"?:
            // Xmind draws an unfilled topic over the bare map; the canvas colour looks the
            // same, keeps lines from showing through, and gives its text a contrast base.
            s.fill = "solid"
            s.fillColor = "canvas"
        default: break
        }
        // Xmind's "inherited" text is black or white, whichever suits the fill.
        if s.textColor == nil { s.textColor = "auto" }
        // Defaults stay unset, so the canvas's own choices still apply.
        if s.italic == false { s.italic = nil }
        if s.underline == false { s.underline = nil }
        if s.strikethrough == false { s.strikethrough = nil }
        if s.textCase == "none" { s.textCase = nil }
        if let w = s.borderWidth, w > 0 {
            // A width alone is a visible solid border in Xmind. Its colour is the branch's;
            // the central topic has no branch, so it takes the class's line colour.
            if s.border == nil { s.border = "solid" }
            if s.borderColor == nil { s.borderColor = role == "root" ? hex(p["line-color"]) ?? s.fillColor : "branch" }
        }
        return s.isEmpty ? nil : s
    }

    /// `#RRGGBBAA` → `#RRGGBB` when opaque; Xmind writes the alpha byte on some fills.
    static func opaque(_ c: String) -> String {
        c.count == 9 && c.hasSuffix("FF") ? String(c.prefix(7)) : c
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
