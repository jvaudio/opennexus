import AppKit
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

    public var font: NSFont {
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
        return f
    }

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
    }

    private var cache: [Key: CGSize] = [:]
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init() {}

    /// Size of the text block (not including padding).
    public func textSize(_ text: String, style: NodeTextStyle) -> CGSize {
        let key = Key(text: text, style: style)
        if let s = cache[key] {
            hits += 1
            return s
        }
        misses += 1
        let s = Self.measure(text, style: style)
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = s
        return s
    }

    /// Uses AppKit string drawing (TextKit), the same engine that draws node text and
    /// backs the editor.
    static func measure(_ text: String, style: NodeTextStyle) -> CGSize {
        let string = text.isEmpty ? " " : text
        let attr = NSAttributedString(string: string, attributes: style.attributes(color: .black))
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        // Natural width first, so short titles never wrap.
        let natural = attr.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: options)
        let width = min(ceil(natural.width), style.maxWidth)
        let fitted = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options)
        let lines = max(1, (fitted.height / style.lineHeight).rounded())
        return CGSize(width: ceil(max(fitted.width, 1)), height: lines * style.lineHeight)
    }
}
