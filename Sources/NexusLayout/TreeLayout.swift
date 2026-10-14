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
    /// Per-branch spacing for this node's children (FMT-1 › Spacing).
    public var siblingGap: CGFloat?
    public var levelGap: CGFloat?
    /// Room reserved around this subtree across the growth axis (boundaries draw in it);
    /// `marginBefore` is the leading side (top in horizontal trees) and holds a title band.
    public var margin: CGFloat
    public var marginBefore: CGFloat

    public init(
        size: CGSize, children: [NodeID], structure: LayoutStructure? = nil, siblingGap: CGFloat? = nil,
        levelGap: CGFloat? = nil, margin: CGFloat = 0, marginBefore: CGFloat? = nil
    ) {
        self.size = size
        self.children = children
        self.structure = structure
        self.siblingGap = siblingGap
        self.levelGap = levelGap
        self.margin = margin
        self.marginBefore = marginBefore ?? margin
    }
}

/// Where a node ended up. `center` is in canvas coordinates; the root sits at the origin.
public struct NodeFrame: Sendable, Equatable {
    public var center: CGPoint
    public var size: CGSize
    public var side: Side
    public var depth: Int

    public init(center: CGPoint, size: CGSize, side: Side, depth: Int) {
        self.center = center
        self.size = size
        self.side = side
        self.depth = depth
    }

    public var rect: CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

public struct LayoutResult: Sendable, Equatable {
    public var frames: [NodeID: NodeFrame] = [:]
    /// The structure family each parent's children were laid out with (for branch-line geometry).
    public var families: [NodeID: String] = [:]
    /// Boxes drawn behind topics (matrix cells, tree-table cells), relative to each node.
    public var cells: [NodeID: LayoutCell] = [:]

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
    /// Balance a mind map's two sides by subtree height rather than by count.
    public var balanceByHeight: Bool = true

    public static let standard = LayoutSpacing()

    /// Compact map (FMT-3): tighter gaps everywhere.
    public var compacted: LayoutSpacing {
        var s = self
        s.mainSiblingGap *= 0.6
        s.subSiblingGap *= 0.6
        s.rootLevelGap *= 0.7
        s.levelGap *= 0.7
        s.verticalLevelGap *= 0.7
        s.horizontalSiblingGap *= 0.6
        return s
    }

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
        let s = r.structure ?? structure
        var engine = Engine(nodes: nodes, spacing: spacing)
        if s.isSelfContained {
            let local = StructureLayouts(nodes: nodes, spacing: spacing).layout(
                root, structure: s, depth: 0, side: .right)
            engine.merge(local.translated(by: origin), into: &result)
            return result
        }
        result.frames[root] = NodeFrame(center: origin, size: r.size, side: .right, depth: 0)
        engine.place(root, structure: s, depth: 0, into: &result)
        return result
    }

    struct Engine {
        let nodes: [NodeID: LayoutNode]
        let spacing: LayoutSpacing
        /// Extent of each subtree across its growth axis (height for horizontal trees,
        /// width for vertical ones), memoised per family.
        var extent: [NodeID: CGFloat] = [:]
        /// Branches with a self-contained structure, laid out locally per side.
        var blocks: [String: LocalLayout] = [:]

        init(nodes: [NodeID: LayoutNode], spacing: LayoutSpacing) {
            self.nodes = nodes
            self.spacing = spacing
        }

        /// The local layout of a branch whose own structure is self-contained (timeline,
        /// fishbone, matrix, tree table, tree), or nil for ordinary branches.
        mutating func block(_ id: NodeID, side: Side, depth: Int) -> LocalLayout? {
            guard let s = nodes[id]?.structure, s.isSelfContained else { return nil }
            let key = "\(id.rawValue)|\(side.rawValue)"
            if let b = blocks[key] { return b }
            let b = StructureLayouts(nodes: nodes, spacing: spacing).layout(id, structure: s, depth: depth, side: side)
            blocks[key] = b
            return b
        }

        func merge(_ l: LocalLayout, into result: inout LayoutResult) {
            result.frames.merge(l.frames) { _, b in b }
            result.families.merge(l.families) { _, b in b }
            result.cells.merge(l.cells) { _, b in b }
        }

