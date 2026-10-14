import CoreGraphics
import Foundation
import NexusCore

/// Which way a branch grows from its parent.
public enum Side: Int, Sendable {
    case left = -1
    case down = 0
    case right = 1
}

/// What the layout needs to know about one node: its measured size and its visible children.
public struct LayoutNode: Sendable, Equatable {
    public var size: CGSize
    public var children: [NodeID]
    /// Per-branch structure override (mixed structures, Option-Command-1…9).
    public var structure: LayoutStructure?

    public init(size: CGSize, children: [NodeID], structure: LayoutStructure? = nil) {
        self.size = size
        self.children = children
        self.structure = structure
    }
}

/// Where a node ended up. `center` is in canvas coordinates; the root sits at the origin.
public struct NodeFrame: Sendable, Equatable {
    public var center: CGPoint
    public var size: CGSize
    public var side: Side
    public var depth: Int

    public var rect: CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

public struct LayoutResult: Sendable, Equatable {
    public var frames: [NodeID: NodeFrame] = [:]
    /// The structure family each parent's children were laid out with (for branch-line geometry).
    public var families: [NodeID: String] = [:]

    public var bounds: CGRect {
        frames.values.reduce(CGRect.null) { $0.union($1.rect) }
    }
}

/// Spacing used by the hierarchical layouts. Defaults match the P0 prototype.
public struct LayoutSpacing: Sendable, Equatable {
    /// Gap between main topics (depth ≤ 1) stacked on one side.
    public var mainSiblingGap: CGFloat = 20
    /// Gap between deeper siblings.
    public var subSiblingGap: CGFloat = 10
    /// Gap from the root's edge to main topics.
    public var rootLevelGap: CGFloat = 64
    /// Gap from any other parent's edge to its children.
    public var levelGap: CGFloat = 40
    /// Org / tree charts.
    public var verticalLevelGap: CGFloat = 56
    public var horizontalSiblingGap: CGFloat = 24

    public static let standard = LayoutSpacing()

    public func siblingGap(_ depth: Int) -> CGFloat { depth <= 1 ? mainSiblingGap : subSiblingGap }
    public func levelGap(_ parentDepth: Int) -> CGFloat { parentDepth == 0 ? rootLevelGap : levelGap }
}

/// Pure tree layouts. Given sizes and visible children, returns a frame per node.
public enum TreeLayout {
    public static func layout(
        root: NodeID, nodes: [NodeID: LayoutNode], structure: LayoutStructure,
        origin: CGPoint = .zero, spacing: LayoutSpacing = .standard
    ) -> LayoutResult {
        var result = LayoutResult()
        guard let r = nodes[root] else { return result }
        result.frames[root] = NodeFrame(center: origin, size: r.size, side: .right, depth: 0)
        var engine = Engine(nodes: nodes, spacing: spacing)
        engine.place(root, structure: r.structure ?? structure, depth: 0, into: &result)
        return result
    }

    struct Engine {
        let nodes: [NodeID: LayoutNode]
        let spacing: LayoutSpacing
        /// Extent of each subtree across its growth axis (height for horizontal trees,
        /// width for vertical ones), memoised per family.
        var extent: [NodeID: CGFloat] = [:]

        init(nodes: [NodeID: LayoutNode], spacing: LayoutSpacing) {
            self.nodes = nodes
            self.spacing = spacing
        }

