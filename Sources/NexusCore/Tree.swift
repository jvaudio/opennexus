import Foundation

/// Read-only tree queries. The file stores only `children`, so parents are derived.
extension Canvas {
    /// The top of every tree on the canvas: the root, floating topics, summary topics and
    /// callout topics.
    public var tops: [NodeID] {
        [root] + floating + summaries.map(\.topic) + callouts.map(\.topic)
    }

    /// Maps every attached node to its parent.
    public func parentMap() -> [NodeID: NodeID] {
        var map: [NodeID: NodeID] = [:]
        map.reserveCapacity(nodes.count)
        for (id, node) in nodes {
            for child in node.children { map[child] = id }
        }
        return map
    }

    public func parent(of id: NodeID) -> NodeID? {
        nodes.first { $0.value.children.contains(id) }?.key
    }

    /// 0 for the root and floating topics, 1 for main topics, and so on.
    public func depth(of id: NodeID, parents: [NodeID: NodeID]? = nil) -> Int {
        let parents = parents ?? parentMap()
        var d = 0
        var cur = id
        while let p = parents[cur] {
            d += 1
            cur = p
        }
        return d
    }

    /// The top of the tree the node belongs to (the root or a floating topic).
    public func treeTop(of id: NodeID, parents: [NodeID: NodeID]) -> NodeID {
        var cur = id
        while let p = parents[cur] { cur = p }
        return cur
    }

    /// Depth-first, pre-order list of a subtree.
    public func subtree(_ id: NodeID, includeFolded: Bool = true) -> [NodeID] {
        var out: [NodeID] = []
        var stack = [id]
        while let cur = stack.popLast() {
            guard let node = nodes[cur] else { continue }
            out.append(cur)
            if includeFolded || !node.folded || cur == id {
                stack.append(contentsOf: node.children.reversed())
            }
        }
        return out
    }

    /// Every node visible on the canvas: the root tree and floating trees, minus folded descendants.
    public func visibleNodes() -> [NodeID] {
        var out: [NodeID] = []
        for top in tops {
            var stack = [top]
            while let cur = stack.popLast() {
                guard let node = nodes[cur] else { continue }
                out.append(cur)
                if !node.folded { stack.append(contentsOf: node.children.reversed()) }
            }
        }
        return out
    }

    /// Count of hidden descendants under a folded node (the fold badge).
    public func hiddenCount(under id: NodeID) -> Int {
        guard let node = nodes[id], node.folded else { return 0 }
        return subtree(id).count - 1
    }

    /// The main topic (depth 1) this node descends from, used for branch colour.
    public func mainBranch(of id: NodeID, parents: [NodeID: NodeID]) -> NodeID? {
        var cur = id
        while let p = parents[cur] {
            if p == root { return cur }
            cur = p
        }
        return nil
    }

    /// Checks structural invariants. Returns a list of problems (empty when valid).
    public func validate() -> [String] {
        var problems: [String] = []
        if nodes[root] == nil { problems.append("root \(root) missing") }
        var seen: [NodeID: NodeID] = [:]
        for (id, node) in nodes {
            for c in node.children {
                if nodes[c] == nil { problems.append("\(id) has missing child \(c)") }
                if let other = seen[c] { problems.append("\(c) has two parents: \(other) and \(id)") }
                seen[c] = id
            }
        }
        if seen[root] != nil { problems.append("root \(root) has a parent") }
        for f in tops.dropFirst() {
            if nodes[f] == nil { problems.append("top \(f) missing") }
            if seen[f] != nil { problems.append("top \(f) has a parent") }
        }
        for b in boundaries where b.nodes.contains(where: { nodes[$0] == nil }) {
            problems.append("boundary \(b.id) wraps a missing node")
        }
        for s in summaries where [s.parent, s.from, s.to].contains(where: { nodes[$0] == nil }) {
            problems.append("summary \(s.id) points at a missing node")
        }
        for c in callouts where nodes[c.host] == nil { problems.append("callout \(c.id) host is missing") }
        for z in zones where z.members.contains(where: { !floating.contains($0) }) {
            problems.append("zone \(z.id) holds a topic that is not floating")
        }
        // Every node must be reachable from the root or a floating topic.
        var reachable = Set<NodeID>()
        for top in tops {
            var stack = [top]
            while let cur = stack.popLast() {
                guard reachable.insert(cur).inserted, let n = nodes[cur] else { continue }
                stack.append(contentsOf: n.children)
            }
        }
        for id in nodes.keys where !reachable.contains(id) {
            problems.append("\(id) is unreachable")
        }
        for r in relationships where nodes[r.from] == nil || nodes[r.to] == nil {
            problems.append("relationship \(r.id) points at a missing node")
        }
        return problems.sorted()
    }
}

extension Canvas {
    /// The deepest nesting OpenNexus creates or opens (deeper branches are moved to
    /// floating topics on load). Layout and drawing recurse by depth, and no real map
    /// comes near it.
    public static let maxDepth = 256

    /// Pre-order walk of the main tree (root first), with depth (root = 0). Iterative,
    /// so a damaged file can't exhaust the stack.
    public func walk(_ visit: (NodeID, Node, Int) -> Void) {
        walk(from: root, visit)
    }

    /// Levels below `id` (0 for a leaf).
    public func height(of id: NodeID) -> Int {
        var h = 0
        walk(from: id) { _, _, d in h = max(h, d) }
        return h
    }

    /// Walks one branch from `top` (depth 0 at `top`).
    public func walk(from top: NodeID, _ visit: (NodeID, Node, Int) -> Void) {
        var stack: [(NodeID, Int)] = [(top, 0)]
        while let (id, d) = stack.popLast() {
            guard let n = nodes[id] else { continue }
            visit(id, n, d)
            for c in n.children.reversed() { stack.append((c, d + 1)) }
        }
    }
}
