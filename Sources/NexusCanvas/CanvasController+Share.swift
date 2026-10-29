import AppKit
import Foundation
import NexusCore
import NexusFormat

/// The Share Link sheet's settings (M44). What the link holds is an Interactive HTML
/// export's (`export`, format `.html`): scope, notes, comments, attachments, layouts,
/// theme and masking, so a link shows what the export would.
public struct ShareState: Equatable, Sendable {
    public enum Expiry: String, CaseIterable, Sendable { case never, day, week, month, date }
    public enum Phase: Equatable, Sendable {
        case editing
        case working
        case done(ShareRecord)
        case failed(String)
    }

    public var export: ExportState
    public var usePassword = false
    public var password = ""
    public var expiry = Expiry.never
    public var date = Date().addingTimeInterval(14 * 86_400)
    public var destination: String?
    public var autoUpdate = false
    public var phase = Phase.editing

    public init(export: ExportState) { self.export = export }

    /// When the link stops working, if ever.
    public func expires(from now: Date = Date()) -> Date? {
        switch expiry {
        case .never: nil
        case .day: now.addingTimeInterval(86_400)
        case .week: now.addingTimeInterval(7 * 86_400)
        case .month: now.addingTimeInterval(30 * 86_400)
        case .date: date
        }
    }
}

extension CanvasController {
    /// File › Share Link…: the sheet, or why it can't open (the network is off, or there's
    /// nowhere to store links).
    public func openShareLink() {
        if mode == .edit { commitEdit() }
        if !shareCenter.networkOn {
            shareNotice = .networkOff
            return
        }
        if shareCenter.store.destinations.isEmpty {
            shareNotice = .noDestination
            return
        }
        var e = ExportState.remembered(.html, prefs: prefs)
        e.image.selection = selection.nodes
        e.image.zone = targetZone
        var s = ShareState(export: e)
        s.expiry = ShareState.Expiry(rawValue: prefs.string("sharing.expiry")) ?? .never
        let last = prefs.string("sharing.lastDestination")
        s.destination = shareCenter.store.destination(last)?.id ?? shareCenter.store.destinations.first?.id
        shareState = s
    }

    public func setShare(_ s: ShareState) {
        var s = s
        s.export.image.selection = selection.nodes
        shareState = s
    }

    public func closeShare() {
        shareState = nil
        onRestoreFocus?()
    }

    public func closeShareNotice() {
        shareNotice = nil
        onRestoreFocus?()
    }

    /// What the link holds: the Interactive HTML export's bundle for the same options.
    public func shareBundle(_ s: ShareState) -> JSONValue {
        ViewerBundle.build(exportModel(s.export), viewerOptions(s.export), prefs: prefs)
    }

    /// The document's name, as links list it.
    var shareDocumentName: String {
        documentPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? exportFileName
    }

    func shareScope(_ e: ExportState) -> ShareScope {
        switch viewerOptions(e).scope {
        case .document: ShareScope(kind: .document, title: shareDocumentName)
        case .canvas(let c):
            ShareScope(kind: .canvas, canvas: c.rawValue, title: canvasTitle(c))
        case .branch(let c, let n):
            ShareScope(
                kind: .branch, canvas: c.rawValue, item: n.rawValue,
                title: store.model.canvases[c]?.nodes[n]?.text ?? "")
        case .zone(let c, let z):
            ShareScope(
                kind: .zone, canvas: c.rawValue, item: z,
                title: store.model.canvases[c]?.zones.first { $0.id == z }?.title ?? "")
        }
    }

    func canvasTitle(_ c: CanvasID) -> String {
        guard let canvas = store.model.canvases[c] else { return "" }
        return canvas.title.isEmpty ? canvas.nodes[canvas.root]?.text ?? "" : canvas.title
    }

