import Foundation
import NexusCore

/// Turning the state into the document, rebuilding only what ops touched. A canvas whose
/// tree, settings or elements changed is walked whole (cached topics are reused unless
/// their fields changed); a canvas where only topic fields changed rebuilds those topics.
/// Either way the result is what building everything from scratch gives, so live replicas
/// and late joiners agree byte for byte.
extension Replica {
    mutating func materialize() -> Changes {
        let d = state.dirty
        state.dirty = ReplicaState.Dirty()
        var out = Changes()
        guard !d.isEmpty else { return out }

        if d.assets {
            for (k, v) in state.assets where doc.assets[k] == nil {
                out.assets[k] = v
                doc.assets[k] = v
            }
        }

        // Canvases added or removed, the tab order, the theme. A canvas placed before its
        // root arrived is added once it can be built.
        let present = presentCanvases()
        let placed = Set(present)
        var docPatch = Patch(canvasID: doc.canvasOrder.first ?? present.first ?? "c1")
        var added = Set<CanvasID>()
        let candidates =
            d.canvasSet ? Set(doc.canvases.keys).union(placed) : d.structure.union(d.nodes.keys)
        for id in candidates.sorted() {
            if placed.contains(id), doc.canvases[id] == nil {
                guard let c = buildCanvas(id, cache: nil, rebuild: []) else { continue }
                var repairedCanvas = c
                repairIfNeeded(id, &repairedCanvas)
                docPatch.canvases[id] = Patch.CanvasChange(before: nil, after: repairedCanvas)
                added.insert(id)
            } else if !placed.contains(id), let old = doc.canvases[id] {
                docPatch.canvases[id] = Patch.CanvasChange(before: old, after: nil)
            }
        }
        let order = present.filter { (doc.canvases[$0] != nil && docPatch.canvases[$0] == nil) || added.contains($0) }
        if order != doc.canvasOrder {
            docPatch.orderBefore = doc.canvasOrder
            docPatch.orderAfter = order
        }
        if d.theme {
            let t = buildTheme()
            if t != doc.theme {
                docPatch.themeBefore = doc.theme
                docPatch.themeAfter = t
            }
        }
        if !docPatch.isEmpty {
            if let first = docPatch.orderAfter?.first ?? present.first { docPatch.canvasID = first }
            doc.apply(docPatch)
            out.patches.append(docPatch)
        }

        // Each canvas already here.
        for c in d.structure.union(d.nodes.keys).sorted() where !added.contains(c) {
            guard let cache = doc.canvases[c] else { continue }
            let dirtyNodes = d.nodes[c] ?? []
            let structural =
                d.structure.contains(c)
                || dirtyNodes.contains { repaired[c]?.contains($0) == true || hasDependencies(c, $0) }
            guard
                let p = structural
                    ? structuralPatch(c, cache: cache, rebuild: dirtyNodes) : fieldPatch(c, cache, dirtyNodes),
                !p.isEmpty
            else { continue }
            doc.apply(p)
            out.patches.append(p)
        }
        return out
    }

