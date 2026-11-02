import CryptoKit
import Foundation
import NexusCore
import NexusFormat

/// Local edits: a committed `Patch` becomes the fewest ops that make the state materialise
/// to the edited document. Each op is applied as it's made, so later ones see earlier ones
/// (a moved topic's new neighbours, say).
extension Replica {
    /// Records a local edit that the app has applied (the patch is applied to `doc` here
    /// too) and returns its ops, to send. `assets`: the document's assets, any new ones go out.
    @discardableResult
    public mutating func record(_ patch: Patch, assets: [String: Data] = [:], undoable: Bool = true) -> [Op] {
        precondition(state.dirty.isEmpty, "materialise remote ops before recording a local edit")
        let before = doc
        doc.apply(patch)
        var group = Group(
            canvas: patch.canvasID, selectionBefore: patch.selectionBefore, selectionAfter: patch.selectionAfter,
            actionName: patch.actionName)

        for (name, data) in assets where state.assets[name] == nil {
            emit(.asset(name, data), &group)
            doc.assets[name] = data
        }
        // Canvases added, removed or replaced, and the tab order.
        if patch.changesCanvasSet {
            placeCanvases(&group)
            for (id, change) in patch.canvases.sorted(by: { $0.key < $1.key }) {
                guard let after = change.after else { continue }
                diffCanvas(id, before: change.before, after: after, nodes: nil, meta: true, &group)
            }
        }
        if patch.themeAfter != nil, before.theme != doc.theme { diffTheme(&group) }
        let c = patch.canvasID
        if patch.canvases[c] == nil, !patch.nodes.isEmpty || patch.metaAfter != nil,
            let b = before.canvases[c], let a = doc.canvases[c]
        {
            diffCanvas(c, before: b, after: a, nodes: Set(patch.nodes.keys), meta: patch.metaAfter != nil, &group)
        }
        state.dirty = ReplicaState.Dirty()
        // One group per undoable edit, even one with no ops (a selection change), so the
        // app's undo stack and this one stay in step.
        if undoable {
            undoStack.append(group)
            redoStack.removeAll()
        }
        return group.ops.map(\.op)
    }

    /// Stamps, applies and keeps an op, with what it replaced.
    mutating func emit(_ change: Op.Change, _ group: inout Group) {
        let op = Op(clock.tick(), change)
        let before: Group.Before =
            switch change {
            case .set(let slot, _):
                .register(state.register(slot)?.value, state.register(slot)?.stamp)
            case .place(let slot, _):
                .place(state.place(slot)?.position, state.place(slot)?.stamp)
            case .move(let c, let n, _, _): .entry(state.entry(c, n))
            case .asset: .none
            }
        state.apply(op)
        group.ops.append((op, before))
    }

    // MARK: Registers

    /// Sets each register under `slot(key)` that differs from `desired` (absent keys clear).
    mutating func setRegisters(
        current: [String: Register]?, desired: [String: JSONValue], _ slot: (String) -> Slot, _ group: inout Group
    ) {
        for (k, v) in desired.sorted(by: { $0.key < $1.key }) where current?[k]?.value != v {
            emit(.set(slot(k), v), &group)
        }
        for (k, r) in (current ?? [:]).sorted(by: { $0.key < $1.key }) where r.value != nil && desired[k] == nil {
            emit(.set(slot(k), nil), &group)
        }
    }

    mutating func diffTheme(_ group: inout Group) {
        setRegisters(current: state.theme, desired: doc.theme.objectValue ?? [:], { .theme($0) }, &group)
    }

    // MARK: Places

    /// Positions for an ordered list: items already in order keep theirs (the longest
    /// run that's already sorted); the rest get new keys between their neighbours.
    /// Returns (item, key) for the items to place.
    mutating func positions(_ items: [String], current keys: [String?]) -> [(String, String)] {
        let kept = Self.longestIncreasing(keys)
        var out: [(String, String)] = []
        var left: String?
        var i = 0
        while i < items.count {
            if kept.contains(i) {
                left = keys[i]
                i += 1
                continue
            }
            var j = i
            while j < items.count, !kept.contains(j) { j += 1 }
            let right = j < items.count ? keys[j] : nil
            let run = Position.run(j - i, between: left, right, stamp: clock.tick())
            for (k, key) in run.enumerated() { out.append((items[i + k], key)) }
            left = run.last
            i = j
        }
        return out
    }

