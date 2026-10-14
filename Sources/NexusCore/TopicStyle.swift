import Foundation

/// Branch-line settings for a topic's outgoing lines (FMT-1 › Branch line).
public struct LineStyle: Hashable, Sendable, JSONRepresentable {
    /// curved, straight, elbow, rounded, tapered, zigzag
    public var shape: String?
    /// `branch` (follow the branch colour) or a hex colour.
    public var color: String?
    public var width: Double?
    /// none, arrow, dot, bar
    public var endCap: String?
    public var taper: Bool?
    /// Children's lines inherit this style.
    public var inherit: Bool?
    /// solid, dashed, dotted
    public var dash: String?
    public var glow: Bool?
    public var extra: [String: JSONValue] = [:]

    public init(
        shape: String? = nil, color: String? = nil, width: Double? = nil, endCap: String? = nil,
        taper: Bool? = nil, inherit: Bool? = nil, dash: String? = nil, glow: Bool? = nil
    ) {
        self.shape = shape
        self.color = color
        self.width = width
        self.endCap = endCap
        self.taper = taper
        self.inherit = inherit
        self.dash = dash
        self.glow = glow
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        shape = try r.optionalString("shape")
        color = try r.optionalString("color")
        width = try r.optionalDouble("width")
        endCap = try r.optionalString("endCap")
        taper = try r.optionalBool("taper")
        inherit = try r.optionalBool("inherit")
        dash = try r.optionalString("dash")
        glow = try r.optionalBool("glow")
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("shape", shape)
        w.set("color", color)
        w.set("width", width)
        w.set("endCap", endCap)
        w.set("taper", taper)
        w.set("inherit", inherit)
        w.set("dash", dash)
        w.set("glow", glow)
        return w.value
    }

    public func merged(over base: LineStyle?) -> LineStyle {
        var out = base ?? LineStyle()
        if let shape { out.shape = shape }
        if let color { out.color = color }
        if let width { out.width = width }
        if let endCap { out.endCap = endCap }
        if let taper { out.taper = taper }
        if let inherit { out.inherit = inherit }
        if let dash { out.dash = dash }
        if let glow { out.glow = glow }
        out.extra.merge(extra) { _, new in new }
        return out
    }

    public var isEmpty: Bool {
        shape == nil && color == nil && width == nil && endCap == nil && taper == nil && inherit == nil
            && dash == nil && glow == nil && extra.isEmpty
    }
}

/// Numbering (FMT-1 › Numbering, EN Enrich).
public struct NumberingStyle: Hashable, Sendable, JSONRepresentable {
    /// none, decimal, tiered, roman, upper, lower, circled, cjk
    public var format: String?
    public var tiered: Bool?
    public var applyToSiblings: Bool?
    public var restart: Bool?
    public var extra: [String: JSONValue] = [:]

    public init(format: String? = nil, tiered: Bool? = nil, applyToSiblings: Bool? = nil, restart: Bool? = nil) {
        self.format = format
        self.tiered = tiered
        self.applyToSiblings = applyToSiblings
        self.restart = restart
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        format = try r.optionalString("format")
        tiered = try r.optionalBool("tiered")
        applyToSiblings = try r.optionalBool("applyToSiblings")
        restart = try r.optionalBool("restart")
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("format", format)
        w.set("tiered", tiered)
        w.set("applyToSiblings", applyToSiblings)
        w.set("restart", restart)
        return w.value
    }
}

/// A topic's style, every field optional. Layers (node, quick style, level, node style
/// preset, theme, defaults) merge with `merged(over:)`; a set field always wins.
public struct TopicStyle: Hashable, Sendable, JSONRepresentable {
    /// One of the 32 shape ids (`rounded`, `rectangle`, `pill`, `hexagon` …).
    public var shape: String?
    /// none, solid, tint, gradient
    public var fill: String?
    /// `branch` or hex.
    public var fillColor: String?
    /// none, solid, dashed, dotted, hand, double
    public var border: String?
    public var borderWidth: Double?
    /// `branch`, `ink` or hex.
    public var borderColor: String?
    public var cornerRadius: Double?
    /// none, soft, hard, glow
    public var shadow: String?
    /// `branch`, `ink` or hex (hard shadows and glows).
    public var shadowColor: String?
    /// system, serif, mono, rounded, hand, or a font family name.
    public var font: String?
    public var fontSize: Double?
    /// regular, medium, semibold, bold, heavy
    public var fontWeight: String?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var code: Bool?
    /// none, upper, lower, title
    public var textCase: String?
    /// leading, center, trailing
    public var align: String?
    public var lineSpacing: Double?
    /// `branch`, `ink` or hex.
    public var textColor: String?
    public var autoContrast: Bool?
    /// Fixed wrap width in points (nil = automatic).
    public var width: Double?
    /// top, left, right, bottom
    public var imagePosition: String?
    public var line: LineStyle?
    public var siblingGap: Double?
    public var levelGap: Double?
    public var numbering: NumberingStyle?
    public var extra: [String: JSONValue] = [:]

