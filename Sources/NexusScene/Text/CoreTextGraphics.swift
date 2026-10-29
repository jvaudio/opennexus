import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The engine when no platform one is installed: CoreText for text, sRGB constants for
/// system colours, ImageIO for images. It follows TextKit's string-drawing geometry where
/// that's documented (widths include trailing spaces, clipped to the wrap width; fixed line
/// heights), so sizes mostly agree with the Mac's (95% of the NexusSceneTests corpus).
public struct CoreTextGraphics: PlatformGraphics {
    public static let shared = CoreTextGraphics()
    /// Text with no font is in Helvetica 12, as AppKit's and UIKit's is.
    static var defaultFont: CTFont { CTFontCreateWithName("Helvetica" as CFString, 12, nil) }

    public init() {}

    // MARK: Text

    /// The attributed string in CoreText's own attributes. Keys CoreText shares with
    /// `TextKey` (font, kern, underline) and the ones it ignores pass through.
    func coreText(_ s: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: s)
        let all = NSRange(location: 0, length: s.length)
        s.enumerateAttributes(in: all) { attrs, range, _ in
            var a = attrs
            if a[TextKey.font] == nil { a[TextKey.font] = Self.defaultFont }
            a[TextKey.color] = nil
            a[TextKey.background] = nil
            a[TextKey.paragraph] = nil
            if let c = TextColorValue(attribute: attrs[TextKey.color]) {
                a[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = resolve(c)
            } else {
                a[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true
            }
            if let p = attrs[TextKey.paragraph] as? TextParagraph {
                a[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = Self.paragraph(p)
            }
            if let o = (attrs[TextKey.baselineOffset] as? NSNumber)?.doubleValue, o != 0 {
                a[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = o
            }
            out.setAttributes(a, range: range)
        }
        return out
    }

    public func coreTextString(_ text: NSAttributedString) -> NSAttributedString { coreText(text) }

    /// A text colour, with system colours from this engine (whichever one is installed).
    func resolve(_ c: TextColorValue) -> CGColor {
        switch c {
        case .fixed(let c): c
        case .system(let s): color(s)
        }
    }

    static func paragraph(_ p: TextParagraph) -> CTParagraphStyle {
        var align: CTTextAlignment =
            switch p.alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            }
        var mode: CTLineBreakMode = p.lineBreak == .wordWrap ? .byWordWrapping : .byTruncatingTail
        var lh = CGFloat(p.lineHeight ?? 0)
        return withUnsafeBytes(of: &align) { a in
            withUnsafeBytes(of: &mode) { m in
                withUnsafeBytes(of: &lh) { l in
                    var settings = [
                        CTParagraphStyleSetting(
                            spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                        CTParagraphStyleSetting(
                            spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: m.baseAddress!),
                    ]
                    if p.lineHeight != nil {
                        settings.append(
                            CTParagraphStyleSetting(
                                spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: l.baseAddress!))
                        settings.append(
                            CTParagraphStyleSetting(
                                spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: l.baseAddress!))
                    }
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }

    struct Laid {
        var frame: CTFrame
        var lines: [CTLine]
        var origins: [CGPoint]
        var height: CGFloat
    }

    /// Lines laid out in a column `width` wide, stacked from the top (y up from the
    /// bottom of a tall path, as CoreText reports them).
    func lay(_ s: NSAttributedString, width: CGFloat) -> Laid {
        let fs = CTFramesetterCreateWithAttributedString(coreText(s) as CFAttributedString)
        let tall: CGFloat = 1e7
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: tall), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var height: CGFloat = 0
        if let last = lines.last, let o = origins.last {
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(last, nil, &descent, nil)
            height = tall - o.y + descent
            if let lh = lineHeight(s) { height = CGFloat(lines.count) * lh }
        }
        return Laid(frame: frame, lines: lines, origins: origins, height: height)
    }

    func lineHeight(_ s: NSAttributedString) -> CGFloat? {
        guard s.length > 0, let p = s.attribute(TextKey.paragraph, at: 0, effectiveRange: nil) as? TextParagraph
        else { return nil }
        return p.lineHeight.map { CGFloat($0) }
    }

    /// TextKit's height for one line: the paragraph's fixed line height, else the tallest
    /// run's font line height raised by its baseline offset. Fonts substituted for missing
    /// glyphs (CJK, emoji) don't count, as in TextKit.
    func lineBoxHeight(_ s: NSAttributedString) -> CGFloat {
        if let lh = lineHeight(s) { return lh }
        var h: CGFloat = 0
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { a, _, _ in
            let f = a[TextKey.font].map { $0 as! CTFont } ?? Self.defaultFont
            let offset = max(0, (a[TextKey.baselineOffset] as? NSNumber)?.doubleValue ?? 0)
            h = max(h, Fonts.lineHeight(f) + offset)
        }
        return h
    }

    public func boundingRect(_ text: NSAttributedString, size: CGSize, options: TextOptions) -> CGRect {
        guard options.contains(.lineFragmentOrigin) else {
            let s = self.size(text)
            let line = CTLineCreateWithAttributedString(coreText(text) as CFAttributedString)
            var ascent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, nil, nil)
            return CGRect(x: 0, y: -ascent, width: s.width, height: s.height)
        }
        let width = min(size.width, 1e7)
        let laid = lay(text, width: width)
        var w: CGFloat = 0
        for l in laid.lines { w = max(w, min(CTLineGetTypographicBounds(l, nil, nil, nil), width)) }
        return CGRect(x: 0, y: 0, width: w, height: laid.height)
    }

    public func size(_ text: NSAttributedString) -> CGSize {
        let line = CTLineCreateWithAttributedString(coreText(text) as CFAttributedString)
        return CGSize(width: CTLineGetTypographicBounds(line, nil, nil, nil), height: lineBoxHeight(text))
    }

    public func draw(
        _ text: NSAttributedString, with rect: CGRect, options: TextOptions, in ctx: CGContext, flipped: Bool
    ) {
        let laid = lay(text, width: rect.width)
        let tall: CGFloat = 1e7
        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: -2, dy: -2))
        for (i, line) in laid.lines.enumerated() {
            let top = tall - laid.origins[i].y
            let y = flipped ? rect.minY + top : rect.maxY - top
            if options.contains(.truncatesLastLine), flipped ? y > rect.maxY : y < rect.minY { break }
            drawLine(line, x: rect.minX + laid.origins[i].x, baseline: y, text: text, in: ctx, flipped: flipped)
        }
        ctx.restoreGState()
    }

    public func draw(_ text: NSAttributedString, in rect: CGRect, context ctx: CGContext, flipped: Bool) {
        draw(text, with: rect, options: [.lineFragmentOrigin], in: ctx, flipped: flipped)
    }

    /// `point` is the line box's top-left corner in a flipped context and its bottom-left
    /// in an unflipped one, as in TextKit.
    public func draw(_ text: NSAttributedString, at point: CGPoint, in ctx: CGContext, flipped: Bool) {
        let line = CTLineCreateWithAttributedString(coreText(text) as CFAttributedString)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        let baseline = flipped ? point.y + ascent : point.y + lineBoxHeight(text) - ascent
        drawLine(line, x: point.x, baseline: baseline, text: text, in: ctx, flipped: flipped)
    }

    /// One line at a baseline, with the highlights and strikethroughs CoreText doesn't
    /// draw itself (it draws underlines).
    func drawLine(
        _ line: CTLine, x: CGFloat, baseline: CGFloat, text: NSAttributedString, in ctx: CGContext, flipped: Bool
    ) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baseline)
        if flipped { ctx.scaleBy(x: 1, y: -1) }
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let r = CTRunGetStringRange(run)
            guard r.location < text.length else { continue }
            let attrs = text.attributes(at: r.location, effectiveRange: nil)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let w = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
            var origin = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
            if let bg = attrs[TextKey.background], CFGetTypeID(bg as CFTypeRef) == CGColor.typeID {
                ctx.setFillColor(bg as! CGColor)
                ctx.fill(CGRect(x: origin.x, y: -descent, width: w, height: ascent + descent))
            }
            let color = TextColorValue(attribute: attrs[TextKey.color]).map(resolve) ?? CGColor(gray: 0, alpha: 1)
            let font = (attrs[TextKey.font] as! CTFont?) ?? Self.defaultFont
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(1, CTFontGetUnderlineThickness(font)))
            if (attrs[TextKey.strikethrough] as? Int ?? 0) != 0 {
                let y = CTFontGetXHeight(font) / 2
                ctx.strokeLineSegments(between: [CGPoint(x: origin.x, y: y), CGPoint(x: origin.x + w, y: y)])
            }
        }
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Fonts, colours and images

    public func font(family: String, weight: Int, size: CGFloat) -> CTFont? {
        Fonts.coreTextFamily(family, weight: weight, size: size)
    }

    public func font(_ f: CTFont, adding trait: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(f, 0, nil, trait, trait) ?? f
    }

    public func color(_ c: SystemColor) -> CGColor {
        switch c {
        case .label: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 216.0 / 255)
        case .secondaryLabel: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 127.0 / 255)
        case .accent: CGColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
        case .teal: CGColor(srgbRed: 0.188, green: 0.69, blue: 0.78, alpha: 1)
        case .red: CGColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
        case .gray: CGColor.calibratedWhite(0.5)
        case .white: CGColor(gray: 1, alpha: 1)
        case .clear: CGColor(gray: 0, alpha: 0)
        }
    }

    public func image(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 8192,
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options) ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public func drawPicture(
        size: CGSize, in rect: CGRect, context ctx: CGContext, flipped: Bool,
        _ draw: @escaping (CGContext, CGRect) -> Void
    ) {
        guard size.width > 0, size.height > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: flipped ? rect.maxY : rect.minY)
        ctx.scaleBy(x: rect.width / size.width, y: (flipped ? -1 : 1) * rect.height / size.height)
        draw(ctx, CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
}
