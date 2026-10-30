@preconcurrency import CoreSpotlight
import CryptoKit
import NexusAI
import NexusCanvas
import NexusCore
import NexusFormat
import NexusScene
import NexusTouch
import UIKit
import UniformTypeIdentifiers
import WidgetKit

/// iPadOS integration (M47b): Spotlight, the widgets, Share captures and `opennexus://`
/// links, as the Mac's `Integrations` does them. Captures the Share extension queued in the
/// App Group are added to the Inbox (or the map chosen) when the app comes forward.
@MainActor
final class Integrations {
    static let shared = Integrations()
    let prefs = Preferences.shared
    /// The windows' scenes, for Spotlight results and captures (the front one acts).
    private var scenes: [WeakScene] = []
    private var widgetRefresh: Task<Void, Never>?

    struct WeakScene { weak var scene: TouchScene? }

    func start() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Integrations.shared.drainCaptures() } }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) { n in
            let key = n.userInfo?["key"] as? String ?? ""
            MainActor.assumeIsolated { Integrations.shared.settingChanged(key) }
        }
        writeExtensionSettings()
        scheduleWidgetRefresh()
    }

    func attach(_ scene: TouchScene) {
        scenes.removeAll { $0.scene == nil }
        scenes.append(WeakScene(scene: scene))
        scene.onDocumentOpened = { [weak self] m in self?.documentOpened(m) }
    }

    var frontScene: TouchScene? { scenes.last { $0.scene != nil }?.scene }

    func settingChanged(_ key: String) {
        if key == "integrations.share" || key == "integrations.clipper" { writeExtensionSettings() }
        if key == "integrations.spotlight" {
            if prefs.bool("integrations.spotlight") {
                for s in scenes { if let m = s.scene?.document { index(m.document) } }
            } else {
                CSSearchableIndex.default().deleteAllSearchableItems()
            }
        }
    }

    func writeExtensionSettings() {
        guard let group = AppGroup.container else { return }
        try? ExtensionSettings(share: prefs.bool("integrations.share"), clipper: prefs.bool("integrations.clipper"))
            .write(to: group)
    }

    func documentOpened(_ m: TouchDocumentModel) {
        index(m.document)
        scheduleWidgetRefresh()
        m.document.store.addObserver(self) { _ in Integrations.shared.scheduleWidgetRefresh() }
    }

    // MARK: Spotlight

    /// One item per topic; choosing one opens the map at that topic. Encrypted documents
    /// are never indexed (D117).
    func index(_ doc: TouchDocument) {
        guard prefs.bool("integrations.spotlight"), !doc.isEncrypted, doc.lockedFiles == nil else { return }
        let url = doc.fileURL
        let domain = Self.token(url)
        rememberToken(url)
        let items = Self.searchableItems(doc.store.model, url: url)
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// A map's Spotlight items, at most 5,000: one per topic, in the file's domain.
    static func searchableItems(_ model: DocumentModel, url: URL) -> [CSSearchableItem] {
        let domain = token(url)
        let text = SpotlightText(model, fileName: url.lastPathComponent)
        return text.topics.prefix(5_000).map { t -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: UTType.text)
            a.title = t.text
            a.displayName = t.text
            a.contentDescription = "\(url.lastPathComponent) › \(t.breadcrumb)"
            a.textContent = [t.note, t.labels.joined(separator: " ")].compactMap { $0 }.joined(separator: "\n")
            a.keywords = t.labels
            a.containerTitle = text.title
            a.containerIdentifier = domain
            return CSSearchableItem(
                uniqueIdentifier: "\(domain)|\(t.canvas.rawValue)|\(t.node.rawValue)", domainIdentifier: domain,
                attributeSet: a)
        }
    }

    func continueSpotlight(_ activity: NSUserActivity, in scene: TouchScene) {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 3, let url = url(forToken: parts[0]) else { return }
        scene.open(url, canvas: CanvasID(parts[1]), node: NodeID(parts[2]))
    }

    // MARK: Tokens (links carry these, never a path)

    static func token(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static let tokensKey = "integrations.tokens"

    func rememberToken(_ url: URL) {
        guard let b = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        var all = UserDefaults.standard.dictionary(forKey: Self.tokensKey) as? [String: Data] ?? [:]
        all[Self.token(url)] = b
        UserDefaults.standard.set(all, forKey: Self.tokensKey)
    }

    func url(forToken token: String) -> URL? {
        guard let b = (UserDefaults.standard.dictionary(forKey: Self.tokensKey) as? [String: Data])?[token] else {
            return nil
        }
        var stale = false
        return try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: Widgets

    func scheduleWidgetRefresh() {
        widgetRefresh?.cancel()
        widgetRefresh = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            refreshWidgets()
        }
    }

    /// The inbox's newest items and the recent maps with their Quick Look previews.
    func refreshWidgets() {
        guard let group = AppGroup.container else { return }
        let inboxModel =
            openDocument(TouchLibrary.inboxURL)?.document.store.model
            ?? (try? NexusPackage.read(from: TouchLibrary.inboxURL))
        let inboxCanvas = inboxModel?.orderedCanvases.first
        let inbox =
            inboxCanvas.map { c in c.nodes[c.root]?.children.reversed().compactMap { c.nodes[$0]?.text } ?? [] } ?? []
        let dir = WidgetSnapshot.directory(in: group)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var recents: [WidgetSnapshot.Map] = []
        for url in TouchLibrary.shared.recents.prefix(4) {
            let token = Self.token(url)
            rememberToken(url)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var thumb: String?
            if let data = try? Data(contentsOf: url.appending(path: NexusPackage.previewName)) {
                thumb = "\(token).png"
                try? data.write(to: dir.appending(path: "\(token).png"), options: .atomic)
            }
            let doc = try? NexusPackage.read(from: url)
            let detail =
                doc.map {
                    "\($0.orderedCanvases.first.map { HomeView.typeName($0.type) } ?? "Map") · \(Loc.n("%lld topic", "%lld topics", $0.topicCount))"
                }
                ?? Loc.t("Locked")
            recents.append(
                .init(
                    token: token, title: url.deletingPathExtension().lastPathComponent, detail: detail, thumbnail: thumb
                ))
        }
        let snap = WidgetSnapshot(inbox: Array(inbox.prefix(6)), inboxCount: inbox.count, recents: recents)
        if snap.inbox != WidgetSnapshot.read(from: group)?.inbox
            || snap.recents != WidgetSnapshot.read(from: group)?.recents
        {
            try? snap.write(to: group)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Captures (Share, Shortcuts)

    /// Captures the Share extension queued in the App Group.
    func drainCaptures() {
        guard let group = AppGroup.container else { return }
        for c in CaptureQueue.drain(in: group) { Task { await receive(c) } }
    }

    func receive(_ c: Capture) async {
        let target = c.target.flatMap { url(forToken: $0) }
        switch c.kind {
        case .page where prefs.bool("integrations.clipper"):
            let points = await PageSummary.keyPoints(title: c.title ?? "", text: c.pageText ?? "", selection: c.text)
            add(.items([CaptureComposer.clip(title: c.title ?? c.text, points: points, url: c.url)]), to: target)
        case .link, .page:
            add(.items([.init(text: c.title ?? c.text, note: c.title == nil ? nil : c.text, link: c.url)]), to: target)
        case .image:
            add(.items([.init(text: c.text.isEmpty ? "Image" : c.text)]), to: target, image: c.image)
        case .text:
            guard let r = CaptureComposer.compose(c.text, multiline: prefs.string("integrations.captureMultiline"))
            else { return }
            add(r, to: target)
        }
    }

    /// Adds captured topics to a map (nil: the Inbox) as one undo step: the open document
    /// if it is that map, otherwise the file itself, through file coordination.
    func add(_ result: CaptureComposer.Result, to target: URL?, image: Data? = nil) {
        if case .map(let doc) = result {
            frontScene?.newDocument(doc)
            return
        }
        guard case .items(var items) = result, !items.isEmpty else { return }
        let url = target ?? TouchLibrary.inboxURL
        if url == TouchLibrary.inboxURL { TouchLibrary.ensureInbox() }
        if let open = openDocument(url) {
            let store = open.document.store
            attach(image, to: &items, in: store)
            if let canvas = store.model.orderedCanvases.first,
                let patch = CaptureComposer.patch(adding: items, to: canvas)
            {
                store.commit(patch)
                open.document.updateChangeCount(.done)
            }
        } else {
            let doc = TouchDocument(fileURL: url)
            Task { @MainActor in
                guard await doc.open() else { return }
                self.attach(image, to: &items, in: doc.store)
                if let canvas = doc.store.model.orderedCanvases.first,
                    let patch = CaptureComposer.patch(adding: items, to: canvas)
                {
                    doc.store.commit(patch)
                    doc.updateChangeCount(.done)
                }
                await doc.close()
                self.scheduleWidgetRefresh()
            }
        }
        scheduleWidgetRefresh()
    }

    /// The window showing the document at `url`, if one is.
    func openDocument(_ url: URL) -> TouchDocumentModel? {
        scenes.compactMap { $0.scene?.document }.first {
            $0.document.fileURL.standardizedFileURL == url.standardizedFileURL
        }
    }

    private func attach(_ image: Data?, to items: inout [CaptureComposer.Item], in store: DocumentStore) {
        guard let image, !items.isEmpty else { return }
        let name = CanvasController.storeAsset(image, ext: "png", in: store)
        let size = UIImage(data: image)?.size
        let w = size.map { min(Double($0.width), 200) }
        let h = size.map { Double($0.height) * (w ?? 200) / max(Double($0.width), 1) }
        items[0].image = AssetRef(asset: name, width: w, height: h)
    }
}
