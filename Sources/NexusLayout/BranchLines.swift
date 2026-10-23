import CoreGraphics
import Foundation

/// Geometry of the parent-to-child connector the layout draws.
public enum BranchLineShape: String, Sendable, CaseIterable {
    case curved, straight, elbow, roundedElbow, zigzag

    /// Maps style names (FMT-1: curved, straight, elbow, rounded, tapered, zigzag).
    public init(name: String) {
        switch name {
        case "straight": self = .straight
        case "elbow": self = .elbow
        case "rounded": self = .roundedElbow
        case "zigzag": self = .zigzag
        default: self = .curved
        }
    }
}

public enum BranchLines {
    /// Horizontal run per unit of height along a fishbone bone (matches the layout).
    public static let fishboneSlope: CGFloat = 0.5

    /// The connector from a parent to one child, in canvas coordinates.
    /// Underline-style nodes attach lines to their baseline (`parentBaseline`,
    /// `childBaseline`), and the line runs on under the child's text.
    public static func path(
        from parent: NodeFrame, to child: NodeFrame, family: String, shape: BranchLineShape = .curved,
        parentBaseline: Bool = false, childBaseline: Bool = false
    ) -> CGPath {
        let p = CGMutablePath()
        let pr = parent.rect
        let cr = child.rect
        switch family {
        case "none", "brace", "matrix", "treeTable":
            // Drawn by the structure (cells, braces) instead of per-child lines.
            return p
        case "indent":
            // └ from under the parent's leading edge to the child's leading edge.
            let left = child.side != .left
            let x = left ? min(pr.minX + 10, cr.minX - 6) : max(pr.maxX - 10, cr.maxX + 6)
            p.move(to: CGPoint(x: x, y: pr.maxY))
            p.addLine(to: CGPoint(x: x, y: child.center.y))
            p.addLine(to: CGPoint(x: left ? cr.minX : cr.maxX, y: child.center.y))
            return p
        case "fishboneSub":
            // └ like "indent", but beside the sub-causes, which may sit further from the
            // bone than the cause does, so the line never crosses the bone.
            let x =
                child.side == .left
                ? max(pr.minX + 4, min(pr.maxX - 4, cr.maxX + 6)) : min(pr.maxX - 4, max(pr.minX + 4, cr.minX - 6))
            p.move(to: CGPoint(x: x, y: pr.maxY))
            p.addLine(to: CGPoint(x: x, y: child.center.y))
            p.addLine(to: CGPoint(x: child.side == .left ? cr.maxX : cr.minX, y: child.center.y))
            return p
        case "timeline":
            // The axis: siblings sit on one line, so segments join behind the events.
            let right = child.center.x >= parent.center.x
            p.move(to: CGPoint(x: right ? pr.maxX : pr.minX, y: parent.center.y))
            p.addLine(to: CGPoint(x: right ? cr.minX : cr.maxX, y: child.center.y))
            return p
        case "timelineV":
            p.move(to: CGPoint(x: parent.center.x, y: pr.maxY))
            p.addLine(to: CGPoint(x: child.center.x, y: cr.minY))
            return p
        case "fishbone":
            // Spine from the head to the bone's foot, then the bone up (or down) to its label.
            let bodyLeft = child.side == .left
            let lean: CGFloat = bodyLeft ? 1 : -1
            let topBone = child.center.y < parent.center.y
            let reach = abs(child.center.y - parent.center.y) - child.size.height / 2
            let foot = CGPoint(x: child.center.x + lean * reach * fishboneSlope, y: parent.center.y)
            p.move(to: CGPoint(x: bodyLeft ? pr.minX : pr.maxX, y: parent.center.y))
            p.addLine(to: foot)
            p.addLine(to: CGPoint(x: child.center.x, y: topBone ? cr.maxY : cr.minY))
            return p
        case "fishboneCause":
            // A rib from the cause to its bone at the cause's height.
            let lean: CGFloat = child.side == .left ? 1 : -1
            let y = cr.maxY - 2
            let below = child.center.y > parent.center.y
            let along = below ? y - pr.maxY : pr.minY - y
            let boneX = parent.center.x + lean * along * fishboneSlope
            p.move(to: CGPoint(x: lean > 0 ? cr.minX : cr.maxX, y: y))
            p.addLine(to: CGPoint(x: boneX, y: y))
            return p
        default:
            break
        }
        if child.side == .down {
            let start = CGPoint(x: parent.center.x, y: parent.center.y + parent.size.height / 2)
            let end = CGPoint(x: child.center.x, y: child.center.y - child.size.height / 2)
            // Org charts read as reporting lines: a curved default becomes a bus.
            vertical(p, start, end, shape: family == "org" && shape == .curved ? .elbow : shape)
            return p
        }
        let dir = CGFloat(child.side.rawValue)
        let start = CGPoint(
            x: parent.center.x + dir * parent.size.width / 2,
            y: parentBaseline ? parent.center.y + parent.size.height / 2 : parent.center.y)
        let end = CGPoint(
            x: child.center.x - dir * child.size.width / 2,
            y: childBaseline ? child.center.y + child.size.height / 2 : child.center.y)
        horizontal(p, start, end, shape: shape)
        if childBaseline {
            p.addLine(to: CGPoint(x: child.center.x + dir * child.size.width / 2, y: end.y))
        }
        return p
    }

