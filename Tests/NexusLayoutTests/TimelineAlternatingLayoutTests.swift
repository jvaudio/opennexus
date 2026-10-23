import CoreGraphics
import Testing

@testable import NexusCore
@testable import NexusLayout

/// A tree three levels deep with uneven branches and topics of different widths: `mains`
/// main topics, the `i`th with `i % 4` subtopics, every other subtopic with two more.
func unevenTree(mains: Int, prefix: String = "n") -> (NodeID, [NodeID: LayoutNode]) {
    var nodes: [NodeID: LayoutNode] = [:]
    var n = 2
    func add(_ w: CGFloat, _ h: CGFloat, _ kids: [NodeID] = []) -> NodeID {
        let id = NodeID("\(prefix)\(n)")
        n += 1
        nodes[id] = LayoutNode(size: CGSize(width: w, height: h), children: kids)
        return id
    }
    var rootKids: [NodeID] = []
    for i in 0..<mains {
        var subs: [NodeID] = []
        for j in 0..<(i % 4) {
            let leaves = j % 2 == 0 ? [add(70, 26), add(96, 26)] : []
            subs.append(add(CGFloat(80 + 30 * j), 30, leaves))
        }
        rootKids.append(add(CGFloat(90 + 25 * (i % 3)), 38, subs))
    }
    let root = NodeID("\(prefix)1")
    nodes[root] = LayoutNode(size: CGSize(width: 160, height: 52), children: rootKids)
    return (root, nodes)
}

private func overlaps(_ r: LayoutResult) -> [(NodeID, NodeID)] {
    let items = r.frames.sorted { $0.key < $1.key }
    var out: [(NodeID, NodeID)] = []
    for i in items.indices {
        for j in items.indices where j > i {
            if items[i].value.rect.insetBy(dx: 1, dy: 1).intersects(items[j].value.rect.insetBy(dx: 1, dy: 1)) {
                out.append((items[i].key, items[j].key))
            }
        }
    }
    return out
}

private func descendants(_ id: NodeID, _ nodes: [NodeID: LayoutNode]) -> [NodeID] {
    (nodes[id]?.children ?? []).flatMap { [$0] + descendants($0, nodes) }
}

/// Xmind's horizontal timeline (D248) and where branch lines leave each topic (D250).
@Suite struct TimelineAlternatingLayoutTests {
    static let shapes: [(NodeID, [NodeID: LayoutNode])] = [
        uniformTree(mains: 4, subs: 2), uniformTree(mains: 7, subs: 1), uniformTree(mains: 2, subs: 0),
        uniformTree(mains: 5, subs: 6), unevenTree(mains: 9), unevenTree(mains: 3),
    ]

    @Test func branchesAlternateAboveAndBelowTheAxis() {
        for (root, nodes) in Self.shapes {
            let r = TreeLayout.layout(root: root, nodes: nodes, structure: .timelineAlternating)
            #expect(r.frames.count == nodes.count, "every topic placed")
            #expect(overlaps(r).isEmpty, "\(overlaps(r))")
            let events = nodes[root]!.children
            let axis = r.frames[root]!.center.y
            var sides = Set<Bool>()
            for (i, e) in events.enumerated() {
                let f = r.frames[e]!
                #expect(abs(f.center.y - axis) < 0.5, "event \(i) on the axis")
                let branch = descendants(e, nodes)
                if !branch.isEmpty {
                    #expect(r.families[e] == (i % 2 == 0 ? "timelineUp" : "timelineDown"))
                    sides.insert(i % 2 == 0)
                }
                for d in branch {
                    let dr = r.frames[d]!.rect
                    #expect(i % 2 == 0 ? dr.maxY < f.rect.minY : dr.minY > f.rect.maxY, "event \(i): its side")
                    #expect(dr.minX > f.center.x, "grows to the right of its stem")
                }
            }
            if events.count > 1, events.prefix(2).allSatisfy({ !(nodes[$0]!.children.isEmpty) }) {
                #expect(sides == [true, false], "both sides of the axis")
            }
            // Events in order along the axis, apart.
            let rects = events.map { r.frames[$0]!.rect }
            #expect(zip(rects, rects.dropFirst()).allSatisfy { $0.maxX + 28 <= $1.minX + 0.5 })
            #expect(rects.first.map { $0.minX > r.frames[root]!.rect.maxX } ?? true)
        }
    }

