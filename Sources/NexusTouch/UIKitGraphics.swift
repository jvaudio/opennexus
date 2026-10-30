#if os(iOS)
import NexusCore
import NexusScene
import UIKit

/// The iPad's engine for scenes (M47b): UIKit's string drawing (TextKit), the engine that
/// backs the editor, so topics measure and draw as the Mac's do (M47a measured 98.3% the
/// same size; the rest is the fonts themselves); UIKit's dynamic system colours; UIImage
/// decoding.
@objc(OpenNexusPlatformGraphics)
public final class UIKitGraphics: NSObject, PlatformGraphics, PlatformGraphicsProvider, @unchecked Sendable {
    public static let shared = UIKitGraphics()
    public static var platformGraphics: any PlatformGraphics { shared }

    /// Installs UIKit's engine for every scene in this process (idempotent).
    public static func install() {
        if !(Graphics.platform is UIKitGraphics) { Graphics.install(shared) }
    }

    private let lock = NSLock()
    private var paragraphs: [TextParagraph: NSParagraphStyle] = [:]
    private var last: (source: NSAttributedString, converted: NSAttributedString)?

    // MARK: Conversion

    public func paragraph(_ p: TextParagraph) -> NSParagraphStyle {
        lock.withLock {
            if let s = paragraphs[p] { return s }
            let s = NSMutableParagraphStyle()
            s.alignment =
                switch p.alignment {
                case .left: .left
                case .center: .center
                case .right: .right
                }
            s.lineBreakMode = p.lineBreak == .wordWrap ? .byWordWrapping : .byTruncatingTail
            if let lh = p.lineHeight {
                s.minimumLineHeight = lh
                s.maximumLineHeight = lh
            }
            paragraphs[p] = s
            return s
        }
    }

    /// The Mac's system colours in UIKit: the accent is the app's tint.
    public static func uiColor(_ c: SystemColor) -> UIColor {
        switch c {
        case .label: .label
        case .secondaryLabel: .secondaryLabel
        case .accent: .tintColor
        case .teal: .systemTeal
        case .red: .systemRed
        case .gray: .gray
        case .white: .white
        case .clear: .clear
        }
    }

    static func uiColor(attribute a: Any) -> UIColor? {
        switch TextColorValue(attribute: a) {
        case .fixed(let c): UIColor(cgColor: c)
        case .system(let s): uiColor(s)
        case nil: nil
        }
    }

    /// Styled text in UIKit's attributes: colours as UIColor, paragraphs as
    /// NSParagraphStyle; fonts are already UIFonts (CTFont is toll-free bridged).
    public func uiKit(_ s: NSAttributedString) -> NSAttributedString {
        if let last = lock.withLock({ last }), last.source === s { return last.converted }
        let out = NSMutableAttributedString(attributedString: s)
        let all = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(TextKey.color, in: all) { v, r, _ in
            guard let v else { return }
            out.removeAttribute(TextKey.color, range: r)
            if let c = Self.uiColor(attribute: v) { out.addAttribute(.foregroundColor, value: c, range: r) }
        }
        s.enumerateAttribute(TextKey.background, in: all) { v, r, _ in
            guard let v else { return }
            out.removeAttribute(TextKey.background, range: r)
            if let c = Self.uiColor(attribute: v) { out.addAttribute(.backgroundColor, value: c, range: r) }
        }
        s.enumerateAttribute(TextKey.paragraph, in: all) { v, r, _ in
            guard let p = v as? TextParagraph else { return }
            out.removeAttribute(TextKey.paragraph, range: r)
            out.addAttribute(.paragraphStyle, value: paragraph(p), range: r)
        }
        // Only immutable strings are cached by identity: a mutable one may change later.
        if !(s is NSMutableAttributedString) { lock.withLock { last = (s, out) } }
        return out
    }

    static func options(_ o: TextOptions) -> NSStringDrawingOptions {
        var d: NSStringDrawingOptions = []
        if o.contains(.lineFragmentOrigin) { d.insert(.usesLineFragmentOrigin) }
        if o.contains(.fontLeading) { d.insert(.usesFontLeading) }
        if o.contains(.truncatesLastLine) { d.insert(.truncatesLastVisibleLine) }
        return d
    }

