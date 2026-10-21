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
        f.relationships = relationships.filter { $0.connects(within: keep) }
        f.boundaries = boundaries.filter { !$0.nodes.isEmpty && Set($0.nodes).isSubset(of: keep) }
        f.summaries = summaries.filter {
            keep.contains($0.parent) && keep.contains($0.from) && keep.contains($0.to) && keep.contains($0.topic)
        }
        for s in f.summaries { f.nodes[s.topic] = nodes[s.topic] }
        f.nextSequence = Canvas.seed(for: f.nodes.keys)
        return f
    }
}

extension Canvas {
    /// Zones as a fragment (copy and cut on a selected zone, D196): each zone with its
    /// members' branches where they sit, plus the boundaries and summaries inside them and
    /// every relationship that touches the copy. A relationship with an end outside the copy
    /// travels too; only a paste back into this canvas keeps it. The placeholder root lists
    /// the members, so a build that predates zone paste pastes their branches as topics.
    public func zoneFragment(_ ids: [String]) -> Canvas {
        let picked = zones.filter { ids.contains($0.id) }.map { z in
            var x = z
            x.members = z.members.filter { nodes[$0] != nil }
            return x
        }
        let members = picked.flatMap(\.members)
        var f = fragment(members)
        // `fragment` attaches its tops; a zone copy keeps them floating where they are.
        for m in members { f.nodes[m] = nodes[m] }
        f.floating = members
        f.zones = picked
        let inside = Set(f.nodes.keys)
        let zoneIDs = Set(picked.map(\.id))
        func within(_ e: RelationshipEnd) -> Bool {
            e.topic.map(inside.contains) ?? e.zone.map(zoneIDs.contains) ?? false
        }
        f.relationships = relationships.filter { within($0.from) || within($0.to) }
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
        // Dependencies outside the branch survive only within the same canvas (Duplicate
        // Branch, paste back into the source).
        insertCopies(of: src, map, sameCanvas: src.id == canvas.id) { old, n in
            guard old == top else { return }
            n.kind = .topic
            n.position = nil
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
        let rels = src.relationships.filter { $0.connects(within: Set(map.keys)) }
        copyElements(of: src, nodes: map, relationships: rels, sameCanvas: false)
        return newTop
    }

    /// Pastes a zone fragment (`Canvas.zoneFragment`) moved by `dx`, `dy`: each zone gets a
    /// fresh id, its members land as floating topics at their copied positions plus the
    /// offset, and relationships follow the copy. One whose other end is outside the copy
    /// is kept only when `sameCanvas` and that end is still here, as `graft` does for
    /// dependencies (D196). Returns the new zones' ids.
    @discardableResult
    public mutating func pasteZones(_ f: Canvas, by dx: Double, _ dy: Double, sameCanvas: Bool) -> [String] {
        guard !f.zones.isEmpty else { return [] }
        let tops = f.zones.flatMap(\.members).filter { f.nodes[$0] != nil }
        var map: [NodeID: NodeID] = [:]
        for t in tops { for id in f.subtree(t) { map[id] = makeNodeID() } }
        for s in f.summaries where map[s.parent] != nil && map[s.from] != nil && map[s.to] != nil {
            map[s.topic] = map[s.topic] ?? makeNodeID()
        }
        let topSet = Set(tops)
        insertCopies(of: f, map, sameCanvas: sameCanvas) { old, n in
            guard topSet.contains(old) else { return }
            let p = n.position ?? CanvasPoint(x: 0, y: 0)
            n.kind = .floating
            n.position = CanvasPoint(x: p.x + dx, y: p.y + dy)
        }
        var zones: [String: String] = [:]
        updateMeta { c in
            for z in f.zones {
                var x = z
                x.id = Self.fresh("z", c.zones.map(\.id))
                x.origin = CanvasPoint(x: z.origin.x + dx, y: z.origin.y + dy)
                x.members = z.members.compactMap { map[$0] }
                zones[z.id] = x.id
                c.zones.append(x)
            }
            c.floating.append(contentsOf: tops.compactMap { map[$0] })
        }
        copyElements(of: f, nodes: map, zones: zones, relationships: f.relationships, sameCanvas: sameCanvas)
        return f.zones.compactMap { zones[$0.id] }
    }

    /// Pastes a zone fragment with the top-left corner of its zones at `origin`.
    @discardableResult
    public mutating func pasteZones(_ f: Canvas, at origin: CanvasPoint, sameCanvas: Bool) -> [String] {
        guard let x = f.zones.map(\.origin.x).min(), let y = f.zones.map(\.origin.y).min() else { return [] }
        return pasteZones(f, by: origin.x - x, origin.y - y, sameCanvas: sameCanvas)
    }

    /// Inserts copies of `src`'s nodes under their new ids in `map`, with children, topic
    /// links and dependencies following the copy. A dependency on a topic outside it
    /// survives only when `sameCanvas` and that topic is here. `adjust` changes a copy
    /// before it's inserted (the tops).
    private mutating func insertCopies(
        of src: Canvas, _ map: [NodeID: NodeID], sameCanvas: Bool, adjust: (NodeID, inout Node) -> Void
    ) {
        for (old, new) in map {
            guard var n = src.nodes[old] else { continue }
            n.children = n.children.compactMap { map[$0] }
            adjust(old, &n)
            if let link = n.link, let t = TopicLink.parse(link), t.canvas == src.id, let m = map[t.node] {
                n.link = TopicLink.make(canvas: canvas.id, node: m)
            }
            if var t = n.todo, !t.after.isEmpty {
                t.after = t.after.compactMap { d in
                    if let m = map[d.task] {
                        var x = d
                        x.task = m
                        return x
                    }
                    return sameCanvas && canvas.nodes[d.task] != nil ? d : nil
                }
                n.todo = t
            }
            insert(n, as: new)
        }
    }

    /// Adds copies of `rels` and of the boundaries and summaries wholly inside `map`, with
    /// fresh ids. A relationship end the copy carries moves to its copy; any other end is
    /// kept only when `sameCanvas` and it's still here, or the relationship is dropped.
    private mutating func copyElements(
        of src: Canvas, nodes map: [NodeID: NodeID], zones: [String: String] = [:], relationships rels: [Relationship],
        sameCanvas: Bool
    ) {
        let bounds = src.boundaries.filter { !$0.nodes.isEmpty && $0.nodes.allSatisfy { map[$0] != nil } }
        let sums = src.summaries.filter { map[$0.parent] != nil && map[$0.from] != nil && map[$0.to] != nil }
        guard !rels.isEmpty || !bounds.isEmpty || !sums.isEmpty else { return }
        updateMeta { c in
            // New ids by end kind, so an end of any kind can follow its element.
            var elements: [String: [String: String]] = ["zone": zones]
            for b in bounds {
                var x = b
                x.id = Self.fresh("b", c.boundaries.map(\.id))
                x.nodes = b.nodes.compactMap { map[$0] }
                elements["boundary", default: [:]][b.id] = x.id
                c.boundaries.append(x)
            }
            for s in sums {
                var x = s
                x.id = Self.fresh("s", c.summaries.map(\.id))
                x.parent = map[s.parent]!
                x.from = map[s.from]!
                x.to = map[s.to]!
                x.topic = map[s.topic]!
                elements["summary", default: [:]][s.id] = x.id
                c.summaries.append(x)
            }
            for r in rels {
                let ends = [r.from, r.to].map { Self.remap($0, nodes: map, elements: elements, in: c, sameCanvas) }
                guard let from = ends[0], let to = ends[1] else { continue }
                var x = r
                x.id = Self.fresh("r", c.relationships.map(\.id))
                x.from = from
                x.to = to
                c.relationships.append(x)
            }
        }
    }

    /// One relationship end after a copy: the copied topic or element, else the original
    /// when `sameCanvas` and it's on `c`, else nil.
    static func remap(
        _ end: RelationshipEnd, nodes: [NodeID: NodeID], elements: [String: [String: String]], in c: Canvas,
        _ sameCanvas: Bool
    ) -> RelationshipEnd? {
        switch end {
        case .topic(let id):
            if let m = nodes[id] { return .topic(m) }
        case .zone(let id):
            if let m = elements["zone"]?[id] { return .zone(m) }
        @unknown default:
            // Kinds added later (boundary, summary or callout ends) follow by kind and id.
            if let m = elements[end.kind]?[end.rawValue] { return RelationshipEnd(kind: end.kind, id: m) }
        }
        return sameCanvas && c.has(end) ? end : nil
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
