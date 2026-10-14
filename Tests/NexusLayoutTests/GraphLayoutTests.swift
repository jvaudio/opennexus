import CoreGraphics
import Testing

@testable import NexusCore
@testable import NexusLayout

@Suite struct GraphLayoutTests {
    /// The S5 password-reset flow: a decision with two branches that merge into Done.
    static func flow() -> ([NodeID: CGSize], [NodeID], [(NodeID, NodeID)]) {
        let ids: [NodeID] = ["start", "email", "exists", "token", "link", "neutral", "done"]
        var sizes: [NodeID: CGSize] = [:]
        for id in ids { sizes[id] = CGSize(width: id == "exists" ? 180 : 160, height: id == "exists" ? 100 : 44) }
        let edges: [(NodeID, NodeID)] = [
            ("start", "email"), ("email", "exists"), ("exists", "token"), ("exists", "neutral"), ("token", "link"),
            ("link", "done"), ("neutral", "done"),
        ]
        return (sizes, ids, edges)
    }

    @Test func edgesFlowForwardWithoutOverlap() {
        let (sizes, ids, edges) = Self.flow()
        let r = GraphLayout.layout(nodes: sizes, order: ids, edges: edges)
        for (a, b) in edges { #expect(r.frames[a]!.center.y < r.frames[b]!.center.y, "\(a) above \(b)") }
        let frames = Array(r.frames.values)
        for i in frames.indices {
            for j in frames.indices where j > i { #expect(!frames[i].rect.intersects(frames[j].rect)) }
        }
        // The merge sits between its two predecessors.
        let done = r.frames["done"]!.center.x
        let xs = [r.frames["link"]!.center.x, r.frames["neutral"]!.center.x].sorted()
        #expect(done >= xs[0] - 0.5 && done <= xs[1] + 0.5)
        // A straight chain stays aligned.
        #expect(abs(r.frames["start"]!.center.x - r.frames["email"]!.center.x) < 1)
    }

    @Test func cyclesStillLayOut() {
        var (sizes, ids, edges) = Self.flow()
        edges.append(("done", "start"))
        sizes["x"] = CGSize(width: 80, height: 30)
        ids.append("x")
        let r = GraphLayout.layout(nodes: sizes, order: ids, edges: edges, options: .init())
        #expect(r.frames.count == ids.count)
        #expect(r.frames["start"]!.center.y < r.frames["done"]!.center.y)
    }

    @Test func deterministic() {
        let (sizes, ids, edges) = Self.flow()
        var o = GraphLayout.Options()
        o.direction = .right
        let a = GraphLayout.layout(nodes: sizes, order: ids, edges: edges, options: o)
        let b = GraphLayout.layout(nodes: sizes, order: ids, edges: edges, options: o)
        #expect(a == b)
        for (x, y) in edges { #expect(a.frames[x]!.center.x < a.frames[y]!.center.x) }
    }

    @Test func groupsStayTogether() {
        // a feeds four nodes; b and d share a boundary and should be adjacent.
        let ids: [NodeID] = ["a", "b", "c", "d", "e"]
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGSize(width: 100, height: 40)) })
        let edges: [(NodeID, NodeID)] = [("a", "b"), ("a", "c"), ("a", "d"), ("a", "e")]
        var o = GraphLayout.Options()
        o.groups = ["b": 1, "d": 1]
        let r = GraphLayout.layout(nodes: sizes, order: ids, edges: edges, options: o)
        let row = ["b", "c", "d", "e"].sorted { r.frames[NodeID($0)]!.center.x < r.frames[NodeID($1)]!.center.x }
        let ib = row.firstIndex(of: "b")!
        let id = row.firstIndex(of: "d")!
        #expect(abs(ib - id) == 1)
    }

    @Test func swimlanesBandTheirNodes() {
        let ids: [NodeID] = ["req", "review", "approve", "done"]
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGSize(width: 120, height: 50)) })
        let edges: [(NodeID, NodeID)] = [("req", "review"), ("review", "approve"), ("approve", "done")]
        var o = GraphLayout.Options()
        o.direction = .right
        o.lanes = ["req": 0, "review": 1, "approve": 2, "done": 0]
        o.laneCount = 3
        let r = GraphLayout.layout(nodes: sizes, order: ids, edges: edges, options: o)
        #expect(r.bands.count == 3)
        for (id, lane) in o.lanes! { #expect(r.bands[lane].contains(r.frames[id]!.rect), "\(id) in lane \(lane)") }
        for (a, b) in edges { #expect(r.frames[a]!.center.x < r.frames[b]!.center.x) }
    }
}

@Suite struct SequenceLayoutTests {
    /// Artboard 23's sign-in flow.
    @Test func messagesAndActivations() {
        let ps: [NodeID] = ["user", "web", "auth", "db"]
        let sizes = Dictionary(uniqueKeysWithValues: ps.map { ($0, CGSize(width: 150, height: 44)) })
        let ms: [SequenceLayout.Message] = [
            .init(from: "user", to: "web", isReturn: false, labelWidth: 60),
            .init(from: "web", to: "auth", isReturn: false, labelWidth: 90),
            .init(from: "auth", to: "db", isReturn: false, labelWidth: 90),
            .init(from: "db", to: "auth", isReturn: true, labelWidth: 30),
            .init(from: "auth", to: "web", isReturn: true, labelWidth: 70),
            .init(from: "web", to: "user", isReturn: true, labelWidth: 70),
        ]
        let r = SequenceLayout.layout(participants: ps, sizes: sizes, messages: ms)
        #expect(r.messageY == r.messageY.sorted())
        #expect(zip(ps, ps.dropFirst()).allSatisfy { r.frames[$0]!.rect.maxX < r.frames[$1]!.rect.minX })
        // Each callee is active from its call to its return; the initiator has no bar.
        #expect(r.activations["web"] == [r.messageY[0]...r.messageY[5]])
        #expect(r.activations["auth"] == [r.messageY[1]...r.messageY[4]])
        #expect(r.activations["db"] == [r.messageY[2]...r.messageY[3]])
        #expect(r.activations["user"] == nil)
        #expect(r.lifelineBottom > r.messageY.last!)
    }
}