    /// Runs drawing with `ctx` as UIKit's current context. UIKit draws with y down: in a
    /// context with y up, `box` is flipped in place first so the text lands in it upright.
    func drawing(_ ctx: CGContext, flipped: Bool, box: CGRect, _ body: () -> Void) {
        ctx.saveGState()
        if !flipped {
            ctx.translateBy(x: 0, y: box.minY + box.maxY)
            ctx.scaleBy(x: 1, y: -1)
        }
        UIGraphicsPushContext(ctx)
        body()
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    // MARK: PlatformGraphics

    public func boundingRect(_ text: NSAttributedString, size: CGSize, options: TextOptions) -> CGRect {
        uiKit(text).boundingRect(with: size, options: Self.options(options), context: nil)
    }

    public func size(_ text: NSAttributedString) -> CGSize { uiKit(text).size() }

    public func draw(
        _ text: NSAttributedString, with rect: CGRect, options: TextOptions, in ctx: CGContext, flipped: Bool
    ) {
        let s = uiKit(text)
        drawing(ctx, flipped: flipped, box: rect) { s.draw(with: rect, options: Self.options(options), context: nil) }
    }

    public func draw(_ text: NSAttributedString, in rect: CGRect, context ctx: CGContext, flipped: Bool) {
        let s = uiKit(text)
        drawing(ctx, flipped: flipped, box: rect) { s.draw(in: rect) }
    }

    public func draw(_ text: NSAttributedString, at point: CGPoint, in ctx: CGContext, flipped: Bool) {
        let s = uiKit(text)
        // With y up the point is the line box's lower left, as AppKit has it.
        let box = CGRect(origin: point, size: s.size())
        drawing(ctx, flipped: flipped, box: box) { s.draw(at: point) }
    }

    public func font(family: String, weight: Int, size: CGFloat) -> CTFont? {
        Fonts.coreTextFamily(family, weight: weight, size: size)
    }

    public func font(_ f: CTFont, adding trait: CTFontSymbolicTraits) -> CTFont {
        let ui = f as UIFont
        let add: UIFontDescriptor.SymbolicTraits = trait.contains(.traitBold) ? .traitBold : .traitItalic
        guard let d = ui.fontDescriptor.withSymbolicTraits(ui.fontDescriptor.symbolicTraits.union(add)) else {
            return f
        }
        return UIFont(descriptor: d, size: ui.pointSize) as CTFont
    }

    public func coreTextString(_ text: NSAttributedString) -> NSAttributedString { uiKit(text) }

    public func color(_ c: SystemColor) -> CGColor {
        Self.uiColor(c).resolvedColor(with: .current).cgColor
    }

    public func image(_ data: Data) -> CGImage? {
        if let i = UIImage(data: data)?.cgImage { return i }
        return CoreTextGraphics.shared.image(data)
    }

    public func drawPicture(
        size: CGSize, in rect: CGRect, context ctx: CGContext, flipped: Bool,
        _ draw: @escaping (CGContext, CGRect) -> Void
    ) {
        // The picture's context has y up, scaled from its own size to the rect.
        ctx.saveGState()
        if flipped {
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: rect.width / max(size.width, 1), y: -rect.height / max(size.height, 1))
        } else {
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: rect.width / max(size.width, 1), y: rect.height / max(size.height, 1))
        }
        draw(ctx, CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
}

/// A topic's text style in UIKit's terms, for the iPad's text editor.
extension NodeTextStyle {
    public var uiFont: UIFont { font as UIFont }
    public var uiParagraphStyle: NSParagraphStyle { UIKitGraphics.shared.paragraph(paragraphStyle) }

    public func uiAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        let s = UIKitGraphics.shared.uiKit(
            NSAttributedString(string: " ", attributes: attributes(color: .fixed(color.cgColor))))
        var a = s.attributes(at: 0, effectiveRange: nil)
        a[.foregroundColor] = color
        return a
    }

    public func uiAttributed(_ text: String, marks: [TextMark], color: UIColor) -> NSAttributedString {
        let s = NSMutableAttributedString(
            attributedString: UIKitGraphics.shared.uiKit(
                attributed(text, marks: marks, color: .fixed(color.cgColor))))
        // The editor's own colour object, so a dynamic colour stays dynamic.
        s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if (v as? UIColor)?.cgColor == color.cgColor {
                s.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
        return s
    }
}
#endif
