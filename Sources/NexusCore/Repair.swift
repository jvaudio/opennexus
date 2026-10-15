import Foundation

extension Canvas {
    /// Makes a damaged canvas structurally valid without losing topics (M10): a file
    /// edited by hand, merged badly in Git, or cut short can still be opened.
    ///
    /// - A child that's missing, the root, a top, or already placed elsewhere (a second
    ///   parent or a cycle) is dropped from that parent's list; the first parent in
    ///   tree order keeps it.
    /// - Topics no tree reaches become floating topics.
    /// - Relationships, boundaries, summaries, callouts and zones that point at missing
    ///   topics are dropped or trimmed.
    ///
    /// Returns what was repaired (empty for a valid canvas). Afterwards `validate()` is empty.
    @discardableResult
    public mutating func repair() -> [String] {
        var fixes: [String] = []
        // Elements whose anchors are gone.
        let summaryCount = summaries.count
        summaries.removeAll { s in [s.parent, s.from, s.to, s.topic].contains { nodes[$0] == nil } || s.topic == root }
        if summaries.count < summaryCount {
            fixes.append("\(summaryCount - summaries.count) summaries without their topics")
        }
        let calloutCount = callouts.count
        callouts.removeAll { c in nodes[c.host] == nil || nodes[c.topic] == nil || c.topic == root || c.topic == c.host
        }
        if callouts.count < calloutCount {
            fixes.append("\(calloutCount - callouts.count) callouts without their topics")
        }
        var seenTops = Set<NodeID>([root])
        let floatingCount = floating.count
        floating = floating.filter { nodes[$0] != nil && seenTops.insert($0).inserted }
        if floating.count < floatingCount { fixes.append("\(floatingCount - floating.count) floating topic entries") }
        for s in summaries where !seenTops.insert(s.topic).inserted {
            fixes.append("summary \(s.id) reuses a topic")
        }
        summaries.removeAll { s in floating.contains(s.topic) }
        var used = Set([root] + floating)
        summaries = summaries.filter { used.insert($0.topic).inserted }
        callouts = callouts.filter { used.insert($0.topic).inserted }

        // Children: walk from every top; the first parent to claim a topic keeps it.
        var placed = Set(tops)
        var dropped = 0
        func walk(from top: NodeID) {
            var stack = [top]
            while let cur = stack.popLast() {
                guard let n = nodes[cur] else { continue }
                let kept = n.children.filter { c in
                    guard nodes[c] != nil, !placed.contains(c) else { return false }
                    placed.insert(c)
                    return true
                }
                if kept.count != n.children.count {
                    dropped += n.children.count - kept.count
                    nodes[cur]?.children = kept
                }
                stack.append(contentsOf: kept.reversed())
            }
        }
        for t in tops { walk(from: t) }
        if dropped > 0 { fixes.append("\(dropped) broken or repeated child links") }

        // Unreached topics become floating, starting with those no other unreached topic lists.
        var orphans = 0
        while true {
            let rest = nodes.keys.filter { !placed.contains($0) }
            guard !rest.isEmpty else { break }
            let listed = Set(rest.flatMap { nodes[$0]?.children ?? [] })
            let next = rest.filter { !listed.contains($0) }.min() ?? rest.min()!
            floating.append(next)
            nodes[next]?.kind = .floating
            placed.insert(next)
            orphans += 1
            walk(from: next)
        }
        if orphans > 0 { fixes.append("\(orphans) unreachable topics kept as floating topics") }

        // Branches nested deeper than maxDepth become floating topics (each piece keeps
        // its own subtree, up to the limit again).
        var lifted = 0
        var queue = tops
        while let top = queue.popLast() {
            var stack: [(NodeID, Int)] = [(top, 0)]
            while let (id, d) = stack.popLast() {
                guard let n = nodes[id] else { continue }
                if d == Canvas.maxDepth - 1, !n.children.isEmpty {
                    for c in n.children {
                        floating.append(c)
                        nodes[c]?.kind = .floating
                        queue.append(c)
                        lifted += 1
                    }
                    nodes[id]?.children = []
                    continue
                }
                for c in n.children { stack.append((c, d + 1)) }
            }
        }
        if lifted > 0 {
            fixes.append("\(lifted) branches nested over \(Canvas.maxDepth) levels moved to floating topics")
        }

        let relCount = relationships.count
        relationships.removeAll { nodes[$0.from] == nil || nodes[$0.to] == nil }
        if relationships.count < relCount {
            fixes.append("\(relCount - relationships.count) relationships to missing topics")
        }
        var trimmed = 0
        for i in boundaries.indices {
            let before = boundaries[i].nodes.count
            boundaries[i].nodes.removeAll { nodes[$0] == nil }
            trimmed += before - boundaries[i].nodes.count
        }
        boundaries.removeAll { $0.nodes.isEmpty }
        for i in zones.indices {
            let before = zones[i].members.count
            zones[i].members.removeAll { !floating.contains($0) }
            trimmed += before - zones[i].members.count
        }
        if trimmed > 0 { fixes.append("\(trimmed) boundary or zone members that are missing") }
        return fixes
    }
}
