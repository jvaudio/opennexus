import CoreGraphics
import Testing

@testable import NexusCore
@testable import NexusLayout

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

@Suite struct StructureTests {
    static let all: [LayoutStructure] = [
        .mindmapBalanced, .logicRight, .orgDown, .timelineHorizontal, .timelineVertical, .fishboneLeft,
        .fishboneRight, .matrix, .braceRight, .treeTable, .treeIndented,
    ]

    @Test(arguments: all) func noOverlaps(structure: LayoutStructure) {
        for (mains, subs) in [(4, 2), (5, 3), (2, 0), (7, 1)] {
            let (root, nodes) = uniformTree(mains: mains, subs: subs)
            let r = TreeLayout.layout(root: root, nodes: nodes, structure: structure)
            #expect(r.frames.count == nodes.count, "\(structure.rawValue) placed every node")
            #expect(overlaps(r).isEmpty, "\(structure.rawValue) \(mains)×\(subs): \(overlaps(r))")
        }
    }

    @Test func timelineEventsShareTheAxis() {
        let (root, nodes) = uniformTree(mains: 4, subs: 2)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .timelineHorizontal)
        let events = nodes[root]!.children.map { r.frames[$0]! }
        #expect(events.allSatisfy { abs($0.center.y - r.frames[root]!.center.y) < 0.5 })
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.rect.maxX < $1.rect.minX })
        for e in nodes[root]!.children {
            for d in nodes[e]!.children { #expect(r.frames[d]!.rect.minY > r.frames[e]!.rect.maxY) }
        }
    }

    @Test func fishboneBonesAlternate() {
        let (root, nodes) = uniformTree(mains: 4, subs: 2)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .fishboneLeft)
        let head = r.frames[root]!
        let bones = nodes[root]!.children.map { r.frames[$0]! }
        for (i, b) in bones.enumerated() {
            #expect((b.center.y < head.center.y) == (i % 2 == 0), "bone \(i) on the expected side")
            #expect(b.rect.maxX < head.rect.minX, "bones grow away from the head")
        }
        #expect(r.families[root] == "fishbone")
    }

    @Test func matrixCellsFormAGrid() {
        let (root, nodes) = uniformTree(mains: 4, subs: 2)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .matrix)
        let cells = nodes[root]!.children.map { id -> CGRect in
            let f = r.frames[id]!
            return r.cells[id]!.rect.offsetBy(dx: f.center.x, dy: f.center.y)
        }
        #expect(cells.count == 4)
        #expect(abs(cells[0].minY - cells[1].minY) < 0.5 && abs(cells[2].minY - cells[3].minY) < 0.5)
        #expect(cells[0].maxY < cells[2].minY)
        for (i, id) in nodes[root]!.children.enumerated() {
            for d in nodes[id]!.children { #expect(cells[i].contains(r.frames[d]!.rect)) }
        }
        // The header spans the grid.
        #expect(r.frames[root]!.size.width >= cells[1].maxX - cells[0].minX - 0.5)
    }

    @Test func treeTableRowsStack() {
        let (root, nodes) = uniformTree(mains: 3, subs: 2)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .treeTable)
        var lastBottom = r.frames[root]!.rect.maxY
        for id in nodes[root]!.children {
            let f = r.frames[id]!
            let row = r.cells[id]!.rect.offsetBy(dx: f.center.x, dy: f.center.y)
            #expect(row.minY >= lastBottom - 0.5)
            lastBottom = row.maxY
            for d in nodes[id]!.children { #expect(r.frames[d]!.rect.minX > f.rect.maxX) }
        }
    }

    @Test func orgLeavesStackInAColumn() {
        let (root, nodes) = uniformTree(mains: 3, subs: 3)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .orgDown)
        for m in nodes[root]!.children {
            let xs = nodes[m]!.children.map { r.frames[$0]!.rect.minX }
            #expect(Set(xs.map { Int($0.rounded()) }).count == 1, "leaves share a left edge")
            #expect(r.families[m] == "indent")
        }
    }

    /// A fishbone on one branch of a mind map grows away from the root and doesn't
    /// collide with its siblings.
    @Test(arguments: [LayoutStructure.fishboneLeft, .timelineHorizontal, .matrix, .treeTable, .treeIndented])
    func mixedBranchDoesNotCollide(structure: LayoutStructure) {
        var (root, nodes) = uniformTree(mains: 4, subs: 3)
        let mains = nodes[root]!.children
        nodes[mains[1]]!.structure = structure
        nodes[mains[3]]!.structure = structure
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .mindmapBalanced)
        #expect(r.frames.count == nodes.count)
        #expect(overlaps(r).isEmpty, "\(structure.rawValue): \(overlaps(r))")
        let rootRect = r.frames[root]!.rect
        for m in [mains[1], mains[3]] {
            let side = r.frames[m]!.side
            for d in [m] + nodes[m]!.children {
                let f = r.frames[d]!.rect
                #expect(side == .right ? f.minX > rootRect.maxX : f.maxX < rootRect.minX, "\(d) stays on its side")
            }
        }
    }
}

