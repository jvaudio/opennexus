import AppKit
import NexusCanvas
import NexusCore
import NexusFormat
import NexusReplica

/// Live co-editing in the app (M46): joining from invite links (`opennexus://join#…`, the
/// join page's universal link, File › Join Session…), a session's copy in the app
/// container, and a document's part of a session (undo history and the change count).
@MainActor
enum CollabJoin {
    /// Where joined sessions' copies are kept until moved (File › Move To…).
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
            path: "OpenNexus/Sessions")
    }

    static func join(_ link: String) {
        let center = CollabCenter.shared
        guard center.networkOn else { return networkOff() }
        do {
            let s = try center.join(link)
            // Already in it on this Mac: that window.
            if let store = s.store,
                let doc = NSDocumentController.shared.documents.compactMap({ $0 as? NexusDocument }).first(where: {
                    $0.store === store
                })
            {
                doc.showWindows()
                return
            }
            s.onReady = { model in open(model) }
            s.onEnded = { why in alert(Loc.t("Couldn’t join the live session"), why) }
        } catch {
            alert(Loc.t("Couldn’t join the live session"), "\(error)")
        }
    }

    /// Writes the session's document to the container and opens it; opening binds it.
    static func open(_ model: DocumentModel) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = model.orderedCanvases.first.flatMap { c in c.nodes[c.root]?.text }
        var name = String((root ?? "").prefix(60)).components(separatedBy: CharacterSet(charactersIn: "/:\\\n"))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = Loc.t("Live Session") }
        var url = folder.appending(path: "\(name).nexus")
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(name) \(i).nexus")
            i += 1
        }
        do {
            try NexusPackage.write(model, to: url)
        } catch {
            return alert(Loc.t("Couldn’t open the live session"), "\(error)")
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { alert(Loc.t("Couldn’t open the live session"), error.localizedDescription) }
        }
    }

    static func networkOff() {
        let a = NSAlert()
        a.messageText = Loc.t("Live sessions use the network")
        a.informativeText = Loc.t(
            "OpenNexus doesn’t use the network unless you turn it on. Turn on “Use the network” and “Live co-editing” in Settings › Privacy & Data."
        )
        a.addButton(withTitle: Loc.t("Open Settings…"))
        a.addButton(withTitle: Loc.t("Cancel"))
        if a.runModal() == .alertFirstButtonReturn { AppPreferences.shared.showSettings(pane: "privacy") }
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

extension NexusDocument {
    /// A session starting here: undo history starts over (undo is selective from now on), and
    /// other people's edits mark the document edited so autosave keeps them.
    func attachSession(_ s: CollabSession) {
        undoManager?.removeAllActions()
        s.onRemoteChange = { [weak self] in self?.updateChangeCount(.changeDone) }
        s.onEnded = { [weak self] why in
            (self?.windowControllers.first as? DocumentWindowController)?.controller.collabEnded(why)
        }
    }

    /// Reopening a document that's in a session (or a joined session's copy) reconnects it;
    /// what changed offline goes out then.
    func resumeSession() {
        guard case .string(let id)? = store.model.manifestExtra["documentID"],
            let s = CollabCenter.shared.resume(store: store, documentID: id),
            let wc = windowControllers.first as? DocumentWindowController
        else { return }
        wc.controller.attach(s)
    }

    /// Closing keeps the session (on disk) for the next open.
    func suspendSession() {
        guard case .string(let id)? = store.model.manifestExtra["documentID"] else { return }
        CollabCenter.shared.suspend(id)
    }
}
