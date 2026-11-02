import CryptoKit
import Foundation
import NexusCore
import NexusFormat

/// What a sync did, for the log and the app (which tells open documents, M45).
public struct SyncReport: Sendable {
    public enum Change: Sendable, Equatable {
        /// This Mac's changes went up.
        case pushed
        /// Another Mac's changes came down; nothing changed here.
        case pulled
        /// Both changed: merged, written here and pushed.
        case merged(clashes: Int)
        /// New in the library from another Mac.
        case added
        /// Deleted on another Mac: moved to the Trash here.
        case trashed
        /// Deleted here: other Macs will move theirs to the Trash.
        case deleted
        /// Deleted on one Mac and changed on another: the changed copy is kept.
        case kept
        /// The library's copy was purged after the days to keep deleted documents.
        case purged
    }

    public struct Item: Sendable, Equatable {
        public var id: String
        public var path: String
        public var change: Change
        /// The clashes a merge kept this Mac's side of.
        public var clashes: [MergeClash] = []
    }

    public var items: [Item] = []
    /// Documents that couldn't sync this time, and why.
    public var errors: [String: String] = [:]
    /// Things worth saying that aren't errors, by document path.
    public var notes: [String: String] = [:]
    /// Packages written on this Mac.
    public var written: [String] = []
    public var date = Date()

    public var clashes: [MergeClash] { items.flatMap(\.clashes) }
}

/// A clash waiting in Resolve Conflicts: the three sides, and what the merge wrote.
public struct PendingConflict: Sendable {
    public var id: String
    public var path: String
    public var base: DocumentModel?
    public var mine: DocumentModel
    public var theirs: DocumentModel
    public var merged: DocumentModel
    public var theirsDevice: String
    public var date: Date

    /// The merge with the user's choices.
    public func resolve(_ choices: [String: MergeClash.Choice]) -> DocumentMerge {
        DocumentMerge(base: base, current: mine, disk: theirs, choices: choices)
    }

    public var clashes: [MergeClash] { resolve([:]).clashes }
}

/// A deleted document still in the library's trash.
public struct DeletedDocument: Sendable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var date: Date
    public var device: String
}

