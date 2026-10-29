import Foundation
import NexusCore

/// One participant's copy of a co-edited document (M46): the replicated state, and the
/// document it materialises. Local edits arrive as the `Patch`es the app already makes and
/// leave as ops; remote ops arrive and leave as `Patch`es, so the app needs no new paths.
///
/// The document here is only what's shared: canvases, tab order, theme and assets. Chats,
/// the manifest's other keys and a password stay with each copy.
public struct Replica: Sendable {
    public let id: String
    public var clock: HybridClock
    var state = ReplicaState()
    /// The materialised document: equal to the app's model at all times.
    public internal(set) var doc: DocumentModel
    /// Topics a repair changed, rebuilt from their registers next time.
    var repaired: [CanvasID: Set<NodeID>] = [:]
    var undoStack: [Group] = []
    var redoStack: [Group] = []
    /// An undo's or redo's op stamp → the stamp of the value it put back, so an older step
    /// still knows the slot holds its own value (see `Undo.swift`).
    var aliases: [Stamp: Stamp] = [:]

    /// A local commit's ops and what each replaced, for selective undo.
    struct Group: Sendable {
        /// The value an op replaced, and the stamp that had set it.
        enum Before: Sendable {
            case register(JSONValue?, Stamp?)
            case place(String?, Stamp?)
            case entry(TreeEntry?)
            case none
        }
        var ops: [(op: Op, before: Before)] = []
        var canvas: CanvasID
        var selectionBefore: Selection?
        var selectionAfter: Selection?
        var actionName: String
    }

    /// Canvas settings merged key by key, and element lists, as named in the canvas's JSON.
    static let parts: Set<String> = ["layout", "style", "diagram", "presentation", "guide", "schedule"]
    static let elementKinds = ["relationships", "boundaries", "summaries", "callouts", "zones"]
    /// Canvas JSON keys the tree or the places hold.
    static let structural: Set<String> = Set(["id", "nodes", "floating"] + elementKinds)

    /// An empty replica (someone joining): apply a snapshot next.
    public init(id: String, clock: HybridClock? = nil) {
        self.id = id
        self.clock = clock ?? HybridClock(replica: id)
        doc = DocumentModel(canvases: [])
        doc.idSuffix = ReplicaID.suffix(id)
    }

    /// The host's replica: the document as ops stamped by this replica. Returns the ops,
    /// the room's first snapshot.
    public static func seed(_ document: DocumentModel, id: String, clock: HybridClock? = nil) -> (Replica, [Op]) {
        var r = Replica(id: id, clock: clock)
        var empty = document
        empty.canvases = [:]
        empty.canvasOrder = []
        empty.theme = .object([:])
        empty.assets = [:]
        empty.idSuffix = ReplicaID.suffix(id)
        r.doc = empty
        var p = empty.canvasSetPatch(to: document, focus: document.canvasOrder.first ?? "c1", actionName: "")
        p.themeBefore = .object([:])
        p.themeAfter = document.theme
        let ops = r.record(p, assets: document.assets, undoable: false)
        return (r, ops)
    }

    public var idSuffix: String { ReplicaID.suffix(id) }

    // MARK: Remote ops

    /// Applies ops from elsewhere (any order, duplicates welcome) and returns the patches
    /// that bring the document up to date, already applied to `doc`.
    public mutating func receive(_ ops: [Op]) -> Changes {
        for op in ops {
            clock.observe(op.stamp)
            state.apply(op)
        }
        return materialize()
    }

    /// What applying ops changed: patches for the store (whole canvases, the tab order and
    /// the theme first, then one per canvas), and assets that arrived.
    public struct Changes: Sendable {
        public var patches: [Patch] = []
        public var assets: [String: Data] = [:]
        public var isEmpty: Bool { patches.isEmpty && assets.isEmpty }
    }

    // MARK: Snapshot

    /// The state as ops with their own stamps: every register (removals too), place and
    /// move, and the assets. Applying them to any replica is a state merge.
    public func snapshot() -> [Op] {
        var out: [Op] = []
        for (k, r) in state.theme { out.append(Op(r.stamp, .set(.theme(k), r.value))) }
        for (c, p) in state.canvasPlaces { out.append(Op(p.stamp, .place(.canvas(c), p.position))) }
        for (c, cs) in state.canvases {
            for (k, r) in cs.meta { out.append(Op(r.stamp, .set(.canvas(c, k), r.value))) }
            for (p, regs) in cs.parts {
                for (k, r) in regs { out.append(Op(r.stamp, .set(.part(c, p, k), r.value))) }
            }
            for (n, regs) in cs.fields {
                for (k, r) in regs { out.append(Op(r.stamp, .set(.field(c, n, k), r.value))) }
            }
            for (kind, places) in cs.elementPlaces {
                for (id, p) in places { out.append(Op(p.stamp, .place(.element(c, kind, id), p.position))) }
            }
            for (kind, items) in cs.elementFields {
                for (id, regs) in items {
                    for (k, r) in regs { out.append(Op(r.stamp, .set(.element(c, kind, id, k), r.value))) }
                }
            }
            for (n, places) in cs.commentPlaces {
                for (k, p) in places { out.append(Op(p.stamp, .place(.comment(c, n, k), p.position))) }
            }
            for (n, regs) in cs.comments {
                for (k, r) in regs { out.append(Op(r.stamp, .set(.comment(c, n, k), r.value))) }
            }
            for m in cs.tree.log { out.append(Op(m.stamp, .move(c, m.node, m.parent, m.position))) }
        }
        for (name, data) in state.assets { out.append(Op(Stamp(time: 0, count: 0, replica: id), .asset(name, data))) }
        return out.sorted { $0.stamp < $1.stamp }
    }

    /// Builds the whole document again from the state (a late joiner's view), for checks.
    public func rebuilt() -> DocumentModel {
        var fresh = Replica(id: id, clock: clock)
        _ = fresh.receive(snapshot())
        return fresh.doc
    }

    /// Ops in the state (moves kept in the trees' logs), for size checks.
    public var moveCount: Int { state.canvases.values.reduce(0) { $0 + $1.tree.log.count } }
}
