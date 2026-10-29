import Foundation
import NexusCore

/// A value and the stamp of the op that set it.
public struct Register: Hashable, Sendable {
    public var value: JSONValue?
    public var stamp: Stamp
}

/// An ordered-set member's position (nil: removed) and the stamp that set it.
public struct Place: Hashable, Sendable {
    public var position: String?
    public var stamp: Stamp
}

/// One topic's place in its tree.
public struct TreeEntry: Hashable, Sendable {
    public var parent: Parent
    public var position: String
    public var stamp: Stamp
}

/// A canvas's tree under Kleppmann's move operation: every move is kept in stamp order with
/// what it replaced, so a move that arrives late undoes the later ones, applies, and redoes
/// them. A move that would put a topic under itself does nothing.
struct Tree: Sendable {
    struct Move: Sendable {
        var stamp: Stamp
        var node: NodeID
        var parent: Parent
        var position: String
        var old: TreeEntry?
        var applied = false
    }

    var entries: [NodeID: TreeEntry] = [:]
    var kids: [Parent: Set<NodeID>] = [:]
    var log: [Move] = []

    /// Applies a move; false for a duplicate.
    mutating func apply(_ stamp: Stamp, _ node: NodeID, _ parent: Parent, _ position: String) -> Bool {
        let m = Move(stamp: stamp, node: node, parent: parent, position: position)
        if let last = log.last, !(last.stamp < stamp) {
            var lo = 0
            var hi = log.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if log[mid].stamp < stamp { lo = mid + 1 } else { hi = mid }
            }
            if lo < log.count, log[lo].stamp == stamp { return false }
            for i in (lo..<log.count).reversed() { undo(log[i]) }
            log.insert(m, at: lo)
            for i in lo..<log.count {
                var r = log[i]
                redo(&r)
                log[i] = r
            }
        } else {
            var r = m
            redo(&r)
            log.append(r)
        }
        return true
    }

    private mutating func redo(_ m: inout Move) {
        m.old = entries[m.node]
        if case .node(let p) = m.parent, p == m.node || isAncestor(m.node, of: p) {
            m.applied = false
            return
        }
        set(m.node, TreeEntry(parent: m.parent, position: m.position, stamp: m.stamp))
        m.applied = true
    }

    private mutating func undo(_ m: Move) {
        guard m.applied else { return }
        set(m.node, m.old)
    }

    private mutating func set(_ node: NodeID, _ entry: TreeEntry?) {
        if let old = entries[node] { kids[old.parent]?.remove(node) }
        entries[node] = entry
        if let entry { kids[entry.parent, default: []].insert(node) }
    }

    /// True when `a` is `b` or above it.
    func isAncestor(_ a: NodeID, of b: NodeID) -> Bool {
        var cur = b
        var steps = 0
        while true {
            if cur == a { return true }
            guard case .node(let p)? = entries[cur]?.parent, steps < entries.count else { return false }
            cur = p
            steps += 1
        }
    }

    /// Children in position order.
    func children(_ p: Parent) -> [NodeID] {
        guard let set = kids[p], !set.isEmpty else { return [] }
        return set.sorted { entries[$0]!.position < entries[$1]!.position }
    }

    /// The topic and everything under it.
    func subtree(_ id: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var stack = [id]
        while let cur = stack.popLast() {
            out.append(cur)
            stack.append(contentsOf: kids[.node(cur)] ?? [])
        }
        return out
    }
}

/// Everything about one canvas.
struct CanvasState: Sendable {
    /// Top-level settings, by key.
    var meta: [String: Register] = [:]
    /// Settings merged key by key, by object then key.
    var parts: [String: [String: Register]] = [:]
    var fields: [NodeID: [String: Register]] = [:]
    /// Elements: kind → id → (place, fields).
    var elementPlaces: [String: [String: Place]] = [:]
    var elementFields: [String: [String: [String: Register]]] = [:]
    var commentPlaces: [NodeID: [String: Place]] = [:]
    var comments: [NodeID: [String: Register]] = [:]
    var tree = Tree()
}

