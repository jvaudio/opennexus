import CoreGraphics
import Foundation

/// Paths filled and stroked the way AppKit's `NSBezierPath` draws them, so drawing moved
/// off AppKit keeps its pixels: the same curves (ovals start at -45°, rounded corners use
/// AppKit's 0.55228), and the same flatness (0.6; CoreGraphics' own default flattens
/// curves differently). Arcs, lines and rects need nothing special: `CGPath`'s match.
public enum Shapes {
    /// `NSBezierPath.defaultFlatness`.
    public static let flatness: CGFloat = 0.6

    /// `NSBezierPath(ovalIn:)`.
    public static func oval(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY)
        let rx = r.width / 2
        let ry = r.height / 2
        let k = 4.0 / 3.0 * tan(Double.pi / 8)
        func at(_ a: Double) -> CGPoint { CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a)) }
        for i in 0..<4 {
            let a0 = (-45.0 + 90 * Double(i)) * .pi / 180
            let a1 = a0 + .pi / 2
            let p0 = at(a0)
            let p1 = at(a1)
            if i == 0 { p.move(to: p0) }
            p.addCurve(
                to: p1, control1: CGPoint(x: p0.x - k * rx * sin(a0), y: p0.y + k * ry * cos(a0)),
                control2: CGPoint(x: p1.x + k * rx * sin(a1), y: p1.y - k * ry * cos(a1)))
        }
        p.closeSubpath()
        return p
    }

    /// `NSBezierPath(roundedRect:xRadius:yRadius:)`: radii clamp to half the sides.
    public static func roundedRect(_ r: CGRect, xRadius: CGFloat, yRadius: CGFloat) -> CGPath {
        let rx = min(xRadius, r.width / 2)
        let ry = min(yRadius, r.height / 2)
        guard rx > 0, ry > 0 else { return CGPath(rect: r, transform: nil) }
        let k: CGFloat = 0.55228
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + rx, y: r.maxY))
        p.addCurve(
            to: CGPoint(x: r.minX, y: r.maxY - ry), control1: CGPoint(x: r.minX + rx - k * rx, y: r.maxY),
            control2: CGPoint(x: r.minX, y: r.maxY - ry + k * ry))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + ry))
        p.addCurve(
            to: CGPoint(x: r.minX + rx, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + ry - k * ry),
            control2: CGPoint(x: r.minX + rx - k * rx, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rx, y: r.minY))
        p.addCurve(
            to: CGPoint(x: r.maxX, y: r.minY + ry), control1: CGPoint(x: r.maxX - rx + k * rx, y: r.minY),
            control2: CGPoint(x: r.maxX, y: r.minY + ry - k * ry))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - ry))
        p.addCurve(
            to: CGPoint(x: r.maxX - rx, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - ry + k * ry),
            control2: CGPoint(x: r.maxX - rx + k * rx, y: r.maxY))
        p.closeSubpath()
        return p
    }

    /// `NSBezierPath(roundedRect:xRadius:yRadius:)` with equal radii.
    public static func roundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
        roundedRect(r, xRadius: radius, yRadius: radius)
    }

    /// `color.setFill(); path.fill()`.
    public static func fill(_ path: CGPath, _ color: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFlatness(flatness)
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// `NSBezierPath(rect:).fill()` (not `CGContext.fill(_:)`, which rounds differently
    /// at fractional pixels).
    public static func fill(_ rect: CGRect, _ color: CGColor, in ctx: CGContext) {
        fill(CGPath(rect: rect, transform: nil), color, in: ctx)
    }

    /// `color.setFill(); rect.fill()` (`NSRectFill`), which is `CGContext.fill(_:)`.
    public static func fillRect(_ rect: CGRect, _ color: CGColor, in ctx: CGContext) {
        ctx.setFillColor(color)
        ctx.fill(rect)
    }

    /// `path.addClip()`.
    public static func clip(to path: CGPath, in ctx: CGContext) {
        ctx.setFlatness(flatness)
        ctx.addPath(path)
        ctx.clip()
    }

    /// `color.setStroke(); path.stroke()` with the path's line width, cap and join.
    public static func stroke(
        _ path: CGPath, _ color: CGColor, width: CGFloat = 1, cap: CGLineCap = .butt, join: CGLineJoin = .miter,
        dash: [CGFloat] = [], in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.setFlatness(flatness)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineJoin(join)
        ctx.setMiterLimit(10)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Line segments from point to point, as one path (`move`/`line` pairs).
    public static func segments(_ pairs: [(CGPoint, CGPoint)]) -> CGPath {
        let p = CGMutablePath()
        for (a, b) in pairs {
            p.move(to: a)
            p.addLine(to: b)
        }
        return p
    }
}

extension CGColor {
    /// `NSColor(white:alpha:)` (and `NSColor.gray`, `.white`, `.black`), in Generic Gray
    /// Gamma 2.2. `CGColor(gray:alpha:)` is Generic Gray (gamma 1.8): its mid greys come
    /// out lighter (0.5 draws as 146, not 128).
    public static func calibratedWhite(_ white: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: grayGamma22, components: [white, alpha])!
    }

    private static let grayGamma22 = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
}
