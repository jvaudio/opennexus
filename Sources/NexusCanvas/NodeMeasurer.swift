import AppKit
import NexusTheme

/// Text attributes for a node. The same attributes are used to measure, to draw, and
/// to configure the text editor, so a node never wraps differently from how it was
/// measured (P0's "Team / s" artefact, README §14).
public struct NodeTextStyle: Hashable, Sendable {
    public var fontSize: Double
    public var weight: NodeTypography.Weight
    public var lineHeight: Double
    public var monospaced: Bool
    public var maxWidth: Double

    public init(typography t: NodeTypography, monospaced: Bool) {
        fontSize = t.fontSize
        weight = t.weight
        lineHeight = t.lineHeight
        self.monospaced = monospaced
        maxWidth = t.maxWidth
    }

    public var font: NSFont {
        let w: NSFont.Weight =
            switch weight {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
        return monospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: w)
            : NSFont.systemFont(ofSize: fontSize, weight: w)
    }

    public var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
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
        [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: color, .baselineOffset: baselineOffset]
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
