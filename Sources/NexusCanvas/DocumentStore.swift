import Foundation
import NexusCore
import Observation

/// Records patches for undo. The app registers them with `NSUndoManager`; tests and
/// headless tools use `StackUndoRegistrar`.
@MainActor
public protocol UndoRegistrar: AnyObject {
    func register(_ patch: Patch, store: DocumentStore)
}

/// Owns the document model. Every change, including undo and redo, arrives as a
/// `Patch`, and observers (canvas controllers, outline views) are told about each one.
@MainActor
@Observable
public final class DocumentStore {
    public private(set) var model: DocumentModel
    /// Increments on every applied patch; views observe it to refresh.
    public private(set) var revision = 0
    @ObservationIgnored public weak var undoRegistrar: (any UndoRegistrar)?
    @ObservationIgnored private var observers: [ObjectIdentifier: (Patch) -> Void] = [:]
    /// Called after every change so the document can update its change count.
    @ObservationIgnored public var onChange: ((Patch, ChangeKind) -> Void)?

    public enum ChangeKind: Sendable { case done, undone, redone }

    public init(model: DocumentModel) {
        self.model = model
    }

    public func canvas(_ id: CanvasID) -> Canvas? { model.canvases[id] }

    /// Applies a new edit and registers it for undo.
    public func commit(_ patch: Patch) {
        guard !patch.isEmpty else { return }
        model.apply(patch)
        revision += 1
        undoRegistrar?.register(patch, store: self)
        notify(patch, .done)
    }

    /// Applies a patch coming from the undo machinery (already inverted for undo).
    public func applyFromUndo(_ patch: Patch, kind: ChangeKind) {
        model.apply(patch)
        revision += 1
        notify(patch, kind)
    }

    /// Replaces the whole model (revert, reload from disk).
    public func replace(with model: DocumentModel) {
        self.model = model
        revision += 1
        for o in observers.values { o(Patch(canvasID: model.canvasOrder.first ?? "c1")) }
    }

    /// A document-level edit (canvases added, removed or replaced, tab order) as one undo
    /// step. `focus` is the canvas to show afterwards. Assets the edit adds are kept even if
    /// it's undone (they're content-addressed and harmless).
    @discardableResult
    public func commitDocument(_ actionName: String, focus: CanvasID, _ body: (inout DocumentModel) -> Void) -> Patch {
        var after = model
        body(&after)
        let patch = model.canvasSetPatch(to: after, focus: focus, actionName: actionName)
        for (k, v) in after.assets where model.assets[k] == nil { model.assets[k] = v }
        commit(patch)
        return patch
    }

    /// The file changed on disk (an agent, the CLI, Git): merges it with this copy as one
    /// undo step. `base` is what was last read or saved. Returns what kept this copy's
    /// version because both sides changed it.
    @discardableResult
    public func mergeExternal(
        _ disk: DocumentModel, base: DocumentModel, focus: CanvasID, actionName: String = "Change on Disk"
    ) -> [String] {
        let merge = DocumentMerge(base: base, current: model, disk: disk)
        let target = merge.model.canvases[focus] != nil ? focus : (merge.model.canvasOrder.first ?? focus)
        commitDocument(actionName, focus: target) { m in
            m.canvases = merge.model.canvases
            m.canvasOrder = merge.model.canvasOrder
            m.theme = merge.model.theme
            m.assets = merge.model.assets
        }
        return merge.conflicts
    }

    /// Document-level changes outside undo (chats, assets).
    public func updateDocument(_ body: (inout DocumentModel) -> Void) {
        body(&model)
        revision += 1
    }

    public func addObserver(_ owner: AnyObject, _ handler: @escaping (Patch) -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    public func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    private func notify(_ patch: Patch, _ kind: ChangeKind) {
        onChange?(patch, kind)
        for o in observers.values { o(patch) }
    }
}

/// A headless undo registrar backed by `UndoStack`.
@MainActor
public final class StackUndoRegistrar: UndoRegistrar {
    public private(set) var stack = UndoStack()

    public init() {}

    public func register(_ patch: Patch, store: DocumentStore) {
        stack.record(patch)
    }

    @discardableResult
    public func undo(_ store: DocumentStore) -> Bool {
        guard let p = stack.undo() else { return false }
        store.applyFromUndo(p, kind: .undone)
        return true
    }

    @discardableResult
    public func redo(_ store: DocumentStore) -> Bool {
        guard let p = stack.redo() else { return false }
        store.applyFromUndo(p, kind: .redone)
        return true
    }
}
