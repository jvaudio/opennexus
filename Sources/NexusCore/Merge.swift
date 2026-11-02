import Foundation

/// One thing both sides changed differently (M45): a topic, a canvas's settings, or a
/// whole canvas. The merge keeps a side for it (this copy's, unless a choice says
/// otherwise) and reports it, so nothing is lost silently.
public struct MergeClash: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// A topic's fields.
        case topic
        /// A canvas's title, layout, style, relationships, zones and so on.
        case settings
        /// The whole canvas: added on both sides, deleted on one and edited on the other, or
        /// a merge that wouldn't be a valid tree.
        case canvas
    }

    /// What to keep: this copy's side, the other side, or this copy's with the other side's
    /// canvas kept beside it as a conflict copy.
    public enum Choice: String, Hashable, Sendable, CaseIterable {
        case mine, theirs, both
    }

    public var kind: Kind
    public var canvas: CanvasID
    public var node: NodeID?
    /// The canvas's title, as the Resolve Conflicts sheet groups clashes.
    public var canvasTitle: String
    /// How `DocumentMerge.conflicts` names it: "“Pricing”", "canvas settings on “Plan”".
    public var label: String
    /// Each side's topic text (or canvas title), nil where that side deleted it.
    public var base: String?
    public var mine: String?
    public var theirs: String?
    /// What each side changed since the base: "text", "note", "task", "subtopics",
    /// "comments", "markers", "style", "links", "details" (the sheet says them in words).
    public var mineChanges: [String] = []
    public var theirsChanges: [String] = []

    public var id: String { "\(kind.rawValue):\(canvas.rawValue):\(node?.rawValue ?? "")" }
}

/// Three-way merge of a document changed elsewhere (an agent, the CLI, Git, another Mac
/// through sync) with the copy here. `base` is the version both came from.
///
/// Each canvas, topic and canvas setting is taken from whichever side changed it, and a
/// topic's subtopics merge as lists, so topics added under the same parent on both sides
/// all arrive. When both sides changed the same thing differently, this copy's version
/// wins unless `choices` says otherwise, and the merge reports it as a `MergeClash`. A
/// canvas whose merge wouldn't be a valid tree keeps one side whole.
///
/// Without a base (two copies with no common version, such as an iCloud conflict version
/// or a "conflicted copy" file) the merge is two-way: what only one side has is kept,
/// nothing is deleted, and every difference is a clash.
public struct DocumentMerge: Sendable {
    public var model: DocumentModel
    public var clashes: [MergeClash]
    /// The clashes' labels ("Pricing", "canvas settings on Launch plan"), for agents and the CLI.
    public var conflicts: [String] { clashes.map(\.label) }

