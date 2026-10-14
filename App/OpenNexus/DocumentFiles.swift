import AppKit
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusKeys
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Files, import and export in the document window (M7): save and open panels, printing,
/// the Map Shot folder, passwords, recovery snapshots and the canvas tab menu.
extension DocumentWindowController {
    /// Commands the window (not the canvas) runs.
    static let windowCommands: Set<CommandID> = [
        .newCanvas, .inspector, .importFile, .setPassword, .recoverySnapshots, .renameCanvas, .moveCanvasToWindow,
        .duplicateCanvas, .deleteCanvas, .copyCanvas, .pasteCanvas, .saveCanvasAsDocument, .mergeDocuments,
        .printDocument, .export, .mapShot, .splitByBranch,
    ]

    func runWindowCommand(_ id: CommandID) {
        switch id {
        case .newCanvas: addCanvas()
        case .inspector: toggleFormatPanel()
        case .importFile: (NSApp.delegate as? AppDelegate)?.importDocument(nil)
        case .setPassword: controller.documentEncrypted = document_.cryptoKey != nil; controller.passwordSheet = true
        case .recoverySnapshots: controller.snapshots = document_.snapshots
        case .renameCanvas: renameCanvas()
        case .moveCanvasToWindow: openCanvasInNewWindow()
        case .duplicateCanvas: controller.duplicateCanvas()
        case .deleteCanvas: confirmDeleteCanvas()
        case .copyCanvas: controller.copyCanvas()
        case .pasteCanvas: controller.pasteCanvas()
        case .saveCanvasAsDocument: controller.saveCanvasAsDocument()
        case .mergeDocuments: controller.openMerge()
        case .printDocument: controller.openPrint()
        case .export: controller.openExport()
        case .mapShot: controller.openMapShot()
        case .splitByBranch: controller.splitByBranch()
        default: break
        }
        if let w = window, w.firstResponder !== host.canvasView, controller.passwordSheet == false,
            controller.exportState == nil
        {
            w.makeFirstResponder(host.canvasView)
        }
    }

    func wireFileHooks() {
        controller.onSaveFile = { [weak self] data, name in self?.save(data, suggested: name) }
        controller.onSaveFolder = { [weak self] files in self?.saveFolder(files) }
        controller.onSaveMapShot = { [weak self] data, name in self?.saveMapShot(data, name: name) }
        controller.onPrintPDF = { [weak self] data, name in self?.printPDF(data, name: name) }
        controller.onSaveDocument = { [weak self] doc, name in self?.saveDocument(doc, name: name) }
        controller.onChooseMergeFiles = { [weak self] in self?.chooseMergeFiles() }
        controller.onSetPassword = { [weak self] pw, hint, remember in
            self?.document_.setPassword(pw, hint: hint, remember: remember)
            self?.controller.showToast("Encrypted · recovery snapshots use the same key")
        }
        controller.onRemovePassword = { [weak self] in
            self?.document_.removePassword()
            self?.controller.showToast("Password removed")
        }
        controller.onRestoreSnapshot = { [weak self] s in
            guard let self else { return }
            self.document_.restore(s, controller: self.controller)
        }
        if document_.lockedFiles != nil {
            DispatchQueue.main.async { [weak self] in self?.promptUnlock() }
        }
    }

    // MARK: Panels