    /// Create Link: seal, store, then show the link (or why it failed).
    public func createShareLink() {
        guard var s = shareState, let destination = s.destination, s.phase != .working else { return }
        var r = ShareRecord(
            document: shareDocumentName, path: documentPath, scope: shareScope(s.export), destination: destination)
        r.notes = s.export.html.notes
        r.comments = s.export.html.comments
        r.attachments = s.export.html.attachments
        r.expanded = s.export.html.expanded
        r.mask = s.export.mask
        r.theme = s.export.image.theme
        r.expires = s.expires()
        r.autoUpdate = s.autoUpdate
        let bundle = shareBundle(s)
        let password = s.usePassword ? s.password : nil
        s.export.remember(in: prefs.defaults)
        prefs.set("sharing.lastDestination", destination)
        s.phase = .working
        shareState = s
        Task {
            let phase: ShareState.Phase
            do {
                phase = .done(try await shareCenter.create(bundle, record: r, password: password))
            } catch {
                phase = .failed(String(describing: error))
            }
            guard var now = shareState else { return }
            now.phase = phase
            now.password = ""
            shareState = now
        }
    }

    /// The export settings a record was made with, for Update.
    func exportState(for r: ShareRecord) -> ExportState? {
        var e = ExportState.remembered(.html, prefs: prefs)
        e.html.notes = r.notes
        e.html.comments = r.comments
        e.html.attachments = r.attachments
        e.html.expanded = r.expanded
        e.mask = r.mask
        e.image.theme = r.theme
        e.html.document = r.scope.kind == .document
        switch r.scope.kind {
        case .document, .canvas:
            e.image.scope = .canvas
        case .branch:
            guard let n = r.scope.item, store.model.canvases[CanvasID(r.scope.canvas ?? "")]?.nodes[NodeID(n)] != nil
            else { return nil }
            e.image.scope = .branch
            e.image.selection = [NodeID(n)]
        case .zone:
            guard let z = r.scope.item,
                store.model.canvases[CanvasID(r.scope.canvas ?? "")]?.zones.contains(where: { $0.id == z }) == true
            else { return nil }
            e.image.scope = .zone
            e.image.zone = z
        }
        return e
    }

    /// The bundle a record holds, from this document as it is now (nil when its canvas,
    /// branch or zone is gone).
    public func shareBundle(for r: ShareRecord) -> JSONValue? {
        guard let e = exportState(for: r) else { return nil }
        if let c = r.scope.canvas, r.scope.kind != .document {
            guard store.model.canvases[CanvasID(c)] != nil else { return nil }
            // `viewerOptions` reads the scope's canvas from the controller's own canvas.
            if CanvasID(c) != canvasID {
                let other = CanvasController(store: store, canvasID: CanvasID(c))
                other.prefs = prefs
                return ViewerBundle.build(other.exportModel(e), other.viewerOptions(e), prefs: prefs)
            }
        }
        return ViewerBundle.build(exportModel(e), viewerOptions(e), prefs: prefs)
    }

    /// Links of this document marked "Update when I save" are re-published (the app calls
    /// this after a save). A later call replaces one still waiting, so autosaves coalesce.
    public func republishShareLinks(after delay: Duration = .zero) {
        shareRepublish?.cancel()
        guard let path = documentPath, shareCenter.networkOn,
            shareCenter.store.links.contains(where: { $0.autoUpdate && $0.path == path && !$0.isExpired() })
        else { return }
        shareRepublish = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            let due = shareCenter.store.links.filter { $0.autoUpdate && $0.path == path && !$0.isExpired() }
            for r in due {
                guard let b = shareBundle(for: r) else { continue }
                try? await shareCenter.update(r, bundle: b)
            }
        }
    }

    public func closeManageLinks() {
        manageLinks = false
        onRestoreFocus?()
    }

    /// Copies a link and says so.
    public func copyShareLink(_ r: ShareRecord) {
        guard let link = shareCenter.link(r) else { return }
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        showToast(r.password ? Loc.t("Link copied · it asks for the password") : Loc.t("Link copied"))
    }
}