    public init() {}

    public static let empty = TopicStyle()

    public var isEmpty: Bool { self == .empty }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        shape = try r.optionalString("shape")
        fill = try r.optionalString("fill")
        fillColor = try r.optionalString("fillColor")
        border = try r.optionalString("border")
        borderWidth = try r.optionalDouble("borderWidth")
        borderColor = try r.optionalString("borderColor")
        cornerRadius = try r.optionalDouble("cornerRadius")
        shadow = try r.optionalString("shadow")
        shadowColor = try r.optionalString("shadowColor")
        font = try r.optionalString("font")
        fontSize = try r.optionalDouble("fontSize")
        fontWeight = try r.optionalString("fontWeight")
        italic = try r.optionalBool("italic")
        underline = try r.optionalBool("underline")
        strikethrough = try r.optionalBool("strikethrough")
        code = try r.optionalBool("code")
        textCase = try r.optionalString("textCase")
        align = try r.optionalString("align")
        lineSpacing = try r.optionalDouble("lineSpacing")
        textColor = try r.optionalString("textColor")
        autoContrast = try r.optionalBool("autoContrast")
        width = try r.optionalDouble("width")
        imagePosition = try r.optionalString("imagePosition")
        if let l = r.raw("line"), l != .null { line = try LineStyle(json: l, path: "\(path).line") }
        siblingGap = try r.optionalDouble("siblingGap")
        levelGap = try r.optionalDouble("levelGap")
        if let n = r.raw("numbering"), n != .null { numbering = try NumberingStyle(json: n, path: "\(path).numbering") }
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("shape", shape)
        w.set("fill", fill)
        w.set("fillColor", fillColor)
        w.set("border", border)
        w.set("borderWidth", borderWidth)
        w.set("borderColor", borderColor)
        w.set("cornerRadius", cornerRadius)
        w.set("shadow", shadow)
        w.set("shadowColor", shadowColor)
        w.set("font", font)
        w.set("fontSize", fontSize)
        w.set("fontWeight", fontWeight)
        w.set("italic", italic)
        w.set("underline", underline)
        w.set("strikethrough", strikethrough)
        w.set("code", code)
        w.set("textCase", textCase)
        w.set("align", align)
        w.set("lineSpacing", lineSpacing)
        w.set("textColor", textColor)
        w.set("autoContrast", autoContrast)
        w.set("width", width)
        w.set("imagePosition", imagePosition)
        if let line, !line.isEmpty { w.set("line", line.json) }
        w.set("siblingGap", siblingGap)
        w.set("levelGap", levelGap)
        if let numbering { w.set("numbering", numbering.json) }
        return w.value
    }

    /// `self` layered over `base`: every field set here wins.
    public func merged(over base: TopicStyle) -> TopicStyle {
        var o = base
        if let shape { o.shape = shape }
        if let fill { o.fill = fill }
        if let fillColor { o.fillColor = fillColor }
        if let border { o.border = border }
        if let borderWidth { o.borderWidth = borderWidth }
        if let borderColor { o.borderColor = borderColor }
        if let cornerRadius { o.cornerRadius = cornerRadius }
        if let shadow { o.shadow = shadow }
        if let shadowColor { o.shadowColor = shadowColor }
        if let font { o.font = font }
        if let fontSize { o.fontSize = fontSize }
        if let fontWeight { o.fontWeight = fontWeight }
        if let italic { o.italic = italic }
        if let underline { o.underline = underline }
        if let strikethrough { o.strikethrough = strikethrough }
        if let code { o.code = code }
        if let textCase { o.textCase = textCase }
        if let align { o.align = align }
        if let lineSpacing { o.lineSpacing = lineSpacing }
        if let textColor { o.textColor = textColor }
        if let autoContrast { o.autoContrast = autoContrast }
        if let width { o.width = width }
        if let imagePosition { o.imagePosition = imagePosition }
        if let line { o.line = line.merged(over: base.line) }
        if let siblingGap { o.siblingGap = siblingGap }
        if let levelGap { o.levelGap = levelGap }
        if let numbering { o.numbering = numbering }
        o.extra.merge(extra) { _, new in new }
        return o
    }
}

/// A key-value field on a node (Data tab), optionally pinned to show on the node.
public struct MetadataField: Hashable, Sendable, JSONRepresentable {
    public var key: String
    public var value: String
    public var pinned: Bool
    public var extra: [String: JSONValue] = [:]

    public init(key: String, value: String, pinned: Bool = false) {
        self.key = key
        self.value = value
        self.pinned = pinned
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        key = try r.optionalString("key") ?? ""
        value = try r.optionalString("value") ?? ""
        pinned = try r.bool("pinned", default: false)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("key", key)
        w.set("value", value)
        w.set("pinned", pinned, omitting: false)
        return w.value
    }
}
