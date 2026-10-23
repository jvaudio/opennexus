import CoreGraphics
import Foundation
import NexusCore

/// A box a structure draws behind its topics (matrix cells, tree-table cells), stored
/// relative to its owning node's centre so it follows that node's animation.
public struct LayoutCell: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// A matrix quadrant, titled by its node.
        case matrixCell
        /// A tree-table row header (colour bar on the left).
        case tableRow
        /// A tree-table cell.
        case tableCell
    }

    public var kind: Kind
    public var rect: CGRect

    public init(kind: Kind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }
}

/// One subtree laid out on its own, relative to its top node's centre at the origin.
struct LocalLayout {
    var frames: [NodeID: NodeFrame] = [:]
    var families: [NodeID: String] = [:]
    var cells: [NodeID: LayoutCell] = [:]

    var bbox: CGRect {
        var r = frames.values.reduce(CGRect.null) { $0.union($1.rect) }
        for (id, c) in cells {
            guard let f = frames[id] else { continue }
            r = r.union(c.rect.offsetBy(dx: f.center.x, dy: f.center.y))
        }
        return r
    }

    func translated(by d: CGPoint) -> LocalLayout {
        var out = self
        for (id, f) in frames {
            out.frames[id]?.center = CGPoint(x: f.center.x + d.x, y: f.center.y + d.y)
        }
        return out
    }
}

/// Timeline, fishbone, matrix, tree table and indented tree (artboard S4). Each lays out
/// its whole subtree; deeper levels hang as indented stacks.
struct StructureLayouts {
    let nodes: [NodeID: LayoutNode]
    let spacing: LayoutSpacing

    static let indent: CGFloat = 22
    static let stackGap: CGFloat = 10

    func size(_ id: NodeID) -> CGSize { nodes[id]?.size ?? .zero }
    func kids(_ id: NodeID) -> [NodeID] { nodes[id]?.children ?? [] }

    func layout(_ top: NodeID, structure: LayoutStructure, depth: Int, side: Side) -> LocalLayout {
        var l = LocalLayout()
        let s = size(top)
        l.frames[top] = NodeFrame(center: .zero, size: s, side: side, depth: depth)
        switch structure.family {
        case "timeline":
            structure == .timelineVertical
                ? timelineVertical(top, depth: depth, into: &l) : timeline(top, depth: depth, side: side, into: &l)
        case "fishbone":
            // fishbone.left: bones grow left of the head; .right mirrors. A branch on the
            // left of its parent always grows left so it never folds back.
            let bodyLeft = structure == .fishboneLeft ? side != .right || depth == 0 : side == .left
            fishbone(top, depth: depth, bodyLeft: bodyLeft, into: &l)
        case "matrix":
            matrix(top, depth: depth, into: &l)
        case "treeTable":
            treeTable(top, depth: depth, into: &l)
        default:  // tree.indented
            let r = l.frames[top]!.rect
            l.families[top] = "indent"
            let x = side == .left ? r.maxX - Self.indent : r.minX + Self.indent
            _ = stack(
                kids(top), x: x, top: r.maxY + 12, depth: depth + 1, side: side == .left ? .left : .right, into: &l)
        }
        return l
    }

    /// Stacks `ids` (and, indented, their subtrees) downward starting at `top`. `x` is the
    /// left edge for `.right` and the right edge for `.left`. Returns the bottom edge.
    @discardableResult
    func stack(
        _ ids: [NodeID], x: CGFloat, top: CGFloat, depth: Int, side: Side, gap: CGFloat = Self.stackGap,
        into l: inout LocalLayout
    ) -> CGFloat {
        var y = top
        var bottom = top
        for k in ids {
            let s = size(k)
            let cx = side == .left ? x - s.width / 2 : x + s.width / 2
            l.frames[k] = NodeFrame(center: CGPoint(x: cx, y: y + s.height / 2), size: s, side: side, depth: depth)
            y += s.height
            bottom = y
            if !kids(k).isEmpty {
                l.families[k] = "indent"
                let nx = side == .left ? x - Self.indent : x + Self.indent
                bottom = stack(kids(k), x: nx, top: y + gap, depth: depth + 1, side: side, gap: gap, into: &l)
                y = bottom
            }
            y += gap
        }
        return bottom
    }

    // MARK: Timeline

