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

/// The point on a topic's edge where its branch lines leave it, and which edge it's on.
public struct BranchJunction: Sendable, Equatable {
    public enum Edge: Sendable { case left, right, top, bottom }

    public var point: CGPoint
    public var edge: Edge
    /// The line's first heading, as a unit vector, when it leaves at a slant (a fishbone
    /// sub-cause's small bone, D268): the fold control moves out along it rather than
    /// straight out of the edge, so it stays on the line.
    public var slant: CGVector?

    public init(_ point: CGPoint, _ edge: Edge, slant: CGVector? = nil) {
        self.point = point
        self.edge = edge
        self.slant = slant
    }
}

public enum BranchLines {
    /// Horizontal run per unit of height along a fishbone bone (matches the layout).
    public static let fishboneSlope: CGFloat = 0.5
    /// Where a sub-cause's small bone leaves its parent's rib, in from the parent's end
    /// nearest the bone (matches the layout, D268).
    static let fishboneRibInset: CGFloat = StructureLayouts.ribInset

    /// How far a fishbone topic's end nearest its bone sits from it, at its rib (D269).
    static func fishboneOffset(_ height: CGFloat) -> CGFloat { StructureLayouts.boneOffset(height) }

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
            // A sub-cause's own rib (D268): a small bone leaves the parent's rib under it,
            // `fishboneRibInset` in from its end nearest the bone, and runs parallel to the
            // main bone to the sub-cause's rib, which runs under it to its far end. The
            // layout sets the sub-cause `fishboneOffset` back from the small bone.
            let lean: CGFloat = child.side == .left ? 1 : -1
            let start = CGPoint(x: (lean > 0 ? pr.maxX : pr.minX) - lean * fishboneRibInset, y: pr.maxY - 2)
            let y = cr.maxY - 2
            p.move(to: start)
            p.addLine(to: CGPoint(x: (lean > 0 ? cr.maxX : cr.minX) + lean * fishboneOffset(child.size.height), y: y))
            p.addLine(to: CGPoint(x: lean > 0 ? cr.minX : cr.maxX, y: y))
            return p
        case "timeline", "timelineAlt":
            // The axis: siblings sit on one line, so segments join behind the events.
            let right = child.center.x >= parent.center.x
            p.move(to: CGPoint(x: right ? pr.maxX : pr.minX, y: parent.center.y))
            p.addLine(to: CGPoint(x: right ? cr.minX : cr.maxX, y: child.center.y))
            return p
        case "timelineUp", "timelineDown":
            // A stem from the event's centre, up or down past the axis, then across to the
            // topic beside it (D248).
            let up = family == "timelineUp"
            p.move(to: CGPoint(x: parent.center.x, y: up ? pr.minY : pr.maxY))
            p.addLine(to: CGPoint(x: parent.center.x, y: child.center.y))
            p.addLine(to: CGPoint(x: child.side == .left ? cr.maxX : cr.minX, y: child.center.y))
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

    /// Where a topic's branch lines leave it, for its fold control and "+N" badge (D250):
    /// the start of `path` to `child`, its first visible child. A folded topic has none, so
    /// its family says where the line would start. `parent` is the topic's own parent,
    /// which says which end of a fishbone bone its label is at.
    public static func junction(
        of frame: NodeFrame, family: String, child: NodeFrame?, parent: NodeFrame?, baseline: Bool = false
    ) -> BranchJunction {
        let r = frame.rect
        let c = frame.center
        switch family {
        case "fishboneCause":
            // Causes' ribs meet the bone, which leaves the label at its end nearest the spine.
            let topBone = parent.map { c.y < $0.center.y } ?? true
            return topBone
                ? BranchJunction(CGPoint(x: c.x, y: r.maxY), .bottom) : BranchJunction(CGPoint(x: c.x, y: r.minY), .top)
        case "none", "brace", "matrix", "treeTable":
            // No line per child: on the topic's branch side, as the badge always was (D215).
            return sideJunction(frame)
        default:
            break
        }
        if let child {
            let line = path(from: frame, to: child, family: family, parentBaseline: baseline)
            if let start = firstPoint(line) {
                let edge: BranchJunction.Edge =
                    start.x >= r.maxX - 0.5
                    ? .right : start.x <= r.minX + 0.5 ? .left : start.y <= c.y ? .top : .bottom
                return BranchJunction(start, edge, slant: firstSlant(line))
            }
        }
        let left = frame.side == .left
        switch family {
        case "indent":
            return BranchJunction(CGPoint(x: left ? r.maxX - 10 : r.minX + 10, y: r.maxY), .bottom)
        case "fishboneSub":
            return BranchJunction(CGPoint(x: left ? r.maxX - 4 : r.minX + 4, y: r.maxY), .bottom)
        case "timelineUp":
            return BranchJunction(CGPoint(x: c.x, y: r.minY), .top)
        case "timelineDown", "timelineV", "org", "tree":
            return BranchJunction(CGPoint(x: c.x, y: r.maxY), .bottom)
        case "logic", "mindmap", "timeline", "timelineAlt", "fishbone":
            let y = baseline ? r.maxY : c.y
            return left
                ? BranchJunction(CGPoint(x: r.minX, y: y), .left) : BranchJunction(CGPoint(x: r.maxX, y: y), .right)
        default:
            return sideJunction(frame)
        }
    }

    /// The middle of the topic's edge on its branch side.
    private static func sideJunction(_ frame: NodeFrame) -> BranchJunction {
        let r = frame.rect
        return switch frame.side {
        case .left: BranchJunction(CGPoint(x: r.minX, y: r.midY), .left)
        case .down: BranchJunction(CGPoint(x: r.midX, y: r.maxY), .bottom)
        case .right: BranchJunction(CGPoint(x: r.maxX, y: r.midY), .right)
        }
    }

    /// The first segment's heading when it's a straight line neither horizontal nor
    /// vertical; nil otherwise (curves and square lines leave along the edge's normal).
    private static func firstSlant(_ path: CGPath) -> CGVector? {
        var points: [CGPoint] = []
        var straight = false
        path.applyWithBlock { el in
            guard points.count < 2 else { return }
            switch el.pointee.type {
            case .moveToPoint: points = [el.pointee.points[0]]
            case .addLineToPoint:
                if points.count == 1 {
                    points.append(el.pointee.points[0])
                    straight = true
                }
            default: if points.count == 1 { points.append(points[0]) }
            }
        }
        guard straight, points.count == 2 else { return nil }
        let dx = points[1].x - points[0].x
        let dy = points[1].y - points[0].y
        let len = hypot(dx, dy)
        guard len > 0.5, abs(dx) > 0.5, abs(dy) > 0.5 else { return nil }
        return CGVector(dx: dx / len, dy: dy / len)
    }

    private static func firstPoint(_ path: CGPath) -> CGPoint? {
        var out: CGPoint?
        path.applyWithBlock { el in
            if out == nil, el.pointee.type == .moveToPoint { out = el.pointee.points[0] }
        }
        return out
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
