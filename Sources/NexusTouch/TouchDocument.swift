#if os(iOS)
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene
import UIKit
import UniformTypeIdentifiers

/// A `.nexus` package (or `.nexusjson` file) on the iPad (M47b, D393): what `NexusDocument`
/// is on the Mac. Autosaves through `UIDocument`, writes the Quick Look preview and the
/// viewer copy, and merges a change made elsewhere (another device through iCloud Drive or
/// a synced folder, an agent) with unsaved edits as one undo step instead of reverting.
@MainActor
public final class TouchDocument: UIDocument {
    /// Made on first use, on the main actor (`UIDocument`'s initialiser isn't isolated).
    public private(set) lazy var store: DocumentStore = {
        let s = DocumentStore(model: .blank())
        s.undoRegistrar = undoBridge
        return s
    }()
    private lazy var undoBridge = UndoManagerRegistrar { [weak self] in self?.undoManager }
    /// What's on disk as far as this document knows: the base for merging (M9).
    public private(set) var diskBase: DocumentModel?
    /// An encrypted package waiting for its password.
    public private(set) var lockedFiles: [String: Data]?
    /// The key while the document is password-protected (memory only).
    var cryptoKey: PackageCrypto.Key?
    /// The document was just made (it opens with the central topic in Edit mode).
    public var isFresh = false
    /// Changes made elsewhere that were merged ("Updated from iCloud · ⌘Z undoes").
    public var onMerged: ((_ conflicts: [String]) -> Void)?
    var prefs: Preferences { .shared }

    public static let packageType = UTType(exportedAs: "com.opennexus.document", conformingTo: .package)
    public static let jsonType = UTType(exportedAs: "com.opennexus.json-document", conformingTo: .json)

    var isJSON: Bool { fileURL.pathExtension.lowercased() == "nexusjson" }

    /// Writes a new document at `url` (a starter's model, or the Settings default).
    public static func create(at url: URL, model: DocumentModel) async throws -> TouchDocument {
        let doc = TouchDocument(fileURL: url)
        doc.store.replace(with: model)
        doc.isFresh = true
        let saved = await withCheckedContinuation { c in
            doc.save(to: url, for: .forCreating) { c.resume(returning: $0) }
        }
        guard saved else { throw CocoaError(.fileWriteUnknown) }
        return doc
    }

    // MARK: Reading and writing

    /// `UIDocument` asks for contents on the main queue (it writes them in the background).
    public nonisolated override func contents(forType typeName: String) throws -> Any {
        nonisolated(unsafe) let me = self
        return try onMain { try me.contentsOnMain() }
    }

    func contentsOnMain() throws -> Any {
        if let lockedFiles { return NexusPackage.directoryWrapper(from: lockedFiles) }
        let doc = modelForSaving()
        diskBase = store.model
        if isJSON {
            return Data(ViewerCopy.json(doc, pretty: prefs.string("files.jsonLayout") != "compact", prefs: prefs).utf8)
        }
        var files = NexusPackage.files(for: doc)
        if let key = cryptoKey {
            return NexusPackage.directoryWrapper(from: try PackageCrypto.encrypt(files, with: key))
        }
        if let png = HeadlessExport.previewPNG(store.model) { files[NexusPackage.previewName] = png }
        ViewerCopy.add(to: &files, doc, prefs: prefs)
        return NexusPackage.directoryWrapper(from: files)
    }

    /// A stable id for this document's per-device chats (kept in the manifest).
    var documentID: String {
        if case .string(let s)? = store.model.manifestExtra["documentID"] { return s }
        let id = UUID().uuidString
        store.updateDocument { $0.manifestExtra["documentID"] = .string(id) }
        return id
    }

    /// The model as written: AI chats go in the file, on this device, or nowhere
    /// (Settings › Privacy & Data › Keep AI chats), as on the Mac.
    func modelForSaving() -> DocumentModel {
        _ = documentID
        var doc = store.model
        doc.encrypted = cryptoKey != nil
        switch prefs.string("privacy.keepChats") {
        case "mac":
            ChatStore.save(doc.chats, documentID: documentID)
            doc.chats = []
        case "none":
            doc.chats = []
        default: break
        }
        return doc
    }

    /// Chats kept on this device come back when the document opens.
    func loadChatsFromDevice() {
        guard store.model.chats.isEmpty, case .string(let id)? = store.model.manifestExtra["documentID"] else { return }
        let chats = ChatStore.load(documentID: id)
        if !chats.isEmpty { store.updateDocument { $0.chats = chats } }
    }

