#if os(iOS)
import AVFoundation
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusKeys
import NexusScene
import Observation
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// One open document on the iPad (M47b): what `DocumentWindowController` is on the Mac.
/// It owns the controller and the canvas, outline and Gantt views, answers the window
/// commands (File, canvas tabs, sharing, collaboration) and the controller's file hooks,
/// and holds the state the screen shows: the view mode, the inspector, the popover a
/// request opened, immersion for ZEN and Present.
@MainActor
@Observable
public final class TouchDocumentModel {
    public let document: TouchDocument
    public let controller: CanvasController
    @ObservationIgnored public let canvasView: TouchCanvasView
    @ObservationIgnored public let outlineView: TouchOutlineView
    @ObservationIgnored public let ganttView: TouchGanttView

    public private(set) var viewMode: CanvasViewMode = .canvas
    public var inspectorVisible = UserDefaults.standard.bool(forKey: "formatPanelVisible") {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: "formatPanelVisible") }
    }
    /// ZEN and Present hide the toolbar, the tabs and the inspector.
    public private(set) var immersive = false
    /// Presenting, and whether the audience sees it on another display (the iPad then
    /// shows the presenter view).
    public private(set) var presenting = false
    public var presenterVisible = false
    /// A request's popover and where it hangs.
    public var request: ActiveRequest?
    /// Rename Canvas…, Delete Canvas…, the password prompt, Settings, the starter picker.
    public var renaming: CanvasID?
    public var renameText = ""
    public var confirmingDelete: CanvasID?
    public var needsPassword = false
    public var settingsPane: SettingsRequest?
    public var choosingStarter = false
    /// The document camera is open (Scan Document…).
    public var scanning = false
    /// A file to preview (attachments) or hand to the share sheet.
    public var quickLook: URL?
    public var printing: PrintJob?
    public var error: String?

    /// Closes the document (Home comes back).
    @ObservationIgnored public var onClose: () -> Void = {}
    /// File › Import…, joining a live session, and new documents go through the library.
    @ObservationIgnored public var onImport: () -> Void = {}
    @ObservationIgnored public var onJoin: (String) -> Void = { _ in }
    @ObservationIgnored public var onOpenDocument: (DocumentModel, String) -> Void = { _, _ in }

    @ObservationIgnored private var chromeBeforeImmersion: (inspector: Bool, mode: CanvasViewMode)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var snapshotTimer: Timer?

    public struct ActiveRequest: Identifiable {
        public let id = UUID()
        public var request: CanvasRequest
        public var anchor: CGRect
        public var size: CGSize
    }

    public struct SettingsRequest: Identifiable {
        public var pane: String
        public var record: CommandID?
        public var id: String { pane + (record?.rawValue ?? "") }
    }

    public struct PrintJob: Identifiable {
        public let id = UUID()
        public var data: Data
        public var name: String
    }

    /// The commands the screen runs rather than the controller (the Mac's window commands,
    /// less Move to New Window: an iPad scene shows one canvas of a document).
    public static let windowCommands: Set<CommandID> = [
        .newCanvas, .inspector, .importFile, .setPassword, .recoverySnapshots, .renameCanvas, .duplicateCanvas,
        .deleteCanvas, .copyCanvas, .pasteCanvas, .saveCanvasAsDocument, .mergeDocuments, .printDocument, .export,
        .exportHTML, .shareLink, .manageShareLinks, .mapShot, .splitByBranch, .nextPanel, .previousPanel,
        .syncHistory, .resolveConflicts, .mergeConflictCopies, .collaborate, .joinSession,
    ]

    public init(document: TouchDocument) {
        self.document = document
        controller = CanvasController(store: document.store)
        canvasView = TouchCanvasView(controller: controller)
        outlineView = TouchOutlineView(controller: controller)
        ganttView = TouchGanttView(controller: controller)
        outlineView.isHidden = true
        ganttView.isHidden = true
        wire()
        startSnapshots()
        if document.isFresh {
            DispatchQueue.main.async { [controller] in controller.beginEditing(replacingWith: "") }
        } else if let z = controller.defaultZoom, document.fileURL.pathExtension.isEmpty {
            canvasView.setZoom(z)
        }
        if document.lockedFiles != nil && !document.unlockFromKeychain() { needsPassword = true }
    }

    public var title: String {
        let name = document.fileURL.deletingPathExtension().lastPathComponent
        return name.isEmpty ? Loc.t("Untitled") : name
    }

    // MARK: Wiring

    private func wire() {
        controller.onViewMode = { [weak self] m in self?.apply(m) }
        controller.onOpenAISettings = { [weak self] in self?.settingsPane = SettingsRequest(pane: "ai") }
        controller.onRebind = { [weak self] id in self?.settingsPane = SettingsRequest(pane: "shortcuts", record: id) }
        controller.onOpenSettings = { [weak self] pane in self?.settingsPane = SettingsRequest(pane: pane) }
        controller.documentPath = document.fileURL.path
        controller.documentIDProvider = { [weak self] in self?.document.documentID ?? UUID().uuidString }
        controller.onJoinSession = { [weak self] link in self?.onJoin(link) }
        controller.onCollabAttached = { [weak self] s in self?.attach(s) }
        controller.onCollabEnded = { [weak self] in self?.document.undoManager?.removeAllActions() }
        controller.onZen = { [weak self] on in self?.setImmersive(on) }
        controller.onPresent = { [weak self] on in
            guard let self else { return }
            self.presenting = on
            self.setImmersive(on)
            self.presenterVisible = on && ExternalDisplay.shared.connected
            if !on { self.controller.refreshView() }
        }
        controller.onTogglePresenter = { [weak self] in self?.presenterVisible.toggle() }
        controller.onExportSlides = { [weak self] f in self?.exportSlides(f) }
        controller.externalCommands = Self.windowCommands
        controller.onExternalCommand = { [weak self] id in self?.runWindowCommand(id) }
        canvasView.onWindowCommand = { [weak self] id in
            guard let self else { return false }
            // ⌘Z and ⇧⌘Z: the document's undo, as the Mac's Edit menu sends `undo:` to it.
            if id == .undo || id == .redo { return self.undoOrRedo(id) }
            guard Self.windowCommands.contains(id) else { return false }
            self.runWindowCommand(id)
            return true
        }
        controller.onRequest = { [weak self] r in self?.handle(r) }
        controller.onOpenURL = { url in UIApplication.shared.open(url) }
        controller.onSaveText = { [weak self] name, text in self?.save(Data(text.utf8), suggested: name) }
        controller.onShowFormatPanel = { [weak self] in self?.inspectorVisible = true }
        controller.onSaveFile = { [weak self] data, name in self?.save(data, suggested: name) }
        controller.onSaveFolder = { [weak self] files in self?.saveFolder(files) }
        controller.onSaveMapShot = { [weak self] data, name in self?.save(data, suggested: name) }
        controller.onPrintPDF = { [weak self] data, name in self?.printing = PrintJob(data: data, name: name) }
        controller.onSaveDocument = { [weak self] doc, name in self?.saveDocument(doc, name: name) }
        controller.onChooseMergeFiles = { [weak self] in self?.chooseMergeFiles() }
        controller.onSetPassword = { [weak self] pw, hint, remember in
            self?.document.setPassword(pw, hint: hint, remember: remember)
            self?.controller.showToast(Loc.t("Encrypted · recovery snapshots use the same key"))
        }
        controller.onRemovePassword = { [weak self] in
            self?.document.removePassword()
            self?.controller.showToast(Loc.t("Password removed"))
        }
        controller.onConflictCopiesMerged = { [weak self] copies in
            guard let url = self?.document.fileURL else { return }
            ConflictCopies.finish(copies, of: url)
        }
        controller.onRestoreSnapshot = { [weak self] s in
            guard let self else { return }
            self.document.restore(s, controller: self.controller)
        }
        document.onMerged = { [weak self] conflicts in
            guard let self else { return }
            self.controller.showToast(
                conflicts.isEmpty
                    ? Loc.t("Updated with changes made elsewhere · ⌘Z undoes")
                    : Loc.n(
                        "Merged changes made elsewhere · %lld conflict kept both ways",
                        "Merged changes made elsewhere · %lld conflicts kept both ways", conflicts.count))
        }
        document.onError = { [weak self] text in self?.error = text }
    }

    /// A session starting here: undo history starts over (undo is selective from now on), and
    /// other people's edits mark the document edited so autosave keeps them.
    func attach(_ s: CollabSession) {
        document.undoManager?.removeAllActions()
        s.onRemoteChange = { [weak self] in self?.document.updateChangeCount(.done) }
        s.onEnded = { [weak self] why in self?.controller.collabEnded(why) }
    }

    /// Reopening a document that's in a session reconnects it.
    public func resumeSession() {
        guard case .string(let id)? = document.store.model.manifestExtra["documentID"],
            let s = CollabCenter.shared.resume(store: document.store, documentID: id)
        else { return }
        controller.attach(s)
    }

    /// Settings › Files › Snapshot every N seconds of editing.
    private func startSnapshots() {
        let every = max(10, Double(controller.prefs.string("files.snapshotEvery")) ?? 30)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.document.writeSnapshot() }
        }
    }

    /// Ends the document's session on this iPad: a last snapshot, the look remembered, the
    /// session kept for the next open.
    public func close() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        document.writeSnapshot()
        controller.rememberLook()
        if case .string(let id)? = document.store.model.manifestExtra["documentID"] { CollabCenter.shared.suspend(id) }
        document.close { _ in }
        onClose()
    }

    // MARK: View modes and immersion

    public func setViewMode(_ m: CanvasViewMode) { controller.viewMode = m }

    func apply(_ mode: CanvasViewMode) {
        viewMode = mode
        outlineView.isHidden = mode == .canvas || mode == .gantt
        ganttView.isHidden = mode != .gantt
        canvasView.isHidden = mode == .outline || mode == .gantt
        controller.outlineFocused = mode == .outline || mode == .split
        controller.ganttFocused = mode == .gantt
        switch mode {
        case .canvas: canvasView.takeKeyboard()
        case .gantt: _ = ganttView.becomeFirstResponder()
        default: _ = outlineView.becomeFirstResponder()
        }
    }

    /// ZEN and Present hide the chrome; leaving restores it.
    func setImmersive(_ on: Bool) {
        if on {
            if chromeBeforeImmersion == nil { chromeBeforeImmersion = (inspectorVisible, controller.viewMode) }
            inspectorVisible = false
            if controller.viewMode != .canvas { controller.viewMode = .canvas }
            immersive = true
        } else if let before = chromeBeforeImmersion {
            chromeBeforeImmersion = nil
            immersive = false
            inspectorVisible = before.inspector
            controller.viewMode = before.mode
        }
        _ = canvasView.becomeFirstResponder()
    }

    // MARK: Window commands

    /// Undo or Redo on the document; false when there's nothing to undo or redo.
    func undoOrRedo(_ id: CommandID) -> Bool {
        guard let u = document.undoManager else { return false }
        if id == .undo, u.canUndo {
            u.undo()
            return true
        }
        if id == .redo, u.canRedo {
            u.redo()
            return true
        }
        return false
    }

    public func runWindowCommand(_ id: CommandID) {
        switch id {
        case .newCanvas: addCanvas()
        case .inspector: inspectorVisible.toggle()
        case .importFile: onImport()
        case .setPassword:
            controller.documentEncrypted = document.isEncrypted
            controller.passwordSheet = true
        case .recoverySnapshots: controller.snapshots = document.snapshots
        case .renameCanvas:
            renameText = controller.canvas.title
            renaming = controller.canvasID
        case .duplicateCanvas: controller.duplicateCanvas()
        case .deleteCanvas: confirmingDelete = controller.canvasID
        case .copyCanvas: controller.copyCanvas()
        case .pasteCanvas: controller.pasteCanvas()
        case .saveCanvasAsDocument: controller.saveCanvasAsDocument()
        case .mergeDocuments: controller.openMerge()
        case .printDocument: controller.openPrint()
        case .export: controller.openExport()
        case .exportHTML: controller.openExport(.html)
        case .shareLink: controller.openShareLink()
        case .manageShareLinks: controller.manageLinks = true
        case .syncHistory: controller.openSyncHistory()
        case .resolveConflicts:
            document.resolveConflicts()
            controller.openResolveConflicts()
        case .mergeConflictCopies: findConflictCopies(offer: false)
        case .collaborate: controller.openCollaborate()
        case .joinSession: controller.openJoinSession()
        case .mapShot: controller.openMapShot()
        case .splitByBranch: controller.splitByBranch()
        case .nextPanel, .previousPanel: moveFocus(forward: id == .nextPanel)
        default: break
        }
    }

    /// ⌘T, the tab strip's + and New Canvas: the starter picker, unless Settings › Editing
    /// turns it off, which uses the starter picked last.
    public func addCanvas() {
        if !controller.prefs.bool("editing.starterPicker") {
            controller.addCanvas(from: StarterLibrary.lastUsed(prefs: controller.prefs))
        } else {
            choosingStarter = true
        }
    }

    public func rename() {
        let t = renameText.trimmingCharacters(in: .whitespaces)
        if let id = renaming, !t.isEmpty {
            controller.switchCanvas(to: id)
            controller.renameCanvas(t)
        }
        renaming = nil
    }

    public func confirmDelete() {
        if let id = confirmingDelete { controller.deleteCanvas(id) }
        confirmingDelete = nil
    }

    /// Copies other apps' sync left beside this document (M45).
    public func findConflictCopies(offer: Bool) {
        let copies = ConflictCopies.find(for: document.fileURL)
        guard !copies.isEmpty else {
            if !offer { controller.showToast(Loc.t("No conflicting copies of this document")) }
            return
        }
        controller.offerConflictCopies(copies)
        if !offer { controller.mergeConflictCopies() }
    }

    /// F6 / ⇧F6: canvas (or outline or Gantt), then the inspector when it shows.
    func moveFocus(forward: Bool) {
        var regions: [(String, UIResponder)] = []
        switch viewMode {
        case .canvas: regions.append((Loc.t("Canvas"), canvasView))
        case .outline: regions.append((Loc.t("Outline"), outlineView))
        case .split: regions += [(Loc.t("Outline"), outlineView), (Loc.t("Canvas"), canvasView)]
        case .gantt: regions.append((Loc.t("Gantt chart"), ganttView))
        }
        let current = regions.firstIndex { $0.1.isFirstResponder }
        let i = current.map { (forward ? $0 + 1 : $0 - 1 + regions.count) % regions.count } ?? 0
        _ = regions[i].1.becomeFirstResponder()
        UIAccessibility.post(notification: .announcement, argument: regions[i].0)
    }

    // MARK: Requests (popovers)

    func handle(_ r: CanvasRequest) {
        switch r {
        case .audio(let id):
            if let a = controller.canvas.nodes[id]?.audio, let data = controller.store.model.assets[a.asset] {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                player = try? AVAudioPlayer(data: data)
                player?.play()
                controller.showToast(Loc.f("Playing audio note · %lld s", Int(a.duration)))
                return
            }
        case .image(let id):
            PlatformOpen.choose([.image]) { [weak self] urls in
                guard let self, let url = urls.first else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                self.controller.setImage(
                    data, ext: url.pathExtension.isEmpty ? "png" : url.pathExtension, size: UIImage(data: data)?.size,
                    on: id, source: url)
            }
            return
        case .attachment(let id, let index):
            guard let n = controller.canvas.nodes[id], n.attachments.indices.contains(index),
                let data = controller.store.model.assets[n.attachments[index].asset]
            else { return }
            let name = n.attachments[index].name ?? n.attachments[index].asset
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
            quickLook = url
            return
        default: break
        }
        guard let size = CanvasRequestView.size(r, controller: controller) else { return }
        request = ActiveRequest(request: r, anchor: anchor(for: r), size: size)
    }

    /// Where a request's popover hangs: the topic's row in the outline or the Gantt while
    /// that view shows, else the topic (or the legend) on the canvas (D254).
    func anchor(for r: CanvasRequest) -> CGRect {
        let fallback = CGRect(x: canvasView.bounds.midX, y: canvasView.bounds.midY, width: 1, height: 1)
        guard let id = r.node else {
            if let rect = controller.scene.legend?.rect { return canvasView.camera.toView(rect) }
            return canvasView.viewRect(of: controller.selection.primary) ?? fallback
        }
        if viewMode == .gantt, let a = ganttView.anchor(of: id) { return ganttView.convert(a, to: canvasView) }
        if viewMode == .outline || (viewMode == .split && controller.outlineFocused),
            let a = outlineView.anchor(of: id)
        {
            return outlineView.convert(a, to: canvasView)
        }
        return canvasView.viewRect(of: id) ?? fallback
    }

    public func closeRequest() {
        request = nil
        _ = canvasView.becomeFirstResponder()
    }

    // MARK: Files

    /// Exports go through the document picker (Save to Files).
    func save(_ data: Data, suggested name: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            controller.showToast(Loc.f("Couldn’t write %@: %@", name, error.localizedDescription))
            return
        }
        PlatformOpen.export(url) { [weak self] saved in
            if saved != nil { self?.controller.showToast(Loc.f("Exported %@", name)) }
        }
    }

    func saveFolder(_ files: [(String, Data)]) {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: controller.canvas.title.isEmpty
                ? Loc.t("Export") : controller.canvas.title)
        try? FileManager.default.removeItem(at: folder)
        do {
            for (name, data) in files {
                let url = folder.appending(path: name)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        } catch {
            controller.showToast(Loc.f("Couldn’t write %@: %@", folder.lastPathComponent, error.localizedDescription))
            return
        }
        PlatformOpen.export(folder) { [weak self] saved in
            if saved != nil {
                self?.controller.showToast(Loc.n("Exported %lld File", "Exported %lld Files", files.count))
            }
        }
    }

    func saveDocument(_ doc: DocumentModel, name: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: name + ".nexus")
        do {
            try? FileManager.default.removeItem(at: url)
            try NexusPackage.write(doc, to: url)
        } catch {
            controller.showToast(Loc.f("Couldn’t save: %@", error.localizedDescription))
            return
        }
        PlatformOpen.export(url) { [weak self] saved in
            if saved != nil { self?.controller.showToast(Loc.f("Saved %@", url.lastPathComponent)) }
        }
    }

    func chooseMergeFiles() {
        PlatformOpen.choose(TouchLibrary.importTypes, multiple: true) { [weak self] urls in
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                self?.controller.addMergeSource(url)
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    /// Export: PDF · PowerPoint · Video (Keynote opens PowerPoint files).
    func exportSlides(_ format: String) {
        let base = controller.canvas.title.isEmpty ? Loc.t("Slides") : controller.canvas.title
        let images = SlideExporter.renderSlides(document.store.model, canvas: controller.canvasID)
        let slides = controller.slides.filter { !$0.skipped }
        switch format {
        case "PDF": save(SlideExporter.pdf(images), suggested: "\(base).pdf")
        case "Video":
            let url = FileManager.default.temporaryDirectory.appending(path: "\(base).mp4")
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor [weak self] in
                do {
                    try await SlideExporter.video(images, to: url)
                    PlatformOpen.export(url) { [weak self] saved in
                        if saved != nil { self?.controller.showToast(Loc.t("Video exported")) }
                    }
                } catch {
                    self?.controller.showToast(Loc.f("Video export failed: %@", error.localizedDescription))
                }
            }
        default:
            save(
                SlideExporter.pptx(images, titles: slides.map(\.title), notes: slides.map(\.note)),
                suggested: "\(base).pptx")
        }
    }

    /// The password prompt's Open.
    public func unlock(_ password: String, remember: Bool) -> Bool {
        do {
            try document.unlock(password: password, remember: remember)
            needsPassword = false
            if let first = document.store.model.canvasOrder.first { controller.switchCanvas(to: first) }
            return true
        } catch {
            return false
        }
    }
}

extension CanvasRequest {
    /// The topic a request is about (the legend's is about none).
    var node: NodeID? {
        switch self {
        case .note(let id), .comments(let id), .link(let id), .labels(let id), .markers(let id), .stickers(let id),
            .audio(let id), .image(let id):
            id
        case .attachment(let id, _): id
        case .legend: nil
        }
    }
}
#endif
