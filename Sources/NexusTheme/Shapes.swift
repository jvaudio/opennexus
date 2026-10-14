import CoreGraphics
import Foundation

/// The 32 topic shapes (FMT-1 › Shape). Common shapes are parametric so corners stay
/// true at any size; the rest come from the artboard's 24×16 path data, scaled to the node.
public enum ShapeLibrary {
    public struct Shape: Sendable, Identifiable {
        public var id: String
        public var name: String
        /// Path in a 24×16 box (FMT-1 data); used for the picker and for non-parametric shapes.
        public var icon: String
    }

    public static let all: [Shape] = [
        ("rounded", "Rounded", "M4 1h16a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3H4a3 3 0 0 1-3-3V4a3 3 0 0 1 3-3z"),
        ("rectangle", "Rectangle", "M1 1h22v14H1z"),
        ("pill", "Pill", "M8 1h8a7 7 0 0 1 0 14H8A7 7 0 0 1 8 1z"),
        ("ellipse", "Ellipse", "M12 1a11 7 0 1 0 0 14a11 7 0 1 0 0-14z"),
        ("circle", "Circle", "M12 1a7 7 0 1 0 0 14a7 7 0 1 0 0-14z"),
        ("diamond", "Diamond", "M12 1l11 7-11 7L1 8z"),
        ("parallelogram", "Parallelogram", "M6 1h17l-5 14H1z"),
        ("trapezoid", "Trapezoid", "M5 1h14l4 14H1z"),
        ("hexagon", "Hexagon", "M6 1h12l5 7-5 7H6L1 8z"),
        ("octagon", "Octagon", "M7 1h10l6 4v6l-6 4H7l-6-4V5z"),
        ("triangle", "Triangle", "M12 1l11 14H1z"),
        ("cloud", "Cloud", "M7 15a4 4 0 0 1-1-7.9A5 5 0 0 1 15.5 5 4 4 0 0 1 18 15z"),
        ("document", "Document", "M1 1h22v11c-7-4-15 4-22 0z"),
        ("cylinder", "Cylinder", "M1 4c0-4 22-4 22 0v8c0 4-22 4-22 0z M1 4c0 4 22 4 22 0"),
        ("underline", "Underline", "M1 14h22"),
        ("text", "Text only", "M6 6h12 M6 10h8"),
        ("squircle", "Squircle", "M12 1c9 0 11 2 11 7s-2 7-11 7S1 13 1 8s2-7 11-7z"),
        ("cut-corner", "Cut corner", "M5 1h18v10l-4 4H1V5z"),
        ("double", "Double", "M1 1h22v14H1z M3 3h18v10H3z"),
        ("tag", "Tag", "M1 1h16l6 7-6 7H1z"),
        ("chevron", "Chevron", "M1 1h17l5 7-5 7H1l5-7z"),
        ("arrow", "Arrow", "M1 5h14V1l8 7-8 7v-4H1z"),
        ("star", "Star", "M12 1l3 4.5 5 .5-3.7 3.4 1 5-5.3-2.6L6.7 14.4l1-5L4 6l5-.5z"),
        ("shield", "Shield", "M12 1l10 3v4c0 4-4 6.5-10 7.5C6 14.5 2 12 2 8V4z"),
        ("folder", "Folder", "M1 3h8l2 2h12v10H1z"),
        ("sticky", "Sticky note", "M1 1h22v10l-4 4H1z M19 15v-4h4"),
        ("speech", "Speech", "M3 1h18a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H9l-4 3v-3H3a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2z"),
        ("brackets", "Brackets", "M5 1H2v14h3 M19 1h3v14h-3"),
        ("flag", "Flag", "M2 15V1h16l-3 4 3 4H2"),
        ("card", "Card", "M1 1h20v12H1z M3 15h20V3"),
        ("ring-pill", "Ring pill", "M8 1h8a7 7 0 0 1 0 14H8A7 7 0 0 1 8 1z M8 4h8a4 4 0 0 1 0 8H8a4 4 0 0 1 0-8z"),
        ("hand", "Hand-drawn", "M2 2c6-1 14 1 20 0 1 4-1 8 0 12-6 1-14-1-20 0-1-4 1-8 0-12z"),
    ].map { Shape(id: $0.0, name: $0.1, icon: $0.2) }

    public static func shape(_ id: String) -> Shape? { all.first { $0.id == id } }

    /// Shapes with no fillable outline (text sits on a line or alone).
    public static let openShapes: Set<String> = ["underline", "text", "brackets"]