    /// Called on the main queue after a background read.
    public nonisolated override func load(fromContents contents: Any, ofType typeName: String?) throws {
        nonisolated(unsafe) let (me, contents) = (self, contents)
        try onMain { try me.loadOnMain(contents) }
    }

    func loadOnMain(_ contents: Any) throws {
        let doc = try Self.read(contents, name: fileURL.lastPathComponent, key: cryptoKey)
        switch doc {
        case .locked(let files):
            lockedFiles = files
        case .open(let model):
            lockedFiles = nil
            store.replace(with: model)
            diskBase = model
            loadChatsFromDevice()
        }
    }

    enum Read {
        case open(DocumentModel)
        case locked([String: Data])
    }

    static func read(_ contents: Any, name: String, key: PackageCrypto.Key?) throws -> Read {
        if let data = contents as? Data { return .open(try DocumentJSON.parse(data, name: name)) }
        guard let wrapper = contents as? FileWrapper else { throw CocoaError(.fileReadCorruptFile) }
        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            return .open(try DocumentJSON.parse(data, name: name))
        }
        var files = NexusPackage.flatten(wrapper)
        if PackageCrypto.isEncrypted(files) {
            guard let key, let opened = try? PackageCrypto.decrypt(files, with: key) else { return .locked(files) }
            files = opened
        }
        return .open(try NexusPackage.read(files: files))
    }

    /// Opens a locked document with its password (remembered in the Keychain when asked
    /// and Settings › Security allows).
    public func unlock(password: String, remember: Bool = false) throws {
        guard let files = lockedFiles, let info = PackageCrypto.info(files) else { return }
        let key = PackageCrypto.derive(password: password, info: info)
        let opened = try PackageCrypto.decrypt(files, with: key)
        let doc = try NexusPackage.read(files: opened)
        cryptoKey = key
        lockedFiles = nil
        store.replace(with: doc)
        diskBase = doc
        if remember && prefs.bool("files.keychain") {
            Self.passwords.setSecret(Data(password.utf8), info.keychainAccount)
        }
    }

    /// Opens a locked document with the password the Keychain kept for it, if any.
    public func unlockFromKeychain() -> Bool {
        guard prefs.bool("files.keychain"), let files = lockedFiles, let info = PackageCrypto.info(files),
            let data = Self.passwords.secret(info.keychainAccount)
        else { return false }
        return (try? unlock(password: String(decoding: data, as: UTF8.self))) != nil
    }

    /// The password's hint, while the document is locked.
    public var passwordHint: String? { lockedFiles.flatMap { PackageCrypto.info($0)?.hint } }

    public var isEncrypted: Bool { cryptoKey != nil }

    /// Document passwords in the Keychain (this app only), as on the Mac.
    static let passwords = KeychainSecrets(service: "org.opennexus.document-password")

    public func setPassword(_ password: String, hint: String?, remember: Bool) {
        if let old = cryptoKey { Self.passwords.deleteSecret(old.info.keychainAccount) }
        let key = PackageCrypto.derive(password: password, info: PackageCrypto.newInfo(hint: hint))
        cryptoKey = key
        if remember && prefs.bool("files.keychain") {
            Self.passwords.setSecret(Data(password.utf8), key.info.keychainAccount)
        }
        updateChangeCount(.done)
        autosave { _ in }
    }

    public func removePassword() {
        if let old = cryptoKey { Self.passwords.deleteSecret(old.info.keychainAccount) }
        cryptoKey = nil
        updateChangeCount(.done)
    }

    // MARK: Recovery snapshots

    private var lastSnapshotRevision = -1

    /// Settings › Files › Snapshot every N seconds of editing (the screen's timer calls this).
    public func writeSnapshot() {
        guard prefs.bool("files.snapshots"), lockedFiles == nil, store.revision != lastSnapshotRevision else { return }
        lastSnapshotRevision = store.revision
        _ = try? SnapshotStore.write(
            NexusPackage.files(for: modelForSaving()), documentID: documentID, topics: store.model.topicCount,
            key: cryptoKey)
    }

    public var snapshots: [RecoverySnapshot] { SnapshotStore.list(documentID: documentID) }

    /// Restore is one undo step.
    public func restore(_ s: RecoverySnapshot, controller: CanvasController) {
        do {
            let restored = try NexusPackage.read(files: try SnapshotStore.read(s, key: cryptoKey))
            let focus = restored.canvasOrder.first ?? controller.canvasID
            store.commitDocument(Loc.t("Restore Snapshot"), focus: focus) { d in
                d.canvases = restored.canvases
                d.canvasOrder = restored.canvasOrder
                d.theme = restored.theme
                for (k, v) in restored.assets where d.assets[k] == nil { d.assets[k] = v }
            }
            controller.showToast(
                Loc.f(
                    "Restored the snapshot from %@ · ⌘Z undoes", s.date.formatted(date: .abbreviated, time: .shortened))
            )
        } catch {
            controller.showToast(Loc.f("Couldn’t restore: %@", "\(error)"))
        }
    }

    // MARK: Changes made elsewhere

    /// The file changed on disk. `UIDocument` would revert, losing undo and unsaved edits;
    /// instead the change is merged in as one undo step (D114).
    public nonisolated override func presentedItemDidChange() {
        nonisolated(unsafe) let me = self
        DispatchQueue.main.async { MainActor.assumeIsolated { me.mergeFromDisk() } }
    }

    /// `UIDocument` reverts to the file when another writer replaces it (a synced folder's
    /// copy), which would drop undo and the edits not yet saved; an open document merges the
    /// change instead, as `presentedItemDidChange` does (D114, D409). `mergeFromDisk` makes
    /// its own coordinated read.
    public nonisolated override func revert(toContentsOf url: URL, completionHandler: ((Bool) -> Void)? = nil) {
        nonisolated(unsafe) let (me, done) = (self, completionHandler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard url == me.fileURL, me.diskBase != nil, me.lockedFiles == nil else {
                    return me.revertReplacing(url) { done?($0) }
                }
                me.mergeFromDisk()
                // What a revert records, so the file doesn't read as changed again.
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                me.fileModificationDate = values?.contentModificationDate
                done?(true)
            }
        }
    }

    private func revertReplacing(_ url: URL, _ done: @escaping @Sendable (Bool) -> Void) {
        super.revert(toContentsOf: url, completionHandler: done)
    }

    public func mergeFromDisk() {
        guard lockedFiles == nil, let base = diskBase else { return }
        var disk: DocumentModel?
        var coordError: NSError?
        let key = cryptoKey
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: fileURL, options: [], error: &coordError) {
            u in
            let contents: Any? =
                u.pathExtension.lowercased() == "nexusjson"
                ? try? Data(contentsOf: u) : try? FileWrapper(url: u, options: [.immediate])
            guard let contents, case .open(let m)? = try? Self.read(contents, name: u.lastPathComponent, key: key)
            else { return }
            disk = m
        }
        guard let disk,
            disk.canvases != base.canvases || disk.canvasOrder != base.canvasOrder || disk.theme != base.theme
        else { return }
        merge(disk, base: base)
    }

    func merge(_ disk: DocumentModel, base: DocumentModel) {
        let wasClean = !hasUnsavedChanges
        let conflicts = store.mergeExternal(disk, base: base, focus: store.model.canvasOrder.first ?? "c1")
        diskBase = disk
        if wasClean && conflicts.isEmpty { updateChangeCount(.done) }
        onMerged?(conflicts)
    }

    /// iCloud kept other devices' versions of this document: each is merged in, then the
    /// conflict is resolved (M45's three-way merge, against what was last read here).
    public func resolveConflicts() {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL), !versions.isEmpty else {
            return
        }
        let base = diskBase ?? store.model
        for v in versions {
            let contents: Any? =
                isJSON ? try? Data(contentsOf: v.url) : try? FileWrapper(url: v.url, options: [.immediate])
            if let contents,
                case .open(let m)? = try? Self.read(contents, name: fileURL.lastPathComponent, key: cryptoKey)
            {
                store.mergeExternal(m, base: base, focus: store.model.canvasOrder.first ?? "c1")
            }
            v.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
        updateChangeCount(.done)
        onMerged?([])
    }

    /// Saving or reading failed (the screen shows it).
    public var onError: ((String) -> Void)?

    public nonisolated override func handleError(_ error: any Error, userInteractionPermitted: Bool) {
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
        let text = error.localizedDescription
        nonisolated(unsafe) let me = self
        DispatchQueue.main.async { MainActor.assumeIsolated { me.onError?(text) } }
    }
}

/// `UIDocument` calls its subclass on the main thread without saying so to Swift; this
/// asserts it and carries the (non-Sendable) result out, as the Mac's `onMain` does.
nonisolated func onMain<T>(_ body: @MainActor () throws -> T) throws -> T {
    nonisolated(unsafe) var result: Result<T, any Error>?
    MainActor.assumeIsolated {
        do { result = .success(try body()) } catch { result = .failure(error) }
    }
    switch result! {
    case .success(let v): return v
    case .failure(let e): throw e
    }
}
#endif