    func save(_ data: Data, suggested name: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let t = UTType(filenameExtension: (name as NSString).pathExtension) { panel.allowedContentTypes = [t] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try data.write(to: url, options: .atomic)
                    self?.controller.showToast("Exported \(url.lastPathComponent)")
                } catch {
                    self?.controller.showToast("Couldn’t write \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    func saveFolder(_ files: [(String, Data)]) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export \(files.count) Files"
        panel.message = "One PNG per main branch, named after it."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dir = panel.url else { return }
            MainActor.assumeIsolated {
                for (name, data) in files { try? data.write(to: dir.appending(path: name), options: .atomic) }
                self?.controller.showToast("Exported \(files.count) branch images")
            }
        }
    }

    func saveDocument(_ doc: DocumentModel, name: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".nexus"
        panel.allowedContentTypes = [UTType(exportedAs: "com.opennexus.document")]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try NexusPackage.write(doc, to: url)
                    self?.controller.showToast("Saved \(url.lastPathComponent)")
                } catch {
                    self?.controller.showToast("Couldn’t save: \(error.localizedDescription)")
                }
            }
        }
    }

    func chooseMergeFiles() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = Self.importTypes
        panel.message = "Choose .nexus, .xmind, OPML, Markdown or other maps to merge."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                for url in panel.urls { self?.controller.addMergeSource(url) }
            }
        }
    }

    static var importTypes: [UTType] {
        InterchangeFormat.importable.flatMap(\.extensions).compactMap { UTType(filenameExtension: $0) }
            + [UTType(exportedAs: "com.opennexus.document"), .folder]
    }

    // MARK: Print (⌘P)

    func printPDF(_ data: Data, name: String) {
        guard let window, let pdf = PDFDocument(data: data) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        guard let op = pdf.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        op.jobTitle = name
        op.showsPrintPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Map Shot folder (Settings › Export, default Desktop)

    static let mapShotFolderKey = "export.mapShotFolder"

    func saveMapShot(_ data: Data, name: String) {
        if let folder = Self.mapShotFolder() {
            let ok = folder.startAccessingSecurityScopedResource()
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            do {
                try data.write(to: folder.appending(path: name), options: .atomic)
                controller.showToast("Map Shot copied and saved to \(folder.lastPathComponent)")
                return
            } catch {}
        }
        // First shot (or the folder moved): ask once, remember with a bookmark.
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.prompt = "Save Map Shots Here"
        panel.message =
            "Map Shots are copied to the clipboard and saved in this folder. Change it in Settings › Export."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                MainActor.assumeIsolated { self?.controller.showToast("Map Shot copied") }
                return
            }
            MainActor.assumeIsolated {
                if let b = try? url.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                {
                    UserDefaults.standard.set(b, forKey: Self.mapShotFolderKey)
                }
                try? data.write(to: url.appending(path: name), options: .atomic)
                self?.controller.showToast("Map Shot copied and saved to \(url.lastPathComponent)")
            }
        }
    }

    static func mapShotFolder() -> URL? {
        guard let b = UserDefaults.standard.data(forKey: mapShotFolderKey) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: b, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: Canvas tab menu (artboard 50)

    func renameCanvas() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Canvas"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = controller.canvas.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                let t = field.stringValue.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self?.controller.renameCanvas(t) }
            }
        }
    }

    func confirmDeleteCanvas() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(controller.canvas.title.isEmpty ? "this canvas" : controller.canvas.title)”?"
        alert.informativeText = "You can undo this."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.controller.deleteCanvas() }
        }
    }

    /// Move to new window: a second window on the same document, showing this canvas.
    func openCanvasInNewWindow() {
        let id = controller.canvasID
        let wc = DocumentWindowController(document: document_)
        document_.addWindowController(wc)
        wc.controller.switchCanvas(to: id)
        wc.showWindow(nil)
        if let others = document_.store.model.canvasOrder.first(where: { $0 != id }) {
            controller.switchCanvas(to: others)
        }
    }

    // MARK: Unlock

    func promptUnlock() {
        guard let window, let files = document_.lockedFiles else { return }
        let hint = PackageCrypto.info(files)?.hint
        let alert = NSAlert()
        alert.messageText = "“\(document_.displayName ?? "This document")” is password-protected"
        alert.informativeText = hint.map { "Hint: \($0)" } ?? "Enter its password to open it."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        remember.state = .on
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(remember)
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Close Document")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard r == .alertFirstButtonReturn else {
                    self.document_.close()
                    return
                }
                do {
                    try self.document_.unlock(password: field.stringValue, remember: remember.state == .on)
                    self.controller.switchCanvas(to: self.document_.store.model.canvasOrder.first!)
                } catch {
                    self.controller.showToast("\(error)")
                    DispatchQueue.main.async { self.promptUnlock() }
                }
            }
        }
    }
}

/// The canvas tab menu (artboard 50): right-click a tab, or the ▾ on the active one.
struct CanvasTabMenu: View {
    var controller: CanvasController
    var target: CanvasID

    var body: some View {
        Button("New Canvas") { send(.newCanvas) }.keyboardShortcut("t", modifiers: .command)
        Button("New Canvas from Selected Topic") { on { controller.newCanvasFromTopic() } }
            .keyboardShortcut("n", modifiers: [.option, .command])
        Button("Duplicate Canvas") { on { controller.duplicateCanvas() } }
        Button("Rename…") { on { send(.renameCanvas) } }
        Divider()
        Button("Copy Canvas") { on { controller.copyCanvas() } }
        Button("Paste Canvas") { on { controller.pasteCanvas() } }.disabled(!controller.canPasteCanvas)
        Divider()
        Button("Save Canvas as Document…") { on { controller.saveCanvasAsDocument() } }
        Button("Move to New Window") { on { send(.moveCanvasToWindow) } }
        Divider()
        Button("Delete Canvas…", role: .destructive) { on { send(.deleteCanvas) } }
    }

    /// Acts on the tab that was clicked.
    func on(_ body: () -> Void) {
        controller.switchCanvas(to: target)
        body()
    }

    func send(_ id: CommandID) {
        let item = NSMenuItem()
        item.representedObject = id.rawValue
        NSApp.sendAction(#selector(DocumentWindowController.performRegistryCommand(_:)), to: nil, from: item)
    }
}
