#if os(iOS)
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One iPad window (M47b): Home, or the document it opened. Home is the launch screen
/// (D388): recents, New from a type or a starter, Open… through the document picker,
/// Import…, the Inbox; `opennexus://` links and files opened from other apps land here.
@MainActor
@Observable
public final class TouchScene {
    public let library: TouchLibrary
    public let home = HomeModel()
    public private(set) var document: TouchDocumentModel?
    /// The document pickers and Settings, shown by the window.
    public var opening = false
    public var importing = false
    public var settings = false
    /// Image to map's progress while it runs.
    public var importProgress: ImageImportProgress?
    public var error: String?
    /// Opening a document (iCloud may download it first).
    public private(set) var busy = false

    /// Captures and Spotlight (the app's integrations) hear about documents here.
    @ObservationIgnored public var onDocumentOpened: (TouchDocumentModel) -> Void = { _ in }

    public init(library: TouchLibrary = .shared) {
        self.library = library
        wireHome()
        reloadHome()
    }

    public func reloadHome() { library.reload(home) }

    private func wireHome() {
        home.onNew = { [weak self] type in
            self?.newDocument(CanvasController.newDocumentModel(prefs: .shared, type: type))
        }
        home.onOpen = { [weak self] url in self?.open(url) }
        home.onImport = { [weak self] in self?.importing = true }
        home.onDropFiles = { [weak self] urls in
            for url in urls {
                if ["nexus", "nexusjson"].contains(url.pathExtension.lowercased()) {
                    self?.open(url)
                } else {
                    self?.importFile(url)
                }
            }
        }
        // A starter from the shelf or the picker; a Blank one starts in Edit mode.
        home.onTemplate = { [weak self] t in
            self?.newDocument(
                t.document(prefs: .shared), named: t.title,
                fresh: t.isBlank && Preferences.shared.bool("editing.startInEdit"),
                guide: StarterGallery.startsWithGuide(t, prefs: .shared))
        }
        home.onInbox = { [weak self] in self?.openInbox() }
        home.onFilter = { [weak self] url, name in
            self?.open(url) { model in
                if let f = model.controller.canvas.filters.first(where: { $0.name == name }) {
                    model.controller.applySavedFilter(f)
                }
            }
        }
    }

    // MARK: Documents

    /// Makes a document in the library's folder and opens it.
    public func newDocument(
        _ model: DocumentModel, named name: String? = nil, fresh: Bool? = nil, guide: Bool = false,
        then: ((TouchDocumentModel) -> Void)? = nil
    ) {
        let root = model.orderedCanvases.first.flatMap { $0.nodes[$0.root]?.text }
        let startInEdit = fresh ?? Preferences.shared.bool("editing.startInEdit")
        run {
            let doc = try await self.library.create(model, named: name ?? root ?? Loc.t("Untitled"), fresh: startInEdit)
            let m = self.show(doc)
            if guide { m.controller.guideVisible = true }
            then?(m)
        }
    }

    /// Opens a document in place.
    public func open(_ url: URL, then: ((TouchDocumentModel) -> Void)? = nil) {
        if let document, document.document.fileURL.standardizedFileURL == url.standardizedFileURL {
            then?(document)
            return
        }
        home.downloading.insert(url)
        run {
            defer { self.home.downloading.remove(url) }
            let doc = try await self.library.open(url)
            let m = self.show(doc)
            m.resumeSession()
            m.findConflictCopies(offer: true)
            then?(m)
        }
    }

    /// Opens a map and selects a topic (Spotlight results, widget links).
    public func open(_ url: URL, canvas: CanvasID?, node: NodeID?) {
        open(url) { m in
            let c = m.controller
            if let canvas, c.store.model.canvases[canvas] != nil, canvas != c.canvasID { c.switchCanvas(to: canvas) }
            if let node, c.canvas.nodes[node] != nil {
                c.select(node)
                c.onReveal?(node)
            }
        }
    }

    public func openInbox() {
        TouchLibrary.ensureInbox()
        open(TouchLibrary.inboxURL)
    }

    /// File › Import… and files from other apps: a new document from what they read as.
    public func importFile(_ url: URL) {
        library.importFile(url, progress: { [weak self] p in self?.importProgress = p }) { [weak self] result in
            guard let self else { return }
            self.importProgress = nil
            switch result {
            case .success(let imported):
                self.newDocument(imported.document, named: imported.report.source, fresh: false) { m in
                    if let first = imported.document.canvasOrder.first { m.controller.switchCanvas(to: first) }
                    m.controller.showImportReport(imported.report)
                }
            case .failure(let error):
                self.error = Loc.f("Couldn’t import “%@”", url.lastPathComponent) + "\n" + String(describing: error)
            }
        }
    }

