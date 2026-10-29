import Foundation
import NexusCore

/// Selective undo: undoing a local edit puts back only what still holds the value that edit
/// set (the same stamp), so it never reverts someone else's later change. Redo does the
/// same over the undo's own ops. Remote edits never enter these stacks.
///
/// An undo's op has a new stamp but puts back an older value; `aliases` remembers which, so
/// undoing the step before it still finds its own value there.
extension Replica {
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// What an undo or redo did: ops to send and patches for the store.
    public struct Step: Sendable {
        public var ops: [Op]
        public var changes: Changes
        public var actionName: String
    }

    public mutating func undo() -> Step? {
        guard let g = undoStack.popLast() else { return nil }
        let (step, inverse) = invert(g, selection: g.selectionBefore)
        redoStack.append(inverse)
        return step
    }

    public mutating func redo() -> Step? {
        guard let g = redoStack.popLast() else { return nil }
        let (step, inverse) = invert(g, selection: g.selectionAfter)
        undoStack.append(inverse)
        return step
    }

    /// Forgets local history (a session starting, or the app clearing its undo stack).
    public mutating func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        aliases.removeAll()
    }

    /// True when the slot's current value is the one the op at `mine` set, directly or as
    /// put back by undos and redos since.
    func holds(_ current: Stamp?, _ mine: Stamp) -> Bool {
        var s = current
        while let x = s {
            if x == mine { return true }
            s = aliases[x]
        }
        return false
    }

    mutating func invert(_ g: Group, selection: Selection?) -> (Step, Group) {
        precondition(state.dirty.isEmpty, "materialise remote ops before undoing")
        var out = Group(
            canvas: g.canvas, selectionBefore: g.selectionAfter, selectionAfter: g.selectionBefore,
            actionName: g.actionName)
        for (op, before) in g.ops.reversed() {
            let restored: Stamp?
            switch (op.change, before) {
            case (.set(let slot, _), .register(let v, let s)):
                guard holds(state.register(slot)?.stamp, op.stamp) else { continue }
                emit(.set(slot, v), &out)
                restored = s
            case (.place(let slot, _), .place(let p, let s)):
                guard holds(state.place(slot)?.stamp, op.stamp) else { continue }
                emit(.place(slot, p), &out)
                restored = s
            case (.move(let c, let n, _, _), .entry(let e)):
                guard holds(state.entry(c, n)?.stamp, op.stamp) else { continue }
                emit(.move(c, n, e?.parent ?? .trash, e?.position ?? ""), &out)
                restored = e?.stamp
            default:
                continue
            }
            if let restored, let last = out.ops.last { aliases[last.op.stamp] = restored }
        }
        // `out` holds the inverses newest first, so inverting it again replays forward.
        var changes = materialize()
        if let selection, let i = changes.patches.lastIndex(where: { $0.canvasID == g.canvas }) {
            changes.patches[i].selectionAfter = selection
        } else if let selection {
            // Nothing left to put back (someone else changed it all since): the selection still moves.
            var p = Patch(canvasID: g.canvas, actionName: g.actionName)
            p.selectionAfter = selection
            changes.patches.append(p)
        }
        return (Step(ops: out.ops.map(\.op), changes: changes, actionName: g.actionName), out)
    }
}