    /// - Parameters:
    ///   - choices: by `MergeClash.id`; a clash without one keeps this copy's side.
    ///   - copySuffix: the title suffix of a conflict-copy canvas ("theirs").
    public init(
        base: DocumentModel?, current: DocumentModel, disk: DocumentModel,
        choices: [String: MergeClash.Choice] = [:], copySuffix: String = "theirs"
    ) {
        var out = current
        var clashes: [MergeClash] = []
        var copies: [(after: CanvasID, canvas: Canvas, title: String?)] = []
        let ids = Set(base?.canvases.keys ?? [:].keys).union(current.canvases.keys).union(disk.canvases.keys)
        for id in ids.sorted(by: { $0.rawValue < $1.rawValue }) {
            let b = base?.canvases[id]
            let c = current.canvases[id]
            let d = disk.canvases[id]
            if base != nil, c == b {
                out.canvases[id] = d
            } else if c == d || (base != nil && d == b) || (base == nil && (c == nil || d == nil)) {
                // Unchanged there, the same on both sides, or (two-way) only on one side.
                out.canvases[id] = c ?? d
            } else if base != nil, b == nil, let c, let d {
                // A new canvas on each side that happens to share an id: two canvases. The
                // other side's keeps the id (it may be published already); this one moves.
                out.canvases[id] = d
                copies.append((id, c, nil))
            } else if let c, let d {
                var m = CanvasMerge(base: b, mine: c, theirs: d, choices: choices)
                m.run()
                if m.result.validate().isEmpty {
                    out.canvases[id] = m.result
                    clashes += m.clashes
                    if m.clashes.contains(where: { choices[$0.id] == .both }) { copies.append((id, d, copySuffix)) }
                } else {
                    let clash = Self.canvasClash(id, b, c, d)
                    clashes.append(clash)
                    out.canvases[id] = choices[clash.id] == .theirs ? d : c
                    if choices[clash.id] == .both { copies.append((id, d, copySuffix)) }
                }
            } else {
                // Deleted on one side and edited on the other.
                let clash = Self.canvasClash(id, b, c, d)
                clashes.append(clash)
                switch choices[clash.id] {
                case .theirs: out.canvases[id] = d
                case .both: out.canvases[id] = c ?? d
                default: out.canvases[id] = c
                }
            }
        }
        if let base {
            // Tab order: this copy's if it was reordered here, else the other's; then newcomers.
            var order = current.canvasOrder == base.canvasOrder ? disk.canvasOrder : current.canvasOrder
            order = order.filter { out.canvases[$0] != nil }
            for id in disk.canvasOrder + current.canvasOrder where out.canvases[id] != nil && !order.contains(id) {
                order.append(id)
            }
            out.canvasOrder = order
            if current.theme == base.theme { out.theme = disk.theme }
        } else {
            var order = current.canvasOrder.filter { out.canvases[$0] != nil }
            for id in disk.canvasOrder where out.canvases[id] != nil && !order.contains(id) { order.append(id) }
            out.canvasOrder = order
        }
        out.canvasOrder.removeAll { out.canvases[$0] == nil }
        for (after, canvas, suffix) in copies {
            let at = out.canvasOrder.firstIndex(of: after)
            guard let new = out.add([canvas], after: at).first else { continue }
            if let suffix { out.canvases[new]?.title = "\(Self.title(canvas, canvas.id)) (\(suffix))" }
        }
        for (k, v) in disk.assets where out.assets[k] == nil { out.assets[k] = v }
        model = out
        self.clashes = clashes
    }

    /// The pre-M45 form: this copy wins every clash.
    public init(base: DocumentModel, current: DocumentModel, disk: DocumentModel) {
        self.init(base: Optional(base), current: current, disk: disk)
    }

    static func title(_ c: Canvas?, _ id: CanvasID) -> String {
        guard let c else { return id.rawValue }
        return c.title.isEmpty ? (c.nodes[c.root]?.text ?? id.rawValue) : c.title
    }

    static func canvasClash(_ id: CanvasID, _ b: Canvas?, _ c: Canvas?, _ d: Canvas?) -> MergeClash {
        let t = title(c ?? d, id)
        return MergeClash(
            kind: .canvas, canvas: id, node: nil, canvasTitle: t, label: "canvas “\(t)”", base: b.map { title($0, id) },
            mine: c.map { title($0, id) }, theirs: d.map { title($0, id) })
    }

    /// What differs between a topic and its base, as `MergeClash` names it.
    public static func changes(_ n: Node?, base: Node?) -> [String] {
        guard let n, let base, base != n else { return [] }
        var what: [String] = []
        if n.text != base.text { what.append("text") }
        if n.note != base.note { what.append("note") }
        if n.todo != base.todo { what.append("task") }
        if n.children != base.children { what.append("subtopics") }
        if n.comments != base.comments { what.append("comments") }
        if n.markers != base.markers || n.labels != base.labels { what.append("markers") }
        if n.style != base.style || n.quickStyle != base.quickStyle { what.append("style") }
        if n.link != base.link || n.attachments != base.attachments || n.image != base.image { what.append("links") }
        return what.isEmpty ? ["details"] : what
    }
}