    /// Events ride a horizontal axis from the root; details hang beneath each event.
    func timeline(_ top: NodeID, depth: Int, side: Side, into l: inout LocalLayout) {
        let root = l.frames[top]!.rect
        let dir: CGFloat = side == .left ? -1 : 1
        l.families[top] = "timeline"
        var cursor = dir > 0 ? root.maxX + 36 : root.minX - 36
        for e in kids(top) {
            let s = size(e)
            let cx = cursor + dir * s.width / 2
            l.frames[e] = NodeFrame(center: CGPoint(x: cx, y: 0), size: s, side: side, depth: depth + 1)
            var extent = s.width
            if !kids(e).isEmpty {
                l.families[e] = "indent"
                let er = l.frames[e]!.rect
                let x = dir > 0 ? er.minX + 14 : er.maxX - 14
                stack(kids(e), x: x, top: er.maxY + 16, depth: depth + 2, side: side, into: &l)
                for d in subtree(e) where d != e {
                    if let f = l.frames[d] {
                        extent = max(extent, dir > 0 ? f.rect.maxX - er.minX : er.maxX - f.rect.minX)
                    }
                }
            }
            cursor += dir * (extent + 28)
        }
    }

    /// Vertical axis: events go down; details stack to the right of each event.
    func timelineVertical(_ top: NodeID, depth: Int, into l: inout LocalLayout) {
        let root = l.frames[top]!.rect
        l.families[top] = "timelineV"
        var y = root.maxY + 30
        for e in kids(top) {
            let s = size(e)
            l.frames[e] = NodeFrame(center: CGPoint(x: 0, y: y + s.height / 2), size: s, side: .down, depth: depth + 1)
            var bottom = y + s.height
            if !kids(e).isEmpty {
                l.families[e] = "indent"
                let er = l.frames[e]!.rect
                bottom = max(
                    bottom, stack(kids(e), x: er.maxX + 30, top: er.minY, depth: depth + 2, side: .right, into: &l))
                l.families[e] = "logic"
            }
            y = bottom + 24
        }
    }

    // MARK: Fishbone

    static let boneSlope: CGFloat = 0.5
    /// Room between a cause's block (the cause and the sub-causes stacked under it) and
    /// the next cause, the bone's label or the spine.
    static let causeGap: CGFloat = 6
    /// Room between a stack of sub-causes and the bone where it comes closest: well over a
    /// cause's 12 pt, so sub-causes on a lower bone still read as set back (D237).
    static let boneClearance: CGFloat = 26

    /// The head is the top node; bones alternate above and below a spine; causes hang
    /// off each bone. `bodyLeft` grows the spine to the left of the head.
    func fishbone(_ top: NodeID, depth: Int, bodyLeft: Bool, into l: inout LocalLayout) {
        let head = l.frames[top]!.rect
        let side: Side = bodyLeft ? .left : .right
        // `lean` is +1 when bones lean right toward a head on the right.
        let lean: CGFloat = bodyLeft ? 1 : -1
        let slope = Self.boneSlope
        l.families[top] = "fishbone"
        l.frames[top]?.side = side
        let bones = kids(top)
        var cursor = bodyLeft ? head.minX - 40 : head.maxX + 40
        var j = 0
        while j < bones.count {
            let pair = Array(bones[j..<min(j + 2, bones.count)])
            var reach: CGFloat = 0
            var placed: [(NodeID, Bone, Bool)] = []
            for (k, b) in pair.enumerated() {
                let topBone = k == 0
                let bone = self.bone(b, topBone: topBone, depth: depth, side: side)
                placed.append((b, bone, topBone))
                let maxCause = kids(b).map { size($0).width }.max() ?? 0
                reach = max(reach, bone.length * slope + max(size(b).width / 2, maxCause + 20))
            }
            // The spine point for this pair sits at `cursor`.
            for (b, bone, topBone) in placed {
                let s = size(b)
                let L = bone.length
                let cx = cursor - lean * L * slope
                let cy = topBone ? -(L + s.height / 2) : L + s.height / 2
                l.frames[b] = NodeFrame(center: CGPoint(x: cx, y: cy), size: s, side: side, depth: depth + 1)
                if !bone.causes.isEmpty { l.families[b] = "fishboneCause" }
                // `u` runs along the bone from its label end toward the spine.
                func boneX(_ u: CGFloat) -> CGFloat { cx + lean * u * slope }
                for (c, u, subs) in bone.causes {
                    let cs = size(c)
                    let y = topBone ? u - L : L - u
                    let ccx = boneX(u) - lean * (12 + cs.width / 2)
                    l.frames[c] = NodeFrame(
                        center: CGPoint(x: ccx, y: y - cs.height / 2 + 2), size: cs, side: side, depth: depth + 2)
                    guard let subs else { continue }
                    // Sub-causes stack under the cause, set back from the bone. A lower
                    // bone leans toward them as it goes down, so they move out to clear it.
                    l.families[c] = "fishboneSub"
                    let cr = l.frames[c]!.rect
                    let drop = cr.maxY + 6 + subs.bbox.maxY - y
                    let limit = boneX(topBone ? u + drop : u - drop) - lean * Self.boneClearance
                    let x = bodyLeft ? min(cr.maxX - 10, limit) : max(cr.minX + 10, limit)
                    let moved = subs.translated(by: CGPoint(x: x, y: cr.maxY + 6))
                    l.frames.merge(moved.frames) { a, _ in a }
                    l.families.merge(moved.families) { a, _ in a }
                }
            }
            // Clear whatever reaches furthest from the spine, sub-causes included.
            for (b, _, _) in placed {
                for d in subtree(b) {
                    guard let r = l.frames[d]?.rect else { continue }
                    reach = max(reach, bodyLeft ? cursor - r.minX : r.maxX - cursor)
                }
            }
            cursor -= lean * (reach + 24)
            j += 2
        }
    }