    /// Extra room a shape needs around the text so it stays inside the outline.
    public static func size(for shape: String, content c: CGSize) -> CGSize {
        switch shape {
        case "diamond": CGSize(width: max(176, c.width * 1.5), height: max(88, c.height * 2))
        case "ellipse": CGSize(width: c.width * 1.22, height: c.height * 1.3)
        case "circle":
            CGSize(width: max(c.width, c.height) * 1.15, height: max(c.width, c.height) * 1.15)
        case "triangle": CGSize(width: c.width * 1.7, height: c.height * 2)
        case "hexagon", "parallelogram", "trapezoid", "tag", "chevron": CGSize(width: c.width + 28, height: c.height)
        case "octagon", "cut-corner": CGSize(width: c.width + 16, height: c.height + 6)
        case "cloud": CGSize(width: c.width * 1.3 + 12, height: c.height * 1.5)
        case "star": CGSize(width: c.width * 1.9, height: c.height * 2.2)
        case "cylinder": CGSize(width: c.width, height: c.height + 14)
        case "arrow": CGSize(width: c.width + 32, height: c.height * 1.4)
        case "shield": CGSize(width: c.width + 12, height: c.height + 16)
        case "speech": CGSize(width: c.width, height: c.height + 10)
        case "document", "folder", "sticky", "card", "flag": CGSize(width: c.width + 8, height: c.height + 8)
        case "double", "ring-pill": CGSize(width: c.width + 8, height: c.height + 6)
        default: c
        }
    }

    /// Vertical offset of the text centre inside the shape (folders, speech bubbles…).
    public static func textOffset(for shape: String, height h: CGFloat) -> CGFloat {
        switch shape {
        case "triangle": h * 0.18
        case "speech": -5
        case "cylinder": 4
        case "folder": 3
        case "document": -3
        case "shield": -4
        default: 0
        }
    }

    /// The outline for a node of `rect`. `radius` applies to rounded shapes.
    public static func path(_ id: String, in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        switch id {
        case "rounded", "squircle", "text", "underline":
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case "rectangle":
            return CGPath(rect: rect, transform: nil)
        case "pill":
            let p = min(rect.width, rect.height) / 2
            return CGPath(roundedRect: rect, cornerWidth: p, cornerHeight: p, transform: nil)
        case "ring-pill":
            let p = min(rect.width, rect.height) / 2
            let m = CGMutablePath()
            m.addRoundedRect(in: rect, cornerWidth: p, cornerHeight: p)
            let inner = rect.insetBy(dx: 4, dy: 4)
            let q = min(inner.width, inner.height) / 2
            m.addRoundedRect(in: inner, cornerWidth: q, cornerHeight: q)
            return m
        case "ellipse", "circle":
            return CGPath(ellipseIn: rect, transform: nil)
        case "double":
            let m = CGMutablePath()
            m.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
            let inner = rect.insetBy(dx: 3.5, dy: 3.5)
            m.addRoundedRect(in: inner, cornerWidth: max(0, r - 3), cornerHeight: max(0, r - 3))
            return m
        case "hand":
            return wobble(
                CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil), seed: 7,
                amplitude: 1.4)
        default:
            guard let s = shape(id), let p = SVGPath.parse(s.icon) else {
                return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            }
            let b = p.boundingBoxOfPath
            var t = CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / max(b.width, 0.001), y: rect.height / max(b.height, 0.001))
                .translatedBy(x: -b.minX, y: -b.minY)
            return p.copy(using: &t) ?? p
        }
    }

    /// A hand-drawn version of a path: points are nudged by a smooth, seeded wobble.
    public static func wobble(_ path: CGPath, seed: UInt64, amplitude: CGFloat) -> CGPath {
        var rng = seed
        func noise() -> CGFloat {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(Double(rng >> 33) / Double(UInt32.max)) * 2 - 1
        }
        let out = CGMutablePath()
        var points: [CGPoint] = []
        var flattened: [CGPoint] = []
        var start = CGPoint.zero
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                start = e.points[0]
                points = [start]
            case .addLineToPoint:
                points.append(e.points[0])
            case .addQuadCurveToPoint:
                points.append(e.points[1])
            case .addCurveToPoint:
                points.append(e.points[2])
            case .closeSubpath:
                points.append(start)
            @unknown default: break
            }
        }
        // Resample edges so the wobble is spread evenly.
        for (a, b) in zip(points, points.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            let n = max(1, Int(d / 14))
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n)
                flattened.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        guard let first = flattened.first else { return path }
        let jitter = flattened.map { CGPoint(x: $0.x + noise() * amplitude, y: $0.y + noise() * amplitude) }
        out.move(to: jitter[0])
        for i in 1..<jitter.count {
            let p0 = jitter[i - 1]
            let p1 = jitter[i]
            out.addQuadCurve(to: CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2), control: p0)
        }
        out.addQuadCurve(to: CGPoint(x: first.x + amplitude * 0.8, y: first.y - amplitude * 0.6), control: jitter.last!)
        return out
    }
}

