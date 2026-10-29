import CryptoKit
import Foundation
import NexusCore
import NexusFormat
import NexusScene
import NexusSync
import Observation

/// Bring-your-own sync (M45): library folders kept in step through the user's own
/// S3-compatible bucket, encrypted by default (D348). The engine (`NexusSync`) does the
/// work off the main thread; this keeps the libraries, their secrets in the Keychain, the
/// schedule, and what Settings, Home and open documents show.

/// A folder of documents synced to a bucket and prefix.
public struct SyncLibrary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The folder's path, and a security-scoped bookmark to reopen it (the app is sandboxed).
    public var folder: String
    public var bookmark: Data?
    /// The bucket: endpoint, region, bucket, prefix and access key (the secret is in the Keychain).
    public var bucket: ShareDestination
    /// Sealed with the library key (D348); off stores plain JSON.
    public var encrypted = true
    /// The Test found the provider honours conditional writes.
    public var conditionalWrites = true

    public init(id: String = UUID().uuidString, name: String, folder: String, bucket: ShareDestination) {
        self.id = id
        self.name = name
        self.folder = folder
        self.bucket = bucket
    }

    public var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }

    /// The bucket's address fields are filled in.
    public var isComplete: Bool { bucket.isComplete && !folder.isEmpty }

    public static func newBucket() -> ShareDestination {
        var d = ShareDestination(kind: .s3, name: "Sync")
        d.prefix = "opennexus-sync/"
        return d
    }
}

/// One line of the sync log (Settings › Sync).
public struct SyncLogLine: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var library: String
    public var text: String
    public var problem = false
}

public enum SyncStatus: Equatable, Sendable {
    /// Sync or the network is off.
    case off
    case synced(Date)
    case syncing
    /// The bucket couldn't be reached, or refused.
    case offline(String)
    /// Clashes waiting in Resolve Conflicts.
    case conflicts(Int)

    public var label: String {
        switch self {
        case .off: Loc.t("Off")
        case .synced(let d): Loc.f("Synced %@", d.formatted(date: .omitted, time: .shortened))
        case .syncing: Loc.t("Syncing…")
        case .offline: Loc.t("Offline")
        case .conflicts(let n): Loc.n("%lld conflict", "%lld conflicts", n)
        }
    }

    public var glyph: String {
        switch self {
        case .off: "○"
        case .synced: "✓"
        case .syncing: "↻"
        case .offline: "⚠︎"
        case .conflicts: "⇄"
        }
    }
}

