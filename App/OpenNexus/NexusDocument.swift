import AppKit
import LocalAuthentication
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange

/// A `.nexus` package document. Autosaves in place and keeps versions (File › Revert To),
/// writes recovery snapshots, and encrypts when a password is set (M7).
final class NexusDocument: NSDocument {
    let store = DocumentStore(model: .blank())
    private let undoBridge = DocumentUndoRegistrar()
    /// True for a brand-new untitled document, so the window opens with the root in Edit mode.
    private(set) var isFreshBlank = true
    /// The derived key while the document is password-protected (kept in memory only).
    nonisolated(unsafe) var cryptoKey: PackageCrypto.Key?
    /// An encrypted package waiting for its password (the window shows the unlock prompt).
    nonisolated(unsafe) var lockedFiles: [String: Data]?
    private var snapshotTimer: Timer?
    private var lastSnapshotRevision = -1

    override init() {
        super.init()
        undoBridge.document = self
        store.undoRegistrar = undoBridge
        // A new document takes Settings › Editing › New documents and Appearance › Default look.
        store.replace(with: CanvasController.newDocumentModel(prefs: .shared))
        isFreshBlank = Preferences.shared.bool("editing.startInEdit")
        if Preferences.shared.string("files.saveAs") == "json" { fileType = Self.jsonType }
    }

    static let packageType = "com.opennexus.document"
    static let jsonType = "com.opennexus.json-document"
    var prefs: Preferences { .shared }