/// One canvas's three-way (or two-way) merge.
struct CanvasMerge {
    let base: Canvas?
    var mine: Canvas
    let theirs: Canvas
    let choices: [String: MergeClash.Choice]
    var result: Canvas
    var clashes: [MergeClash] = []

    init(base: Canvas?, mine: Canvas, theirs: Canvas, choices: [String: MergeClash.Choice]) {
        self.base = base
        self.mine = mine
        self.theirs = theirs
        self.choices = choices
        result = mine
    }

    var title: String { DocumentMerge.title(mine, mine.id) }

    static func meta(_ c: Canvas) -> Canvas {
        var m = c
        m.nodes = [:]
        return m
    }

    /// A node without its subtopics, which merge as a list.
    static func fields(_ n: Node?) -> Node? {
        guard var n else { return nil }
        n.children = []
        return n
    }

    func prefersTheirs(_ clash: MergeClash) -> Bool { choices[clash.id] == .theirs }

    mutating func run() {
        // A topic added on each side under the same id (ids count up per canvas) is two
        // topics: this side's, not yet published, takes a fresh id. Without a base, the same
        // id with different text under a different parent is taken to be two topics too.
        let mineParents = Self.parents(mine)
        let theirParents = Self.parents(theirs)
        let collisions = mine.nodes.compactMap { id, n -> NodeID? in
            guard let t = theirs.nodes[id], t != n else { return nil }
            if let base { return base.nodes[id] == nil ? id : nil }
            return t.text != n.text && mineParents[id] != theirParents[id] ? id : nil
        }
        if !collisions.isEmpty {
            var used = Set(base?.nodes.keys ?? [:].keys).union(mine.nodes.keys).union(theirs.nodes.keys)
            var next = Canvas.seed(for: used)
            var map: [NodeID: NodeID] = [:]
            for id in collisions.sorted(by: { ($0.sequence ?? 0, $0.rawValue) < ($1.sequence ?? 0, $1.rawValue) }) {
                var fresh = NodeID("n\(next)")
                while used.contains(fresh) {
                    next += 1
                    fresh = NodeID("n\(next)")
                }
                used.insert(fresh)
                map[id] = fresh
            }
            if let renamed = mine.renamingNodes(map) { mine = renamed }
            result = mine
        }
        for id in Set(base?.nodes.keys ?? [:].keys).union(mine.nodes.keys).union(theirs.nodes.keys) {
            let bn = base?.nodes[id]
            let cn = mine.nodes[id]
            let dn = theirs.nodes[id]
            if base == nil {
                if cn == nil, let dn {
                    result.nodes[id] = dn
                    continue
                }
                guard let cn, let dn, cn != dn else { continue }
                mergeNode(id, bn: nil, cn: cn, dn: dn)
                continue
            }
            if cn == bn {
                result.nodes[id] = dn
            } else if dn == bn || dn == cn {
                continue
            } else if let cn, let dn {
                mergeNode(id, bn: bn, cn: cn, dn: dn)
            } else {
                // Deleted on one side and edited on the other (or added on both).
                let clash = topicClash(id, bn, cn, dn)
                clashes.append(clash)
                if prefersTheirs(clash) { result.nodes[id] = dn }
            }
        }
        repairTree()
        mergeSettings()
        // Relationships and other references whose ends the other side removed go too.
        let ends = result
        result.relationships.removeAll { !ends.has($0.from) || !ends.has($0.to) }
        result.floating.removeAll { result.nodes[$0] == nil }
    }

    /// Both sides changed this topic: its fields from one side (a clash when both changed
    /// them), its subtopics merged as lists.
    mutating func mergeNode(_ id: NodeID, bn: Node?, cn: Node, dn: Node) {
        let bf = Self.fields(bn)
        let cf = Self.fields(cn)
        let df = Self.fields(dn)
        var out: Node
        if cf == df || (bn != nil && df == bf) {
            out = cn
        } else if bn != nil, cf == bf {
            out = dn
        } else {
            let clash = topicClash(id, bn, cn, dn)
            clashes.append(clash)
            out = prefersTheirs(clash) ? dn : cn
        }
        out.children = Self.mergeList(base: bn?.children, mine: cn.children, theirs: dn.children)
        result.nodes[id] = out
    }