@MainActor
@Observable
public final class SyncCenter {
    public static let shared = SyncCenter(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "OpenNexus/Sync"), secrets: PlatformNetwork.secrets(service: "org.opennexus.sync"),
        transport: PlatformNetwork.transport())

    public private(set) var libraries: [SyncLibrary] = []
    public private(set) var status: [String: SyncStatus] = [:]
    public private(set) var log: [SyncLogLine] = []
    /// Per library, documents with clashes to resolve: id → path in the folder.
    public private(set) var conflicts: [String: [String: String]] = [:]
    @ObservationIgnored public var secrets: any SecretStore
    @ObservationIgnored public var transport: any ShareTransport
    @ObservationIgnored public var prefs: Preferences
    @ObservationIgnored public var networkLog: NetworkLog
    /// This Mac's name in history and the remote trash (nil: the computer's name).
    @ObservationIgnored public var device: String?
    /// Called for each package a sync wrote (open documents merge it and say so).
    @ObservationIgnored public var onWritten: ((URL) -> Void)?
    @ObservationIgnored let directory: URL?
    @ObservationIgnored var engines: [String: SyncEngine] = [:]
    @ObservationIgnored var scoped: Set<String> = []
    @ObservationIgnored var recentWrites: [String: Date] = [:]
    @ObservationIgnored var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var timer: Task<Void, Never>?
    @ObservationIgnored var observer: (any NSObjectProtocol)?
    static let maxLog = 300
    /// Looked up once, when the first library syncs.
    static let computerName = CanvasHosts.platform().deviceName

    public init(
        directory: URL?, secrets: any SecretStore, transport: any ShareTransport, prefs: Preferences = .shared,
        networkLog: NetworkLog? = nil
    ) {
        self.directory = directory
        self.secrets = secrets
        self.transport = transport
        self.prefs = prefs
        self.networkLog = networkLog ?? ShareCenter.shared.log
        if let file = directory?.appending(path: "libraries.json"), let data = try? Data(contentsOf: file),
            let libs = try? ShareStore.decoder.decode([SyncLibrary].self, from: data)
        {
            libraries = libs
        }
        if let file = directory?.appending(path: "sync-log.json"), let data = try? Data(contentsOf: file),
            let l = try? ShareStore.decoder.decode([SyncLogLine].self, from: data)
        {
            log = l
        }
        for l in libraries { status[l.id] = networkOn ? .synced(.distantPast) : .off }
    }

    /// The master switch and sync's own (both off on a fresh install).
    public var networkOn: Bool { prefs.bool("network.enabled") && prefs.bool("network.sync") }

    /// The service's allow-list for sync: the hosts of every library's bucket.
    public var allowedHosts: [String] { Array(Set(libraries.flatMap(\.bucket.hosts))).sorted() }

    func save() {
        guard let directory, let data = try? ShareStore.encoder.encode(libraries) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "libraries.json"), options: [.atomic])
    }

    func saveLog() {
        guard let directory, let data = try? ShareStore.encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "sync-log.json"), options: [.atomic])
    }

    func note(_ lib: SyncLibrary, _ text: String, problem: Bool = false, save: Bool = true) {
        log.insert(SyncLogLine(date: Date(), library: lib.name, text: text, problem: problem), at: 0)
        if log.count > Self.maxLog { log.removeLast(log.count - Self.maxLog) }
        if save { saveLog() }
    }

    public func clearLog() {
        log = []
        saveLog()
    }

    // MARK: Libraries

    public func library(_ id: String) -> SyncLibrary? { libraries.first { $0.id == id } }

    /// The library whose folder holds `url`.
    public func library(containing url: URL) -> SyncLibrary? {
        let p = url.standardizedFileURL.path(percentEncoded: false)
        return libraries.first { p.hasPrefix($0.folderURL.standardizedFileURL.path(percentEncoded: false)) }
    }

    func relativePath(_ url: URL, in lib: SyncLibrary) -> String {
        let root = lib.folderURL.standardizedFileURL.path(percentEncoded: false)
        var p = url.standardizedFileURL.path(percentEncoded: false)
        if p.hasPrefix(root) { p.removeFirst(root.count) }
        return p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func credential(_ lib: SyncLibrary) -> String? {
        secrets.secret("sync:\(lib.id)").flatMap { String(data: $0, encoding: .utf8) }.flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    func key(_ lib: SyncLibrary) -> SymmetricKey? {
        secrets.secret("synckey:\(lib.id)").flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
    }

    /// Saves a library. A nil `secret` keeps the saved one; an encrypted library without a
    /// key gets a new one, or `recoveryKey`'s (another Mac's library).
    public enum AddError: Error, Equatable { case badRecoveryKey }

    public func save(_ lib: SyncLibrary, secret: String?, recoveryKey: String? = nil) throws {
        if let text = recoveryKey, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let k = RecoveryKey.key(text) else { throw AddError.badRecoveryKey }
            let data = k.withUnsafeBytes { Data($0) }
            // Another library's key: what this Mac synced under the old one no longer applies.
            if let old = secrets.secret("synckey:\(lib.id)"), old != data, let d = directory?.appending(path: lib.id) {
                try? FileManager.default.removeItem(at: d)
            }
            secrets.setSecret(data, "synckey:\(lib.id)")
        } else if lib.encrypted, key(lib) == nil {
            secrets.setSecret(Sealed.newKey().withUnsafeBytes { Data($0) }, "synckey:\(lib.id)")
        }
        if let secret { secrets.setSecret(Data(secret.utf8), "sync:\(lib.id)") }
        if let i = libraries.firstIndex(where: { $0.id == lib.id }) {
            libraries[i] = lib
        } else {
            libraries.append(lib)
        }
        engines[lib.id] = nil
        status[lib.id] = networkOn ? .synced(.distantPast) : .off
        save()
    }

    /// Removes the library from this Mac: its folder and the bucket stay as they are.
    public func remove(_ id: String) {
        secrets.deleteSecret("sync:\(id)")
        secrets.deleteSecret("synckey:\(id)")
        libraries.removeAll { $0.id == id }
        engines[id] = nil
        status[id] = nil
        conflicts[id] = nil
        if let d = directory?.appending(path: id) { try? FileManager.default.removeItem(at: d) }
        save()
    }

    /// The library key as text, to set up another Mac (Show Recovery Key…).
    public func recoveryKey(_ id: String) -> String? {
        library(id).flatMap(key).map(RecoveryKey.text)
    }

    /// Forgets what this Mac synced: the next sync merges each document two ways.
    public func resetState(_ id: String) async {
        guard let lib = library(id) else { return }
        try? await engine(lib)?.reset()
        note(lib, Loc.t("Reset this Mac’s sync state"))
    }

    func folderURL(_ lib: SyncLibrary) -> URL {
        guard let b = lib.bookmark else { return lib.folderURL }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard
            let url = try? URL(resolvingBookmarkData: b, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return lib.folderURL }
        if !scoped.contains(lib.id), url.startAccessingSecurityScopedResource() { scoped.insert(lib.id) }
        return url
    }

    func engine(_ lib: SyncLibrary) -> SyncEngine? {
        if let e = engines[lib.id] { return e }
        guard let directory, let secret = credential(lib) else { return nil }
        let k = lib.encrypted ? key(lib) : nil
        if lib.encrypted, k == nil { return nil }
        let send = transport
        let netLog = networkLog
        let t = NetSyncTransport(
            destination: lib.bucket, secret: secret, allowedHosts: allowedHosts, purpose: Loc.t("Sync"),
            send: { await send.exchange($0, body: $1) },
            onLog: { entries in Task { @MainActor in netLog.append(entries) } })
        let days = Int(prefs.string("sync.keepDeleted")) ?? 30
        let e = SyncEngine(
            transport: t, crypto: LibraryCrypto(key: k), folder: DiskFolder(folderURL(lib)),
            stateDirectory: directory.appending(path: lib.id),
            options: .init(
                device: device ?? Self.computerName, keepDeletedDays: days, conditionalWrites: lib.conditionalWrites))
        engines[lib.id] = e
        return e
    }

    // MARK: Syncing

    /// Checks the bucket, and whether it honours conditional writes (remembered).
    public func test(_ id: String) async -> NetReply {
        guard let lib = library(id) else { return .failed(Loc.t("No such library.")) }
        guard networkOn else { return .failed(Loc.t("Sync uses the network, which is off.")) }
        guard let secret = credential(lib) else { return .failed(Loc.f("%@ has no credential saved.", lib.name)) }
        let send = transport
        let netLog = networkLog
        let t = NetSyncTransport(
            destination: lib.bucket, secret: secret, allowedHosts: allowedHosts, purpose: Loc.t("Test sync"),
            send: { await send.exchange($0, body: $1) },
            onLog: { entries in Task { @MainActor in netLog.append(entries) } })
        let r = await t.test()
        if r.ok, let c = r.conditionalWrites, var l = library(id), l.conditionalWrites != c {
            l.conditionalWrites = c
            if let i = libraries.firstIndex(where: { $0.id == id }) { libraries[i] = l }
            engines[id] = nil
            save()
        }
        return r
    }

    /// Syncs one library, or all of them.
    public func syncNow(_ id: String? = nil) async {
        guard networkOn else {
            for l in libraries { status[l.id] = .off }
            return
        }
        for lib in libraries where id == nil || lib.id == id {
            await sync(lib)
        }
    }

    func sync(_ lib: SyncLibrary) async {
        guard let engine = engine(lib) else {
            status[lib.id] = .offline(Loc.t("Missing its credential or key"))
            note(lib, Loc.t("Can’t sync: the bucket’s secret key or the library key is missing."), problem: true)
            return
        }
        status[lib.id] = .syncing
        let root = folderURL(lib)
        do {
            // Below the UI's priority, so typing keeps the fast cores (A9).
            let report = try await Task.detached(priority: .utility) { try await engine.sync() }.value
            for path in report.written {
                let url = root.appending(path: path, directoryHint: .isDirectory)
                recentWrites[url.standardizedFileURL.path(percentEncoded: false)] = Date()
                onWritten?(url)
            }
            describe(report, lib)
            let c = await engine.conflicts
            conflicts[lib.id] = c
            status[lib.id] = c.isEmpty ? .synced(Date()) : .conflicts(c.count)
        } catch {
            status[lib.id] = .offline(String(describing: error))
            note(lib, String(describing: error), problem: true)
        }
    }

    func describe(_ r: SyncReport, _ lib: SyncLibrary) {
        for item in r.items {
            let name = (item.path as NSString).lastPathComponent
            let text: String =
                switch item.change {
                case .pushed: Loc.f("Sent %@", name)
                case .pulled: Loc.f("Received %@", name)
                case .merged(let n):
                    n == 0
                        ? Loc.f("Merged %@", name)
                        : Loc.f("Merged %@ · %@ to resolve", name, Loc.n("%lld conflict", "%lld conflicts", n))
                case .added: Loc.f("Added %@ from another Mac", name)
                case .trashed: Loc.f("Moved %@ to the Trash (deleted on another Mac)", name)
                case .deleted: Loc.f("Deleted %@ from the library", name)
                case .kept: Loc.f("Kept %@: deleted on one Mac, changed on another", name)
                case .purged: Loc.f("Removed %@ from the bucket for good", name)
                }
            note(
                lib, text, problem: { if case .merged(let n) = item.change { return n > 0 } else { return false } }(),
                save: false)
        }
        for (path, why) in r.errors.sorted(by: { $0.key < $1.key }) {
            note(lib, "\((path as NSString).lastPathComponent): \(why)", problem: true, save: false)
        }
        for (path, why) in r.notes.sorted(by: { $0.key < $1.key }) {
            note(lib, "\((path as NSString).lastPathComponent): \(why)", save: false)
        }
        if !r.items.isEmpty || !r.errors.isEmpty || !r.notes.isEmpty { saveLog() }
    }

    /// The package was just written by sync (so its document says "Updated from sync").
    public func justWrote(_ url: URL) -> Bool {
        let k = url.standardizedFileURL.path(percentEncoded: false)
        guard let d = recentWrites[k], Date().timeIntervalSince(d) < 30 else { return false }
        recentWrites[k] = nil
        return true
    }

    /// A document was saved: sync its library a moment later (saves come in bursts).
    public func documentSaved(_ url: URL) {
        syncSoon(url, after: .seconds(2))
    }

    /// A window became key: look for changes from other Macs.
    public func windowBecameKey(_ url: URL?) {
        guard let url else { return }
        syncSoon(url, after: .milliseconds(300))
    }

    func syncSoon(_ url: URL, after: Duration) {
        guard networkOn, let lib = library(containing: url) else { return }
        pending[lib.id]?.cancel()
        pending[lib.id] = Task { [weak self] in
            try? await Task.sleep(for: after)
            guard !Task.isCancelled, let self, let lib = self.library(lib.id) else { return }
            await self.sync(lib)
        }
    }

    /// Whether a change to this package came from sync: written by the last sync, or one
    /// running now (an open document says "Updated from sync").
    public func fromSync(_ url: URL) -> Bool {
        if justWrote(url) { return true }
        guard let lib = library(containing: url) else { return false }
        return status[lib.id] == .syncing
    }

    /// At launch, then on Settings › Sync › Sync every (and again when it or the network
    /// switches change).
    public func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: Preferences.didChange, object: prefs, queue: .main
            ) { [weak self] n in
                let key = n.userInfo?["key"] as? String
                MainActor.assumeIsolated { self?.settingChanged(key) }
            }
        }
        timer?.cancel()
        timer = Task { [weak self] in
            await self?.syncNow()
            while !Task.isCancelled {
                let minutes = Double(self?.prefs.string("sync.interval") ?? "15") ?? 0
                try? await Task.sleep(for: .seconds(minutes > 0 ? minutes * 60 : 600))
                guard !Task.isCancelled, let self else { return }
                if minutes > 0 { await self.syncNow() }
            }
        }
    }

    func settingChanged(_ key: String?) {
        switch key {
        case "network.enabled", "network.sync", "sync.interval":
            if !networkOn { for l in libraries { status[l.id] = .off } }
            start()
        case "sync.keepDeleted":
            engines = [:]
        default: break
        }
    }

    // MARK: Documents

    /// What a document's sync knows about it: its library, engine and id.
    func handle(_ url: URL) async -> (SyncLibrary, SyncEngine, String)? {
        guard let lib = library(containing: url), let e = engine(lib) else { return nil }
        let path = relativePath(url, in: lib)
        guard let id = await e.documentID(at: path) else { return nil }
        return (lib, e, id)
    }

    public func isSynced(_ url: URL) -> Bool { library(containing: url) != nil }

    /// The status a document's card shows: its library's, or conflicts of its own.
    public func status(of url: URL) -> SyncStatus? {
        guard let lib = library(containing: url) else { return nil }
        let path = relativePath(url, in: lib)
        if conflicts[lib.id]?.values.contains(path) == true { return .conflicts(1) }
        return status[lib.id] ?? .off
    }

    /// Clashes from the last merge of this document, if any wait.
    public func pendingConflict(for url: URL) async -> PendingConflict? {
        guard let (_, e, id) = await handle(url) else { return nil }
        return try? await e.conflict(id)
    }

    public func clearConflict(for url: URL) async {
        guard let (lib, e, id) = await handle(url) else { return }
        try? await e.clearConflict(id)
        let c = await e.conflicts
        conflicts[lib.id] = c
        if case .conflicts = status[lib.id] { status[lib.id] = c.isEmpty ? .synced(Date()) : .conflicts(c.count) }
    }

    /// The document's revisions in the library, newest first.
    public func history(for url: URL) async throws -> [HeadRecord] {
        guard networkOn else { throw ShareCenter.Failure.networkOff }
        guard let (_, e, id) = await handle(url) else { return [] }
        return try await e.history(id)
    }

    public func model(for url: URL, revision: HeadRecord) async throws -> DocumentModel {
        guard let (_, e, id) = await handle(url) else { throw SyncError.damaged("the document") }
        return try NexusPackage.read(files: try await e.files(id, revision))
    }

    /// Deleted documents still in the library's trash.
    public func deleted(_ id: String) async throws -> [DeletedDocument] {
        guard networkOn else { throw ShareCenter.Failure.networkOff }
        guard let lib = library(id), let e = engine(lib) else { return [] }
        return try await e.deletedDocuments()
    }

    public func restore(_ doc: DeletedDocument, in id: String) async {
        guard let lib = library(id), let e = engine(lib) else { return }
        do {
            try await e.restore(doc.id)
            note(lib, Loc.f("Restored %@", (doc.path as NSString).lastPathComponent))
        } catch {
            note(lib, String(describing: error), problem: true)
        }
        await sync(lib)
    }
}
