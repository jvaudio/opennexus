import CoreGraphics
import CoreText
import Foundation
import NexusCore
import NexusScene
import NexusTheme

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The typeset form of the topic being edited, on a card beneath the editor (M48): the
/// editor always shows source, so this is where a formula shows as you type, and where
/// MathJax's message shows when it can't be typeset.
public struct MathPreview: Equatable {
    public var text: StyledText
    /// The topic's wrapping width, when the preview wraps as the topic will.
    public var wrap: CGFloat?
    public var error: String?
    public var fill: RGBA
    public var border: RGBA
    public var errorColor: RGBA

    public static func == (a: Self, b: Self) -> Bool {
        a.text.isEqual(to: b.text) && a.wrap == b.wrap && a.error == b.error && a.fill == b.fill
            && a.border == b.border && a.errorColor == b.errorColor
    }

    static let pad: CGFloat = 8
    static var messageFont: CTFont { Fonts.system(11) }

    var message: StyledText? {
        error.map { StyledText($0, TextAttributes(font: Self.messageFont, color: .fixed(errorColor.cgColor))) }
    }

    /// The card's size in view points at `zoom`.
    public func size(zoom: CGFloat) -> CGSize {
        let t = MathLayout(text, width: wrap).size
        let m = message?.lineSize ?? .zero
        return CGSize(
            width: ceil(max(t.width * zoom, m.width) + Self.pad * 2),
            height: ceil(t.height * zoom + (m.height > 0 ? m.height + 4 : 0) + Self.pad * 2))
    }

    /// Draws the card filling `rect` in a context with y down.
    public func draw(in ctx: CGContext, rect: CGRect, zoom: CGFloat) {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setFillColor(fill.cgColor)
        ctx.setStrokeColor(border.cgColor)
        ctx.setLineWidth(1)
        ctx.drawPath(using: .fillStroke)
        let layout = MathLayout(text, width: wrap)
        ctx.translateBy(x: rect.minX + Self.pad, y: rect.minY + Self.pad)
        ctx.scaleBy(x: zoom, y: zoom)
        layout.draw(in: CGRect(origin: .zero, size: layout.size), context: ctx, flipped: true)
        ctx.restoreGState()
        message?.draw(
            at: CGPoint(x: rect.minX + Self.pad, y: rect.minY + Self.pad + layout.size.height * zoom + 4), in: ctx)
    }
}

extension CanvasController {
    /// The preview while a topic holding formulas (or a `/math` topic) is edited; nil
    /// otherwise, and while editing a relationship or other element.
    public func mathPreview() -> MathPreview? {
        guard let e = edit, e.element == nil, let n = scene.nodes[e.node],
            !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var style = n.textStyle
        switch canvas.nodes[e.node]?.textFormat {
        case "math": style.format = "math"
        case nil:
            guard prefs.bool("editing.typesetMath"), !MathMarkup.scan(e.text).formulas.isEmpty else { return nil }
            style.format = nil
            style.typesetsMath = true
        default: return nil
        }
        let theme = scene.theme
        let fill = scene.canvasColor
        let errorColor = theme.formulaErrorColor(on: fill, canvas: fill)
        let text = style.attributed(
            e.text, marks: e.marks, color: .fixed(theme.ink.cgColor), errorColor: .fixed(errorColor.cgColor))
        let wrap = MathLayout(text, width: nil).size.width > style.maxWidth ? CGFloat(style.maxWidth) : nil
        return MathPreview(
            text: text, wrap: wrap, error: MathText.error(in: text), fill: fill, border: theme.ink.alpha(0.18),
            errorColor: errorColor)
    }
}

#if os(macOS)
/// The preview card on the Mac's canvas.
final class MathPreviewView: NSView {
    var preview: MathPreview? {
        didSet { if preview != oldValue { needsDisplay = true } }
    }
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let preview, let ctx = NSGraphicsContext.current?.cgContext else { return }
        preview.draw(in: ctx, rect: bounds, zoom: zoom)
    }
}
#else
/// The preview card on the iPad's and iPhone's canvas.
package final class MathPreviewView: UIView {
    package var preview: MathPreview? {
        didSet {
            guard preview != oldValue else { return }
            setNeedsDisplay()
            accessibilityValue = preview?.error.map { Loc.f("Formula error: %@", $0) }
        }
    }
    package var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { setNeedsDisplay() } }
    }

    package override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = Loc.t("Formula preview")
    }

    package required init?(coder: NSCoder) { fatalError() }

    package override func draw(_ rect: CGRect) {
        guard let preview, let ctx = UIGraphicsGetCurrentContext() else { return }
        preview.draw(in: ctx, rect: bounds, zoom: zoom)
    }
}
#endif