    func topicClash(_ id: NodeID, _ bn: Node?, _ cn: Node?, _ dn: Node?) -> MergeClash {
        MergeClash(
            kind: .topic, canvas: mine.id, node: id, canvasTitle: title,
            label: "“\((cn ?? dn)?.text ?? id.rawValue)”", base: bn?.text, mine: cn?.text, theirs: dn?.text,
            mineChanges: DocumentMerge.changes(cn, base: bn), theirsChanges: DocumentMerge.changes(dn, base: bn))
    }

    /// Subtopics: this side's order, without what the other side removed, with what it
    /// added placed after the sibling it follows there. Without a base, a union.
    static func mergeList(base: [NodeID]?, mine: [NodeID], theirs: [NodeID]) -> [NodeID] {
        if let base {
            if mine == base { return theirs }
            if theirs == base || theirs == mine { return mine }
        }
        let b = Set(base ?? [])
        let t = Set(theirs)
        var out = base == nil ? mine : mine.filter { !b.contains($0) || t.contains($0) }
        for (i, id) in theirs.enumerated() where !out.contains(id) && !b.contains(id) {
            let after = theirs[..<i].last { out.contains($0) }
            let at = after.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? (i == 0 ? 0 : out.count)
            out.insert(id, at: at)
        }
        return out
    }

    static func parents(_ c: Canvas) -> [NodeID: NodeID] {
        var out: [NodeID: NodeID] = [:]
        for (p, n) in c.nodes { for x in n.children { out[x] = p } }
        return out
    }