    @Test func eachBranchIsALogicChart() {
        let (root, nodes) = unevenTree(mains: 9)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .timelineAlternating)
        for e in nodes[root]!.children {
            let kids = nodes[e]!.children
            // The event's topics stack beside its stem, the first at the top, left edges aligned.
            let rects = kids.map { r.frames[$0]!.rect }
            #expect(zip(rects, rects.dropFirst()).allSatisfy { $0.maxY < $1.minY })
            #expect(Set(rects.map { Int($0.minX.rounded()) }).count <= 1)
            for k in kids where !(nodes[k]!.children.isEmpty) {
                #expect(r.families[k] == "logic")
                let kr = r.frames[k]!
                let leaves = nodes[k]!.children.map { r.frames[$0]! }
                #expect(leaves.allSatisfy { $0.rect.minX > kr.rect.maxX + 20 })
                let mid = (leaves.first!.center.y + leaves.last!.center.y) / 2
                #expect(abs(mid - kr.center.y) < 0.5, "centred on their parent")
            }
        }
    }

    @Test func stemsCrossNoOtherTopic() {
        for (root, nodes) in Self.shapes {
            let r = TreeLayout.layout(root: root, nodes: nodes, structure: .timelineAlternating)
            for e in nodes[root]!.children {
                guard let fam = r.families[e], let ef = r.frames[e] else { continue }
                for k in nodes[e]!.children {
                    let path = BranchLines.path(from: ef, to: r.frames[k]!, family: fam)
                    for (id, f) in r.frames where id != e && id != k {
                        #expect(!stemCrosses(path, f.rect.insetBy(dx: 1, dy: 1)), "line to \(k) crosses \(id)")
                    }
                }
            }
        }
    }

    /// Whether any straight segment of `path` passes through `box`.
    func stemCrosses(_ path: CGPath, _ box: CGRect) -> Bool {
        var pts: [CGPoint] = []
        path.applyWithBlock { pts.append($0.pointee.points[0]) }
        for (a, b) in zip(pts, pts.dropFirst()) {
            let seg = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            if seg.insetBy(dx: -0.01, dy: -0.01).intersects(box) { return true }
        }
        return false
    }

    @Test func onTheLeftItMirrors() {
        // A timeline branch beside other main topics, on the left of the central topic.
        var (root, nodes) = unevenTree(mains: 4)
        let (branch, timeline) = unevenTree(mains: 6, prefix: "t")
        nodes.merge(timeline) { a, _ in a }
        nodes[branch]!.structure = .timelineAlternating
        nodes[root]!.children.insert(branch, at: 2)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .mindmapLeft)
        #expect(overlaps(r).isEmpty, "\(overlaps(r))")
        let rootRect = r.frames[root]!.rect
        for (i, e) in nodes[branch]!.children.enumerated() {
            let f = r.frames[e]!
            #expect(f.rect.maxX < r.frames[branch]!.rect.minX)
            for d in descendants(e, nodes) {
                let dr = r.frames[d]!.rect
                #expect(dr.maxX < f.center.x && dr.maxX < rootRect.minX, "grows left, away from the root")
                #expect(i % 2 == 0 ? dr.maxY < f.rect.minY : dr.minY > f.rect.maxY)
            }
        }
    }

    // MARK: Junctions (D250)

    static let structures: [LayoutStructure] = [
        .mindmapBalanced, .logicRight, .logicLeft, .orgDown, .treeIndented, .timelineHorizontal, .timelineVertical,
        .timelineAlternating, .fishboneLeft, .fishboneRight, .braceRight, .matrix, .treeTable,
    ]

    /// Where the line to a topic's first child starts, read from the drawn path.
    func start(_ r: LayoutResult, _ id: NodeID, _ nodes: [NodeID: LayoutNode]) -> CGPoint? {
        guard let k = nodes[id]?.children.first, let fam = r.families[id] else { return nil }
        var out: CGPoint?
        BranchLines.path(from: r.frames[id]!, to: r.frames[k]!, family: fam).applyWithBlock {
            if out == nil { out = $0.pointee.points[0] }
        }
        return out
    }

    @Test(arguments: structures) func theJunctionIsWhereTheLineLeaves(structure: LayoutStructure) {
        let (root, nodes) = unevenTree(mains: 6)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: structure)
        for (id, n) in nodes where !n.children.isEmpty && id != root {
            guard let fam = r.families[id], let p = start(r, id, nodes) else { continue }
            let j = BranchLines.junction(
                of: r.frames[id]!, family: fam, child: r.frames[n.children[0]], parent: nil)
            if fam == "fishboneCause" {
                // Causes' ribs end on the bone, which leaves the label at its middle.
                #expect(abs(j.point.x - r.frames[id]!.center.x) < 0.5)
                continue
            }
            #expect(j.point == p, "\(structure.rawValue) \(fam): on the line")
            let rect = r.frames[id]!.rect
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(j.point), "on the topic's edge")
        }
    }

    /// Folding a topic names the family its children had, so its "+N" sits where its "−"
    /// was, on the same edge.
    @Test(arguments: structures) func aFoldedTopicKeepsItsJunction(structure: LayoutStructure) {
        let (root, nodes) = unevenTree(mains: 6)
        // Sides split by count, as the canvas does, so a fold doesn't move a branch across.
        var spacing = LayoutSpacing.standard
        spacing.balanceByHeight = false
        let open = TreeLayout.layout(root: root, nodes: nodes, structure: structure, spacing: spacing)
        for (id, n) in nodes where !n.children.isEmpty && id != root {
            guard let fam = open.families[id] else { continue }
            var folded = nodes
            folded[id]!.children = []
            folded[id]!.folded = true
            let shut = TreeLayout.layout(root: root, nodes: folded, structure: structure, spacing: spacing)
            // Org charts stack leaves in a column, which a fold can't see (M32 known gap).
            if fam == "indent" && structure == .orgDown { continue }
            #expect(shut.families[id] == fam, "\(structure.rawValue): \(id) folds as \(fam)")
            let parent = nodes.first { $0.value.children.contains(id) }?.key
            let a = BranchLines.junction(
                of: open.frames[id]!, family: fam, child: open.frames[n.children[0]],
                parent: parent.flatMap { open.frames[$0] })
            let b = BranchLines.junction(
                of: shut.frames[id]!, family: shut.families[id] ?? "", child: nil,
                parent: parent.flatMap { shut.frames[$0] })
            #expect(a.edge == b.edge, "\(structure.rawValue) \(fam)")
            let oa = open.frames[id]!.rect.origin
            let ob = shut.frames[id]!.rect.origin
            let da = CGPoint(x: a.point.x - oa.x, y: a.point.y - oa.y)
            let db = CGPoint(x: b.point.x - ob.x, y: b.point.y - ob.y)
            // Indented lines sit beside their children, a few points in from the edge. A
            // fishbone's sub-causes can move out from a lower bone (D240), and their line too.
            if fam != "fishboneSub" {
                #expect(hypot(da.x - db.x, da.y - db.y) <= 6, "\(structure.rawValue) \(fam): \(da) vs \(db)")
            }
        }
    }

    @Test func junctionsByFamily() {
        let f = NodeFrame(center: CGPoint(x: 100, y: 50), size: CGSize(width: 80, height: 30), side: .right, depth: 2)
        let spine = NodeFrame(
            center: CGPoint(x: 300, y: 200), size: CGSize(width: 90, height: 40), side: .left, depth: 0)
        let cases: [(String, NodeFrame?, BranchJunction)] = [
            ("logic", nil, BranchJunction(CGPoint(x: 140, y: 50), .right)),
            ("timeline", nil, BranchJunction(CGPoint(x: 140, y: 50), .right)),
            ("timelineAlt", nil, BranchJunction(CGPoint(x: 140, y: 50), .right)),
            ("timelineUp", nil, BranchJunction(CGPoint(x: 100, y: 35), .top)),
            ("timelineDown", nil, BranchJunction(CGPoint(x: 100, y: 65), .bottom)),
            ("timelineV", nil, BranchJunction(CGPoint(x: 100, y: 65), .bottom)),
            ("org", nil, BranchJunction(CGPoint(x: 100, y: 65), .bottom)),
            ("indent", nil, BranchJunction(CGPoint(x: 70, y: 65), .bottom)),
            ("fishboneSub", nil, BranchJunction(CGPoint(x: 64, y: 65), .bottom)),
            // A bone above the spine meets its label at the bottom; below it, at the top.
            ("fishboneCause", spine, BranchJunction(CGPoint(x: 100, y: 65), .bottom)),
            ("none", nil, BranchJunction(CGPoint(x: 140, y: 50), .right)),
        ]
        for (fam, parent, want) in cases {
            #expect(BranchLines.junction(of: f, family: fam, child: nil, parent: parent) == want, "\(fam)")
        }
        var low = f
        low.center.y = 350
        #expect(
            BranchLines.junction(of: low, family: "fishboneCause", child: nil, parent: spine)
                == BranchJunction(CGPoint(x: 100, y: 335), .top))
        var left = f
        left.side = .left
        #expect(BranchLines.junction(of: left, family: "indent", child: nil, parent: nil).point.x == 130)
        #expect(BranchLines.junction(of: left, family: "logic", child: nil, parent: nil).edge == .left)
        // Underlined topics: the line leaves from the baseline.
        #expect(
            BranchLines.junction(of: f, family: "logic", child: nil, parent: nil, baseline: true)
                == BranchJunction(CGPoint(x: 140, y: 65), .right))
    }
}
