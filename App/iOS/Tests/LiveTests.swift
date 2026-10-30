import Foundation
import NexusCore
import NexusFormat
import NexusNet
import NexusReplica
import NexusSync
import NexusTouch
import Testing
import UIKit

@testable import NexusCanvas
@testable import OpenNexus

/// A5, the iPad's half (`scripts/test-ipad.sh`, with Docker): a Mac process and this
/// simulator take turns on one folder (`OPENNEXUS_IPAD_LIVE_DIR`), through the app's own
/// network adapter (`InProcessNetwork`). The Mac's half is `IPadLive` in NexusCanvasTests.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENNEXUS_IPAD_LIVE"] == "1"))
struct LiveTests {
    static let env = ProcessInfo.processInfo.environment
    static let dir = URL(fileURLWithPath: env["OPENNEXUS_IPAD_LIVE_DIR"] ?? NSTemporaryDirectory())
    static let s3 = env["OPENNEXUS_LIVE_S3"] ?? "http://127.0.0.1:19000"

    static func texts(_ m: DocumentModel) -> Set<String> {
        Set(m.canvases["c1"]?.nodes.values.map(\.text) ?? [])
    }

    static func waitFor(_ what: String, seconds: Double, _ check: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(seconds)
        while !check(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(check(), "timed out: \(what)")
        if !check() { throw CancellationError() }
    }

    // MARK: A shared library folder (iCloud Drive's stand-in)

    /// The map is open on the iPad with an unsaved edit when the Mac's save lands in the
    /// folder: the document merges it (one undo step) instead of reverting, then saves.
    @Test func iPadMergesTheMacsSave() async throws {
        let url = Self.dir.appending(path: "folder/Plan.nexus")
        let doc = TouchDocument(fileURL: url)
        #expect(await doc.open())
        let controller = CanvasController(store: doc.store)
        controller.host = MemoryCanvasHost()
        var conflicts: [String]?
        doc.onMerged = { conflicts = $0 }
        let channels = try #require(doc.store.model.canvases["c1"]?.nodes.first { $0.value.text == "Channels" }?.key)
        controller.select(channels)
        controller.addChild()
        controller.editorTextDidChange("iPad idea")
        controller.commitEdit()
        // `UIDocument` counts the edit when its undo group closes, at the end of this turn.
        try await Self.waitFor("the edit marks the document changed", seconds: 5) { doc.hasUnsavedChanges }

        // The Mac's save, as a synced folder delivers it: a coordinated replacement, from
        // another thread. On the main thread it would wait for the document, which answers
        // the coordinator there.
        let macSave = try Self.copy(Self.dir.appending(path: "folder-mac.nexus"))
        let error = await Task.detached { () -> String? in
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forReplacing, error: &error
            ) { u in
                _ = try? FileManager.default.replaceItemAt(u, withItemAt: macSave)
            }
            return error?.localizedDescription
        }.value
        #expect(error == nil)
        try await Self.waitFor("the iPad merges the Mac's save", seconds: 20) { conflicts != nil }
        // `UIDocument` asks to revert once the writer is done; merged, not reverted (D409).
        try await Task.sleep(for: .seconds(1))
        #expect(conflicts == [])
        let merged = Self.texts(doc.store.model)
        #expect(merged.contains("iPad idea") && merged.contains("Pricing (Mac)"), "\(merged)")
        // One step: undo takes back the Mac's change, not the iPad's own edit.
        doc.undoManager.undo()
        #expect(!Self.texts(doc.store.model).contains("Pricing (Mac)"))
        #expect(Self.texts(doc.store.model).contains("iPad idea"))
        doc.undoManager.redo()
        #expect(await doc.save(to: url, for: .forOverwriting))
        await doc.close()
    }

    static func copy(_ url: URL) throws -> URL {
        let to = FileManager.default.temporaryDirectory.appending(path: "mac-save-\(UUID().uuidString).nexus")
        try FileManager.default.copyItem(at: url, to: to)
        return to
    }

    // MARK: An S3 library

    struct S3Config: Codable {
        var id: String
        var prefix: String
        var recoveryKey: String
    }

