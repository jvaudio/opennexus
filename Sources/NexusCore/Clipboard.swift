import Foundation

// MARK: Fragments (copy, paste, merge into this canvas)

extension Canvas {
    /// The selected branches as a self-contained canvas: a placeholder root whose children
    /// are copies of each selected topic's subtree, plus the relationships, boundaries and
    /// summaries wholly inside them. Used for copy, cut and "Copy canvas".
    public func fragment(_ tops: [NodeID]) -> Canvas {
        let parents = parentMap()
        // A topic whose ancestor is also selected travels with that ancestor.
        let roots = tops.filter { t in
            nodes[t] != nil && !path(to: t, parents: parents).contains { tops.contains($0) }
        }
        var f = Canvas(id: id, title: title, type: type, rootText: "")
        f.layout = layout
        f.style = style
        var keep = Set<NodeID>()
        for r in roots { keep.formUnion(subtree(r)) }
        for k in keep { f.nodes[k] = nodes[k] }
        for r in roots where r != root {
            f.nodes[r]?.kind = nodes[r]?.kind == .floating ? .topic : (nodes[r]?.kind ?? .topic)
            f.nodes[r]?.position = nil
        }
        // A copied root becomes an ordinary topic under the placeholder.
        let placeholder = NodeID("clip-root")
        f.root = placeholder
        f.nodes[placeholder] = Node(text: "", kind: .root, children: roots)
        if keep.contains(root) { f.nodes[root]?.kind = .topic }
        f.boundaries = boundaries.filter { !$0.nodes.isEmpty && Set($0.nodes).isSubset(of: keep) }
        // A summary over copied siblings comes with its own topic (which isn't their child).
        f.summaries = summaries.filter { keep.contains($0.parent) && keep.contains($0.from) && keep.contains($0.to) }
        // Relationships whose ends all travel: topics, boundaries and summaries (D181).
        f.relationships = relationships.filter { r in
            [r.from, r.to].allSatisfy { end in end.zone == nil && (end.topic.map(keep.contains) ?? f.has(end)) }
        }
        for s in f.summaries { for d in subtree(s.topic) { f.nodes[d] = nodes[d] } }
        f.nextSequence = Canvas.seed(for: f.nodes.keys)
        return f
    }
}

