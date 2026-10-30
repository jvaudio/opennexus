import NexusCanvas
import NexusCore
import NexusTouch
import UIKit

/// Launch arguments the iPad's UI tests use (M47b): a clean library in a temporary
/// folder, onboarding skipped, and optionally a fresh mind map opened at once.
///
///     -uitest              a clean library, no recents, tips off
///     -uitest-new          then a new blank mind map, its central topic in Edit mode
@MainActor
enum UITestSupport {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    static func prepare(_ library: TouchLibrary) {
        guard active else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "uitest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library.folder = folder
        for r in library.recents { library.forget(r) }
        UIView.setAnimationsEnabled(false)
    }

    private static var opened = false

    static func open(in scene: TouchScene) {
        guard active, !opened, ProcessInfo.processInfo.arguments.contains("-uitest-new") else { return }
        opened = true
        scene.newDocument(CanvasController.newDocumentModel(prefs: .shared, type: .mindmap), fresh: true)
    }
}
