import AppKit
import CryptoKit
import Foundation
import NexusFormat
import NexusSync
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// M45 in the app: libraries synced through `SyncCenter`, Resolve Conflicts and Sync
/// History in an open document (A2), conflict copies other apps left (A7), and typing
/// while a sync runs (A9). The bucket is in memory; the engine is the real one.
@MainActor
@Suite(.serialized) struct SyncTests {
    /// One Mac: its sync center, its library folder, and the shared bucket.
    @MainActor struct Mac {
        let center: SyncCenter
        let folder: URL
        let library: SyncLibrary

        init(_ name: String, _ bucket: any SyncTransport, key: SymmetricKey) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
            folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let prefs = Preferences.isolated()
            prefs.set("network.enabled", true)
            prefs.set("network.sync", true)
            center = SyncCenter(
                directory: root.appending(path: "state"), secrets: MemorySecrets(), transport: LocalTransport(),
                prefs: prefs, networkLog: NetworkLog(file: nil))
            center.device = name
            var bucketAddress = SyncLibrary.newBucket()
            bucketAddress.endpoint = "https://s3.example.com"
            bucketAddress.bucket = "plans"
            bucketAddress.accessKey = "AKIA"
            var lib = SyncLibrary(name: "Plans", folder: folder.path(percentEncoded: false), bucket: bucketAddress)
            lib.id = "lib-1"
            try center.save(lib, secret: "secret", recoveryKey: RecoveryKey.text(key))
            library = lib
            center.engines[lib.id] = SyncEngine(
                transport: bucket, crypto: LibraryCrypto(key: key), folder: DiskFolder(folder),
                stateDirectory: root.appending(path: "state/\(lib.id)"), options: .init(device: name))
        }

        var url: URL { folder.appending(path: "Plan.nexus", directoryHint: .isDirectory) }

        func write(_ doc: DocumentModel) async throws {
            try await DiskFolder(folder).write("Plan.nexus", NexusPackage.files(for: doc))
        }

        func read() throws -> DocumentModel { try NexusPackage.read(from: url) }

        func setText(_ from: String, _ to: String) async throws {
            var doc = try read()
            var e = CanvasEditor(doc.canvases["c1"]!)
            e.setText(e.canvas.nodes.first { $0.value.text == from }!.key, to)
            doc.canvases["c1"] = e.canvas
            try await write(doc)
        }