    /// Keeps the tree whole after taking topics from both sides:
    /// - a topic kept here whose parent the other side deleted brings its parent back (a
    ///   deleted branch with an edit inside keeps the path to the edit);
    /// - a subtopic the other side deleted, under a topic kept whole from this side, comes
    ///   back from this side, or leaves the list if this side doesn't have it either;
    /// - a topic moved under different parents on the two sides stays where this side put it.
    mutating func repairTree() {
        var mineParent: [NodeID: NodeID] = [:]
        for (p, n) in mine.nodes { for c in n.children { mineParent[c] = p } }
        let theirParent = Self.parents(theirs)
        var changed = true
        while changed {
            changed = false
            for id in Array(result.nodes.keys) {
                if let p = mineParent[id], result.nodes[p] == nil, let pn = mine.nodes[p] {
                    result.nodes[p] = pn
                    changed = true
                } else if mineParent[id] == nil, result.nodes[id] != nil, let p = theirParent[id],
                    result.nodes[p] == nil, theirs.nodes[p] != nil
                {
                    // Added on the other side under a topic this side deleted: a clash. Kept,
                    // it brings its parents back; otherwise it goes, with what's under it.
                    let clash =
                        clashes.first { $0.kind == .topic && $0.node == id }
                        ?? {
                            let c = topicClash(id, base?.nodes[id], nil, theirs.nodes[id])
                            clashes.append(c)
                            return c
                        }()
                    if prefersTheirs(clash) {
                        var q: NodeID? = p
                        while let x = q, result.nodes[x] == nil, let xn = theirs.nodes[x] {
                            result.nodes[x] = xn
                            q = theirParent[x]
                        }
                    } else {
                        removeSubtree(id)
                    }
                    changed = true
                }
            }
            for (p, n) in result.nodes {
                for c in n.children where result.nodes[c] == nil {
                    if let cn = mine.nodes[c] {
                        result.nodes[c] = cn
                    } else {
                        result.nodes[p]?.children.removeAll { $0 == c }
                    }
                    changed = true
                }
            }
        }
        var parents: [NodeID: [NodeID]] = [:]
        for (p, n) in result.nodes { for c in n.children { parents[c, default: []].append(p) } }
        for (child, ps) in parents where ps.count > 1 {
            let keep = mineParent[child].flatMap { ps.contains($0) ? $0 : nil } ?? ps.min { $0.rawValue < $1.rawValue }!
            for p in ps where p != keep { result.nodes[p]?.children.removeAll { $0 == child } }
        }
        // A topic no list holds any more (its parent came back, or kept another side's
        // list) goes back under this side's parent, after the sibling it follows there.
        let listed = Set(result.nodes.values.flatMap(\.children)).union(result.tops)
        for id in result.nodes.keys.sorted(by: { $0.rawValue < $1.rawValue }) where !listed.contains(id) {
            guard let p = mineParent[id], result.nodes[p] != nil, let siblings = mine.nodes[p]?.children,
                let i = siblings.firstIndex(of: id)
            else { continue }
            let after = siblings[..<i].last { result.nodes[p]!.children.contains($0) }
            let at = after.flatMap { result.nodes[p]!.children.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.nodes[p]!.children.insert(id, at: at)
        }
    }

    /// Removes a topic the other side added, and what's under it that this side doesn't
    /// have (this side's topics stay, and go back under their parent here).
    mutating func removeSubtree(_ id: NodeID) {
        guard mine.nodes[id] == nil, let n = result.nodes.removeValue(forKey: id) else { return }
        for c in n.children { removeSubtree(c) }
    }

    mutating func mergeSettings() {
        let bm = base.map(Self.meta)
        let cm = Self.meta(mine)
        let dm = Self.meta(theirs)
        let nodes = result.nodes
        if cm == dm || (bm != nil && dm == bm) { return }
        if bm != nil, cm == bm {
            result = dm
            result.nodes = nodes
            return
        }
        let clash = MergeClash(
            kind: .settings, canvas: mine.id, node: nil, canvasTitle: title, label: "canvas settings on “\(title)”",
            base: nil, mine: nil, theirs: nil)
        clashes.append(clash)
        if prefersTheirs(clash) {
            result = dm
            result.nodes = nodes
            return
        }
        // Relationships the other side added still come in.
        for r in theirs.relationships
        where !mine.relationships.contains(where: { $0.id == r.id })
            && !(base?.relationships.contains(where: { $0.id == r.id }) ?? false)
        {
            result.relationships.append(r)
        }
        // Floating topics the other side added stay reachable.
        for f in theirs.floating where !result.floating.contains(f) && !(base?.floating.contains(f) ?? false) {
            result.floating.append(f)
        }
    }
}

extension Canvas {
    /// The canvas with topics renamed (`old: new`) wherever an id refers to them: the
    /// topics themselves, subtopic lists, the root and floating topics, relationships,
    /// elements, diagram and schedule records, and topic links into this canvas. It works
    /// on the canvas's JSON, so every kind of reference follows; text never changes.
    public func renamingNodes(_ map: [NodeID: NodeID]) -> Canvas? {
        guard !map.isEmpty else { return self }
        let names = Dictionary(uniqueKeysWithValues: map.map { old, new in (old.rawValue, new.rawValue) })
        let text: Set<String> = [
            "text", "title", "note", "label", "name", "body", "value", "author", "alt", "caption", "description",
            "comment", "markdown", "plain", "speaker", "notes", "hint", "prompt",
        ]
        let prefix = "nexus:topic/\(id.rawValue)/"
        func walk(_ v: JSONValue, key: String?) -> JSONValue {
            switch v {
            case .string(let s):
                if let k = key, text.contains(k) { return v }
                if let n = names[s] { return .string(n) }
                if s.hasPrefix(prefix), let n = names[String(s.dropFirst(prefix.count))] { return .string(prefix + n) }
                return v
            case .array(let a): return .array(a.map { walk($0, key: key) })
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for (k, x) in o { out[names[k] ?? k] = walk(x, key: k) }
                return .object(out)
            default: return v
            }
        }
        return try? Canvas(json: walk(json, key: nil), path: id.rawValue)
    }
}
