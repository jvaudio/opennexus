import CoreGraphics
import CoreText
import Foundation

/// Text with styles, as a Foundation attributed string whose attributes every engine
/// understands. Fonts are `CTFont`s, colours `CGColor`s or `SystemColor`s, paragraphs
/// `TextParagraph`s; the remaining keys share their names and values with AppKit's,
/// UIKit's and CoreText's (`NSFont`, `NSBaselineOffset`, `NSKern`, `NSUnderline`,
/// `NSStrikethrough`, `NSLink`).
public typealias StyledText = NSAttributedString

public enum TextKey {
    /// A `CTFont`.
    public static let font = NSAttributedString.Key("NSFont")
    /// A `CGColor`, or a `SystemColor`'s raw value as a `String`.
    public static let color = NSAttributedString.Key("OpenNexusColor")
    /// The run's highlight behind the glyphs: a `CGColor`.
    public static let background = NSAttributedString.Key("OpenNexusBackground")
    /// A `TextParagraph`.
    public static let paragraph = NSAttributedString.Key("OpenNexusParagraph")
    /// Points up from the baseline (a number).
    public static let baselineOffset = NSAttributedString.Key("NSBaselineOffset")
    /// Extra space after each glyph (a number).
    public static let kern = NSAttributedString.Key("NSKern")
    /// 1 for a single underline.
    public static let underline = NSAttributedString.Key("NSUnderline")
    /// 1 for a single strikethrough.
    public static let strikethrough = NSAttributedString.Key("NSStrikethrough")
    /// A link (a `String` or `URL`).
    public static let link = NSAttributedString.Key("NSLink")
}

/// A paragraph's alignment, line breaking and fixed line height. A class so attributed
/// strings compare it by value (`isEqual`) and share instances.
public final class TextParagraph: NSObject, Sendable {
    public enum Alignment: Int, Sendable { case left, center, right }
    public enum LineBreak: Int, Sendable { case wordWrap, truncateTail }

    public let alignment: Alignment
    public let lineBreak: LineBreak
    /// Both the minimum and maximum line height, when set.
    public let lineHeight: Double?

    public init(alignment: Alignment = .left, lineBreak: LineBreak = .wordWrap, lineHeight: Double? = nil) {
        self.alignment = alignment
        self.lineBreak = lineBreak
        self.lineHeight = lineHeight
    }

    public static let centered = TextParagraph(alignment: .center)

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? TextParagraph else { return false }
        return o.alignment == alignment && o.lineBreak == lineBreak && o.lineHeight == lineHeight
    }

    public override var hash: Int {
        var h = Hasher()
        h.combine(alignment)
        h.combine(lineBreak)
        h.combine(lineHeight)
        return h.finalize()
    }
}

/// A colour for text: fixed, or a system colour resolved where it's drawn.
public enum TextColorValue: Sendable {
    case fixed(CGColor)
    case system(SystemColor)

    /// The attribute value stored under `TextKey.color`.
    public var attribute: Any {
        switch self {
        case .fixed(let c): c
        case .system(let s): s.rawValue
        }
    }

    /// Reads a `TextKey.color` value back.
    public init?(attribute: Any?) {
        if let s = attribute as? String, let sc = SystemColor(rawValue: s) {
            self = .system(sc)
        } else if let a = attribute, CFGetTypeID(a as CFTypeRef) == CGColor.typeID {
            self = .fixed(a as! CGColor)
        } else {
            return nil
        }
    }

    /// The colour now (system colours through the platform).
    public var cgColor: CGColor {
        switch self {
        case .fixed(let c): c
        case .system(let s): Graphics.platform.color(s)
        }
    }
}

/// Builds attribute dictionaries the way AppKit code wrote them.
public struct TextAttributes {
    public var values: [NSAttributedString.Key: Any] = [:]

    public init(
        font: CTFont, color: TextColorValue? = nil, paragraph: TextParagraph? = nil, baselineOffset: Double? = nil,
        kern: Double? = nil, underline: Bool = false, strikethrough: Bool = false
    ) {
        values[TextKey.font] = font
        if let color { values[TextKey.color] = color.attribute }
        if let paragraph { values[TextKey.paragraph] = paragraph }
        if let baselineOffset { values[TextKey.baselineOffset] = baselineOffset }
        if let kern { values[TextKey.kern] = kern }
        if underline { values[TextKey.underline] = 1 }
        if strikethrough { values[TextKey.strikethrough] = 1 }
    }
}

extension NSAttributedString {
    /// Styled text with one set of attributes.
    public convenience init(_ string: String, _ a: TextAttributes) {
        self.init(string: string, attributes: a.values)
    }

    /// Styled text in one font, otherwise plain.
    public convenience init(_ string: String, font: CTFont) {
        self.init(string: string, attributes: [TextKey.font: font])
    }
}

/// Measuring and drawing styled text through the installed engine; text with typeset
/// formulas goes through `MathLayout` instead (M48).
extension NSAttributedString {
    public func boundingRect(size: CGSize, options: TextOptions) -> CGRect {
        if MathText.contains(self) {
            let wraps = options.contains(.lineFragmentOrigin) && size.width < 1e6
            return CGRect(origin: .zero, size: MathLayout(self, width: wraps ? size.width : nil).size)
        }
        return Graphics.platform.boundingRect(self, size: size, options: options)
    }

    /// The unwrapped size of one line (`size()`).
    public var lineSize: CGSize {
        MathText.contains(self) ? MathLayout(self, width: nil).size : Graphics.platform.size(self)
    }

    public func draw(with rect: CGRect, options: TextOptions, in ctx: CGContext, flipped: Bool = true) {
        if MathText.contains(self) {
            MathLayout(self, width: rect.width).draw(in: rect, context: ctx, flipped: flipped)
            return
        }
        Graphics.platform.draw(self, with: rect, options: options, in: ctx, flipped: flipped)
    }

    public func draw(in rect: CGRect, context ctx: CGContext, flipped: Bool = true) {
        if MathText.contains(self) {
            MathLayout(self, width: rect.width).draw(in: rect, context: ctx, flipped: flipped)
            return
        }
        Graphics.platform.draw(self, in: rect, context: ctx, flipped: flipped)
    }

    public func draw(at point: CGPoint, in ctx: CGContext, flipped: Bool = true) {
        if MathText.contains(self) {
            let l = MathLayout(self, width: nil)
            l.draw(in: CGRect(origin: point, size: l.size), context: ctx, flipped: flipped)
            return
        }
        Graphics.platform.draw(self, at: point, in: ctx, flipped: flipped)
    }
}

extension String {
    /// The unwrapped size of this string in a font, as `size(withAttributes:)` gives it.
    public func size(in font: CTFont) -> CGSize {
        NSAttributedString(self, font: font).lineSize
    }

    /// The unwrapped width of this string in a font, as `size(withAttributes:)` gives it.
    public func width(in font: CTFont) -> CGFloat { size(in: font).width }
}