        /// Org charts stack a parent's leaf children in an indented column (6 per column).
        func stacksLeaves(_ id: NodeID) -> Bool {
            guard let n = nodes[id], !n.children.isEmpty else { return false }
            return n.children.allSatisfy { (nodes[$0]?.children.isEmpty ?? true) }
        }

        static let stackColumn = 6

        /// Children of `id` are placed by the parent's effective structure. A child that
        /// overrides the structure lays out its own subtree with it.
        mutating func place(_ id: NodeID, structure: LayoutStructure, depth: Int, into result: inout LayoutResult) {
            guard let node = nodes[id], !node.children.isEmpty, let frame = result.frames[id] else { return }
            let family = structure.family
            result.families[id] = family
            switch structure {
            case .mindmapBalanced where depth == 0:
                var half = (node.children.count + 1) / 2
                if spacing.balanceByHeight, node.children.count > 2 {
                    // Split where the two sides' total heights are closest.
                    let hs = node.children.map { height($0, depth: depth + 1) }
                    let total = hs.reduce(0, +)
                    var acc: CGFloat = 0
                    var best = (half, CGFloat.greatestFiniteMagnitude)
                    for (i, h) in hs.enumerated() {
                        acc += h
                        let diff = abs(total - 2 * acc)
                        if diff <= best.1 { best = (i + 1, diff) }  // ties favour the right side
                    }
                    half = max(1, min(node.children.count - 1, best.0))
                }
                let right = Array(node.children.prefix(half))
                let left = Array(node.children.dropFirst(half).reversed())
                placeHorizontal(right, parent: frame, side: .right, depth: depth, into: &result, owner: id)
                placeHorizontal(left, parent: frame, side: .left, depth: depth, into: &result, owner: id)
            case .mindmapLeft where depth == 0, .logicLeft,
                .braceLeft where depth == 0:
                placeHorizontal(node.children, parent: frame, side: .left, depth: depth, into: &result, owner: id)
            case .orgDown where depth > 0 && stacksLeaves(id):
                placeStack(node.children, parent: frame, depth: depth, into: &result)
                result.families[id] = "indent"
            case .orgDown, .treeDown:
                placeVertical(node.children, parent: frame, depth: depth, into: &result)
            default:
                // Mind map below the root keeps the side it started on; logic charts grow right.
                let side: Side = frame.side == .left ? .left : .right
                placeHorizontal(node.children, parent: frame, side: side, depth: depth, into: &result, owner: id)
            }
            for child in node.children {
                if let f = result.frames[child], let b = block(child, side: f.side, depth: depth + 1) {
                    merge(b.translated(by: f.center), into: &result)
                    continue
                }
                let s = nodes[child]?.structure ?? childStructure(structure, depth: depth)
                place(child, structure: s, depth: depth + 1, into: &result)
            }
        }

        /// Leaf children in indented columns under their parent (org chart, artboard S4).
        mutating func placeStack(_ kids: [NodeID], parent: NodeFrame, depth: Int, into result: inout LayoutResult) {
            let colW = kids.compactMap { nodes[$0]?.size.width }.max() ?? 0
            let top = parent.center.y + parent.size.height / 2 + 12
            var x = parent.center.x - parent.size.width / 2 + StructureLayouts.indent
            var y = top
            for (i, k) in kids.enumerated() {
                guard let n = nodes[k] else { continue }
                if i > 0 && i % Self.stackColumn == 0 {
                    x += colW + 16
                    y = top
                }
                result.frames[k] = NodeFrame(
                    center: CGPoint(x: x + n.size.width / 2, y: y + n.size.height / 2), size: n.size, side: .right,
                    depth: depth + 1)
                y += n.size.height + StructureLayouts.stackGap
            }
        }

        /// Below the root, a balanced mind map continues as a one-sided tree.
        func childStructure(_ s: LayoutStructure, depth: Int) -> LayoutStructure {
            switch s {
            case .braceLeft: .braceLeft
            default: s.family == "mindmap" ? .logicRight : s
            }
        }

        // MARK: Horizontal (mind map, logic chart)

