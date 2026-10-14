import AppKit
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

    var nsWeight: NSFont.Weight {
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
    public var font: NSFont {
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

    /// NSFont is immutable once made, so sharing it across threads under a lock is safe.
    final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [FontKey: NSFont] = [:]
        subscript(key: FontKey) -> NSFont? {
            get { lock.withLock { fonts[key] } }
            set { lock.withLock { fonts[key] = newValue } }
        }
    }

    private func makeFont() -> NSFont {
        let size = CGFloat(fontSize)
        var f: NSFont
        switch code ? "mono" : family {
        case "system", "": f = .systemFont(ofSize: size, weight: nsWeight)
        case "mono": f = .monospacedSystemFont(ofSize: size, weight: nsWeight)
        case "serif", "rounded":
            let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
            let design: NSFontDescriptor.SystemDesign = family == "serif" ? .serif : .rounded
            f = base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case "hand":
            // A handwriting face that ships with macOS (no bundled font needed).
            let heavy = weight == .bold || weight == .heavy || weight == .semibold
            f =
                NSFont(name: heavy ? "Noteworthy-Bold" : "Noteworthy-Light", size: size)
                ?? NSFont(name: "ChalkboardSE-Regular", size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
        default:
            f =
                NSFontManager.shared.font(
                    withFamily: family, traits: [], weight: Self.managerWeight(weight), size: size)
                ?? .systemFont(ofSize: size, weight: nsWeight)
        }
        if italic {
            f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
        }
        // Settings › Appearance › CJK font: Chinese, Japanese and Korean text falls back to it.
        if let cjk = Self.cjkFamily {
            let fallback = NSFontDescriptor(fontAttributes: [.family: cjk])
            if let withCascade = NSFont(
                descriptor: f.fontDescriptor.addingAttributes([.cascadeList: [fallback]]), size: size)
            {
                f = withCascade
            }
        }
        return f
    }

    /// Set from Settings (nil keeps the system's CJK fallback).
    nonisolated(unsafe) public static var cjkFamily: String?

    static func managerWeight(_ w: NodeTypography.Weight) -> Int {
        switch w {
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 11
        }
    }

    public var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment =
            switch align {
            case "leading": .left
            case "trailing": .right
            default: .center
            }
        p.lineBreakMode = .byWordWrapping
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        return p
    }

    /// Baseline shift that centres glyphs in a line box taller than the font's own line
    /// (TextKit puts the extra height above the glyphs).
    public var baselineOffset: Double {
        let f = font
        let natural = f.ascender - f.descender + f.leading
        return max(0, (lineHeight - natural) / 2)
    }

    /// The title with its rich-text runs applied over the base attributes.
    public func attributed(_ text: String, marks: [TextMark], color: NSColor, linkColor: NSColor? = nil)
        -> NSAttributedString
    {
        if format == "math" {
            return MathText.render(text, size: CGFloat(fontSize) * 1.15, color: color, paragraph: paragraphStyle)
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
                let base = s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont ?? font
                var f = base
                if m.bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if m.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                s.addAttribute(.font, value: f, range: r)
            }
            if m.underline { s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
            if m.strikethrough {
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            }
            if let link = m.link {
                s.addAttribute(.link, value: link, range: r)
                s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                if let linkColor { s.addAttribute(.foregroundColor, value: linkColor, range: r) }
            }
        }
        return s
    }

    public func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraphStyle, .foregroundColor: color, .baselineOffset: baselineOffset,
        ]
        if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
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
    }

    private var cache: [Key: CGSize] = [:]
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init() {}

    func clearCache() { cache.removeAll() }

    /// Size of the text block (not including padding).
    public func textSize(_ text: String, style: NodeTextStyle, marks: [TextMark] = []) -> CGSize {
        let key = Key(text: text, style: style, marks: marks)
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

    /// Uses AppKit string drawing (TextKit), the same engine that draws node text and
    /// backs the editor.
    static func measure(_ text: String, style: NodeTextStyle, marks: [TextMark] = []) -> CGSize {
        let string = text.isEmpty ? " " : text
        let attr = style.attributed(string, marks: marks, color: .black)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        // Natural width first, so short titles never wrap.
        let natural = attr.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: options)
        let width = min(ceil(natural.width), style.maxWidth)
        func fit(_ w: CGFloat) -> (CGRect, CGFloat) {
            let r = attr.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: options)
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