/// The whole replicated state: what every replica agrees on once it has the same ops.
struct ReplicaState: Sendable {
    var theme: [String: Register] = [:]
    var canvasPlaces: [CanvasID: Place] = [:]
    var canvases: [CanvasID: CanvasState] = [:]
    var assets: [String: Data] = [:]

    /// What applying ops touched, for materialising only that.
    struct Dirty: Sendable {
        var theme = false
        var canvasSet = false
        var assets = false
        /// Canvases whose tree, settings or elements changed (rebuilt whole).
        var structure: Set<CanvasID> = []
        /// Topics whose fields or comments changed.
        var nodes: [CanvasID: Set<NodeID>] = [:]
        var isEmpty: Bool { !theme && !canvasSet && !assets && structure.isEmpty && nodes.isEmpty }
    }

    var dirty = Dirty()

    /// The register's current value and stamp.
    func register(_ slot: Slot) -> Register? {
        switch slot {
        case .theme(let k): theme[k]
        case .canvas(let c, let k): canvases[c]?.meta[k]
        case .part(let c, let p, let k): canvases[c]?.parts[p]?[k]
        case .field(let c, let n, let k): canvases[c]?.fields[n]?[k]
        case .element(let c, let kind, let id, let k): canvases[c]?.elementFields[kind]?[id]?[k]
        case .comment(let c, let n, let k): canvases[c]?.comments[n]?[k]
        }
    }

    func place(_ slot: PlaceSlot) -> Place? {
        switch slot {
        case .canvas(let c): canvasPlaces[c]
        case .element(let c, let kind, let id): canvases[c]?.elementPlaces[kind]?[id]
        case .comment(let c, let n, let k): canvases[c]?.commentPlaces[n]?[k]
        }
    }

    func entry(_ c: CanvasID, _ n: NodeID) -> TreeEntry? { canvases[c]?.tree.entries[n] }

    mutating func apply(_ op: Op) {
        switch op.change {
        case .set(let slot, let value):
            if let r = register(slot), !(r.stamp < op.stamp) { return }
            let r = Register(value: value, stamp: op.stamp)
            switch slot {
            case .theme(let k):
                theme[k] = r
                dirty.theme = true
            case .canvas(let c, let k):
                canvases[c, default: CanvasState()].meta[k] = r
                dirty.structure.insert(c)
            case .part(let c, let p, let k):
                canvases[c, default: CanvasState()].parts[p, default: [:]][k] = r
                dirty.structure.insert(c)
            case .field(let c, let n, let k):
                canvases[c, default: CanvasState()].fields[n, default: [:]][k] = r
                dirty.nodes[c, default: []].insert(n)
            case .element(let c, let kind, let id, let k):
                canvases[c, default: CanvasState()].elementFields[kind, default: [:]][id, default: [:]][k] = r
                dirty.structure.insert(c)
            case .comment(let c, let n, let k):
                canvases[c, default: CanvasState()].comments[n, default: [:]][k] = r
                dirty.nodes[c, default: []].insert(n)
            }
        case .place(let slot, let position):
            if let p = place(slot), !(p.stamp < op.stamp) { return }
            let p = Place(position: position, stamp: op.stamp)
            switch slot {
            case .canvas(let c):
                canvasPlaces[c] = p
                dirty.canvasSet = true
            case .element(let c, let kind, let id):
                canvases[c, default: CanvasState()].elementPlaces[kind, default: [:]][id] = p
                dirty.structure.insert(c)
            case .comment(let c, let n, let k):
                canvases[c, default: CanvasState()].commentPlaces[n, default: [:]][k] = p
                dirty.nodes[c, default: []].insert(n)
            }
        case .move(let c, let n, let parent, let position):
            if canvases[c, default: CanvasState()].tree.apply(op.stamp, n, parent, position) {
                dirty.structure.insert(c)
            }
        case .asset(let name, let data):
            if assets[name] == nil {
                assets[name] = data
                dirty.assets = true
            }
        }
    }
}