    /// A bone's length and where its causes sit along it (from the label end toward the
    /// spine), with each cause's sub-causes stacked from its top-left (`.right`) or
    /// top-right (`.left`) corner at the origin.
    struct Bone {
        var length: CGFloat
        var causes: [(NodeID, CGFloat, LocalLayout?)]
    }

    /// Causes keep the even spacing of a bone sized to their count, and move apart only
    /// where a cause and the sub-causes under it would come within `causeGap` of the next
    /// cause, the label or the spine; the bone grows by as much.
    func bone(_ b: NodeID, topBone: Bool, depth: Int, side: Side) -> Bone {
        let causes = kids(b)
        let even = max(64, 40 + CGFloat(causes.count) * 30)
        let step = even / CGFloat(causes.count + 1)
        let gap = Self.causeGap
        var out: [(NodeID, CGFloat, LocalLayout?)] = []
        var shift: CGFloat = 0
        var end: CGFloat = 0
        for (i, c) in causes.enumerated() {
            var subs: LocalLayout?
            // The rib runs 2 pt above the cause's bottom; sub-causes start 6 pt below it.
            var below: CGFloat = 2
            if !kids(c).isEmpty {
                var sl = LocalLayout()
                below += 6 + stack(kids(c), x: 0, top: 0, depth: depth + 3, side: side, gap: 6, into: &sl)
                subs = sl
            }
            let above = size(c).height - 2
            let (before, after) = topBone ? (above, below) : (below, above)
            let u = max(CGFloat(i + 1) * step + shift, end + gap + before)
            shift = u - CGFloat(i + 1) * step
            end = u + after
            out.append((c, u, subs))
        }
        return Bone(length: max(even + shift, end + gap), causes: out)
    }

    // MARK: Matrix