    /// Joins a live session from its invite (M46).
    public func join(_ link: String) {
        library.join(link) { [weak self] doc in
            guard let self else { return }
            self.show(doc).resumeSession()
        } failed: { [weak self] why in
            self?.error = Loc.t("Couldn’t join the live session") + "\n" + why
        }
    }

    @discardableResult
    func show(_ doc: TouchDocument) -> TouchDocumentModel {
        document?.close()
        let m = TouchDocumentModel(document: doc)
        m.onClose = { [weak self, weak m] in
            guard let self, self.document === m else { return }
            self.document = nil
            self.reloadHome()
        }
        m.onImport = { [weak self] in self?.importing = true }
        m.onJoin = { [weak self] link in self?.join(link) }
        document = m
        onDocumentOpened(m)
        return m
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await body()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Links

    /// `opennexus://inbox`, `new`, `open/<token>` (widgets), `join#<invite>` (M46); file
    /// URLs of documents (open in place) and of other formats (import).
    public func handle(_ url: URL, token: (String) -> URL? = { _ in nil }) {
        if url.isFileURL {
            if ["nexus", "nexusjson"].contains(url.pathExtension.lowercased()) { open(url) } else { importFile(url) }
            return
        }
        guard url.scheme == "opennexus" else {
            if url.path.hasSuffix("/join/") || url.path.hasSuffix("/join") { join(url.absoluteString) }
            return
        }
        switch url.host() {
        case "inbox": openInbox()
        case "new": home.onNew(.mindmap)
        case "open": if let u = token(url.lastPathComponent) { open(u) }
        case "join": join(url.absoluteString)
        default: break
        }
    }
}

/// An iPad window's root: Home with Open…, Import… and Settings, or the open document.
public struct TouchSceneView: View {
    @Bindable var scene: TouchScene

    public init(scene: TouchScene) { self.scene = scene }

    public var body: some View {
        Group {
            if let doc = scene.document {
                TouchDocumentScreen(model: doc, library: scene.library)
                    .id(ObjectIdentifier(doc))
            } else {
                NavigationStack {
                    HomeView(model: scene.home)
                        .toolbar {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button {
                                    scene.opening = true
                                } label: {
                                    Label(Loc.t("Open…"), systemImage: "folder")
                                }
                                .accessibilityIdentifier("open-document")
                                Button {
                                    scene.settings = true
                                } label: {
                                    Label(Loc.t("Settings"), systemImage: "gearshape")
                                }
                                .accessibilityIdentifier("settings")
                            }
                        }
                        .navigationTitle(Loc.t("Home"))
                        .navigationBarTitleDisplayMode(.inline)
                        .searchable(
                            text: Binding(get: { scene.home.query }, set: { scene.home.query = $0 }),
                            prompt: Loc.t("Search maps and nodes"))
                }
                .onAppear { scene.reloadHome() }
            }
        }
        .overlay {
            if scene.busy { ProgressView().controlSize(.large) }
        }
        .focusedSceneValue(\.touchScene, scene)
        .fileImporter(
            isPresented: $scene.opening, allowedContentTypes: [TouchDocument.packageType, TouchDocument.jsonType]
        ) { result in
            if case .success(let url) = result { scene.open(url) }
        }
        .fileImporter(isPresented: $scene.importing, allowedContentTypes: TouchLibrary.importTypes) { result in
            if case .success(let url) = result { scene.importFile(url) }
        }
        .fullScreenCover(isPresented: $scene.settings) {
            SettingsSheet(request: .init(pane: "general"), library: scene.library) { scene.settings = false }
        }
        .sheet(item: $scene.importProgress) { p in
            ImageImportView(progress: p).padding(24).presentationDetents([.height(180)])
        }
        .alert(
            Loc.t("Something went wrong"),
            isPresented: Binding(get: { scene.error != nil }, set: { if !$0 { scene.error = nil } })
        ) {
            Button(Loc.t("OK"), role: .cancel) { scene.error = nil }
        } message: {
            Text(verbatim: scene.error ?? "")
        }
    }
}

extension FocusedValues {
    /// The window the menu bar's commands act on.
    @Entry public var touchScene: TouchScene?
}

/// The menu bar's window command (A7): Open… (⌘O). ⌘, is iPadOS's own: it opens the app's
/// page in the Settings app (D405). The canvas's commands are its `keyCommands` (D390).
public struct TouchSceneCommands: Commands {
    @FocusedValue(\.touchScene) var scene

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(Loc.t("Open…")) { scene?.opening = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(scene == nil)
        }
    }
}
#endif
