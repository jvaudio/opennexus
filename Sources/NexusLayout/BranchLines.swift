import CoreGraphics
import Foundation

/// Geometry of the parent-to-child connector the layout draws.
public enum BranchLineShape: String, Sendable, CaseIterable {
    case curved, straight, elbow, roundedElbow
}

public enum BranchLines {
    /// The connector from a parent to one child, in canvas coordinates.
    public static func path(
        from parent: NodeFrame, to child: NodeFrame, family: String,
        shape: BranchLineShape = .curved
    ) -> CGPath {
        let p = CGMutablePath()
        if child.side == .down {
            let start = CGPoint(x: parent.center.x, y: parent.center.y + parent.size.height / 2)
            let end = CGPoint(x: child.center.x, y: child.center.y - child.size.height / 2)
            let midY = (start.y + end.y) / 2
            p.move(to: start)
            switch shape {
            case .straight:
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
            return p
        }

        let dir = CGFloat(child.side.rawValue)
        let start = CGPoint(x: parent.center.x + dir * parent.size.width / 2, y: parent.center.y)
        let end = CGPoint(x: child.center.x - dir * child.size.width / 2, y: child.center.y)
        let midX = (start.x + end.x) / 2
        p.move(to: start)
        switch shape {
        case .straight:
            p.addLine(to: end)
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
        return p
    }

    /// A zero-length path at the parent's connector point, used as the start of the
    /// draw-on animation for a new branch.
    public static func collapsedPath(
        at parent: NodeFrame, toward child: NodeFrame, family: String,
        shape: BranchLineShape = .curved
    ) -> CGPath {
        var c = child
        c.center =
            child.side == .down
            ? CGPoint(x: parent.center.x, y: parent.center.y + parent.size.height / 2)
            : CGPoint(x: parent.center.x + CGFloat(child.side.rawValue) * parent.size.width / 2, y: parent.center.y)
        c.size = .zero
        return path(from: parent, to: c, family: family, shape: shape)
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