/// Syncs one library: a folder of packages and a bucket prefix (M45). An actor, so hashing,
/// sealing and merging run off the main thread and one sync runs at a time.
public actor SyncEngine {
    public struct Options: Sendable {
        /// This Mac's name, in history and the remote trash.
        public var device: String
        /// Days a deleted document's objects stay in the bucket.
        public var keepDeletedDays: Int
        /// The provider honours `If-Match` and `If-None-Match` (the Test finds out); when
        /// not, a head write is read back to check it's ours.
        public var conditionalWrites: Bool
        public var now: @Sendable () -> Date

        public init(
            device: String, keepDeletedDays: Int = 30, conditionalWrites: Bool = true,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.device = device
            self.keepDeletedDays = keepDeletedDays
            self.conditionalWrites = conditionalWrites
            self.now = now
        }
    }

    let transport: any SyncTransport
    let crypto: LibraryCrypto
    let folder: any SyncFolder
    let stateURL: URL
    public var options: Options
    var state: LibraryState
    var running = false
    var again = false
    /// Head writes that lost a race, per sync, before a document waits for the next sync.
    static let attempts = 5

    public init(
        transport: any SyncTransport, crypto: LibraryCrypto, folder: any SyncFolder, stateDirectory: URL,
        options: Options
    ) {
        self.transport = transport
        self.crypto = crypto
        self.folder = folder
        self.stateURL = stateDirectory
        self.options = options
        let file = stateDirectory.appending(path: "state.json")
        state =
            (try? Data(contentsOf: file)).flatMap { try? Coding.decoder.decode(LibraryState.self, from: $0) }
            ?? LibraryState()
    }

    public func setOptions(_ o: Options) { options = o }

    // MARK: Sync

    /// Syncs every document. A call while one runs makes that one go round once more.
    @discardableResult
    public func sync() async throws -> SyncReport {
        if running {
            again = true
            return SyncReport()
        }
        running = true
        defer { running = false }
        var report = SyncReport()
        repeat {
            again = false
            report = try await syncOnce()
        } while again
        return report
    }

    func syncOnce() async throws -> SyncReport {
        var report = SyncReport(date: options.now())
        _ = try await library()
        let local = try await scan(&report)
        let listed = state.library.map { Array($0.documents.keys) } ?? []
        let ids = Set(local.keys).union(listed).union(state.docs.keys)
        for id in ids.sorted() {
            do {
                try await syncDocument(id, local[id], &report)
            } catch let e as SyncError {
                if case .transport = e { throw e }
                report.errors[local[id]?.path ?? state.docs[id]?.head.path ?? id] = e.description
            }
        }
        try await purge(&report)
        try saveState()
        collectGarbage()
        return report
    }

    struct Local {
        var path: String
        var files: [String: Data]
    }

    /// The folder's documents by id. A package without an id gets one; a Finder duplicate
    /// (the same id twice) gets a new one, and the copy the library knows keeps the old.
    func scan(_ report: inout SyncReport) async throws -> [String: Local] {
        var out: [String: Local] = [:]
        var pending: [Local] = []
        for path in try await folder.documents() {
            guard let files = try await folder.read(path), files["manifest.json"] != nil else { continue }
            if let id = SyncFiles.documentID(files) {
                if let other = out[id] {
                    // Keep the one at the path the library knows.
                    if state.docs[id]?.head.path == path {
                        out[id] = Local(path: path, files: files)
                        pending.append(other)
                    } else {
                        pending.append(Local(path: path, files: files))
                    }
                } else {
                    out[id] = Local(path: path, files: files)
                }
            } else {
                pending.append(Local(path: path, files: files))
            }
        }
        for l in pending where !SyncFiles.isOpaque(l.files) {
            let id = UUID().uuidString
            guard let files = SyncFiles.withID(l.files, id) else { continue }
            do {
                try await folder.write(l.path, files, replacing: l.files)
            } catch SyncError.changedHere {
                continue  // saved meanwhile: it gets its id next time
            }
            report.written.append(l.path)
            out[id] = Local(path: l.path, files: files)
        }
        return out
    }

    func syncDocument(_ id: String, _ local: Local?, _ report: inout SyncReport) async throws {
        guard SyncFiles.valid(id) else { return }
        if let entry = state.library?.documents[id], let deleted = entry.deleted {
            try await tombstoned(id, local, deleted: deleted, &report)
            return
        }
        var local = local
        for attempt in 0..<Self.attempts {
            // A lost race may have left a merge on disk: start from what's there.
            if attempt > 0, let l = local, let files = try await folder.read(l.path) {
                local = Local(path: l.path, files: files)
            }
            do {
                if try await syncDocumentOnce(id, local, &report) { return }
            } catch SyncError.changedHere {
                // Saved on this Mac while this sync worked: nothing was written, and the
                // save starts another sync, which begins from it.
                return
            }
        }
        report.errors[local?.path ?? id] = "Another Mac kept changing it; it will sync next time."
    }

    /// Deleted on another Mac (or here, earlier).
    func tombstoned(_ id: String, _ local: Local?, deleted: Date, _ report: inout SyncReport) async throws {
        guard let local else {
            state.docs[id] = nil
            return
        }
        let unchanged = state.docs[id].map { names(local.files) == $0.head.files } ?? false
        if unchanged {
            do {
                try await folder.trash(local.path, replacing: local.files)
            } catch SyncError.changedHere {
                return  // changed here meanwhile: the next sync keeps it
            }
            state.docs[id] = nil
            state.conflicts[id] = nil
            report.items.append(.init(id: id, path: local.path, change: .trashed))
        } else {
            // Changed here since it was deleted elsewhere: the change wins.
            try await updateLibrary { $0.documents[id] = LibraryRecord.Entry() }
            report.items.append(.init(id: id, path: local.path, change: .kept))
            try await syncDocument(id, local, &report)
        }
    }

    /// One attempt; false when another Mac wrote the head first.
    func syncDocumentOnce(_ id: String, _ local: Local?, _ report: inout SyncReport) async throws -> Bool {
        let known = state.docs[id]
        let remote = try await head(id, known: known)

        guard let local else {
            switch (known, remote) {
            case (nil, nil):
                return true
            case (nil, let r?):
                // New from another Mac.
                let path = try await freePath(r.head.path)
                try await folder.write(path, try await download(id, r.head))
                report.written.append(path)
                state.docs[id] = .init(head: r.head, etag: r.etag)
                report.items.append(.init(id: id, path: path, change: .added))
            case (let k?, let r?) where r.head.revision != k.head.revision:
                // Deleted here, changed elsewhere: the change wins.
                let path = try await freePath(r.head.path)
                try await folder.write(path, try await download(id, r.head))
                report.written.append(path)
                state.docs[id] = .init(head: r.head, etag: r.etag)
                report.items.append(.init(id: id, path: path, change: .kept))
            case (let k?, _):
                // Deleted here.
                let now = options.now()
                let device = options.device
                try await updateLibrary {
                    $0.documents[id] = .init(deleted: now, path: k.head.path, device: device)
                }
                state.docs[id] = nil
                state.conflicts[id] = nil
                report.items.append(.init(id: id, path: k.head.path, change: .deleted))
            }
            return true
        }

        let mine = names(local.files)
        let opaque = SyncFiles.isOpaque(local.files)
        guard let remote else {
            // New here (or its head is gone): create it.
            let head = makeHead(parents: known.map { [$0.head.revision] } ?? [], local.path, mine, opaque: opaque)
            guard try await push(id, head, local.files, condition: .ifNoneMatch, known: known, remote: nil) else {
                return false
            }
            try await ensureListed(id)
            report.items.append(.init(id: id, path: local.path, change: .pushed))
            return true
        }

        if let known, remote.head.revision == known.head.revision {
            // Only this Mac may have changed.
            guard mine != known.head.files || local.path != known.head.path else {
                try await ensureListed(id)
                return true
            }
            let head = makeHead(parents: [known.head.revision], local.path, mine, opaque: opaque)
            guard
                try await push(
                    id, head, local.files, condition: .ifMatch(remote.etag), known: known, remote: remote.head)
            else { return false }
            report.items.append(.init(id: id, path: local.path, change: .pushed))
            return true
        }

        // Without conditional writes, another Mac can overwrite this Mac's last revision in
        // the moment between checking the head and writing it: merge it back in.
        var base = known?.head
        var overwritten = false
        if !options.conditionalWrites, let known {
            overwritten = try await !descends(id, remote.head, known.head.revision)
        }
        if overwritten, let parent = known?.head.parents.first {
            base = try await record(id, parent)
        }

        if let known, mine == known.head.files, !overwritten {
            // Only the other Mac changed: fast-forward.
            var path = local.path
            if local.path == known.head.path, remote.head.path != local.path {
                path = try await freePath(remote.head.path)
                try await folder.move(local.path, to: path)
            }
            if mine != remote.head.files {
                try await folder.write(path, try await download(id, remote.head), replacing: local.files)
                report.written.append(path)
            }
            state.docs[id] = .init(head: remote.head, etag: remote.etag)
            report.items.append(.init(id: id, path: path, change: .pulled))
            return true
        }

        // Both changed (or this Mac has no base): merge base · this Mac · the library.
        let theirsFiles = try await download(id, remote.head)
        var baseFiles = try base.flatMap { try cached($0.files) }
        if baseFiles == nil, overwritten, let base { baseFiles = try await download(id, base) }
        let path = known.map { local.path != $0.head.path ? local.path : remote.head.path } ?? local.path
        var mergedFiles: [String: Data]
        var clashes: [MergeClash] = []
        if opaque || SyncFiles.isOpaque(theirsFiles) || remote.head.opaque == true {
            // Can't merge without the password: this Mac's copy wins; the other stays in history.
            mergedFiles = local.files
            report.notes[local.path] =
                "Changed on this Mac and on \(remote.head.device) while password-protected: this Mac’s copy was kept, and the other is in Sync History."
        } else {
            let base = try baseFiles.map { try NexusPackage.read(files: $0) }
            let m = DocumentMerge(
                base: base, current: try NexusPackage.read(files: local.files),
                disk: try NexusPackage.read(files: theirsFiles))
            mergedFiles = NexusPackage.files(for: m.model)
            clashes = m.clashes
        }
        let merged = names(mergedFiles)
        if merged == remote.head.files {
            // The library already has everything this Mac had.
            if mine != merged {
                try await folder.write(local.path, theirsFiles, replacing: local.files)
                report.written.append(local.path)
            }
            state.docs[id] = .init(head: remote.head, etag: remote.etag)
            report.items.append(.init(id: id, path: local.path, change: .pulled))
            return true
        }
        let parents = [remote.head.revision] + (known.map { [$0.head.revision] } ?? [])
        var head = makeHead(parents: parents, path, merged, opaque: opaque)
        head.clashes = clashes.isEmpty ? nil : clashes.count
        if merged != mine {
            try await folder.write(local.path, mergedFiles, replacing: local.files)
            report.written.append(local.path)
        }
        if path != local.path { try await folder.move(local.path, to: path) }
        try cache(theirsFiles)
        guard
            try await push(
                id, head, mergedFiles, condition: .ifMatch(remote.etag), known: known, remote: remote.head)
        else { return false }
        if !clashes.isEmpty {
            try cache(local.files)
            state.conflicts[id] = .init(
                base: known?.head.files, mine: mine, theirs: remote.head.files, merged: merged,
                theirsDevice: remote.head.device, date: options.now(), path: path)
            try saveState()
        }
        report.items.append(.init(id: id, path: path, change: .merged(clashes: clashes.count), clashes: clashes))
        return true
    }

    // MARK: Heads and blobs

    struct Remote {
        var head: HeadRecord
        var etag: String
    }

    func head(_ id: String, known: LibraryState.Doc?) async throws -> Remote? {
        switch try await transport.get(Layout.head(id), ifNoneMatch: known?.etag) {
        case .missing: return nil
        case .notModified:
            guard let known else { throw SyncError.damaged("a head") }
            return Remote(head: known.head, etag: known.etag)
        case .found(let data, let etag):
            let head = try Coding.decode(HeadRecord.self, try crypto.open(data), "a document’s head")
            return Remote(head: head, etag: etag)
        }
    }

    /// A revision's record from history.
    func record(_ id: String, _ rev: String) async throws -> HeadRecord? {
        guard case .found(let data, _) = try await transport.get(Layout.history(id, rev), ifNoneMatch: nil) else {
            return nil
        }
        return try Coding.decode(HeadRecord.self, try crypto.open(data), "a history record")
    }

    /// Whether `head` comes after `revision` (looking back 50 revisions at most).
    func descends(_ id: String, _ head: HeadRecord, _ revision: String) async throws -> Bool {
        var queue = head.parents
        var seen = Set<String>()
        while let r = queue.first, seen.count < 50 {
            queue.removeFirst()
            if r == revision { return true }
            guard seen.insert(r).inserted else { continue }
            queue += try await record(id, r)?.parents ?? []
        }
        return seen.count >= 50
    }

    func makeHead(parents: [String], _ path: String, _ files: [String: String], opaque: Bool) -> HeadRecord {
        let now = options.now().timeIntervalSince1970.rounded(.down)
        return HeadRecord(
            revision: LibraryCrypto.hex(Sealed.randomBytes(12)), parents: parents, device: options.device,
            date: Date(timeIntervalSince1970: now), path: path, files: files, opaque: opaque ? true : nil)
    }

    /// Uploads the blobs the library lacks, the history record, then the head if nobody
    /// wrote it first. State changes only after the head is written.
    func push(
        _ id: String, _ head: HeadRecord, _ files: [String: Data], condition: SyncCondition,
        known: LibraryState.Doc?, remote: HeadRecord?
    ) async throws -> Bool {
        // Blobs the library has: none if the document's head is gone (purged).
        let present =
            remote == nil
            ? Set<String>() : Set(known.map { Array($0.head.files.values) } ?? []).union(remote!.files.values)
        var sent = Set<String>()
        for path in files.keys.sorted() {
            let name = head.files[path]!
            guard !present.contains(name), sent.insert(name).inserted else { continue }
            _ = try await transport.put(
                Layout.blob(id, name), try crypto.seal(files[path]!, type: LibraryCrypto.blobType), condition: .none)
        }
        let record = try crypto.seal(try Coding.encode(head), type: LibraryCrypto.recordType)
        _ = try await transport.put(Layout.history(id, head.revision), record, condition: .none)
        let etag: String
        if options.conditionalWrites {
            guard case .stored(let e) = try await transport.put(Layout.head(id), record, condition: condition) else {
                return false
            }
            etag = e
        } else {
            // The provider ignores conditions: check nobody moved the head, write, read back.
            let now = try await transport.get(Layout.head(id), ifNoneMatch: nil)
            switch (condition, now) {
            case (.ifNoneMatch, .found), (.ifMatch, .missing): return false
            case (.ifMatch(let e), .found(_, let current)) where e != current: return false
            default: break
            }
            _ = try await transport.put(Layout.head(id), record, condition: .none)
            guard case .found(let data, let e) = try await transport.get(Layout.head(id), ifNoneMatch: nil),
                (try? Coding.decode(HeadRecord.self, try crypto.open(data), "head"))?.revision == head.revision
            else { return false }
            etag = e
        }
        try cache(files)
        state.docs[id] = .init(head: head, etag: etag)
        try saveState()
        return true
    }

    /// The files of a head, from the cache or the library; each blob is checked against its name.
    func download(_ id: String, _ head: HeadRecord) async throws -> [String: Data] {
        var out: [String: Data] = [:]
        var fetched: [String: Data] = [:]
        for (path, name) in head.files {
            if let d = fetched[name] ?? cachedBlob(name) {
                out[path] = d
                continue
            }
            guard case .found(let stored, _) = try await transport.get(Layout.blob(id, name), ifNoneMatch: nil) else {
                throw SyncError.damaged("a missing file in \(head.path)")
            }
            let d = try crypto.open(stored)
            guard crypto.name(d) == name else { throw SyncError.damaged("a file in \(head.path)") }
            fetched[name] = d
            out[path] = d
        }
        // Kept as the next merge's base.
        try cache(Dictionary(uniqueKeysWithValues: fetched.map { ($0.key, $0.value) }))
        return out
    }

    func names(_ files: [String: Data]) -> [String: String] { files.mapValues(crypto.name) }

    // MARK: The library record

    @discardableResult
    func library() async throws -> LibraryRecord {
        for _ in 0..<Self.attempts {
            switch try await transport.get(Layout.library, ifNoneMatch: state.library == nil ? nil : state.libraryETag)
            {
            case .notModified:
                return state.library!
            case .found(let data, let etag):
                let rec = try Coding.decode(LibraryRecord.self, try crypto.open(data), "library.json")
                guard rec.format == LibraryRecord.formatName else { throw SyncError.damaged("library.json") }
                guard rec.version <= LibraryRecord.version else { throw SyncError.newer(rec.version) }
                state.library = rec
                state.libraryETag = etag
                return rec
            case .missing:
                let rec = LibraryRecord()
                let data = try crypto.seal(try Coding.encode(rec), type: LibraryCrypto.recordType)
                if case .stored(let etag) = try await transport.put(Layout.library, data, condition: .ifNoneMatch) {
                    state.library = rec
                    state.libraryETag = etag
                    return rec
                }
            }
        }
        throw SyncError.transport("The library kept changing; try again.")
    }

    /// Applies a change to `library.json` if nobody wrote it first, else re-reads and retries.
    func updateLibrary(_ change: (inout LibraryRecord) -> Void) async throws {
        for _ in 0..<Self.attempts {
            var rec = try await library()
            let before = rec
            change(&rec)
            if rec == before { return }
            let data = try crypto.seal(try Coding.encode(rec), type: LibraryCrypto.recordType)
            let condition: SyncCondition = state.libraryETag.map { .ifMatch($0) } ?? .ifNoneMatch
            if options.conditionalWrites {
                if case .stored(let etag) = try await transport.put(Layout.library, data, condition: condition) {
                    state.library = rec
                    state.libraryETag = etag
                    return
                }
            } else {
                _ = try await transport.put(Layout.library, data, condition: .none)
                state.library = nil
                if try await library() == rec { return }
            }
            state.library = nil
        }
        throw SyncError.transport("The library kept changing; try again.")
    }

    func ensureListed(_ id: String) async throws {
        guard state.library?.documents[id] == nil else { return }
        try await updateLibrary { if $0.documents[id] == nil { $0.documents[id] = .init() } }
    }

    // MARK: Deletes

    /// Documents deleted from the library whose objects are still there.
    public func deletedDocuments() async throws -> [DeletedDocument] {
        let rec = try await library()
        return rec.documents.compactMap { id, e in
            e.deleted.map { DeletedDocument(id: id, path: e.path ?? id, date: $0, device: e.device ?? "") }
        }.sorted { $0.date > $1.date }
    }

    /// Brings a deleted document back: every Mac downloads it at its next sync.
    public func restore(_ id: String) async throws {
        try await updateLibrary { $0.documents[id]?.deleted = nil }
        _ = try await sync()
    }

    /// Removes the objects of documents deleted more than the days to keep ago.
    func purge(_ report: inout SyncReport) async throws {
        let cutoff = options.now().addingTimeInterval(-Double(options.keepDeletedDays) * 86_400)
        for (id, e) in state.library?.documents ?? [:] {
            guard let d = e.deleted, d < cutoff, SyncFiles.valid(id) else { continue }
            for key in try await transport.list(Layout.docs(id)) { try await transport.delete(key) }
            try await updateLibrary { $0.documents[id] = nil }
            report.items.append(.init(id: id, path: e.path ?? id, change: .purged))
        }
    }

    // MARK: History

    /// A document's revisions, newest first, following each revision's first parent.
    public func history(_ id: String, limit: Int = 50) async throws -> [HeadRecord] {
        guard let start = try await head(id, known: nil)?.head else { return [] }
        var out = [start]
        while out.count < limit, let parent = out.last?.parents.first, let r = try await record(id, parent) {
            out.append(r)
        }
        return out
    }

    /// A revision's package files.
    public func files(_ id: String, _ head: HeadRecord) async throws -> [String: Data] {
        try await download(id, head)
    }

    /// The id of the document at `path`, if the library has synced it.
    public func documentID(at path: String) -> String? {
        state.docs.first { $0.value.head.path == path }?.key
    }

    public var lastSynced: [String: HeadRecord] { state.docs.mapValues(\.head) }

    // MARK: Conflicts

    /// Documents with clashes to resolve: id → path.
    public var conflicts: [String: String] { state.conflicts.mapValues(\.path) }

    public func conflict(_ id: String) throws -> PendingConflict? {
        guard let c = state.conflicts[id] else { return nil }
        func model(_ names: [String: String]) throws -> DocumentModel {
            guard let files = try cached(names) else { throw SyncError.damaged("the clash’s copies") }
            return try NexusPackage.read(files: files)
        }
        return PendingConflict(
            id: id, path: c.path, base: c.base.flatMap { try? model($0) }, mine: try model(c.mine),
            theirs: try model(c.theirs),
            merged: try model(c.merged), theirsDevice: c.theirsDevice, date: c.date)
    }

    /// The clashes were resolved (or dismissed).
    public func clearConflict(_ id: String) throws {
        state.conflicts[id] = nil
        try saveState()
    }

    /// Forgets what this Mac synced: the next sync merges each document two ways.
    public func reset() throws {
        state = LibraryState()
        try? FileManager.default.removeItem(at: stateURL)
        try saveState()
    }

    // MARK: State and cache

    func saveState() throws {
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        try Coding.encode(state).write(to: stateURL.appending(path: "state.json"), options: .atomic)
    }

    var blobs: URL { stateURL.appending(path: "blobs") }

    func cache(_ files: [String: Data]) throws {
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for d in files.values {
            let u = blobs.appending(path: crypto.name(d))
            if !FileManager.default.fileExists(atPath: u.path(percentEncoded: false)) {
                try d.write(to: u, options: .atomic)
            }
        }
    }

    func cachedBlob(_ name: String) -> Data? {
        guard let d = try? Data(contentsOf: blobs.appending(path: name)), crypto.name(d) == name else { return nil }
        return d
    }

    /// Files by name from the cache; nil if any is missing.
    func cached(_ names: [String: String]) throws -> [String: Data]? {
        var out: [String: Data] = [:]
        for (path, name) in names {
            guard let d = cachedBlob(name) else { return nil }
            out[path] = d
        }
        return out
    }

    /// Deletes cached blobs nothing refers to any more.
    func collectGarbage() {
        var keep = Set(state.docs.values.flatMap(\.head.files.values))
        for c in state.conflicts.values {
            keep.formUnion(c.mine.values)
            keep.formUnion(c.theirs.values)
            keep.formUnion(c.merged.values)
            keep.formUnion(c.base.map { Array($0.values) } ?? [])
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: blobs.path(percentEncoded: false))) ?? []
        for n in names where !keep.contains(n) { try? FileManager.default.removeItem(at: blobs.appending(path: n)) }
    }

    /// `path`, or "Name 2.nexus" and so on when another package is there.
    func freePath(_ path: String) async throws -> String {
        let taken = Set(try await folder.documents())
        guard taken.contains(path) else { return path }
        let ext = "." + NexusPackage.fileExtension
        let stem = path.hasSuffix(ext) ? String(path.dropLast(ext.count)) : path
        var n = 2
        while taken.contains("\(stem) \(n)\(ext)") { n += 1 }
        return "\(stem) \(n)\(ext)"
    }
}