/// A compact SVG path-data parser (M L H V C S Q T A Z, absolute and relative).
public enum SVGPath {
    public static func parse(_ d: String) -> CGPath? {
        var tokens: [String] = []
        var cur = ""
        func flush() {
            if !cur.isEmpty { tokens.append(cur) }
            cur = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" {
                flush()
                tokens.append(String(ch))
            } else if ch == "," || ch == " " {
                flush()
            } else if ch == "-" {
                if !cur.isEmpty && !cur.hasSuffix("e") { flush() }
                cur.append(ch)
            } else if ch == "." && cur.contains(".") {
                flush()
                cur.append(ch)
            } else {
                cur.append(ch)
            }
        }
        flush()

        let p = CGMutablePath()
        var i = 0
        var cmd: Character = "M"
        var pt = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        func num() -> CGFloat? {
            guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        func flag() -> Bool? {
            guard i < tokens.count else { return nil }
            // Flags may be packed ("0 0 1" or "001"); take one digit.
            let t = tokens[i]
            if t.count > 1, t.allSatisfy({ $0 == "0" || $0 == "1" }) {
                tokens[i] = String(t.dropFirst())
                return t.first == "1"
            }
            i += 1
            return t == "1"
        }
        while i < tokens.count {
            if let c = tokens[i].first, tokens[i].count == 1, c.isLetter {
                cmd = c
                i += 1
                if c == "z" || c == "Z" {
                    p.closeSubpath()
                    pt = start
                    lastControl = nil
                    continue
                }
            }
            let rel = cmd.isLowercase
            let o = rel ? pt : .zero
            switch cmd.uppercased() {
            case "M":
                guard let x = num(), let y = num() else { return p }
                pt = CGPoint(x: o.x + x, y: o.y + y)
                p.move(to: pt)
                start = pt
                cmd = rel ? "l" : "L"
                lastControl = nil
            case "L":
                guard let x = num(), let y = num() else { return p }
                pt = CGPoint(x: o.x + x, y: o.y + y)
                p.addLine(to: pt)
                lastControl = nil
            case "H":
                guard let x = num() else { return p }
                pt = CGPoint(x: (rel ? pt.x : 0) + x, y: pt.y)
                p.addLine(to: pt)
                lastControl = nil
            case "V":
                guard let y = num() else { return p }
                pt = CGPoint(x: pt.x, y: (rel ? pt.y : 0) + y)
                p.addLine(to: pt)
                lastControl = nil
            case "C":
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num()
                else { return p }
                let c2 = CGPoint(x: o.x + x2, y: o.y + y2)
                pt = CGPoint(x: o.x + x, y: o.y + y)
                p.addCurve(to: pt, control1: CGPoint(x: o.x + x1, y: o.y + y1), control2: c2)
                lastControl = c2
            case "S":
                guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return p }
                let c1 = lastControl.map { CGPoint(x: 2 * pt.x - $0.x, y: 2 * pt.y - $0.y) } ?? pt
                let c2 = CGPoint(x: o.x + x2, y: o.y + y2)
                pt = CGPoint(x: o.x + x, y: o.y + y)
                p.addCurve(to: pt, control1: c1, control2: c2)
                lastControl = c2
            case "Q":
                guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { return p }
                let c = CGPoint(x: o.x + x1, y: o.y + y1)
                pt = CGPoint(x: o.x + x, y: o.y + y)
                p.addQuadCurve(to: pt, control: c)
                lastControl = c
            case "A":
                guard let rx = num(), let ry = num(), let rot = num(), let large = flag(), let sweep = flag(),
                    let x = num(), let y = num()
                else { return p }
                let end = CGPoint(x: o.x + x, y: o.y + y)
                addArc(p, from: pt, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                pt = end
                lastControl = nil
            default:
                i += 1
            }
        }
        return p
    }

    /// SVG endpoint arc → centre parameterisation → cubic Béziers (SVG spec F.6).
    static func addArc(
        _ p: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
        rotation: CGFloat, large: Bool, sweep: Bool
    ) {
        guard rx0 != 0, ry0 != 0, p0 != p1 else {
            p.addLine(to: p1)
            return
        }
        var rx = abs(rx0)
        var ry = abs(ry0)
        let phi = rotation * .pi / 180
        let cosP = cos(phi)
        let sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry
        let cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dTheta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4 / 3 * tan(delta / 4)
        var th = theta1
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        for _ in 0..<segments {
            let a = point(th)
            let b = point(th + delta)
            let da = deriv(th)
            let db = deriv(th + delta)
            p.addCurve(
                to: b, control1: CGPoint(x: a.x + t * da.x, y: a.y + t * da.y),
                control2: CGPoint(x: b.x - t * db.x, y: b.y - t * db.y))
            th += delta
        }
    }
}