        /// The document open in a window: a controller whose store has an undo stack.
        func open() throws -> (CanvasController, StackUndoRegistrar) {
            let store = DocumentStore(model: try read())
            let undo = StackUndoRegistrar()
            store.undoRegistrar = undo
            let c = CanvasController(store: store)
            c.syncCenter = center
            c.documentPath = url.path(percentEncoded: false)
            return (c, undo)
        }
    }

    /// A bucket a few milliseconds away, like a real one.
    struct Distant: SyncTransport {
        let bucket = MemoryBucket()
        func get(_ key: String, ifNoneMatch: String?) async throws -> SyncGet {
            try await Task.sleep(for: .milliseconds(4))
            return try await bucket.get(key, ifNoneMatch: ifNoneMatch)
        }
        func put(_ key: String, _ data: Data, condition: SyncCondition) async throws -> SyncPut {
            try await Task.sleep(for: .milliseconds(4))
            return try await bucket.put(key, data, condition: condition)
        }
        func delete(_ key: String) async throws { try await bucket.delete(key) }
        func list(_ prefix: String) async throws -> [String] { try await bucket.list(prefix) }
    }

    func texts(_ m: DocumentModel) -> Set<String> {
        Set(m.canvases.values.flatMap { $0.nodes.values.map(\.text) })
    }

    func waitFor(_ what: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !what() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(what())
    }

    /// Two Macs change "Pricing": B's sync keeps its own side, lists one conflict, and the
    /// open document resolves it as one undo step.
    func clashed() async throws -> (Mac, Mac) {
        let bucket = MemoryBucket()
        let key = Sealed.newKey()
        let a = try Mac("A", bucket, key: key)
        let b = try Mac("B", bucket, key: key)
        try await a.write(launchPlanDocument())
        await a.center.syncNow()
        await b.center.syncNow()
        #expect(try b.read().canvases == launchPlanDocument().canvases)
        try await a.setText("Pricing", "Pricing (A)")
        try await b.setText("Pricing", "Pricing (B)")
        await a.center.syncNow()
        await b.center.syncNow()
        return (a, b)
    }

    @Test(arguments: MergeClash.Choice.allCases) func aClashResolvesAsOneUndoStep(_ choice: MergeClash.Choice)
        async throws
    {
        let (_, b) = try await clashed()
        #expect(b.center.status["lib-1"] == .conflicts(1))
        #expect(b.center.status(of: b.url) == .conflicts(1))
        #expect(texts(try b.read()).contains("Pricing (B)"), "this Mac's side until resolved")

        let (c, undo) = try b.open()
        c.openResolveConflicts()
        try await waitFor { c.resolveState != nil }
        let s = try #require(c.resolveState)
        #expect(s.clashes.count == 1)
        #expect(s.clashes[0].mine == "Pricing (B)" && s.clashes[0].theirs == "Pricing (A)")
        #expect(s.choice(s.clashes[0]) == .mine)

        c.choose(choice, for: s.clashes[0])
        c.applyResolution()
        #expect(c.resolveState == nil)
        let after = texts(c.store.model)
        switch choice {
        case .mine:
            #expect(after.contains("Pricing (B)") && !after.contains("Pricing (A)"))
            #expect(undo.stack.undoStack.isEmpty, "keeping this Mac's side changes nothing")
        case .theirs:
            #expect(after.contains("Pricing (A)") && !after.contains("Pricing (B)"))
        case .both:
            #expect(after.isSuperset(of: ["Pricing (A)", "Pricing (B)"]))
            #expect(c.store.model.canvases.values.contains { $0.title.contains("from A") })
        }
        if choice != .mine {
            #expect(undo.stack.undoStack.count == 1 && undo.stack.undoStack[0].actionName == "Resolve Conflicts")
            undo.undo(c.store)
            #expect(texts(c.store.model).contains("Pricing (B)") && !texts(c.store.model).contains("Pricing (A)"))
        }
        // Resolved: the library no longer lists it.
        try await waitFor { b.center.conflicts["lib-1"]?.isEmpty == true }
        #expect(b.center.status(of: b.url) != .conflicts(1))
    }

    @Test func resolveKeepsEditsMadeSinceTheMerge() async throws {
        let (_, b) = try await clashed()
        let (c, _) = try b.open()
        // Typed after the sync, before resolving.
        _ = c.store.commitDocument("Typing", focus: "c1") { d in
            var e = CanvasEditor(d.canvases["c1"]!)
            _ = try? e.addChild(of: e.canvas.root, text: "Typed meanwhile")
            d.canvases["c1"] = e.canvas
        }
        c.openResolveConflicts()
        try await waitFor { c.resolveState != nil }
        c.chooseAll(.theirs)
        c.applyResolution()
        #expect(texts(c.store.model).isSuperset(of: ["Pricing (A)", "Typed meanwhile"]))
    }

    @Test func syncHistoryRestoresAsOneUndoStep() async throws {
        let bucket = MemoryBucket()
        let a = try Mac("A", bucket, key: Sealed.newKey())
        try await a.write(launchPlanDocument())
        await a.center.syncNow()
        try await a.setText("Pricing", "Prices")
        await a.center.syncNow()
        let (c, undo) = try a.open()
        c.openSyncHistory()
        try await waitFor { c.syncHistory?.loading == false }
        let items = try #require(c.syncHistory?.items)
        #expect(items.count == 2 && items[0].device == "A")
        c.restoreRevision(items[1])
        try await waitFor { c.syncHistory == nil }
        #expect(texts(c.store.model).contains("Pricing") && !texts(c.store.model).contains("Prices"))
        #expect(undo.stack.undoStack.map(\.actionName) == ["Restore Revision"])
    }

    @Test func documentsOutsideALibraryHaveNoSyncHistory() throws {
        let c = CanvasController(store: DocumentStore(model: launchPlanDocument()))
        c.syncCenter = SyncCenter(
            directory: nil, secrets: MemorySecrets(), transport: LocalTransport(), prefs: .isolated(),
            networkLog: NetworkLog(file: nil))
        c.documentPath = "/tmp/Elsewhere.nexus"
        c.openSyncHistory()
        #expect(c.syncHistory == nil && c.toast?.text == "This document isn’t in a sync library")
    }

    /// A9: key to caret stays under a frame while a library syncs (the engine is an actor
    /// off the main thread; the main actor only hears the result).
    @Test func typingStaysFastWhileALibrarySyncs() async throws {
        let a = try Mac("A", Distant(), key: Sealed.newKey())
        let folder = DiskFolder(a.folder)
        for i in 0..<24 {
            var doc = bigDocument(mains: 10, subs: 10, leaves: 3)
            doc.assets["photo.png"] = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) })
            try await folder.write("Big \(i).nexus", NexusPackage.files(for: doc))
        }
        let h = CanvasHarness(model: bigDocument(mains: 8, subs: 5, leaves: 4))
        let topics = h.canvas.nodes.count
        let clock = ContinuousClock()
        func sample() -> Duration {
            let main = h.canvas.nodes[h.canvas.root]!.children[Int.random(in: 0..<8)]
            h.controller.select(main)
            let d = clock.measure { h.press("tab") }
            h.press("return")
            // Undone, so the map is the same size for every sample.
            while h.canvas.nodes.count > topics, h.undo.undo(h.store) {}
            return d
        }
        /// How long the main actor takes to come back from a 2 ms sleep: main-actor work
        /// queued by sync would show here.
        func wait() async throws -> Duration {
            let t = clock.now
            try await Task.sleep(for: .milliseconds(2))
            return clock.now - t
        }
        var quiet: [Duration] = []
        var quietWaits: [Duration] = []
        for _ in 0..<20 {
            quiet.append(sample())
            quietWaits.append(try await wait())
        }

        final class Flag { var done = false }
        var busy: [Duration] = []
        var stalls: [Duration] = []
        let flag = Flag()
        let center = a.center
        let sync = Task { @MainActor in
            await center.syncNow()
            flag.done = true
        }
        while !flag.done && busy.count < 200 {
            busy.append(sample())
            stalls.append(try await wait())
        }
        await sync.value
        print(
            "key→caret median \(ms(median(quiet))) ms quiet, \(ms(median(busy))) ms during sync (\(busy.count) samples); main actor back from 2 ms in \(ms(median(quietWaits)))/\(ms(quietWaits.max()!)) ms quiet, \(ms(median(stalls)))/\(ms(stalls.max() ?? .zero)) ms during sync (median/longest)"
        )
        #expect(busy.count >= 20, "the sync ran while typing")
        #expect(median(busy) < .milliseconds(16))
        #expect(median(busy) < median(quiet) * 1.15 + .milliseconds(1))
        #expect(median(stalls) < median(quietWaits) + .milliseconds(2))
        #expect(a.center.log.contains { $0.text == "Sent Big 0.nexus" })
    }
}

