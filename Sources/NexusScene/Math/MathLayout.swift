import CoreGraphics
import CoreText
import Foundation

/// Lays out and draws styled text that holds formulas (M48), with CoreText on every
/// platform, so a topic with maths measures and draws the same way wherever it's shown.
/// Each formula's U+FFFC reserves its width, height and depth; a line grows to fit its
/// tallest formula and is never shorter than the paragraph's line height; words are
/// centred in that height as they are in other topics.
public struct MathLayout {
    public struct Line {
        public var line: CTLine
        /// From the layout's left edge, after alignment.
        public var x: CGFloat
        /// The baseline, down from the layout's top.
        public var baseline: CGFloat
        public var width: CGFloat
    }

    /// A formula and the left end of its baseline, from the layout's top-left corner.
    public struct Placed {
        public var run: MathRun
        public var origin: CGPoint
        public var color: TextColorValue?
        public var range: NSRange
    }

    public let text: NSAttributedString
    public private(set) var lines: [Line] = []
    public private(set) var formulas: [Placed] = []
    public private(set) var size: CGSize = .zero

    /// Lays `text` out in a column `width` wide (unwrapped when nil).
    public init(_ text: NSAttributedString, width: CGFloat?) {
        self.text = text
        let ct = Self.coreText(text)
        let ts = CTTypesetterCreateWithAttributedString(ct as CFAttributedString)
        let limit = Double(width ?? 1e7)
        var start = 0
        var y: CGFloat = 0
        var raw: [(CTLine, CFRange, CGFloat, CGFloat, CGFloat)] = []  // line, range, width, ascent, descent
        while start < text.length {
            let count = CTTypesetterSuggestLineBreak(ts, start, limit)
            guard count > 0 else { break }
            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLine(ts, range)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            let (a, d) = Self.metrics(line, text: text, range: range)
            raw.append((line, range, max(0, w), a, d))
            start += count
        }
        let column = width ?? raw.map(\.2).max() ?? 0
        var widest: CGFloat = 0
        for (line, range, w, a, d) in raw {
            let p = text.attribute(TextKey.paragraph, at: range.location, effectiveRange: nil) as? TextParagraph
            let x: CGFloat =
                switch p?.alignment {
                case .center: max(0, (column - w) / 2)
                case .right: max(0, column - w)
                default: 0
                }
            lines.append(Line(line: line, x: x, baseline: y + a, width: w))
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let r = CTRunGetStringRange(run)
                guard r.location < text.length,
                    let m = text.attribute(TextKey.math, at: r.location, effectiveRange: nil) as? MathRun
                else { continue }
                var origin = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
                let color = TextColorValue(
                    attribute: text.attribute(TextKey.color, at: r.location, effectiveRange: nil))
                formulas.append(
                    Placed(
                        run: m, origin: CGPoint(x: x + origin.x, y: y + a), color: color,
                        range: NSRange(location: r.location, length: r.length)))
            }
            y += a + d
            widest = max(widest, w)
        }
        size = CGSize(width: widest, height: y)
    }

    /// The line's ascent and descent: the words centred in the paragraph's line height as
    /// in a topic without maths, made room for every formula in it.
    static func metrics(_ line: CTLine, text: NSAttributedString, range: CFRange) -> (CGFloat, CGFloat) {
        var textAscent: CGFloat = 0
        var textDescent: CGFloat = 0
        var mathAscent: CGFloat = 0
        var mathDescent: CGFloat = 0
        var pad: CGFloat = 0
        var lineHeight: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let r = CTRunGetStringRange(run)
            guard r.location < text.length else { continue }
            let attrs = text.attributes(at: r.location, effectiveRange: nil)
            if let m = attrs[TextKey.math] as? MathRun {
                mathAscent = max(mathAscent, m.ascent)
                mathDescent = max(mathDescent, m.depth)
                pad = max(pad, m.fontSize * 0.08)
                continue
            }
            let f = attrs[TextKey.font].map { $0 as! CTFont } ?? CoreTextGraphics.defaultFont
            let m = Fonts.metrics(f)
            let natural = m.ascender - m.descender + m.leading
            let lh = (attrs[TextKey.paragraph] as? TextParagraph)?.lineHeight.map { CGFloat($0) } ?? natural
            lineHeight = max(lineHeight, lh)
            // Centred in the line box, as `NodeTextStyle.baselineOffset` centres them.
            let a = (lh - (m.ascender - m.descender)) / 2 + m.ascender
            textAscent = max(textAscent, a)
            textDescent = max(textDescent, lh - a)
        }
        if lineHeight == 0, range.location < text.length,
            let p = text.attribute(TextKey.paragraph, at: range.location, effectiveRange: nil) as? TextParagraph,
            let lh = p.lineHeight
        {
            // A line that's only formulas still keeps the paragraph's height.
            textAscent = CGFloat(lh) / 2 + mathAscent / 2 - mathDescent / 2
            textDescent = CGFloat(lh) - textAscent
        }
        return (max(textAscent, mathAscent + pad), max(textDescent, mathDescent + pad))
    }

    /// CoreText's attributes, with a run delegate holding each formula's room. Baseline
    /// offsets are dropped: lines place their words themselves.
    static func coreText(_ s: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: CoreTextGraphics.shared.coreText(s))
        let all = NSRange(location: 0, length: out.length)
        out.removeAttribute(NSAttributedString.Key(kCTBaselineOffsetAttributeName as String), range: all)
        s.enumerateAttribute(TextKey.math, in: all) { v, r, _ in
            guard let m = v as? MathRun else { return }
            out.addAttribute(
                NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: Self.delegate(m), range: r)
            out.addAttribute(
                NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                value: CGColor(gray: 0, alpha: 0), range: r)
        }
        return out
    }

    final class Room {
        let ascent: CGFloat
        let descent: CGFloat
        let width: CGFloat
        init(_ m: MathRun) {
            ascent = m.ascent
            descent = m.depth
            width = m.width
        }
    }

    static func delegate(_ m: MathRun) -> CTRunDelegate {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<Room>.fromOpaque($0).release() },
            getAscent: { Unmanaged<Room>.fromOpaque($0).takeUnretainedValue().ascent },
            getDescent: { Unmanaged<Room>.fromOpaque($0).takeUnretainedValue().descent },
            getWidth: { Unmanaged<Room>.fromOpaque($0).takeUnretainedValue().width })
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(Room(m)).toOpaque())!
    }

    /// Set while a PDF's picture is drawn: formulas leave their room empty, and the PDF
    /// draws them over the picture as paths (main thread).
    nonisolated(unsafe) public static var hidesFormulas = false

    /// Draws the layout with its top-left corner at the rect's (its top in a flipped
    /// context, y down; its bottom-left otherwise).
    public func draw(in rect: CGRect, context ctx: CGContext, flipped: Bool) {
        let column = rect.width
        let shift = max(0, column - size.width)
        for l in lines {
            // Alignment was worked out for the layout's own width; a wider rect centres too.
            let x = rect.minX + l.x + Self.alignmentShift(l, text: text, extra: shift)
            let y = flipped ? rect.minY + l.baseline : rect.maxY - l.baseline
            CoreTextGraphics.shared.drawLine(l.line, x: x, baseline: y, text: text, in: ctx, flipped: flipped)
        }
        guard !Self.hidesFormulas else { return }
        for f in placed(in: rect, flipped: flipped) {
            let c = f.color?.cgColor ?? CGColor(gray: 0, alpha: 1)
            f.run.glyphs.draw(in: ctx, at: f.origin, fontSize: f.run.fontSize, color: c, flipped: flipped)
        }
    }

    /// The formulas with their baselines' left ends in the rect's coordinates.
    public func placed(in rect: CGRect, flipped: Bool) -> [Placed] {
        let shift = max(0, rect.width - size.width)
        var out: [Placed] = []
        var i = 0
        for l in lines {
            let dx = Self.alignmentShift(l, text: text, extra: shift)
            let range = CTLineGetStringRange(l.line)
            while i < formulas.count, formulas[i].range.location < range.location + range.length {
                var f = formulas[i]
                f.origin = CGPoint(
                    x: rect.minX + f.origin.x + dx, y: flipped ? rect.minY + f.origin.y : rect.maxY - f.origin.y)
                out.append(f)
                i += 1
            }
        }
        return out
    }

    public static func alignmentShift(_ l: Line, text: NSAttributedString, extra: CGFloat) -> CGFloat {
        let r = CTLineGetStringRange(l.line)
        guard extra > 0, r.location < text.length else { return 0 }
        switch (text.attribute(TextKey.paragraph, at: r.location, effectiveRange: nil) as? TextParagraph)?.alignment {
        case .center: return extra / 2
        case .right: return extra
        default: return 0
        }
    }
}
