import CoreGraphics
import NexusCore

public enum NavigationDirection: Sendable {
    case up, down, left, right
}

/// Arrow keys move to the nearest node in that direction, so they work in any layout
/// (brief §4). Scoring follows P0: distance along the axis plus 2.2× the cross offset.
public enum SpatialNavigation {
    public static func next(from current: NodeID, direction: NavigationDirection, centers: [NodeID: CGPoint])
        -> NodeID?
    {
        guard let cur = centers[current] else { return nil }
        var best: NodeID?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (id, p) in centers where id != current {
            let dx = p.x - cur.x
            let dy = p.y - cur.y
            let (main, cross): (CGFloat, CGFloat) =
                switch direction {
                case .right: (dx, dy)
                case .left: (-dx, dy)
                case .down: (dy, dx)
                case .up: (-dy, dx)
                }
            guard main > 4 else { continue }
            let score = main + 2.2 * abs(cross)
            // Ties break on id so the result is deterministic.
            if score < bestScore || (score == bestScore && best.map { id < $0 } == true) {
                bestScore = score
                best = id
            }
        }
        return best
    }
}
