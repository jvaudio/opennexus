import AppKit
import NexusCanvas
import NexusCore
import NexusFormat

/// A `.nexus` package document. Autosaves in place and keeps versions (File › Revert To).
final class NexusDocument: NSDocument {
    let store = DocumentStore(model: .blank())
    private let undoBridge = DocumentUndoRegistrar()
    /// True for a brand-new untitled document, so the window opens with the root in Edit mode.
    private(set) var isFreshBlank = true

    override init() {
        super.init()
        undoBridge.document = self
        store.undoRegistrar = undoBridge
    }

    nonisolated override class var autosavesInPlace: Bool { true }
    nonisolated override class var preservesVersions: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        NexusPackage.fileWrapper(for: store.model)
    }

    nonisolated override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let doc = try NexusPackage.read(from: fileWrapper)
        // AppKit reads on the main thread unless concurrent reading is enabled (it is not).
        MainActor.assumeIsolated {
            isFreshBlank = false
            store.replace(with: doc)
        }
    }
}

/// Registers canvas patches with the document's `NSUndoManager`, so Edit › Undo, the
/// change count, autosave and versions all see every model change.
final class DocumentUndoRegistrar: UndoRegistrar {
    weak var document: NexusDocument?

    func register(_ patch: Patch, store: DocumentStore) {
        guard let um = document?.undoManager else { return }
        registerInverse(of: patch, undoManager: um, store: store)
        um.setActionName(patch.actionName)
    }

    private func registerInverse(of patch: Patch, undoManager um: UndoManager, store: DocumentStore) {
        let inverse = patch.inverted
        um.registerUndo(withTarget: store) { [weak self] store in
            MainActor.assumeIsolated {
                store.applyFromUndo(inverse, kind: um.isUndoing ? .undone : .redone)
                self?.registerInverse(of: inverse, undoManager: um, store: store)
                um.setActionName(patch.actionName)
            }
        }
    }
}
