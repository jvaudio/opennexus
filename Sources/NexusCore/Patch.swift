import Foundation

/// A reversible change to one canvas: the before and after image of every node it
/// touched, plus the canvas's non-node fields when those changed.
///
/// Every model change (typing, restructuring, style, layout mode, conversion, AI
/// accepts, merges) is a `Patch`, so undo covers all of them the same way.
public struct Patch: Sendable, Equatable {
    public struct NodeChange: Sendable, Equatable {
        public var before: Node?
        public var after: Node?
    }

    public var canvasID: CanvasID
    public var nodes: [NodeID: NodeChange]
    /// The canvas without its nodes, before and after, when non-node fields changed.
    public var metaBefore: Canvas?
    public var metaAfter: Canvas?
    /// Selection to restore on undo and redo.
    public var selectionBefore: Selection?
    public var selectionAfter: Selection?
    /// Human name for the Edit menu ("Undo Add Topic").
    public var actionName: String

    public init(
        canvasID: CanvasID, nodes: [NodeID: NodeChange] = [:], metaBefore: Canvas? = nil,
        metaAfter: Canvas? = nil, selectionBefore: Selection? = nil, selectionAfter: Selection? = nil,
        actionName: String = ""
    ) {
        self.canvasID = canvasID
        self.nodes = nodes
        self.metaBefore = metaBefore
        self.metaAfter = metaAfter
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.actionName = actionName
    }

    public var isEmpty: Bool { nodes.isEmpty && metaBefore == nil }

    public var inverted: Patch {
        Patch(
            canvasID: canvasID,
            nodes: nodes.mapValues { NodeChange(before: $0.after, after: $0.before) },
            metaBefore: metaAfter, metaAfter: metaBefore,
            selectionBefore: selectionAfter, selectionAfter: selectionBefore,
            actionName: actionName)
    }

    /// Applies the patch forward (`before` → `after`).
    public func apply(to canvas: inout Canvas) {
        precondition(canvas.id == canvasID, "patch for \(canvasID) applied to \(canvas.id)")
        if let metaAfter {
            let nodes = canvas.nodes
            let seq = max(canvas.nextSequence, metaAfter.nextSequence)
            canvas = metaAfter
            canvas.nodes = nodes
            canvas.nextSequence = seq
        }
        for (id, change) in nodes {
            canvas.nodes[id] = change.after
        }
    }

    /// Combines `self` followed by `next` into one patch (used for coalescing and
    /// for grouping several edits into one undo step).
    public func merged(with next: Patch) -> Patch {
        precondition(canvasID == next.canvasID)
        var out = self
        for (id, change) in next.nodes {
            if let existing = out.nodes[id] {
                out.nodes[id] = NodeChange(before: existing.before, after: change.after)
            } else {
                out.nodes[id] = change
            }
        }
        // Drop entries that ended where they started.
        out.nodes = out.nodes.filter { $0.value.before != $0.value.after }
        if next.metaBefore != nil {
            out.metaBefore = out.metaBefore ?? next.metaBefore
            out.metaAfter = next.metaAfter
        }
        if out.metaBefore == out.metaAfter {
            out.metaBefore = nil
            out.metaAfter = nil
        }
        out.selectionAfter = next.selectionAfter ?? out.selectionAfter
        return out
    }
}

/// The current selection: a primary node (where the caret goes, where keys act)
/// and an ordered set for multi-selection.
public struct Selection: Hashable, Sendable {
    public var primary: NodeID
    public var nodes: [NodeID]

    public init(_ primary: NodeID) {
        self.primary = primary
        self.nodes = [primary]
    }

    public init(primary: NodeID, nodes: [NodeID]) {
        self.primary = primary
        self.nodes = nodes.contains(primary) ? nodes : [primary] + nodes
    }

    public func contains(_ id: NodeID) -> Bool { nodes.contains(id) }

    public func extended(with id: NodeID) -> Selection {
        Selection(primary: id, nodes: nodes.contains(id) ? nodes : nodes + [id])
    }
}