    static func syncCenter() throws -> (SyncCenter, SyncLibrary) {
        let cfg = try JSONDecoder().decode(S3Config.self, from: Data(contentsOf: dir.appending(path: "s3.json")))
        let prefs = Preferences.isolated()
        prefs.set("network.enabled", true)
        prefs.set("network.sync", true)
        let center = SyncCenter(
            directory: dir.appending(path: "s3-ipad-state"), secrets: MemorySecrets(),
            transport: InProcessNetwork.Transport(), prefs: prefs, networkLog: NetworkLog(file: nil))
        center.device = "iPad"
        var bucket = ShareDestination(id: "minio", kind: .s3, name: "MinIO")
        bucket.endpoint = s3
        bucket.bucket = "sync"
        bucket.prefix = cfg.prefix
        bucket.accessKey = "onxtest"
        let lib = SyncLibrary(
            id: cfg.id, name: "Live", folder: dir.appending(path: "s3-ipad").path(percentEncoded: false),
            bucket: bucket)
        try center.save(lib, secret: "onxtest-secret-key", recoveryKey: cfg.recoveryKey)
        return (center, lib)
    }

    /// Synced with nothing in the log flagged: a document's error leaves the status synced.
    static func synced(_ center: SyncCenter, _ lib: SyncLibrary) -> Bool {
        guard case .synced = center.status[lib.id] else { return false }
        return !center.log.contains(where: \.problem)
    }

    /// What the syncs since the log had `count` lines said, oldest first (the log is newest first).
    static func said(_ center: SyncCenter, since count: Int) -> [String] {
        center.log.prefix(center.log.count - count).reversed().map(\.text)
    }

    /// The iPad joins the Mac's library with its recovery key, pulls the map, edits it and
    /// pushes; the Mac has edited its own copy meanwhile (`IPadLive.macMergesTheIPad`).
    @Test func iPadSyncsAnS3Library() async throws {
        let (center, lib) = try Self.syncCenter()
        await center.syncNow(lib.id)
        #expect(Self.synced(center, lib), "\(String(describing: center.status[lib.id])) \(center.log.map(\.text))")
        #expect(Self.said(center, since: 0) == ["Added Plan.nexus from another Mac"], "\(center.log.map(\.text))")
        let folder = DiskFolder(lib.folderURL)
        let files = try #require(try await folder.read("Plan.nexus"))
        var doc = try NexusPackage.read(files: files)
        #expect(Self.texts(doc).contains("Pricing"))
        var e = CanvasEditor(doc.canvases["c1"]!)
        let risks = try #require(e.canvas.nodes.first { $0.value.text == "Risks" }?.key)
        try e.addChild(of: risks, text: "iPad risk")
        doc.canvases["c1"] = e.canvas
        try await folder.write("Plan.nexus", NexusPackage.files(for: doc))
        let before = center.log.count
        await center.syncNow(lib.id)
        #expect(Self.synced(center, lib), "\(center.log.map(\.text))")
        #expect(Self.said(center, since: before) == ["Sent Plan.nexus"], "\(center.log.map(\.text))")
    }

    /// After the Mac merged and pushed: the iPad pulls both edits, and its copy is the Mac's.
    @Test func iPadSeesTheMerge() async throws {
        let (center, lib) = try Self.syncCenter()
        await center.syncNow(lib.id)
        #expect(Self.synced(center, lib))
        let files = try #require(try await DiskFolder(lib.folderURL).read("Plan.nexus"))
        let doc = try NexusPackage.read(files: files)
        let t = Self.texts(doc)
        #expect(t.contains("iPad risk") && t.contains("Timeline (Mac)"), "\(t)")
        let mac = try NexusPackage.read(from: Self.dir.appending(path: "s3-mac/Plan.nexus"))
        #expect(sharedCanonical(doc) == sharedCanonical(mac))
    }

    // MARK: A live session

