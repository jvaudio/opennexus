import NexusCanvas
import NexusCore
import NexusScene
import NexusTouch
import UIKit

/// Launch arguments the UI tests use (M47b, M47c): a clean library in a temporary folder,
/// onboarding skipped, and optionally a fresh mind map or a starter opened at once.
///
///     -uitest              a clean library, no recents, tips off
///     -uitest-new          then a new blank mind map, its central topic in Edit mode
///     -uitest-starter ID   then a new document from that starter (`StarterLibrary`)
///     -uitest-display      as if a second display were connected (AirPlay's Screen Mirroring)
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
        if ProcessInfo.processInfo.arguments.contains("-uitest-display") { ExternalDisplay.shared.connect() }
    }

    private static var opened = false

    static func open(in scene: TouchScene) {
        let args = ProcessInfo.processInfo.arguments
        guard active, !opened else { return }
        if args.contains("-uitest-new") {
            opened = true
            scene.newDocument(CanvasController.newDocumentModel(prefs: .shared, type: .mindmap), fresh: true)
        } else if let i = args.firstIndex(of: "-uitest-starter"), i + 1 < args.count,
            let starter = StarterLibrary.starter(args[i + 1])
        {
            opened = true
            scene.newDocument(starter.document(prefs: .shared), named: Loc.t(starter.name), fresh: false)
        }
    }
}
