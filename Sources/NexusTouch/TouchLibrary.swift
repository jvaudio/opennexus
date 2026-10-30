#if os(iOS)
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iPad's documents (M47b): new ones go in the app's Documents folder ("On My iPad ›
/// OpenNexus", or iCloud Drive's OpenNexus folder when the app has one), recents are kept
/// as bookmarks so documents opened from Files reopen, and imports, the Inbox and joined
/// sessions become documents here. One library serves every window.
@MainActor
@Observable
public final class TouchLibrary {
    public static let shared = TouchLibrary()

    /// Recently opened documents, newest first.
    public private(set) var recents: [URL] = []
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored public var folder: URL

    /// Apple Intelligence's state and Settings' buttons: the app supplies them.
    @ObservationIgnored public var aiAvailability: () -> AIAvailability = { .unsupported }
    @ObservationIgnored public var settingsAction: (String) -> Void = { _ in }

    static let recentsKey = "touch.recents"
    static let maxRecents = 30

    public init(defaults: UserDefaults = .standard, folder: URL? = nil) {
        self.defaults = defaults
        self.folder = folder ?? Self.documentsFolder
        recents = Self.resolve(defaults.array(forKey: Self.recentsKey) as? [Data] ?? [])
    }

    /// iCloud Drive's OpenNexus folder when this device and app have one, else On My iPad.
    static var documentsFolder: URL {
        if let cloud = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return cloud.appending(path: "Documents")
        }
        return URL.documentsDirectory
    }

    static func resolve(_ bookmarks: [Data]) -> [URL] {
        bookmarks.compactMap { b in
            var stale = false
            return try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    /// Remembers a document (Home lists it first).
    public func noteOpened(_ url: URL) {
        recents.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(Self.maxRecents))
        let bookmarks = recents.compactMap { u -> Data? in
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            return try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: Self.recentsKey)
    }

    public func forget(_ url: URL) {
        recents.removeAll { $0 == url }
        noteOpenedNothing()
    }

    private func noteOpenedNothing() {
        let bookmarks = recents.compactMap { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil) }
        defaults.set(bookmarks, forKey: Self.recentsKey)
    }

    /// A name for a new document that's free in the folder ("Untitled", "Untitled 2"…).
    public func freeURL(named base: String, ext: String = "nexus") -> URL {
        let clean = base.components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = clean.isEmpty ? Loc.t("Untitled") : String(clean.prefix(60))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appending(path: "\(name).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(name) \(i).\(ext)")
            i += 1
        }
        return url
    }

    /// Makes and opens a document from a model (a starter, an import, a joined session).
    public func create(_ model: DocumentModel, named name: String, fresh: Bool) async throws -> TouchDocument {
        let doc = try await TouchDocument.create(at: freeURL(named: name), model: model)
        doc.isFresh = fresh
        noteOpened(doc.fileURL)
        return doc
    }

    /// Opens a document in place (from Files, Home or a link), downloading it from iCloud
    /// first if it isn't here yet.
    public func open(_ url: URL) async throws -> TouchDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        if CloudDownload.isPending(url) { try await CloudDownload.download(url) }
        let doc = TouchDocument(fileURL: url)
        let ok = await doc.open()
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard ok else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        noteOpened(url)
        return doc
    }

    /// What File › Import… and Merge accept.
    public static var importTypes: [UTType] {
        InterchangeFormat.importable.flatMap(\.extensions).compactMap { UTType(filenameExtension: $0) }
            + [TouchDocument.packageType, TouchDocument.jsonType, .folder]
    }

    /// Reads a file another app made into a document model, with its import report.
    /// Pictures and PDFs go through image to map (Vision, and Apple Intelligence when it
    /// can run), which reports its progress.
    public func importFile(
        _ url: URL, progress: @escaping (ImageImportProgress) -> Void,
        done: @escaping (Result<Imported, any Error>) -> Void
    ) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let name = url.lastPathComponent
            if ImageToMap.isImage(name: name) {
                let data = try Data(contentsOf: url)
                let p = ImageImportProgress(name: name)
                progress(p)
                _ = p.start(data, refine: Preferences.shared.bool(ImageToMap.refineKey)) { outcome in
                    switch outcome {
                    case .imported(let im): done(.success(im))
                    case .failed(let error): done(.failure(error))
                    case .cancelled: break
                    }
                }
                return
            }
            var files: [String: Data]?
            var data: Data?
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = NexusPackage.flatten(try FileWrapper(url: url, options: .immediate))
            } else {
                data = try Data(contentsOf: url)
            }
            done(.success(try Interchange.importFile(name: name, data: data, files: files)))
        } catch {
            done(.failure(error))
        }
    }

    // MARK: Inbox and live sessions

    /// The Inbox map (Quick Capture's and Share's default target), in Application Support.
    public static var inboxURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
            path: "OpenNexus/Inbox.nexus")
    }

    public static func ensureInbox() {
        guard !FileManager.default.fileExists(atPath: inboxURL.path) else { return }
        try? FileManager.default.createDirectory(
            at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NexusPackage.write(
            DocumentModel(canvases: [Canvas(id: "c1", title: "Inbox", rootText: "Inbox")]), to: inboxURL)
    }

    public var inboxCount: Int {
        (try? NexusPackage.read(from: Self.inboxURL))?.orderedCanvases.first.map { $0.nodes.count - 1 } ?? 0
    }

    /// Joins a live session from its invite (M46): the session's document is written here
    /// and opened, which binds it.
    public func join(_ link: String, opened: @escaping (TouchDocument) -> Void, failed: @escaping (String) -> Void) {
        let center = CollabCenter.shared
        guard center.networkOn else {
            return failed(
                Loc.t("Live sessions use the network, which is off. Turn it on in Settings › Privacy & Data."))
        }
        do {
            let s = try center.join(link)
            s.onReady = { [weak self] model in
                guard let self else { return }
                let root = model.orderedCanvases.first.flatMap { c in c.nodes[c.root]?.text } ?? ""
                Task { @MainActor in
                    do {
                        opened(
                            try await self.create(
                                model, named: root.isEmpty ? Loc.t("Live Session") : root, fresh: false))
                    } catch {
                        failed("\(error)")
                    }
                }
            }
            s.onEnded = { why in failed(why) }
        } catch {
            failed("\(error)")
        }
    }

    // MARK: Home

    /// Fills Home's model: role, shelf, recents, Inbox count.
    public func reload(_ home: HomeModel) {
        let prefs = Preferences.shared
        home.role = Role(rawValue: prefs.string("general.role")) ?? .engineer
        home.shelf = home.role.shelf
        home.gallery.role = home.role
        home.load(recents)
        home.inboxCount = inboxCount
    }
}

/// A second display (M47b): while a document presents, the audience sees the canvas there
/// and the iPad shows the presenter view.
@MainActor
@Observable
public final class ExternalDisplay {
    public static let shared = ExternalDisplay()

    public private(set) var connected = false
    /// The document presenting, if any.
    public var presenting: TouchDocumentModel?

    public func connect() { connected = true }
    public func disconnect() { connected = false }
}

/// The external display's scene: the presenting canvas, full screen, or the brand mark.
public final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let ws = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            let w = UIWindow(windowScene: ws)
            w.rootViewController = UIHostingController(rootView: ExternalDisplayView())
            w.isHidden = false
            window = w
            ExternalDisplay.shared.connect()
        }
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            window = nil
            ExternalDisplay.shared.disconnect()
        }
    }
}

struct ExternalDisplayView: View {
    @State private var display = ExternalDisplay.shared

    var body: some View {
        ZStack {
            Color.black
            if let m = display.presenting, m.presenting {
                CanvasSlot(model: m, place: .external)
                CanvasOverlayStack(controller: m.controller)
            } else {
                AppIconTile(size: 160).accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