/// A7: copies other apps' sync left are offered and merged in (synthetic versions and files).
@MainActor
@Suite(.serialized) struct ConflictCopyTests {
    final class Versions: ConflictVersions {
        var copies: [ConflictCopy] = []
        var resolved: [URL] = []
        func unresolved(_ url: URL) -> [ConflictCopy] { copies }
        func resolve(_ url: URL) { resolved.append(url) }
    }

    @Test func namesOtherAppsGiveTheirCopies() {
        let m = { (name: String, folder: String) in ConflictCopies.match(name, of: "Plan.nexus", folder: folder) }
        #expect(m("Plan (Jerry's conflicted copy 2026-10-29).nexus", "/Users/j/Dropbox")! == ("Dropbox", "Jerry"))
        #expect(m("Plan (conflicted copy 2026-10-29 101112).nexus", "/Users/j/Dropbox")! == ("Dropbox", nil))
        #expect(m("Plan (Jerry’s conflicted copy).nexus", "/Users/j/Nextcloud")! == ("Nextcloud", "Jerry"))
        #expect(m("Plan.sync-conflict-20261029-101112-ABCDEFG.nexus", "/x")! == ("Syncthing", "ABCDEFG"))
        #expect(m("Plan (1).nexus", "/Users/j/Library/CloudStorage/GoogleDrive-j@x/My Drive")! == ("Google Drive", nil))
        #expect(m("Plan (1).nexus", "/Users/j/Documents") == nil, "an ordinary copy outside Google Drive")
        #expect(
            m("Plan-MacBook-Air.nexus", "/Users/j/Library/CloudStorage/OneDrive-Personal")! == (
                "OneDrive", "MacBook-Air"
            ))
        #expect(m("Plan-MacBook-Air.nexus", "/Users/j/Documents") == nil)
        for other in ["Plan.nexus", "Planning.nexus", "Plan copy.nexus", "Plan (Jerry's conflicted copy).nexusjson"] {
            #expect(m(other, "/Users/j/Dropbox") == nil, "\(other)")
        }
    }

    /// The document, a Dropbox copy that added a topic, a Syncthing copy that renamed one,
    /// an iCloud version that added another, and an unrelated file. (Without a base, two
    /// copies' new topics under the same parent share an id and are one clash.)
    func folder() async throws -> (URL, Versions) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "copies-\(UUID().uuidString)/Dropbox")
        let disk = DiskFolder(dir)
        let base = launchPlanDocument()
        try await disk.write("Plan.nexus", NexusPackage.files(for: base))
        func variant(_ body: (inout CanvasEditor) throws -> Void) rethrows -> DocumentModel {
            var d = base
            var e = CanvasEditor(d.canvases["c1"]!)
            try body(&e)
            d.canvases["c1"] = e.canvas
            return d
        }
        try await disk.write(
            "Plan (Jerry's conflicted copy 2026-10-29).nexus",
            NexusPackage.files(
                for: try variant { e in
                    _ = try e.addChild(
                        of: e.canvas.nodes.first { $0.value.text == "Channels" }!.key, text: "From Dropbox")
                }))
        try await disk.write(
            "Plan.sync-conflict-20261029-101112-ABCDEFG.nexus",
            NexusPackage.files(
                for: variant { e in e.setText(e.canvas.nodes.first { $0.value.text == "Risks" }!.key, "Open risks") }))
        try await disk.write("Other.nexus", NexusPackage.files(for: base))
        let versionURL = dir.deletingLastPathComponent().appending(path: "version.nexus", directoryHint: .isDirectory)
        try await DiskFolder(versionURL.deletingLastPathComponent()).write(
            "version.nexus",
            NexusPackage.files(for: try variant { _ = try $0.addChild(of: $0.canvas.root, text: "From iCloud") }))
        let versions = Versions()
        versions.copies = [
            ConflictCopy(url: versionURL, source: "iCloud Drive", from: "MacBook Air", isVersion: true)
        ]
        return (dir.appending(path: "Plan.nexus", directoryHint: .isDirectory), versions)
    }

    @Test func openingADocumentFindsItsCopies() async throws {
        let (url, versions) = try await folder()
        let copies = ConflictCopies.find(for: url, versions: versions)
        #expect(copies.map(\.source) == ["iCloud Drive", "Dropbox", "Syncthing"])
        #expect(
            copies.map(\.label) == [
                "iCloud Drive copy from MacBook Air", "Dropbox copy from Jerry", "Syncthing copy from ABCDEFG",
            ])
        #expect(copies.allSatisfy { $0.isVersion || $0.modified != nil })
    }

    @Test func mergingCopiesKeepsBothSidesAndTrashesThem() async throws {
        let (url, versions) = try await folder()
        let store = DocumentStore(model: try NexusPackage.read(from: url))
        let undo = StackUndoRegistrar()
        store.undoRegistrar = undo
        let c = CanvasController(store: store)
        var finished: [ConflictCopy] = []
        var trashed: [URL] = []
        c.onConflictCopiesMerged = { copies in
            finished = copies
            ConflictCopies.finish(copies, of: url, versions: versions) { trashed.append($0) }
        }
        c.offerConflictCopies(ConflictCopies.find(for: url, versions: versions))
        #expect(c.conflictCopies.count == 3)
        c.mergeConflictCopies()
        #expect(c.conflictCopies.isEmpty)
        // What only a copy has arrives, one undo step per copy that brought something.
        #expect(
            Set(c.store.model.canvases["c1"]!.nodes.values.map(\.text)).isSuperset(of: ["From Dropbox", "From iCloud"]))
        #expect(undo.stack.undoStack.map(\.actionName) == Array(repeating: "Merge Conflicting Copy", count: 2))
        #expect(c.resolveQueue.isEmpty)
        // The rename is a clash: the document keeps "Risks" until the user chooses.
        let s = try #require(c.resolveState)
        #expect(s.title == "Syncthing copy from ABCDEFG" && s.clashes.count == 1)
        #expect(s.clashes[0].mine == "Risks" && s.clashes[0].theirs == "Open risks")
        #expect(finished.isEmpty, "not done until the clashes are resolved")
        c.choose(.theirs, for: s.clashes[0])
        c.applyResolution()
        #expect(c.store.model.canvases["c1"]!.nodes.values.contains { $0.text == "Open risks" })
        #expect(undo.stack.undoStack.last?.actionName == "Resolve Conflicts")
        #expect(finished.count == 3)
        #expect(versions.resolved == [url])
        #expect(
            Set(trashed.map(\.lastPathComponent)) == [
                "Plan (Jerry's conflicted copy 2026-10-29).nexus", "Plan.sync-conflict-20261029-101112-ABCDEFG.nexus",
            ])
    }

    @Test func notNowLeavesTheCopies() async throws {
        let (url, versions) = try await folder()
        let c = CanvasController(store: DocumentStore(model: try NexusPackage.read(from: url)))
        var finished = false
        c.onConflictCopiesMerged = { _ in finished = true }
        c.offerConflictCopies(ConflictCopies.find(for: url, versions: versions))
        c.dismissConflictCopies()
        #expect(c.conflictCopies.isEmpty && !finished)
        #expect(ConflictCopies.find(for: url, versions: versions).count == 3)
    }
}
