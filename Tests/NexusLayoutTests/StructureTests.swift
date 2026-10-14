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