/// A fishbone whose causes have sub-causes (and one a sub-cause of its own), sized like
/// the canvas draws them: bones, then smaller causes, then smaller sub-causes.
private func fishboneWithSubCauses() -> (NodeID, [NodeID: LayoutNode]) {
    var nodes: [NodeID: LayoutNode] = [:]
    var n = 2
    func add(_ size: CGSize, _ kids: [NodeID] = []) -> NodeID {
        let id = NodeID("n\(n)")
        n += 1
        nodes[id] = LayoutNode(size: size, children: kids)
        return id
    }
    let cause = CGSize(width: 84, height: 26)
    let sub = CGSize(width: 70, height: 22)
    var bones: [NodeID] = []
    for b in 0..<4 {
        var causes: [NodeID] = []
        for c in 0..<3 {
            // Every other cause has two sub-causes; the first bone's first one nests a third.
            var subs: [NodeID] = []
            if (b + c) % 2 == 0 {
                let deep = b == 0 && c == 0 ? [add(sub)] : []
                subs = [add(sub, deep), add(sub)]
            }
            causes.append(add(cause, subs))
        }
        bones.append(add(CGSize(width: 110, height: 38), causes))
    }
    nodes["n1"] = LayoutNode(size: CGSize(width: 160, height: 52), children: bones)
    return ("n1", nodes)
}

/// Pairs of frames closer than `gap` on every side.
private func crowded(_ r: LayoutResult, gap: CGFloat) -> [(NodeID, NodeID)] {
    let items = r.frames.sorted { $0.key < $1.key }
    var out: [(NodeID, NodeID)] = []
    for i in items.indices {
        for j in items.indices where j > i {
            let a = items[i].value.rect.insetBy(dx: -gap / 2, dy: -gap / 2)
            if a.intersects(items[j].value.rect.insetBy(dx: -gap / 2, dy: -gap / 2)) {
                out.append((items[i].key, items[j].key))
            }
        }
    }
    return out
}

extension StructureTests {
    /// Each cause makes room along its bone for its sub-causes, so none sits on the next
    /// cause (M29 drew "Staffing" over "New hires").
    @Test(arguments: [LayoutStructure.fishboneLeft, .fishboneRight])
    func fishboneSubCausesDoNotOverlap(structure: LayoutStructure) {
        let (root, nodes) = fishboneWithSubCauses()
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: structure)
        #expect(r.frames.count == nodes.count)
        #expect(crowded(r, gap: 4).isEmpty, "\(structure.rawValue): \(crowded(r, gap: 4))")
        // Sub-causes stay clear of their bone, which a lower bone leans toward.
        let head = r.frames[root]!
        for b in nodes[root]!.children {
            let bone = r.frames[b]!
            let lean: CGFloat = bone.center.x < head.center.x ? 1 : -1
            let along = abs(bone.center.y - head.center.y) - bone.size.height / 2
            func boneX(_ y: CGFloat) -> CGFloat { bone.center.x + lean * (along - abs(y - head.center.y)) * 0.5 }
            for c in nodes[b]!.children {
                var subs = nodes[c]!.children
                while let d = subs.popLast() {
                    subs += nodes[d]!.children
                    let f = r.frames[d]!.rect
                    let edge = lean > 0 ? f.maxX : f.minX
                    for y in [f.minY, f.maxY] {
                        #expect(lean * (boneX(y) - edge) >= 10, "\(structure.rawValue): \(d) clears its bone")
                    }
                }
            }
        }
    }
}