extension CanvasEditor {
    /// Copies `src`'s branch at `top` (with fresh ids) under `parent`. Relationships,
    /// boundaries and summaries inside the branch come along. Returns the new top.
    @discardableResult
    public mutating func graft(_ src: Canvas, top: NodeID, under parent: NodeID, at index: Int? = nil) throws -> NodeID
    {
        guard self[parent] != nil, src.nodes[top] != nil else { throw TreeOperationRefusal.missingNode }
        var map: [NodeID: NodeID] = [:]
        let ids = src.subtree(top)
        for id in ids { map[id] = makeNodeID() }
        for s in src.summaries where map[s.parent] != nil && map[s.from] != nil && map[s.to] != nil {
            map[s.topic] = map[s.topic] ?? makeNodeID()
        }
        for (old, new) in map {
            guard var n = src.nodes[old] else { continue }
            n.children = n.children.compactMap { map[$0] }
            if old == top {
                n.kind = .topic
                n.position = nil
            }
            if let link = n.link, let t = TopicLink.parse(link), t.canvas == src.id, let m = map[t.node] {
                n.link = TopicLink.make(canvas: canvas.id, node: m)
            }
            // Dependencies inside the branch follow it; ones outside survive only within
            // the same canvas (Duplicate Branch, paste back into the source).
            if var t = n.todo, !t.after.isEmpty {
                t.after = t.after.compactMap { d in
                    if let m = map[d.task] {
                        var x = d
                        x.task = m
                        return x
                    }
                    return src.id == canvas.id && canvas.nodes[d.task] != nil ? d : nil
                }
                n.todo = t
            }
            insert(n, as: new)
        }
        let newTop = map[top]!
        update(parent) {
            $0.folded = false
            if let index, index <= $0.children.count {
                $0.children.insert(newTop, at: index)
            } else {
                $0.children.append(newTop)
            }
        }
        let bounds = src.boundaries.filter { !$0.nodes.isEmpty && $0.nodes.allSatisfy { map[$0] != nil } }
        let sums = src.summaries.filter { map[$0.parent] != nil && map[$0.from] != nil && map[$0.to] != nil }
        // Relationships come along when every end does: a topic, boundary or summary of the
        // branch (D181). Zones stay behind, and so do relationships to them.
        let carried = Set(bounds.map { RelationshipEnd.boundary($0.id) } + sums.map { .summary($0.id) })
        let rels = src.relationships.filter { r in
            [r.from, r.to].allSatisfy { $0.topic.map { map[$0] != nil } ?? carried.contains($0) }
        }
        if !rels.isEmpty || !bounds.isEmpty || !sums.isEmpty {
            updateMeta { c in
                var ends: [RelationshipEnd: RelationshipEnd] = [:]
                for b in bounds {
                    var x = b
                    x.id = Self.fresh("b", c.boundaries.map(\.id))
                    x.nodes = b.nodes.compactMap { map[$0] }
                    c.boundaries.append(x)
                    ends[.boundary(b.id)] = .boundary(x.id)
                }
                for s in sums {
                    var x = s
                    x.id = Self.fresh("s", c.summaries.map(\.id))
                    x.parent = map[s.parent]!
                    x.from = map[s.from]!
                    x.to = map[s.to]!
                    x.topic = map[s.topic]!
                    c.summaries.append(x)
                    ends[.summary(s.id)] = .summary(x.id)
                }
                func moved(_ e: RelationshipEnd) -> RelationshipEnd { e.topic.map { .topic(map[$0]!) } ?? ends[e]! }
                for r in rels {
                    var x = r
                    x.id = Self.fresh("r", c.relationships.map(\.id))
                    x.from = moved(r.from)
                    x.to = moved(r.to)
                    c.relationships.append(x)
                }
            }
        }
        return newTop
    }

    static func fresh(_ prefix: String, _ used: [String]) -> String {
        var i = used.count + 1
        while used.contains("\(prefix)\(i)") { i += 1 }
        return "\(prefix)\(i)"
    }

    /// Pastes a fragment: each of its top-level topics becomes a child of `parent`.
    @discardableResult
    public mutating func paste(_ fragment: Canvas, under parent: NodeID) throws -> [NodeID] {
        let tops = fragment.nodes[fragment.root]?.children ?? []
        return try tops.map { try graft(fragment, top: $0, under: parent) }
    }
}

// MARK: Adding canvases (merge as canvases, import, duplicate)

extension DocumentModel {
    /// Adds canvases with fresh ids (topic links and level references are rewritten),
    /// after `index` in the tab order (at the end by default). Returns the new ids.
    @discardableResult
    public mutating func add(_ incoming: [Canvas], assets: [String: Data] = [:], after index: Int? = nil) -> [CanvasID]
    {
        var map: [CanvasID: CanvasID] = [:]
        for c in incoming {
            var i = canvases.count + 1
            var id = CanvasID("c\(i)")
            while canvases[id] != nil || map.values.contains(id) {
                i += 1
                id = CanvasID("c\(i)")
            }
            map[c.id] = id
        }
        var at = index.map { min($0 + 1, canvasOrder.count) } ?? canvasOrder.count
        var out: [CanvasID] = []
        for var c in incoming {
            let id = map[c.id]!
            c.id = id
            for (nid, n) in c.nodes {
                if let link = n.link, let t = TopicLink.parse(link), let m = map[t.canvas] {
                    c.nodes[nid]?.link = TopicLink.make(canvas: m, node: t.node)
                }
                if let s = n.subCanvas { c.nodes[nid]?.subCanvas = map[s] ?? s }
            }
            if let p = c.diagram.parent, let m = map[p.canvas] { c.diagram.parent?.canvas = m }
            canvases[id] = c
            canvasOrder.insert(id, at: at)
            at += 1
            out.append(id)
        }
        for (k, v) in assets where self.assets[k] == nil { self.assets[k] = v }
        return out
    }
}
