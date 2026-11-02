import CoreText
import Foundation
import NexusCore
import NexusTheme

/// Text attributes for a node. The same attributes are used to measure, to draw, and
/// to configure the text editor, so a node never wraps differently from how it was
/// measured (P0's "Team / s" artefact, README §14).
public struct NodeTextStyle: Hashable, Sendable {
    public var fontSize: Double
    public var weight: NodeTypography.Weight
    public var lineHeight: Double
    /// system, serif, mono, rounded, hand, or a family name.
    public var family: String
    public var italic: Bool
    public var maxWidth: Double
    /// leading, center, trailing
    public var align: String
    public var underline: Bool
    public var strikethrough: Bool
    public var code: Bool
    /// plain (nil), math or code: how the topic's text is typeset (`/math`, `/code`).
    public var format: String?
    public var language: String?
    /// Typeset `$…$` and `$$…$$` in plain text (Settings › Editing › Typeset math in text, M48).
    public var typesetsMath = false

    public init(typography t: NodeTypography, monospaced: Bool) {
        fontSize = t.fontSize
        weight = t.weight
        lineHeight = t.lineHeight
        family = monospaced ? "mono" : "system"
        italic = false
        maxWidth = t.maxWidth
        align = "center"
        underline = false
        strikethrough = false
        code = false
    }

    public init(appearance a: NodeAppearance) {
        fontSize = a.fontSize
        weight = a.fontWeight
        lineHeight = a.lineHeight
        family = a.font
        italic = a.italic
        maxWidth = a.maxWidth
        align = a.align
        underline = a.underline
        strikethrough = a.strikethrough
        code = a.code
    }

    public var fontWeight: FontWeight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    /// Fonts are built once per face: a descriptor with a cascade list is costly, and
    /// every node's style asks for its font several times per update.
    public var font: CTFont {
        let key = FontKey(
            family: code ? "mono" : family, size: fontSize, weight: weight, italic: italic, cjk: Self.cjkFamily)
        if let f = Self.fonts[key] { return f }
        let f = makeFont()
        Self.fonts[key] = f
        return f
    }

    struct FontKey: Hashable {
        var family: String
        var size: Double
        var weight: NodeTypography.Weight
        var italic: Bool
        var cjk: String?
    }

    static let fonts = FontCache()

    /// CTFont is immutable once made, so sharing it across threads under a lock is safe.
    final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [FontKey: CTFont] = [:]
        subscript(key: FontKey) -> CTFont? {
            get { lock.withLock { fonts[key] } }
            set { lock.withLock { fonts[key] = newValue } }
        }
    }

    private func makeFont() -> CTFont {
        let size = CGFloat(fontSize)
        var f: CTFont
        switch code ? "mono" : family {
        case "system", "": f = Fonts.system(size, fontWeight)
        case "mono": f = Fonts.mono(size, fontWeight)
        case "serif": f = Fonts.system(size, fontWeight, design: .serif)
        case "rounded": f = Fonts.system(size, fontWeight, design: .rounded)
        case "hand":
            // A handwriting face that ships with macOS and iOS (no bundled font needed).
            let heavy = weight == .bold || weight == .heavy || weight == .semibold
            f =
                Fonts.named(heavy ? "Noteworthy-Bold" : "Noteworthy-Light", size: size)
                ?? Fonts.named("ChalkboardSE-Regular", size: size) ?? Fonts.system(size, fontWeight)
        default:
            f =
                Fonts.family(family, weight: Self.managerWeight(weight), size: size)
                ?? Fonts.system(size, fontWeight)
        }
        if italic { f = Fonts.adding(.traitItalic, to: f) }
        // Settings › Appearance › CJK font: Chinese, Japanese and Korean text falls back to it.
        if let cjk = Self.cjkFamily { f = Fonts.cascading(f, to: cjk) }
        return f
    }

    /// Set from Settings (nil keeps the system's CJK fallback).
    nonisolated(unsafe) public static var cjkFamily: String?

    public static func managerWeight(_ w: NodeTypography.Weight) -> Int {
        switch w {
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 11
        }
    }

    public var paragraphStyle: TextParagraph {
        let a: TextParagraph.Alignment =
            switch align {
            case "leading": .left
            case "trailing": .right
            default: .center
            }
        return TextParagraph(alignment: a, lineBreak: .wordWrap, lineHeight: lineHeight)
    }

    /// Baseline shift that centres glyphs in a line box taller than the font's own line
    /// (TextKit puts the extra height above the glyphs).
    public var baselineOffset: Double {
        let m = Fonts.metrics(font)
        let natural = m.ascender - m.descender + m.leading
        return max(0, (lineHeight - natural) / 2)
    }

    /// The title with its rich-text runs applied over the base attributes. Formulas become
    /// typeset runs (M48); `highlights` (search matches) are ranges of `text`, marked
    /// before formulas replace their source. A formula with an error shows its source in
    /// `errorColor`.
    public func attributed(
        _ text: String, marks: [TextMark], color: TextColorValue, linkColor: TextColorValue? = nil,
        errorColor: TextColorValue = .system(.red), highlights: [NSRange] = []
    ) -> StyledText {
        if format == "math" {
            return MathText.block(text, base: attributes(color: color), font: font, errorColor: errorColor)
        }
        if format == "code" {
            return CodeText.render(text, size: CGFloat(fontSize) * 0.92, color: color, paragraph: paragraphStyle)
        }
        let s = NSMutableAttributedString(string: text, attributes: attributes(color: color))
        let length = (text as NSString).length
        for m in marks {
            let r = NSRange(location: max(0, m.start), length: max(0, min(m.length, length - m.start)))
            guard r.length > 0, r.location < length else { continue }
            if m.bold || m.italic {
                let base = s.attribute(TextKey.font, at: r.location, effectiveRange: nil).map { $0 as! CTFont } ?? font
                var f = base
                if m.bold { f = Fonts.adding(.traitBold, to: f) }
                if m.italic { f = Fonts.adding(.traitItalic, to: f) }
                s.addAttribute(TextKey.font, value: f, range: r)
            }
            if m.underline { s.addAttribute(TextKey.underline, value: 1, range: r) }
            if m.strikethrough { s.addAttribute(TextKey.strikethrough, value: 1, range: r) }
            if let link = m.link {
                s.addAttribute(TextKey.link, value: link, range: r)
                s.addAttribute(TextKey.underline, value: 1, range: r)
                if let linkColor { s.addAttribute(TextKey.color, value: linkColor.attribute, range: r) }
            }
        }
        for r in highlights where r.location + r.length <= length {
            s.addAttribute(TextKey.background, value: Self.highlight, range: r)
        }
        if typesetsMath { MathText.typeset(s, font: font, errorColor: errorColor) }
        return s
    }

    /// Search matches' highlight behind the text (artboard 47).
    public static let highlight = CGColor(srgbRed: 1, green: 0.86, blue: 0.3, alpha: 0.75)

    public func attributes(color: TextColorValue) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            TextKey.font: font, TextKey.paragraph: paragraphStyle, TextKey.color: color.attribute,
            TextKey.baselineOffset: baselineOffset,
        ]
        if underline { a[TextKey.underline] = 1 }
        if strikethrough { a[TextKey.strikethrough] = 1 }
        return a
    }
}