    private static func vertical(_ p: CGMutablePath, _ start: CGPoint, _ end: CGPoint, shape: BranchLineShape) {
        let midY = (start.y + end.y) / 2
        p.move(to: start)
        switch shape {
        case .straight, .zigzag:
            p.addLine(to: end)
        case .curved:
            p.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
        case .elbow:
            p.addLine(to: CGPoint(x: start.x, y: midY))
            p.addLine(to: CGPoint(x: end.x, y: midY))
            p.addLine(to: end)
        case .roundedElbow:
            let r = min(8, abs(end.x - start.x) / 2, abs(midY - start.y))
            let dir: CGFloat = end.x >= start.x ? 1 : -1
            p.addLine(to: CGPoint(x: start.x, y: midY - r))
            if r > 0.5 {
                p.addQuadCurve(to: CGPoint(x: start.x + dir * r, y: midY), control: CGPoint(x: start.x, y: midY))
                p.addLine(to: CGPoint(x: end.x - dir * r, y: midY))
                p.addQuadCurve(to: CGPoint(x: end.x, y: midY + r), control: CGPoint(x: end.x, y: midY))
            } else {
                p.addLine(to: CGPoint(x: end.x, y: midY))
            }
            p.addLine(to: end)
        }
    }

    private static func horizontal(_ p: CGMutablePath, _ start: CGPoint, _ end: CGPoint, shape: BranchLineShape) {
        let midX = (start.x + end.x) / 2
        let dir: CGFloat = end.x >= start.x ? 1 : -1
        p.move(to: start)
        switch shape {
        case .straight:
            p.addLine(to: end)
        case .zigzag:
            let n = 4
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                let x = start.x + (end.x - start.x) * t
                let y = start.y + (end.y - start.y) * t + (i < n ? (i % 2 == 0 ? -4 : 4) : 0)
                p.addLine(to: CGPoint(x: x, y: y))
            }
        case .curved:
            p.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
        case .elbow:
            p.addLine(to: CGPoint(x: midX, y: start.y))
            p.addLine(to: CGPoint(x: midX, y: end.y))
            p.addLine(to: end)
        case .roundedElbow:
            let r = min(8, abs(end.y - start.y) / 2, abs(midX - start.x))
            let vdir: CGFloat = end.y >= start.y ? 1 : -1
            p.addLine(to: CGPoint(x: midX - dir * r, y: start.y))
            if r > 0.5 {
                p.addQuadCurve(to: CGPoint(x: midX, y: start.y + vdir * r), control: CGPoint(x: midX, y: start.y))
                p.addLine(to: CGPoint(x: midX, y: end.y - vdir * r))
                p.addQuadCurve(to: CGPoint(x: midX + dir * r, y: end.y), control: CGPoint(x: midX, y: end.y))
            } else {
                p.addLine(to: CGPoint(x: midX, y: end.y))
            }
            p.addLine(to: end)
        }
    }

    /// A filled outline that narrows from `startWidth` to `endWidth` along `path`
    /// (tapered branch lines).
    public static func tapered(_ path: CGPath, startWidth: CGFloat, endWidth: CGFloat) -> CGPath {
        var pts: [CGPoint] = []
        var cur = CGPoint.zero
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint:
                cur = e.points[0]
                pts.append(cur)
            case .addQuadCurveToPoint:
                let c = e.points[0]
                let to = e.points[1]
                for i in 1...8 {
                    let t = CGFloat(i) / 8
                    let a = (1 - t) * (1 - t)
                    let b = 2 * (1 - t) * t
                    pts.append(CGPoint(x: a * cur.x + b * c.x + t * t * to.x, y: a * cur.y + b * c.y + t * t * to.y))
                }
                cur = to
            case .addCurveToPoint:
                let c1 = e.points[0]
                let c2 = e.points[1]
                let to = e.points[2]
                for i in 1...12 {
                    let t = CGFloat(i) / 12
                    let u = 1 - t
                    let x = u * u * u * cur.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * to.x
                    let y = u * u * u * cur.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * to.y
                    pts.append(CGPoint(x: x, y: y))
                }
                cur = to
            default: break
            }
        }
        guard pts.count >= 2 else { return path }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for (i, p) in pts.enumerated() {
            let a = pts[max(0, i - 1)]
            let b = pts[min(pts.count - 1, i + 1)]
            var nx = -(b.y - a.y)
            var ny = b.x - a.x
            let len = max(hypot(nx, ny), 0.0001)
            nx /= len
            ny /= len
            let t = CGFloat(i) / CGFloat(pts.count - 1)
            let w = (startWidth + (endWidth - startWidth) * t) / 2
            left.append(CGPoint(x: p.x + nx * w, y: p.y + ny * w))
            right.append(CGPoint(x: p.x - nx * w, y: p.y - ny * w))
        }
        let out = CGMutablePath()
        out.addLines(between: left + right.reversed())
        out.closeSubpath()
        return out
    }

    /// Stroke width by depth (P0): main branches 3, second level 2, deeper 1.6.
    public static func width(forChildDepth depth: Int, family: String) -> CGFloat {
        if family == "org" || family == "tree" { return 2 }
        switch depth {
        case ...1: return 3
        case 2: return 2
        default: return 1.6
        }
    }
}
