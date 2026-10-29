#if os(macOS)
import AppKit
import NexusCore
import NexusScene

/// The Mac's engine for scenes: AppKit's string drawing (TextKit), the same engine that
/// backs the editor, so topics measure and draw exactly as they always have; AppKit's
/// dynamic system colours; NSImage decoding (PDF assets included).
@objc(OpenNexusPlatformGraphics)
public final class AppKitGraphics: NSObject, PlatformGraphics, PlatformGraphicsProvider, @unchecked Sendable {
    public static let shared = AppKitGraphics()
    public static var platformGraphics: any PlatformGraphics { shared }

    /// Installs AppKit's engine for every scene in this process (idempotent).
    public static func install() {
        if !(Graphics.platform is AppKitGraphics) { Graphics.install(shared) }
    }

    private let lock = NSLock()
    private var paragraphs: [TextParagraph: NSParagraphStyle] = [:]
    private var last: (source: NSAttributedString, converted: NSAttributedString)?

    // MARK: Conversion

    func paragraph(_ p: TextParagraph) -> NSParagraphStyle {
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

    static func nsColor(_ c: SystemColor) -> NSColor {
        switch c {
        case .label: .labelColor
        case .secondaryLabel: .secondaryLabelColor
        case .accent: .controlAccentColor
        case .teal: .systemTeal
        case .red: .systemRed
        case .gray: .gray
        case .white: .white
        case .clear: .clear
        }
    }

    static func nsColor(attribute a: Any) -> NSColor? {
        switch TextColorValue(attribute: a) {
        case .fixed(let c): NSColor(cgColor: c)
        case .system(let s): nsColor(s)
        case nil: nil
        }
    }

    /// Styled text in AppKit's attributes: colours as NSColor, paragraphs as
    /// NSParagraphStyle; fonts are already NSFonts (CTFont is toll-free bridged).
    public func appKit(_ s: NSAttributedString) -> NSAttributedString {
        if let last = lock.withLock({ last }), last.source === s { return last.converted }
        let out = NSMutableAttributedString(attributedString: s)
        let all = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(TextKey.color, in: all) { v, r, _ in
            guard let v else { return }
            out.removeAttribute(TextKey.color, range: r)
            if let c = Self.nsColor(attribute: v) { out.addAttribute(.foregroundColor, value: c, range: r) }
        }
        s.enumerateAttribute(TextKey.background, in: all) { v, r, _ in
            guard let v else { return }
            out.removeAttribute(TextKey.background, range: r)
            if let c = Self.nsColor(attribute: v) { out.addAttribute(.backgroundColor, value: c, range: r) }
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

    static func options(_ o: TextOptions) -> NSString.DrawingOptions {
        var d: NSString.DrawingOptions = []
        if o.contains(.lineFragmentOrigin) { d.insert(.usesLineFragmentOrigin) }
        if o.contains(.fontLeading) { d.insert(.usesFontLeading) }
        if o.contains(.truncatesLastLine) { d.insert(.truncatesLastVisibleLine) }
        return d
    }

    /// Runs drawing with `ctx` as AppKit's current context.
    func drawing(_ ctx: CGContext, flipped: Bool, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: flipped)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: PlatformGraphics

    public func boundingRect(_ text: NSAttributedString, size: CGSize, options: TextOptions) -> CGRect {
        appKit(text).boundingRect(with: size, options: Self.options(options))
    }

    public func size(_ text: NSAttributedString) -> CGSize { appKit(text).size() }

    public func draw(
        _ text: NSAttributedString, with rect: CGRect, options: TextOptions, in ctx: CGContext, flipped: Bool
    ) {
        let s = appKit(text)
        drawing(ctx, flipped: flipped) { s.draw(with: rect, options: Self.options(options)) }
    }

    public func draw(_ text: NSAttributedString, in rect: CGRect, context ctx: CGContext, flipped: Bool) {
        let s = appKit(text)
        drawing(ctx, flipped: flipped) { s.draw(in: rect) }
    }

    public func draw(_ text: NSAttributedString, at point: CGPoint, in ctx: CGContext, flipped: Bool) {
        let s = appKit(text)
        drawing(ctx, flipped: flipped) { s.draw(at: point) }
    }

    public func font(family: String, weight: Int, size: CGFloat) -> CTFont? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: weight, size: size)
    }

    public func font(_ f: CTFont, adding trait: CTFontSymbolicTraits) -> CTFont {
        let mask: NSFontTraitMask = trait.contains(.traitBold) ? .boldFontMask : .italicFontMask
        return NSFontManager.shared.convert(f as NSFont, toHaveTrait: mask)
    }

    public func coreTextString(_ text: NSAttributedString) -> NSAttributedString { appKit(text) }

    public func color(_ c: SystemColor) -> CGColor { Self.nsColor(c).cgColor }

    public func image(_ data: Data) -> CGImage? {
        NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    public func drawPicture(
        size: CGSize, in rect: CGRect, context ctx: CGContext, flipped: Bool,
        _ draw: @escaping (CGContext, CGRect) -> Void
    ) {
        let image = NSImage(size: size, flipped: false) { r in
            if let c = NSGraphicsContext.current?.cgContext { draw(c, r) }
            return true
        }
        drawing(ctx, flipped: flipped) { image.draw(in: rect) }
    }
}
/// A topic's text style in AppKit's terms, for the Mac's text editor.
extension NodeTextStyle {
    public var nsFont: NSFont { font as NSFont }
    public var nsParagraphStyle: NSParagraphStyle { AppKitGraphics.shared.paragraph(paragraphStyle) }

    public func nsAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let s = AppKitGraphics.shared.appKit(
            NSAttributedString(string: " ", attributes: attributes(color: .fixed(color.cgColor))))
        var a = s.attributes(at: 0, effectiveRange: nil)
        a[.foregroundColor] = color
        return a
    }

    public func nsAttributed(_ text: String, marks: [TextMark], color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(
            attributedString: AppKitGraphics.shared.appKit(
                attributed(text, marks: marks, color: .fixed(color.cgColor))))
        // The editor's own colour object, so a dynamic colour stays dynamic.
        s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if (v as? NSColor)?.cgColor == color.cgColor {
                s.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
        return s
    }
}
#endif