    /// Canvases that are placed, in tab order.
    func presentCanvases() -> [CanvasID] {
        state.canvasPlaces.compactMap { id, p in p.position.map { (id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    func buildTheme() -> JSONValue {
        var o: [String: JSONValue] = [:]
        for (k, r) in state.theme { if let v = r.value { o[k] = v } }
        return .object(o)
    }

    /// True when the topic's task waits for others (a repair may trim it when they go).
    func hasDependencies(_ c: CanvasID, _ n: NodeID) -> Bool {
        guard case .array(let a)? = state.canvases[c]?.fields[n]?["todo"]?.value?["after"] else { return false }
        return !a.isEmpty
    }

    // MARK: Canvases

    /// The canvas's settings and elements, without topics.
    func buildMeta(_ c: CanvasID, _ cs: CanvasState) -> Canvas? {
        var o: [String: JSONValue] = [:]
        for (k, r) in cs.meta where !Self.structural.contains(k) { if let v = r.value { o[k] = v } }
        for (p, regs) in cs.parts {
            var sub: [String: JSONValue] = [:]
            for (k, r) in regs { if let v = r.value { sub[k] = v } }
            if !sub.isEmpty { o[p] = .object(sub) }
        }
        for kind in Self.elementKinds {
            let items = (cs.elementPlaces[kind] ?? [:]).compactMap { id, p in p.position.map { (id, $0) } }
                .sorted { $0.1 < $1.1 }
            guard !items.isEmpty else { continue }
            o[kind] = .array(
                items.map { id, _ in
                    var e: [String: JSONValue] = [:]
                    for (k, r) in cs.elementFields[kind]?[id] ?? [:] { if let v = r.value { e[k] = v } }
                    e["id"] = .string(id)
                    return .object(e)
                })
        }
        guard let root = o["root"]?.stringValue else { return nil }
        o["id"] = .string(c.rawValue)
        o["nodes"] = .object([root: .object(["text": .string("")])])
        guard var canvas = try? Canvas(json: .object(o), path: c.rawValue) else { return nil }
        canvas.nodes = [:]
        return canvas
    }

    func buildNode(_ c: CanvasID, _ id: NodeID, _ cs: CanvasState, children: [NodeID]) -> Node? {
        guard let regs = cs.fields[id] else { return nil }
        var o: [String: JSONValue] = [:]
        for (k, r) in regs where k != "children" && k != "comments" { if let v = r.value { o[k] = v } }
        guard !o.isEmpty else { return nil }
        o["children"] = .array(children.map { .string($0.rawValue) })
        let comments = (cs.commentPlaces[id] ?? [:]).compactMap { k, p in p.position.map { (k, $0) } }
            .sorted { $0.1 < $1.1 }
            .compactMap { k, _ in cs.comments[id]?[k]?.value }
        if !comments.isEmpty { o["comments"] = .array(comments) }
        return try? Node(json: .object(o), path: id.rawValue)
    }

    /// The canvas from the state. Cached topics are reused unless they're in `rebuild`, a
    /// repair changed them, or their task waits for others; their children are always
    /// the tree's. Nil when the state has no usable root.
    func buildCanvas(_ c: CanvasID, cache: Canvas?, rebuild: Set<NodeID>) -> Canvas? {
        guard let cs = state.canvases[c], var canvas = buildMeta(c, cs) else { return nil }
        let tree = cs.tree
        let repairedHere = repaired[c] ?? []
        var nodes: [NodeID: Node] = [:]
        nodes.reserveCapacity(cache?.nodes.count ?? cs.fields.count)

        // Tops: the root, floating topics, and the topics of summaries and callouts.
        var tops = [canvas.root]
        let floating = tree.children(.floating).filter { $0 != canvas.root }
        tops += floating
        tops += (canvas.summaries.map(\.topic) + canvas.callouts.map(\.topic)).filter {
            tree.entries[$0]?.parent == .attached
        }

        func node(_ id: NodeID) -> Node? {
            let kids = tree.children(.node(id))
            if let cached = cache?.nodes[id], !rebuild.contains(id), !repairedHere.contains(id),
                !hasDependencies(c, id)
            {
                var n = cached
                if n.children != kids { n.children = kids }
                return n
            }
            return buildNode(c, id, cs, children: kids)
        }

        var stack: [NodeID] = []
        for top in tops.reversed() where nodes[top] == nil { stack.append(top) }
        var visited = Set<NodeID>()
        while let id = stack.popLast() {
            guard visited.insert(id).inserted, let n = node(id) else { continue }
            nodes[id] = n
            for k in n.children.reversed() where !visited.contains(k) { stack.append(k) }
        }
        // A topic that couldn't be built drops out of its parent's list.
        let built = Set(nodes.keys)
        for (id, n) in nodes where n.children.contains(where: { !built.contains($0) }) {
            nodes[id]?.children = n.children.filter { built.contains($0) }
        }
        canvas.floating = floating.filter { nodes[$0] != nil }
        canvas.nodes = nodes
        canvas.nextSequence = (nodes.keys.compactMap(\.sequence).max() ?? 0) + 1
        return canvas
    }

    /// A patch from the cached canvas to the rebuilt one, after the deterministic repair.
    mutating func structuralPatch(_ c: CanvasID, cache: Canvas, rebuild: Set<NodeID>) -> Patch? {
        guard var canvas = buildCanvas(c, cache: cache, rebuild: rebuild) else { return nil }
        repairIfNeeded(c, &canvas)
        return diff(cache, canvas)
    }

    /// Only topic fields changed: rebuild those topics.
    mutating func fieldPatch(_ c: CanvasID, _ cache: Canvas, _ ids: Set<NodeID>) -> Patch? {
        guard let cs = state.canvases[c] else { return nil }
        var p = Patch(canvasID: c)
        for id in ids {
            guard let old = cache.nodes[id], let n = buildNode(c, id, cs, children: old.children), n != old else {
                continue
            }
            p.nodes[id] = Patch.NodeChange(before: old, after: n)
        }
        return p
    }

    /// Runs `repair()` when concurrent edits left something dangling (a relationship to a
    /// deleted topic), and remembers the topics it changed.
    mutating func repairIfNeeded(_ c: CanvasID, _ canvas: inout Canvas) {
        guard !canvas.validate().isEmpty else {
            repaired[c] = nil
            return
        }
        let before = canvas.nodes
        canvas.repair()
        var changed = Set<NodeID>()
        for (id, n) in canvas.nodes where before[id] != n { changed.insert(id) }
        repaired[c] = changed.isEmpty ? nil : changed
    }

    func diff(_ a: Canvas, _ b: Canvas) -> Patch {
        var p = Patch(canvasID: a.id)
        for (id, n) in b.nodes where a.nodes[id] != n {
            p.nodes[id] = Patch.NodeChange(before: a.nodes[id], after: n)
        }
        for (id, n) in a.nodes where b.nodes[id] == nil {
            p.nodes[id] = Patch.NodeChange(before: n, after: nil)
        }
        var ma = a
        ma.nodes = [:]
        var mb = b
        mb.nodes = [:]
        if ma != mb {
            p.metaBefore = ma
            p.metaAfter = mb
        }
        return p
    }
}