        /// Children of `id` are placed by the parent's effective structure. A child that
        /// overrides the structure lays out its own subtree with it.
        mutating func place(_ id: NodeID, structure: LayoutStructure, depth: Int, into result: inout LayoutResult) {
            guard let node = nodes[id], !node.children.isEmpty, let frame = result.frames[id] else { return }
            let family = structure.family
            result.families[id] = family
            switch structure {
            case .mindmapBalanced where depth == 0:
                let half = (node.children.count + 1) / 2
                let right = Array(node.children.prefix(half))
                let left = Array(node.children.dropFirst(half).reversed())
                placeHorizontal(right, parent: frame, side: .right, depth: depth, into: &result)
                placeHorizontal(left, parent: frame, side: .left, depth: depth, into: &result)
            case .mindmapLeft where depth == 0, .logicLeft:
                placeHorizontal(node.children, parent: frame, side: .left, depth: depth, into: &result)
            case .orgDown, .treeDown:
                placeVertical(node.children, parent: frame, depth: depth, into: &result)
            default:
                // Mind map below the root keeps the side it started on; logic charts grow right.
                let side: Side = frame.side == .left ? .left : .right
                placeHorizontal(node.children, parent: frame, side: side, depth: depth, into: &result)
            }
            for child in node.children {
                let s = nodes[child]?.structure ?? childStructure(structure, depth: depth)
                place(child, structure: s, depth: depth + 1, into: &result)
            }
        }

        /// Below the root, a balanced mind map continues as a one-sided tree.
        func childStructure(_ s: LayoutStructure, depth: Int) -> LayoutStructure {
            s.family == "mindmap" ? .logicRight : s
        }

        // MARK: Horizontal (mind map, logic chart)

        mutating func height(_ id: NodeID, depth: Int) -> CGFloat {
            if let h = extent[id] { return h }
            guard let node = nodes[id] else { return 0 }
            var total: CGFloat = 0
            for (i, c) in node.children.enumerated() {
                total += height(c, depth: depth + 1) + (i > 0 ? spacing.siblingGap(depth + 1) : 0)
            }
            let h = max(node.size.height, total)
            extent[id] = h
            return h
        }

        mutating func placeHorizontal(
            _ kids: [NodeID], parent: NodeFrame, side: Side, depth: Int,
            into result: inout LayoutResult
        ) {
            guard !kids.isEmpty else { return }
            let gap = spacing.siblingGap(depth + 1)
            var total: CGFloat = 0
            for (i, k) in kids.enumerated() { total += height(k, depth: depth + 1) + (i > 0 ? gap : 0) }
            var y = parent.center.y - total / 2
            let dir = CGFloat(side.rawValue)
            let edgeX = parent.center.x + dir * (parent.size.width / 2 + spacing.levelGap(depth))
            for k in kids {
                guard let n = nodes[k] else { continue }
                let h = height(k, depth: depth + 1)
                let center = CGPoint(x: edgeX + dir * n.size.width / 2, y: y + h / 2)
                result.frames[k] = NodeFrame(center: center, size: n.size, side: side, depth: depth + 1)
                y += h + gap
            }
        }

        // MARK: Vertical (org chart, tree chart)

        var widths: [NodeID: CGFloat] = [:]

        mutating func width(_ id: NodeID) -> CGFloat {
            if let w = widths[id] { return w }
            guard let node = nodes[id] else { return 0 }
            var total: CGFloat = 0
            for (i, c) in node.children.enumerated() {
                total += width(c) + (i > 0 ? spacing.horizontalSiblingGap : 0)
            }
            let w = max(node.size.width, total)
            widths[id] = w
            return w
        }

        mutating func placeVertical(_ kids: [NodeID], parent: NodeFrame, depth: Int, into result: inout LayoutResult) {
            guard !kids.isEmpty else { return }
            var total: CGFloat = 0
            for (i, k) in kids.enumerated() { total += width(k) + (i > 0 ? spacing.horizontalSiblingGap : 0) }
            let rowHeight = kids.compactMap { nodes[$0]?.size.height }.max() ?? 0
            let y = parent.center.y + parent.size.height / 2 + spacing.verticalLevelGap + rowHeight / 2
            var x = parent.center.x - total / 2
            for k in kids {
                guard let n = nodes[k] else { continue }
                let w = width(k)
                result.frames[k] = NodeFrame(
                    center: CGPoint(x: x + w / 2, y: y), size: n.size, side: .down,
                    depth: depth + 1)
                x += w + spacing.horizontalSiblingGap
            }
        }
    }
}
