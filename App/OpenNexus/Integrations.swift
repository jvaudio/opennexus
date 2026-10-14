import AppKit
import CoreSpotlight
import CryptoKit
import NexusAI
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import UniformTypeIdentifiers
import WidgetKit

/// macOS integration (M9): Spotlight, widgets, Services, Share and Safari captures,
/// `opennexus://` links, Handoff, and the agent settings `nexus mcp` reads. Quick Capture
/// lives in QuickCapture.swift; App Intents in Intents.swift.
@MainActor
final class Integrations: NSObject {
    static let shared = Integrations()
    let prefs = Preferences.shared
    private var observer: (any NSObjectProtocol)?
    private var widgetRefresh: DispatchWorkItem?

    func start() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) {
            n in
            let key = n.userInfo?["key"] as? String ?? ""
            MainActor.assumeIsolated { Integrations.shared.settingChanged(key) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Integrations.shared.drainCaptures() } }
        writeAgentPolicy()
        QuickCapture.shared.start()
        drainCaptures()
        scheduleWidgetRefresh()
    }

    func settingChanged(_ key: String) {
        if key.hasPrefix("integrations.mcp") || key == AgentFolders.key || key == "integrations.share"
            || key == "integrations.clipper"
        {
            writeAgentPolicy()
        }
        if key == "integrations.spotlight" {
            if prefs.bool("integrations.spotlight") {
                for d in NSDocumentController.shared.documents { if let nx = d as? NexusDocument { index(nx) } }
            } else {
                CSSearchableIndex.default().deleteAllSearchableItems()
            }
        }
        if key.hasPrefix("integrations.capture") { QuickCapture.shared.start() }
    }

    // MARK: Documents

    func documentOpened(_ doc: NexusDocument) {
        index(doc)
        scheduleWidgetRefresh()
    }

    func documentSaved(_ doc: NexusDocument) {
        index(doc)
        scheduleWidgetRefresh()
    }

    // MARK: Agent settings (`nexus mcp`)

    /// Written to the App Group, where the embedded `nexus` (signed by the same team)
    /// reads it, and to the app container for unsigned builds (D116).
    func writeAgentPolicy() {
        let policy = AgentFolders.policy(prefs)
        var targets: [URL] = []
        if let group = AppGroup.container { targets.append(group.appending(path: AgentPolicy.fileName)) }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            targets.append(support.appending(path: "OpenNexus/\(AgentPolicy.fileName)"))
        }
        for t in targets { try? policy.write(to: t) }
        if let group = AppGroup.container {
            try? ExtensionSettings(share: prefs.bool("integrations.share"), clipper: prefs.bool("integrations.clipper"))
                .write(to: group)
        }
    }

    // MARK: Spotlight

    /// One item per topic; choosing one opens the map at that topic. Encrypted documents
    /// are never indexed (D117).
    func index(_ doc: NexusDocument) {
        guard prefs.bool("integrations.spotlight"), doc.cryptoKey == nil, doc.lockedFiles == nil,
            let url = doc.fileURL
        else { return }
        let domain = doc.documentID
        rememberBookmark(url, for: domain)
        let text = SpotlightText(doc.store.model, fileName: url.lastPathComponent)
        let items = text.topics.prefix(5_000).map { t -> CSSearchableItem in
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
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(Array(items)) { _ in }
        }
    }

    func rememberBookmark(_ url: URL, for domain: String) {
        guard
            let data = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        var all = UserDefaults.standard.dictionary(forKey: "integrations.bookmarks") as? [String: Data] ?? [:]
        all[domain] = data
        UserDefaults.standard.set(all, forKey: "integrations.bookmarks")
    }

    func url(forBookmark key: String) -> URL? {
        guard let data = (UserDefaults.standard.dictionary(forKey: "integrations.bookmarks") as? [String: Data])?[key]
        else { return nil }
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        _ = url?.startAccessingSecurityScopedResource()
        return url
    }

    /// Opens a map and selects a topic (Spotlight results, Handoff, widget links).
    func open(_ url: URL, canvas: CanvasID?, node: NodeID?) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
            MainActor.assumeIsolated {
                guard let wc = (doc as? NexusDocument)?.windowControllers.first as? DocumentWindowController else {
                    return
                }
                let c = wc.controller
                if let canvas, c.store.model.canvases[canvas] != nil, canvas != c.canvasID {
                    c.switchCanvas(to: canvas)
                }
                if let node, c.canvas.nodes[node] != nil {
                    c.select(node)
                    c.onReveal?(node)
                }
            }
        }
    }

    /// Spotlight's "open this result".
    func continueActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
            let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return false }
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 3, let url = url(forBookmark: parts[0]) else { return false }
        open(url, canvas: CanvasID(parts[1]), node: NodeID(parts[2]))
        return true
    }

    // MARK: Widgets

    func scheduleWidgetRefresh() {
        widgetRefresh?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { Integrations.shared.refreshWidgets() } }
        widgetRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// The inbox's newest items and the recent maps with their Quick Look previews.
    func refreshWidgets() {
        guard let group = AppGroup.container else { return }
        let inboxCanvas = (try? NexusPackage.read(from: Inbox.url))?.orderedCanvases.first
        let inbox =
            inboxCanvas.map { c in c.nodes[c.root]?.children.reversed().compactMap { c.nodes[$0]?.text } ?? [] } ?? []
        var tokens = UserDefaults.standard.dictionary(forKey: "widgets.tokens") as? [String: String] ?? [:]
        let dir = WidgetSnapshot.directory(in: group)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var recents: [WidgetSnapshot.Map] = []
        for url in NSDocumentController.shared.recentDocumentURLs.prefix(4) {
            let token = Self.token(url)
            tokens[token] = url.path
            var thumb: String?
            let preview = url.appending(path: NexusPackage.previewName)
            if let data = try? Data(contentsOf: preview) {
                thumb = "\(token).png"
                try? data.write(to: dir.appending(path: thumb!), options: .atomic)
            }
            let doc = try? NexusPackage.read(from: url)
            let detail =
                doc.map {
                    "\($0.orderedCanvases.first.map { HomeView.typeName($0.type) } ?? "Map") · \($0.topicCount) topics"
                }
                ?? "Locked"
            recents.append(
                .init(
                    token: token, title: url.deletingPathExtension().lastPathComponent, detail: detail, thumbnail: thumb
                ))
        }
        UserDefaults.standard.set(tokens, forKey: "widgets.tokens")
        let snap = WidgetSnapshot(inbox: Array(inbox.prefix(6)), inboxCount: inbox.count, recents: recents)
        if snap.inbox != WidgetSnapshot.read(from: group)?.inbox
            || snap.recents != WidgetSnapshot.read(from: group)?.recents
        {
            try? snap.write(to: group)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// An opaque, stable token for a map (links carry this, never a path).
    static func token(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: opennexus:// links

    /// `opennexus://capture` (the Share extension queued something), `quick-capture`,
    /// `inbox`, `open/<token>` (widgets), `new`.
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else {
            return
        }
        handle(url)
    }

    func handle(_ url: URL) {
        guard url.scheme == "opennexus" else { return }
        switch url.host() {
        case "capture": drainCaptures()
        case "quick-capture": QuickCapture.shared.show()
        case "inbox": openInbox()
        case "open":
            let token = url.lastPathComponent
            if let path = (UserDefaults.standard.dictionary(forKey: "widgets.tokens") as? [String: String])?[token] {
                open(URL(fileURLWithPath: path), canvas: nil, node: nil)
            }
        case "new": NewDocument.make()
        default: break
        }
    }

    func openInbox() {
        Inbox.ensure()
        NSDocumentController.shared.openDocument(withContentsOf: Inbox.url, display: true) { _, _, _ in }
    }

    // MARK: Captures (Share, Safari, Services, Quick Capture, intents)

    /// Captures the Share extension and Safari clipper queued in the App Group (or, in an
    /// unsigned build, on the private pasteboard).
    func drainCaptures() {
        var captures: [Capture] = []
        if let group = AppGroup.container { captures += CaptureQueue.drain(in: group) }
        let pb = NSPasteboard(name: .init("com.opennexus.capture"))
        if let data = pb.data(forType: .init("com.opennexus.capture")) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let c = try? dec.decode([Capture].self, from: data) { captures += c }
            pb.clearContents()
        }
        for c in captures { Task { await receive(c) } }
    }

    func receive(_ c: Capture) async {
        let target = c.target.flatMap { t in
            (UserDefaults.standard.dictionary(forKey: "widgets.tokens") as? [String: String])?[t]
        }.map { URL(fileURLWithPath: $0) }
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
            else {
                return
            }
            add(r, to: target)
        }
    }

    /// Adds captured topics to a map (nil: Settings › Send captures to) as one undo step,
    /// or opens a new map. A map that wasn't open is saved and closed again.
    func add(_ result: CaptureComposer.Result, to target: URL?, image: Data? = nil, title: String = "Capture") {
        if case .map(let doc) = result {
            NewDocument.make(model: doc)
            return
        }
        guard case .items(let items) = result, !items.isEmpty else { return }
        let url = target ?? defaultCaptureTarget()
        if url == Inbox.url { Inbox.ensure() }
        let wasOpen = NSDocumentController.shared.document(for: url)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { doc, _, _ in
            MainActor.assumeIsolated {
                guard let nx = doc as? NexusDocument, let canvas = nx.store.model.orderedCanvases.first else { return }
                var items = items
                if let image, !items.isEmpty {
                    let name = CanvasController.storeAsset(image, ext: "png", in: nx.store)
                    let size = NSImage(data: image)?.size
                    let w = size.map { min(Double($0.width), 200) }
                    let h = size.map { Double($0.height) * (w ?? 200) / max(Double($0.width), 1) }
                    items[0].image = AssetRef(asset: name, width: w, height: h)
                }
                guard let patch = CaptureComposer.patch(adding: items, to: canvas) else { return }
                nx.store.commit(patch)
                nx.updateChangeCount(.changeDone)
                Integrations.shared.scheduleWidgetRefresh()
                if wasOpen == nil {
                    nx.autosave(withImplicitCancellability: false) { _ in MainActor.assumeIsolated { nx.close() } }
                }
            }
        }
    }

    func defaultCaptureTarget() -> URL {
        if prefs.string("integrations.captureTarget") == "last",
            let u = NSDocumentController.shared.recentDocumentURLs.first
        {
            return u
        }
        return Inbox.url
    }
}