    /// Joins the Mac's session from its invite, adds a topic, sees the Mac's edit, and writes
    /// its copy for the script to compare with the Mac's.
    @Test func iPadJoinsAMacsSession() async throws {
        let invite = Self.dir.appending(path: "invite")
        try await Self.waitFor("the Mac's invite", seconds: 240) {
            FileManager.default.fileExists(atPath: invite.path(percentEncoded: false))
        }
        let link = try String(contentsOf: invite, encoding: .utf8)
        let prefs = Preferences.isolated()
        prefs.set("network.enabled", true)
        prefs.set("network.collab", true)
        prefs.set("editing.commentAuthor", "iPad")
        let share = ShareCenter(
            store: ShareStore(file: nil), log: NetworkLog(file: nil), secrets: MemorySecrets(),
            transport: InProcessNetwork.Transport(), prefs: prefs)
        let center = CollabCenter(
            directory: FileManager.default.temporaryDirectory.appending(path: "collab-\(UUID().uuidString)"),
            share: share, prefs: prefs)
        center.connector = InProcessNetwork().connector(purpose: "Live session", log: share.log)
        center.saveDelay = .milliseconds(5)
        var harness: TouchHarness?
        let session = try center.join(link)
        session.onReady = { model in
            let h = TouchHarness(model: model)
            h.controller.prefs = prefs
            h.controller.shareCenter = share
            h.controller.collabCenter = center
            let id: String =
                if case .string(let s)? = model.manifestExtra["documentID"] { s } else { UUID().uuidString }
            h.controller.documentIDProvider = { id }
            if let bound = center.resume(store: h.store, documentID: id) { h.controller.attach(bound) }
            harness = h
        }
        try await Self.waitFor("the session's copy", seconds: 30) { harness != nil }
        let h = try #require(harness)
        #expect(Self.texts(h.store.model).contains("Pricing"))
        h.controller.select(h.canvas.root)
        h.controller.addChild()
        h.controller.editorTextDidChange("iPad live")
        h.controller.commitEdit()
        try await Self.waitFor("the Mac's edit", seconds: 60) {
            Self.texts(h.store.model).contains("Pricing (Mac live)")
        }
        try sharedCanonical(h.store.model).write(
            to: Self.dir.appending(path: "ipad-canonical"), atomically: true, encoding: .utf8)
        // Stay in the session until the Mac has compared its copy.
        try await Self.waitFor("the Mac's copy", seconds: 60) {
            FileManager.default.fileExists(
                atPath: Self.dir.appending(path: "mac-canonical").path(percentEncoded: false))
        }
        h.controller.leaveCollab()
    }

    // MARK: A share link

    /// A link to MinIO made on the iPad; Playwright opens it in Chromium and WebKit
    /// (`share.spec.ts`, "share links made on the iPad").
    @Test func iPadMakesAShareLink() async throws {
        let prefs = Preferences.isolated()
        prefs.set("network.enabled", true)
        prefs.set("network.sharing", true)
        prefs.set("sharing.viewerAddress", "http://127.0.0.1:4310/")
        let center = ShareCenter(
            store: ShareStore(file: nil), log: NetworkLog(file: nil), secrets: MemorySecrets(),
            transport: InProcessNetwork.Transport(), prefs: prefs)
        var minio = ShareDestination(id: "minio", kind: .s3, name: "MinIO")
        minio.endpoint = Self.s3
        minio.bucket = "maps"
        minio.accessKey = "onxtest"
        center.saveDestination(minio, secret: "onxtest-secret-key")
        let test = await center.test(minio)
        #expect(test.ok, "\(test.error ?? "")")

        var model = nodeStyleSampleDocument(theme: "classic", style: "soft")
        model.canvases["c1"]?.title = "Made on the iPad"
        let h = TouchHarness(model: model)
        h.controller.prefs = prefs
        h.controller.shareCenter = center
        h.controller.openShareLink()
        var s = try #require(h.controller.shareState)
        s.destination = "minio"
        var r = ShareRecord(
            document: h.controller.shareDocumentName, path: h.controller.documentPath,
            scope: h.controller.shareScope(s.export), destination: "minio")
        r.mask = s.export.mask
        let made = try await center.create(h.controller.shareBundle(s), record: r, password: nil)
        let link = try #require(center.link(made))
        #expect(link.hasPrefix("http://127.0.0.1:4310/"))

        // What the reader should see: the Interactive HTML export's bundle.
        let html = h.controller.exportHTML(s.export)
        let open = "<script type=\"application/json\" id=\"opennexus-bundle\">"
        let start = try #require(html.range(of: open))
        let end = try #require(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
        let bundle = try CanonicalJSON.parse(Data(html[start.upperBound..<end.lowerBound].utf8))

        let out = repoRoot.appending(path: "web/fixtures/share-ipad")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(CanonicalJSON.compact(bundle).utf8).write(to: out.appending(path: "ipad.bundle.json"))
        let manifest = JSONValue.object([
            "viewer": .string("http://127.0.0.1:4310/"),
            "cases": .array([
                .object([
                    "name": .string("minio-from-ipad"), "link": .string(link), "expect": .string("ready"),
                    "routes": .array([]), "bundle": .string("ipad.bundle.json"),
                ])
            ]),
        ])
        try CanonicalJSON.data(manifest).write(to: out.appending(path: "manifest.json"))
    }
}

/// The shared part of a document as canonical bytes (the Mac's `sharedCanonical`).
func sharedCanonical(_ doc: DocumentModel) -> String {
    var out = "order: \(doc.canvasOrder.map(\.rawValue))\n"
    for id in doc.canvasOrder {
        if let c = doc.canvases[id] { out += CanonicalJSON.string(c.json) }
    }
    out += CanonicalJSON.string(doc.theme)
    return out + "assets: \(doc.assets.keys.sorted())\n"
}
