import CoreGraphics
import CoreText
import Foundation
import NexusTheme

/// A typeset formula (M48): MathJax's glyphs and rules as shapes, in ems, y down, with the
/// baseline at y = 0, so it draws at any size in any colour. Exporters write the same
/// shapes, which is why a formula is the same vector everywhere.
public struct MathGlyphs: Sendable, Hashable {
    /// One filled or stroked shape. Its path is never mutated once made, so sharing it
    /// across threads is safe.
    public struct Piece: @unchecked Sendable, Hashable {
        public var path: CGPath
        /// A colour the formula sets itself (`\color`, `\colorbox`); nil draws in the text's.
        public var color: RGBA?
        /// The line width in ems for a stroked shape (rules drawn as outlines), nil to fill.
        public var stroke: Double?

        public init(path: CGPath, color: RGBA? = nil, stroke: Double? = nil) {
            self.path = path
            self.color = color
            self.stroke = stroke
        }
    }

    public var pieces: [Piece]
    /// Advance width, in ems.
    public var width: Double
    /// Height above the baseline, in ems.
    public var ascent: Double
    /// Depth below the baseline, in ems.
    public var depth: Double

    public init(pieces: [Piece], width: Double, ascent: Double, depth: Double) {
        self.pieces = pieces
        self.width = width
        self.ascent = ascent
        self.depth = depth
    }

    /// The size at `fontSize` points.
    public func size(_ fontSize: CGFloat) -> CGSize {
        CGSize(width: width * fontSize, height: (ascent + depth) * fontSize)
    }

    /// Draws the formula with its baseline's left end at `origin`. In a flipped context
    /// (y down) the shapes draw as stored; otherwise they're mirrored to y up.
    public func draw(in ctx: CGContext, at origin: CGPoint, fontSize: CGFloat, color: CGColor, flipped: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: fontSize, y: flipped ? fontSize : -fontSize)
        for p in pieces {
            let c = p.color?.cgColor ?? color
            ctx.addPath(p.path)
            if let w = p.stroke {
                ctx.setStrokeColor(c)
                ctx.setLineWidth(w)
                ctx.strokePath()
            } else {
                ctx.setFillColor(c)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    /// The formula as a standalone SVG document in points at `fontSize`, every shape a path
    /// (the goldens, Word's vector images).
    public func svg(fontSize: CGFloat, color: RGBA) -> String {
        let s = size(fontSize)
        var out =
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Self.n(s.width))\" height=\"\(Self.n(s.height))\" viewBox=\"0 0 \(Self.n(s.width)) \(Self.n(s.height))\">"
        let t = CGAffineTransform(translationX: 0, y: ascent * fontSize).scaledBy(x: fontSize, y: fontSize)
        for p in pieces { out += Self.element(p, transform: t, color: color) }
        return out + "</svg>"
    }

    /// One shape as an SVG `<path>`, placed by `transform` (from ems, y down, to the page).
    public static func element(_ p: Piece, transform t: CGAffineTransform, color: RGBA) -> String {
        var transform = t
        let d = Self.d(p.path.copy(using: &transform) ?? p.path)
        let c = Self.hex(p.color ?? color)
        let alpha = (p.color ?? color).a
        let opacity = alpha < 1 ? " \(p.stroke == nil ? "fill" : "stroke")-opacity=\"\(n(alpha))\"" : ""
        if let w = p.stroke {
            let scale = (abs(t.a) + abs(t.d)) / 2
            return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(c)\" stroke-width=\"\(n(w * scale))\"\(opacity)/>"
        }
        return "<path d=\"\(d)\" fill=\"\(c)\"\(opacity)/>"
    }

    /// Path data with two decimals, in absolute commands.
    public static func d(_ path: CGPath) -> String {
        var s = ""
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: s += "M\(n(p[0].x)) \(n(p[0].y))"
            case .addLineToPoint: s += "L\(n(p[0].x)) \(n(p[0].y))"
            case .addQuadCurveToPoint: s += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
            case .addCurveToPoint:
                s += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
            case .closeSubpath: s += "Z"
            @unknown default: break
            }
        }
        return s
    }

    /// A number with at most two decimals and no trailing zeros ("-0" is "0").
    static func n(_ v: CGFloat) -> String { n(Double(v)) }

    static func n(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == 0 { return "0" }
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func hex(_ c: RGBA) -> String {
        func h(_ v: Double) -> String {
            let i = max(0, min(255, Int((v * 255).rounded())))
            return String(i, radix: 16).leftPadded(to: 2)
        }
        return "#" + h(c.r) + h(c.g) + h(c.b)
    }
}

extension String {
    fileprivate func leftPadded(to n: Int) -> String {
        count >= n ? self : String(repeating: "0", count: n - count) + self
    }
}
