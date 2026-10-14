import AppKit
import NexusCore
import NexusFormat

/// A `.nexus` package document. Autosaves in place and keeps versions (File › Revert To).
final class NexusDocument: NSDocument {
    var model: DocumentModel = .blank()

    nonisolated override class var autosavesInPlace: Bool { true }
    nonisolated override class var preservesVersions: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        NexusPackage.fileWrapper(for: model)
    }

    nonisolated override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let doc = try NexusPackage.read(from: fileWrapper)
        // AppKit reads on the main thread unless concurrent reading is enabled (it is not).
        MainActor.assumeIsolated { model = doc }
    }
}