/// Measures node text and caches the result.
@MainActor
public final class NodeMeasurer {
    private struct Key: Hashable {
        var text: String
        var style: NodeTextStyle
        var marks: [TextMark]
        /// For text with maths, the engine's generation: a size measured with a formula's
        /// source gives way once the formula is typeset.
        var math: Int
    }

    private var cache: [Key: CGSize] = [:]
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init() {}

    public func clearCache() { cache.removeAll() }

    /// Size of the text block (not including padding).
    public func textSize(_ text: String, style: NodeTextStyle, marks: [TextMark] = []) -> CGSize {
        let math =
            style.format == "math" || (style.typesetsMath && MathMarkup.mayContain(text))
            ? MathEngine.shared.generation : -1
        let key = Key(text: text, style: style, marks: marks, math: math)
        if let s = cache[key] {
            hits += 1
            return s
        }
        misses += 1
        let s = Self.measure(text, style: style, marks: marks)
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = s
        return s
    }

    /// Uses the platform's string drawing (TextKit on the Mac), the same engine that draws
    /// node text and backs the editor.
    public static func measure(_ text: String, style: NodeTextStyle, marks: [TextMark] = []) -> CGSize {
        measure(text, style: style, marks: marks, engine: Graphics.platform)
    }

    /// The same measurement with a given engine (NexusSceneTests compares CoreText's with TextKit's).
    package static func measure(_ text: String, style: NodeTextStyle, marks: [TextMark], engine: any PlatformGraphics)
        -> CGSize
    {
        let string = text.isEmpty ? " " : text
        let attr = style.attributed(string, marks: marks, color: .fixed(CGColor(gray: 0, alpha: 1)))
        if MathText.contains(attr) {
            // Formulas: CoreText's layout, which draws them too. A line can't break inside a
            // formula, so one wider than the topic widens it.
            var size = MathLayout(attr, width: nil).size
            if size.width > style.maxWidth { size = MathLayout(attr, width: style.maxWidth).size }
            return CGSize(width: ceil(max(size.width, 1)), height: ceil(size.height))
        }
        let options: TextOptions = [.lineFragmentOrigin, .fontLeading]
        // Natural width first, so short titles never wrap.
        let natural = engine.boundingRect(
            attr, size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: options)
        let width = min(ceil(natural.width), style.maxWidth)
        func fit(_ w: CGFloat) -> (CGRect, CGFloat) {
            let r = engine.boundingRect(
                attr, size: CGSize(width: w, height: .greatestFiniteMagnitude), options: options)
            return (r, max(1, (r.height / style.lineHeight).rounded()))
        }
        var (fitted, lines) = fit(width)
        if lines > 1 {
            // Balanced wrapping: the narrowest width that keeps the same line count, so a
            // long topic never ends on a lone word.
            var lo = max(1, width / lines)
            var hi = width
            while hi - lo > 2 {
                let mid = ((lo + hi) / 2).rounded(.down)
                if fit(mid).1 <= lines { hi = mid } else { lo = mid }
            }
            (fitted, lines) = fit(hi)
        }
        return CGSize(width: ceil(max(fitted.width, 1)), height: lines * style.lineHeight)
    }
}
