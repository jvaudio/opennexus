import Foundation
import NexusCore
import NexusScene

/// Registers canvas patches with a document's `UndoManager`, so Undo, the change count,
/// autosave and versions all see every model change. The Mac's `NSDocument` and the
/// iPad's `UIDocument` each hand it their undo manager (moved here from the Mac app in
/// M47b).
@MainActor
public final class UndoManagerRegistrar: UndoRegistrar {
    let undoManager: @MainActor () -> UndoManager?

    public init(_ undoManager: @escaping @MainActor () -> UndoManager?) { self.undoManager = undoManager }

    public func register(_ patch: Patch, store: DocumentStore) {
        guard let um = undoManager() else { return }
        if let session = store.collab as? CollabSession {
            registerSelective(session, name: patch.actionName, undoManager: um, store: store)
        } else {
            registerInverse(of: patch, undoManager: um, store: store)
        }
        um.setActionName(Loc.t(patch.actionName))
    }

    /// In a live session (M46) undo is selective: the session puts back only what still
    /// holds this person's own change, never someone else's later one. Each registration
    /// here is one of the session's undo steps, so the two stacks stay in step.
    private func registerSelective(
        _ session: CollabSession, name: String, undoManager um: UndoManager, store: DocumentStore
    ) {
        um.registerUndo(withTarget: store) { [weak self, weak session] store in
            MainActor.assumeIsolated {
                guard let session, store.collab === session else { return }
                if um.isUndoing { session.undo() } else { session.redo() }
                self?.registerSelective(session, name: name, undoManager: um, store: store)
                um.setActionName(Loc.t(name))
            }
        }
    }

    private func registerInverse(of patch: Patch, undoManager um: UndoManager, store: DocumentStore) {
        let inverse = patch.inverted
        um.registerUndo(withTarget: store) { [weak self] store in
            MainActor.assumeIsolated {
                store.applyFromUndo(inverse, kind: um.isUndoing ? .undone : .redone)
                self?.registerInverse(of: inverse, undoManager: um, store: store)
                um.setActionName(Loc.t(patch.actionName))
            }
        }
    }
}