    nonisolated override class var autosavesInPlace: Bool { true }
    nonisolated override class var preservesVersions: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
        startSnapshots()
    }

    /// A stable id for this document's recovery snapshots (kept in the manifest).
    var documentID: String {
        if case .string(let s)? = store.model.manifestExtra["documentID"] { return s }
        let id = UUID().uuidString
        store.updateDocument { $0.manifestExtra["documentID"] = .string(id) }
        return id
    }

    /// The model as written: AI chats go in the file, on this Mac, or nowhere
    /// (Settings › Privacy & Data › Keep AI chats).
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

    func packageFiles() -> [String: Data] { NexusPackage.files(for: modelForSaving()) }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        // A document that was never unlocked is written back exactly as it was read.
        if let lockedFiles { return NexusPackage.directoryWrapper(from: lockedFiles) }
        if typeName == Self.jsonType {
            let json = DocumentJSON.export(
                modelForSaving(), pretty: prefs.string("files.jsonLayout") != "compact", assets: true)
            return FileWrapper(regularFileWithContents: Data(json.utf8))
        }
        let files = packageFiles()
        if let key = cryptoKey {
            return NexusPackage.directoryWrapper(from: try PackageCrypto.encrypt(files, with: key))
        }
        return NexusPackage.directoryWrapper(from: files)
    }

    nonisolated override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        if fileWrapper.isRegularFile, let data = fileWrapper.regularFileContents {
            let doc = try DocumentJSON.parse(data, name: fileWrapper.filename ?? "document")
            MainActor.assumeIsolated {
                isFreshBlank = false
                store.replace(with: doc)
                loadChatsFromMac()
            }
            return
        }
        let files = NexusPackage.flatten(fileWrapper)
        if PackageCrypto.isEncrypted(files), let info = PackageCrypto.info(files) {
            // The Keychain may already know the password (Touch ID first, if required).
            let touchRequired = UserDefaults.standard.bool(forKey: "files.touchID")
            if !touchRequired, UserDefaults.standard.object(forKey: "files.keychain") as? Bool ?? true,
                let pw = Keychain.password(account: info.keychainAccount),
                let opened = try? PackageCrypto.decrypt(files, with: PackageCrypto.derive(password: pw, info: info))
            {
                let doc = try NexusPackage.read(files: opened)
                MainActor.assumeIsolated {
                    cryptoKey = PackageCrypto.derive(password: pw, info: info)
                    isFreshBlank = false
                    store.replace(with: doc)
                }
                return
            }
            MainActor.assumeIsolated {
                lockedFiles = files
                isFreshBlank = false
            }
            return
        }
        let doc = try NexusPackage.read(files: files)
        // AppKit reads on the main thread unless concurrent reading is enabled (it is not).
        MainActor.assumeIsolated {
            isFreshBlank = false
            store.replace(with: doc)
            loadChatsFromMac()
        }
    }

    /// Chats kept on this Mac come back when the document opens.
    func loadChatsFromMac() {
        guard store.model.chats.isEmpty, case .string(let id)? = store.model.manifestExtra["documentID"] else { return }
        let chats = ChatStore.load(documentID: id)
        if !chats.isEmpty { store.updateDocument { $0.chats = chats } }
    }

    // MARK: Closing and saving

    /// Settings › Files › Ask before closing unsaved new documents (off: they close quietly).
    override func canClose(
        withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?
    ) {
        if fileURL == nil, !prefs.bool("files.askBeforeClosing"), let sel = shouldCloseSelector {
            let obj = delegate as AnyObject
            typealias Callback =
                @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            let imp = obj.method(for: sel)
            unsafeBitCast(imp, to: Callback.self)(obj, sel, self, true, contextInfo)
            return
        }
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    /// Settings › Files › Default location for new documents.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        let fm = FileManager.default
        switch prefs.string("files.location") {
        case "documents": savePanel.directoryURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        case "icloud":
            savePanel.directoryURL =
                fm.url(forUbiquityContainerIdentifier: nil)?.appending(path: "Documents")
                ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
        default: break
        }
        return super.prepareSavePanel(savePanel)
    }

    /// An imported document opens on its content, not in Edit mode.
    func markImported() {
        isFreshBlank = false
        updateChangeCount(.changeDone)
    }

    // MARK: Password

    /// Unlocks a document opened without a stored password.
    /// Settings › Security › Require Touch ID: the stored password is used only after Touch ID
    /// (or the login password) succeeds.
    func unlockWithTouchID(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let files = lockedFiles, let info = PackageCrypto.info(files), prefs.bool("files.keychain"),
            let pw = Keychain.password(account: info.keychainAccount)
        else { return done(false) }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return done(false) }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open an encrypted document") { ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ok, (try? self.unlock(password: pw, remember: false)) != nil else { return done(false) }
                    done(true)
                }
            }
        }
    }

    func unlock(password: String, remember: Bool) throws {
        guard let files = lockedFiles, let info = PackageCrypto.info(files) else { return }
        let key = PackageCrypto.derive(password: password, info: info)
        let opened = try PackageCrypto.decrypt(files, with: key)
        let doc = try NexusPackage.read(files: opened)
        cryptoKey = key
        lockedFiles = nil
        store.replace(with: doc)
        if remember && prefs.bool("files.keychain") { Keychain.setPassword(password, account: info.keychainAccount) }
        lastActivity = Date()
    }

    func setPassword(_ password: String, hint: String?, remember: Bool) {
        if let old = cryptoKey { Keychain.delete(account: old.info.keychainAccount) }
        let key = PackageCrypto.derive(password: password, info: PackageCrypto.newInfo(hint: hint))
        cryptoKey = key
        if remember && prefs.bool("files.keychain") {
            Keychain.setPassword(password, account: key.info.keychainAccount)
        }
        updateChangeCount(.changeDone)
        autosave(withImplicitCancellability: false) { _ in }
    }

    func removePassword() {
        if let old = cryptoKey { Keychain.delete(account: old.info.keychainAccount) }
        cryptoKey = nil
        updateChangeCount(.changeDone)
    }

    // MARK: Recovery snapshots

    /// Settings › Files › Snapshot every N seconds of editing, and on close. The same timer
    /// locks an encrypted document after the idle time in Settings › Security.
    func startSnapshots() {
        snapshotTimer?.invalidate()
        lastSnapshotRevision = store.revision
        let every = max(10, Double(prefs.string("files.snapshotEvery")) ?? 30)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: min(every, 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(every: every) }
        }
        if prefsObserver == nil {
            prefsObserver = NotificationCenter.default.addObserver(
                forName: Preferences.didChange, object: Preferences.shared, queue: .main
            ) { [weak self] n in
                let key = n.userInfo?["key"] as? String
                MainActor.assumeIsolated {
                    if key?.hasPrefix("files.snapshot") == true { self?.startSnapshots() }
                }
            }
        }
    }

    private var lastActivity = Date()
    private var lastSnapshotAt = Date()
    private var prefsObserver: (any NSObjectProtocol)?
    private var seenRevision = -1

    func tick(every: Double) {
        if store.revision != seenRevision {
            seenRevision = store.revision
            lastActivity = Date()
        }
        if Date().timeIntervalSince(lastSnapshotAt) >= every - 1 {
            lastSnapshotAt = Date()
            writeSnapshot()
        }
        let idle = Double(prefs.string("files.lockAfter")) ?? 0
        if idle > 0, cryptoKey != nil, lockedFiles == nil, Date().timeIntervalSince(lastActivity) > idle * 60 {
            lockNow()
        }
    }

    /// Locks an encrypted document: its content leaves memory until the password (or
    /// Touch ID) unlocks it again.
    func lockNow() {
        guard let key = cryptoKey, let sealed = try? PackageCrypto.encrypt(packageFiles(), with: key) else { return }
        autosave(withImplicitCancellability: false) { _ in }
        lockedFiles = sealed
        cryptoKey = nil
        store.replace(with: DocumentModel(canvases: [Canvas(id: "c1", title: "Locked", rootText: "Locked")]))
        for wc in windowControllers { (wc as? DocumentWindowController)?.promptUnlock() }
    }

    func writeSnapshot() {
        guard prefs.bool("files.snapshots"), lockedFiles == nil, store.revision != lastSnapshotRevision else { return }
        lastSnapshotRevision = store.revision
        try? SnapshotStore.write(packageFiles(), documentID: documentID, topics: store.model.topicCount, key: cryptoKey)
    }

    var snapshots: [RecoverySnapshot] { SnapshotStore.list(documentID: documentID) }

    /// Restore is one undo step.
    func restore(_ s: RecoverySnapshot, controller: CanvasController) {
        do {
            let restored = try NexusPackage.read(files: try SnapshotStore.read(s, key: cryptoKey))
            let focus = restored.canvasOrder.first ?? controller.canvasID
            store.commitDocument("Restore Snapshot", focus: focus) { d in
                d.canvases = restored.canvases
                d.canvasOrder = restored.canvasOrder
                d.theme = restored.theme
                for (k, v) in restored.assets where d.assets[k] == nil { d.assets[k] = v }
            }
            controller.showToast(
                "Restored the snapshot from \(s.date.formatted(date: .abbreviated, time: .shortened)) · ⌘Z undoes")
        } catch {
            controller.showToast("Couldn’t restore: \(error)")
        }
    }

    override func close() {
        writeSnapshot()
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        super.close()
    }
}

/// Registers canvas patches with the document's `NSUndoManager`, so Edit › Undo, the
/// change count, autosave and versions all see every model change.
final class DocumentUndoRegistrar: UndoRegistrar {
    weak var document: NexusDocument?

    func register(_ patch: Patch, store: DocumentStore) {
        guard let um = document?.undoManager else { return }
        registerInverse(of: patch, undoManager: um, store: store)
        um.setActionName(patch.actionName)
    }

    private func registerInverse(of patch: Patch, undoManager um: UndoManager, store: DocumentStore) {
        let inverse = patch.inverted
        um.registerUndo(withTarget: store) { [weak self] store in
            MainActor.assumeIsolated {
                store.applyFromUndo(inverse, kind: um.isUndoing ? .undone : .redone)
                self?.registerInverse(of: inverse, undoManager: um, store: store)
                um.setActionName(patch.actionName)
            }
        }
    }
}

/// Document passwords in the login Keychain (generic passwords, this app only).
enum Keychain {
    nonisolated static let service = "org.opennexus.document-password"

    nonisolated static func setPassword(_ password: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(password.utf8),
            kSecAttrLabel as String: "OpenNexus document password",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    nonisolated static func password(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    nonisolated static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