        mutating func height(_ id: NodeID, depth: Int, side: Side = .right) -> CGFloat {
            if let b = block(id, side: side, depth: depth) { return b.bbox.height }
            if let h = extent[id] { return h }
            guard let node = nodes[id] else { return 0 }
            var total: CGFloat = 0
            let gap = node.siblingGap ?? spacing.siblingGap(depth + 1)
            for (i, c) in node.children.enumerated() {
                total += height(c, depth: depth + 1) + (i > 0 ? gap : 0)
            }
            let h = max(node.size.height, total) + node.marginBefore + node.margin
            extent[id] = h
            return h
        }

        mutating func placeHorizontal(
            _ kids: [NodeID], parent: NodeFrame, side: Side, depth: Int,
            into result: inout LayoutResult, owner: NodeID? = nil
        ) {
            guard !kids.isEmpty else { return }
            let ownerNode = owner.flatMap { nodes[$0] }
            let gap = ownerNode?.siblingGap ?? spacing.siblingGap(depth + 1)
            var total: CGFloat = 0
            for (i, k) in kids.enumerated() {
                total += height(k, depth: depth + 1, side: side) + (i > 0 ? gap : 0)
            }
            var y = parent.center.y - total / 2
            let dir = CGFloat(side.rawValue)
            let edgeX =
                parent.center.x + dir * (parent.size.width / 2 + (ownerNode?.levelGap ?? spacing.levelGap(depth)))
            for k in kids {
                guard let n = nodes[k] else { continue }
                let h = height(k, depth: depth + 1, side: side)
                if let b = block(k, side: side, depth: depth + 1) {
                    // A self-contained branch: its whole box sits beyond the level gap.
                    let bb = b.bbox
                    let cx = dir > 0 ? edgeX - bb.minX : edgeX - bb.maxX
                    let size = b.frames[k]?.size ?? n.size
                    result.frames[k] = NodeFrame(
                        center: CGPoint(x: cx, y: y - bb.minY), size: size, side: side, depth: depth + 1)
                    y += h + gap
                    continue
                }
                let inner = h - n.marginBefore - n.margin
                let center = CGPoint(x: edgeX + dir * n.size.width / 2, y: y + n.marginBefore + inner / 2)
                result.frames[k] = NodeFrame(center: center, size: n.size, side: side, depth: depth + 1)
                y += h + gap
            }
        }

        // MARK: Vertical (org chart, tree chart)

        var widths: [NodeID: CGFloat] = [:]

        mutating func width(_ id: NodeID) -> CGFloat {
            if let b = block(id, side: .down, depth: 1) { return b.bbox.width }
            if let w = widths[id] { return w }
            guard let node = nodes[id] else { return 0 }
            if stacksLeaves(id) {
                let colW = node.children.compactMap { nodes[$0]?.size.width }.max() ?? 0
                let cols = CGFloat((node.children.count + Self.stackColumn - 1) / Self.stackColumn)
                let w = max(node.size.width, StructureLayouts.indent + cols * colW + (cols - 1) * 16) + 2 * node.margin
                widths[id] = w
                return w
            }
            var total: CGFloat = 0
            for (i, c) in node.children.enumerated() {
                total += width(c) + (i > 0 ? spacing.horizontalSiblingGap : 0)
            }
            let w = max(node.size.width, total) + 2 * node.margin
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
                if let b = block(k, side: .down, depth: 1) {
                    let bb = b.bbox
                    let top = y - rowHeight / 2
                    result.frames[k] = NodeFrame(
                        center: CGPoint(x: x - bb.minX, y: top - bb.minY), size: b.frames[k]?.size ?? n.size,
                        side: .down, depth: depth + 1)
                    x += w + spacing.horizontalSiblingGap
                    continue
                }
                // A stacked parent hangs its column below its left half.
                let cx = stacksLeaves(k) ? x + n.size.width / 2 : x + w / 2
                result.frames[k] = NodeFrame(
                    center: CGPoint(x: cx, y: y), size: n.size, side: .down,
                    depth: depth + 1)
                x += w + spacing.horizontalSiblingGap
            }
        }
    }
}
