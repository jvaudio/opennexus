import CoreGraphics
import Testing

@testable import NexusCore
@testable import NexusLayout

func uniformTree(mains: Int, subs: Int) -> (NodeID, [NodeID: LayoutNode]) {
    var nodes: [NodeID: LayoutNode] = [:]
    var rootKids: [NodeID] = []
    var n = 2
    for _ in 0..<mains {
        let m = NodeID("n\(n)"); n += 1
        var kids: [NodeID] = []
        for _ in 0..<subs {
            let s = NodeID("n\(n)"); n += 1
            nodes[s] = LayoutNode(size: CGSize(width: 80, height: 32), children: [])
            kids.append(s)
        }
        nodes[m] = LayoutNode(size: CGSize(width: 110, height: 38), children: kids)
        rootKids.append(m)
    }
    nodes["n1"] = LayoutNode(size: CGSize(width: 160, height: 52), children: rootKids)
    return ("n1", nodes)
}

@Suite struct LayoutTests {
    @Test func balancedMindMapSplitsSides() {
        let (root, nodes) = uniformTree(mains: 5, subs: 2)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .mindmapBalanced)
        let mains = nodes[root]!.children
        #expect(mains.prefix(3).allSatisfy { r.frames[$0]!.side == .right && r.frames[$0]!.center.x > 0 })
        #expect(mains.suffix(2).allSatisfy { r.frames[$0]!.side == .left && r.frames[$0]!.center.x < 0 })
        // Grandchildren inherit the side.
        for m in mains {
            for s in nodes[m]!.children { #expect(r.frames[s]!.side == r.frames[m]!.side) }
        }
        #expect(r.frames.count == nodes.count)
    }

    @Test func childrenEdgeAlignAtLevelGap() {
        let (root, nodes) = uniformTree(mains: 2, subs: 0)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .logicRight)
        for m in nodes[root]!.children {
            let f = r.frames[m]!
            #expect(abs(f.rect.minX - 144) < 0.001, "\(f)")
        }
    }

    @Test func noOverlapsInLogicChart() {
        let (root, nodes) = uniformTree(mains: 6, subs: 4)
        for structure in [LayoutStructure.logicRight, .mindmapBalanced, .orgDown] {
            let r = TreeLayout.layout(root: root, nodes: nodes, structure: structure)
            let rects = r.frames.values.map(\.rect)
            for i in rects.indices {
                for j in rects.indices where j > i {
                    #expect(!rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j].insetBy(dx: 1, dy: 1)), "\(structure)")
                }
            }
        }
    }

    @Test func orgChartGoesDown() {
        let (root, nodes) = uniformTree(mains: 3, subs: 2)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .orgDown)
        for m in nodes[root]!.children {
            #expect(r.frames[m]!.center.y > r.frames[root]!.center.y)
            #expect(r.frames[m]!.side == .down)
        }
    }

    @Test func siblingsKeepOrderTopToBottom() {
        let (root, nodes) = uniformTree(mains: 4, subs: 3)
        let r = TreeLayout.layout(root: root, nodes: nodes, structure: .logicRight)
        let ys = nodes[root]!.children.map { r.frames[$0]!.center.y }
        #expect(ys == ys.sorted())
    }
}