// MARK: Services (Settings › Services menu: New Map from Selection)

extension Integrations {
    /// "New OpenNexus Map from Selection": the selected text becomes a map (outline text
    /// keeps its hierarchy).
    @objc func newMapFromSelection(
        _ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard prefs.bool("integrations.services") else {
            error.pointee = "Services are turned off in OpenNexus › Settings › Integrations." as NSString
            return
        }
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        if let (ic, _) = Interchange.parsePasted(text, title: "Selection") {
            var report = ImportReport(source: "Selection", format: "Text")
            NewDocument.make(model: DocumentModel(canvases: CanvasBuilder.build([ic], report: &report)))
        } else {
            var c = Canvas(id: "c1", title: "", rootText: text.trimmingCharacters(in: .whitespacesAndNewlines))
            CanvasController.applyDefaults(&c, prefs: prefs)
            NewDocument.make(model: DocumentModel(canvases: [c]))
        }
        NSApp.activate()
    }

    /// "Add to OpenNexus Inbox": the selection becomes inbox topics.
    @objc func addSelectionToInbox(
        _ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard prefs.bool("integrations.services") else {
            error.pointee = "Services are turned off in OpenNexus › Settings › Integrations." as NSString
            return
        }
        guard let text = pb.string(forType: .string), let r = CaptureComposer.compose(text) else { return }
        add(r, to: Inbox.url)
    }
}