    /// Indexes of a longest strictly increasing subsequence of the non-nil keys.
    static func longestIncreasing(_ keys: [String?]) -> Set<Int> {
        var tails: [Int] = []  // index into keys of the smallest tail of each length
        var prev = [Int](repeating: -1, count: keys.count)
        for (i, k) in keys.enumerated() {
            guard let k else { continue }
            var lo = 0
            var hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if keys[tails[mid]]! < k { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out = Set<Int>()
        var cur = tails.last ?? -1
        while cur >= 0 {
            out.insert(cur)
            cur = prev[cur]
        }
        return out
    }

    mutating func placeCanvases(_ group: inout Group) {
        let order = doc.canvasOrder
        let wanted = Set(order)
        for (id, p) in state.canvasPlaces.sorted(by: { $0.key < $1.key })
        where p.position != nil && !wanted.contains(id) {
            emit(.place(.canvas(id), nil), &group)
        }
        let placed = positions(order.map(\.rawValue), current: order.map { state.canvasPlaces[$0]?.position })
        for (id, key) in placed { emit(.place(.canvas(CanvasID(id)), key), &group) }
    }

    // MARK: Canvases

    /// Ops that turn the state's canvas into `after`. `nodes`: the topics that changed (nil:
    /// all of them); `meta`: whether settings or elements did.
    mutating func diffCanvas(
        _ c: CanvasID, before: Canvas?, after a: Canvas, nodes: Set<NodeID>?, meta: Bool, _ group: inout Group
    ) {
        // A canvas made again under an id the state has seen: its old topics go.
        let stale = before == nil ? Set(state.canvases[c]?.tree.entries.keys ?? [:].keys) : []
        let ids = nodes ?? Set(a.nodes.keys).union(before?.nodes.keys ?? [:].keys).union(stale)
        if meta { diffMeta(c, a, &group) }
        // Fields and comments.
        for id in ids.sorted() {
            guard let n = a.nodes[id] else { continue }
            var desired = n.json.objectValue ?? [:]
            desired["children"] = nil
            desired["comments"] = nil
            setRegisters(current: state.canvases[c]?.fields[id], desired: desired, { .field(c, id, $0) }, &group)
            diffComments(c, id, n.comments, &group)
        }
        diffTree(c, before: before, after: a, ids: ids, meta: meta, &group)
    }

    mutating func diffMeta(_ c: CanvasID, _ a: Canvas, _ group: inout Group) {
        var m = a
        m.nodes = [:]
        let o = m.json.objectValue ?? [:]
        var top: [String: JSONValue] = [:]
        for (k, v) in o where !Self.structural.contains(k) && !Self.parts.contains(k) { top[k] = v }
        let cs = state.canvases[c]
        setRegisters(
            current: cs?.meta.filter { !Self.parts.contains($0.key) }, desired: top, { .canvas(c, $0) }, &group)
        for p in Self.parts.sorted() {
            let desired = o[p]?.objectValue ?? [:]
            setRegisters(current: state.canvases[c]?.parts[p], desired: desired, { .part(c, p, $0) }, &group)
        }
        for kind in Self.elementKinds {
            let items = (o[kind]?.arrayValue ?? []).compactMap(\.objectValue)
            let ids = items.compactMap { $0["id"]?.stringValue }
            let wanted = Set(ids)
            for (id, p) in (state.canvases[c]?.elementPlaces[kind] ?? [:]).sorted(by: { $0.key < $1.key })
            where p.position != nil && !wanted.contains(id) {
                emit(.place(.element(c, kind, id), nil), &group)
            }
            for e in items {
                guard let id = e["id"]?.stringValue else { continue }
                var fields = e
                fields["id"] = nil
                setRegisters(
                    current: state.canvases[c]?.elementFields[kind]?[id], desired: fields,
                    { .element(c, kind, id, $0) }, &group)
            }
            let current = state.canvases[c]?.elementPlaces[kind] ?? [:]
            let placed = positions(ids, current: ids.map { current[$0]?.position })
            for (id, key) in placed { emit(.place(.element(c, kind, id), key), &group) }
        }
    }

    /// A comment's key: a hash of its content, then which copy of that content it is.
    static func commentKeys(_ comments: [TopicComment]) -> [(String, JSONValue)] {
        var seen: [String: Int] = [:]
        return comments.map { cm in
            let json = cm.json
            let digest = SHA256.hash(data: Data(CanonicalJSON.compact(json).utf8)).prefix(9)
            let h = Data(digest).base64URL()
            let n = seen[h, default: 0]
            seen[h] = n + 1
            return ("\(h)#\(n)", json)
        }
    }

    mutating func diffComments(_ c: CanvasID, _ n: NodeID, _ comments: [TopicComment], _ group: inout Group) {
        let wanted = Self.commentKeys(comments)
        let keys = Set(wanted.map(\.0))
        let places = state.canvases[c]?.commentPlaces[n] ?? [:]
        for (k, p) in places.sorted(by: { $0.key < $1.key }) where p.position != nil && !keys.contains(k) {
            emit(.place(.comment(c, n, k), nil), &group)
        }
        for (k, v) in wanted where state.canvases[c]?.comments[n]?[k]?.value != v {
            emit(.set(.comment(c, n, k), v), &group)
        }
        let current = state.canvases[c]?.commentPlaces[n] ?? [:]
        let placed = positions(wanted.map(\.0), current: wanted.map { current[$0.0]?.position })
        for (k, key) in placed { emit(.place(.comment(c, n, k), key), &group) }
    }

    // MARK: Tree

    /// Moves for topics whose place changed: new parents' lists keep the topics already in
    /// order there; the rest move, in the new tree's breadth-first order so no step makes a
    /// cycle. Deleted topics go to the trash, after everything else.
    mutating func diffTree(
        _ c: CanvasID, before: Canvas?, after a: Canvas, ids: Set<NodeID>, meta: Bool, _ group: inout Group
    ) {
        var lists: [(Parent, [NodeID])] = []
        for id in ids.sorted() {
            guard let n = a.nodes[id] else { continue }
            if before?.nodes[id]?.children != n.children || state.entry(c, id) == nil
                || nodes(c, under: id) != n.children
            {
                lists.append((.node(id), n.children))
            }
        }
        if meta || before == nil { lists.append((.floating, a.floating)) }

        var moves: [(NodeID, Parent, String)] = []
        for (parent, list) in lists {
            let entries = state.canvases[c]?.tree.entries ?? [:]
            let current = list.map { id -> String? in
                guard let e = entries[id], e.parent == parent else { return nil }
                return e.position
            }
            let placed = positions(list.map(\.rawValue), current: current)
            for (id, key) in placed { moves.append((NodeID(id), parent, key)) }
        }
        if state.entry(c, a.root)?.parent != .root { moves.append((a.root, .root, "")) }
        if meta || before == nil {
            for t in a.summaries.map(\.topic) + a.callouts.map(\.topic) where state.entry(c, t)?.parent != .attached {
                moves.append((t, .attached, ""))
            }
        }
        if moves.count > 1 {
            let parents = a.parentMap()
            func depth(_ id: NodeID) -> Int {
                var d = 0
                var cur = id
                while let p = parents[cur], d <= a.nodes.count {
                    d += 1
                    cur = p
                }
                return d
            }
            moves = moves.map { ($0, depth($0.0)) }.sorted { ($0.1, $0.0.0) < ($1.1, $1.0.0) }.map(\.0)
        }
        for (id, parent, key) in moves { emit(.move(c, id, parent, key), &group) }
        let had = before.map { Set($0.nodes.keys) } ?? Set(state.canvases[c]?.tree.entries.keys ?? [:].keys)
        let gone = had.subtracting(a.nodes.keys).filter { ids.contains($0) }
        for id in gone.sorted() where state.entry(c, id)?.parent != .trash {
            emit(.move(c, id, .trash, ""), &group)
        }
    }

    /// The state's children of a topic, in order.
    func nodes(_ c: CanvasID, under id: NodeID) -> [NodeID] {
        state.canvases[c]?.tree.children(.node(id)) ?? []
    }
}