    /// A grid of cells under a header bar; each first-level topic titles a cell and its
    /// children stack inside.
    func matrix(_ top: NodeID, depth: Int, into l: inout LocalLayout) {
        let cells = kids(top)
        l.families[top] = "none"
        guard !cells.isEmpty else { return }
        let n = cells.count
        let cols = n <= 4 ? min(n, 2) : Int(ceil(sqrt(Double(n))))
        let pad: CGFloat = 16
        let gap: CGFloat = 12
        // Lay out each cell's content locally (title at its own centre).
        var contents: [NodeID: LocalLayout] = [:]
        var cellW: CGFloat = 180
        var rowH = [CGFloat](repeating: 120, count: (n + cols - 1) / cols)
        for (i, c) in cells.enumerated() {
            var cl = LocalLayout()
            let s = size(c)
            cl.frames[c] = NodeFrame(center: .zero, size: s, side: .right, depth: depth + 1)
            cl.families[c] = "none"
            let r = cl.frames[c]!.rect
            stack(kids(c), x: r.minX, top: r.maxY + 10, depth: depth + 2, side: .right, gap: 8, into: &cl)
            cl.families[c] = "none"
            let b = cl.bbox
            contents[c] = cl
            cellW = max(cellW, b.width + 2 * pad)
            rowH[i / cols] = max(rowH[i / cols], b.height + 2 * pad)
        }
        let width = CGFloat(cols) * cellW + CGFloat(cols - 1) * gap
        // The header bar spans the grid.
        var header = l.frames[top]!
        header.size.width = max(header.size.width, width)
        l.frames[top] = header
        let left = -width / 2
        var y = header.rect.maxY + 14
        for row in 0..<rowH.count {
            for col in 0..<cols {
                let i = row * cols + col
                guard i < n, let cl = contents[cells[i]] else { continue }
                let c = cells[i]
                let b = cl.bbox
                let cellRect = CGRect(x: left + CGFloat(col) * (cellW + gap), y: y, width: cellW, height: rowH[row])
                // Title at the cell's top-left.
                let d = CGPoint(x: cellRect.minX + pad - b.minX, y: cellRect.minY + pad - b.minY)
                let placed = cl.translated(by: d)
                l.frames.merge(placed.frames) { a, _ in a }
                l.families.merge(placed.families) { a, _ in a }
                let center = placed.frames[c]!.center
                l.cells[c] = LayoutCell(kind: .matrixCell, rect: cellRect.offsetBy(dx: -center.x, dy: -center.y))
            }
            y += rowH[row] + gap
        }
    }

    // MARK: Tree table

    /// Rows of nested cells: depth 1 in the first column, each deeper level in the next;
    /// a parent's cell spans its children's rows. The top node is a header bar.
    func treeTable(_ top: NodeID, depth: Int, into l: inout LocalLayout) {
        l.families[top] = "none"
        let rows = kids(top)
        guard !rows.isEmpty else { return }
        let pad: CGFloat = 16
        var colW: [CGFloat] = []
        func measure(_ id: NodeID, _ d: Int) {
            if colW.count <= d { colW.append(0) }
            colW[d] = max(colW[d], size(id).width + 2 * pad, d == 0 ? 130 : 160)
            for k in kids(id) { measure(k, d + 1) }
        }
        for r in rows { measure(r, 0) }
        let width = colW.reduce(0, +)
        var header = l.frames[top]!
        header.size.width = max(header.size.width, width)
        l.frames[top] = header
        let left = -width / 2
        var colLeft: [CGFloat] = []
        var x = left
        for w in colW {
            colLeft.append(x)
            x += w
        }
        var extents: [NodeID: CGFloat] = [:]
        func extent(_ id: NodeID) -> CGFloat {
            if let e = extents[id] { return e }
            let ks = kids(id)
            let own = max(44, size(id).height + 18)
            let e = ks.isEmpty ? own : max(own, ks.reduce(0) { $0 + extent($1) })
            extents[id] = e
            return e
        }
        func place(_ id: NodeID, _ d: Int, _ y0: CGFloat) {
            let s = size(id)
            let e = extent(id)
            let center = CGPoint(x: colLeft[d] + pad + s.width / 2, y: y0 + e / 2)
            l.frames[id] = NodeFrame(center: center, size: s, side: .right, depth: depth + 1 + d)
            l.families[id] = "none"
            let ks = kids(id)
            let cellWidth = ks.isEmpty ? width - (colLeft[d] - left) : colW[d]
            let rect = CGRect(x: colLeft[d], y: y0, width: cellWidth, height: e)
            l.cells[id] = LayoutCell(
                kind: d == 0 ? .tableRow : .tableCell, rect: rect.offsetBy(dx: -center.x, dy: -center.y))
            var y = y0
            for k in ks {
                place(k, d + 1, y)
                y += extent(k)
            }
        }
        var y = header.rect.maxY + 6
        for r in rows {
            place(r, 0, y)
            y += extent(r)
        }
    }

    func subtree(_ id: NodeID) -> [NodeID] {
        var out = [id]
        var i = 0
        while i < out.count {
            out.append(contentsOf: kids(out[i]))
            i += 1
        }
        return out
    }
}
