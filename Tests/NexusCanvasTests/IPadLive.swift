import Foundation
import NexusFormat
import NexusSync
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusNet

/// M47b's A5, the Mac's half (`scripts/test-ipad.sh`, with Docker): this process and the
/// iPad simulator take turns on one folder (`OPENNEXUS_IPAD_LIVE_DIR`). The iPad's half is
/// `LiveTests` in `App/iOS/Tests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENNEXUS_IPAD_LIVE"] == "1"))
struct IPadLive {
    static let env = ProcessInfo.processInfo.environment
    static let dir = URL(fileURLWithPath: env["OPENNEXUS_IPAD_LIVE_DIR"] ?? NSTemporaryDirectory())
    static let s3 = env["OPENNEXUS_LIVE_S3"] ?? "http://127.0.0.1:19000"

    static func texts(_ m: DocumentModel) -> Set<String> {
        Set(m.canvases["c1"]?.nodes.values.map(\.text) ?? [])
    }

    static func renamed(_ m: DocumentModel, _ from: String, _ to: String) throws -> DocumentModel {
        var m = m
        var e = CanvasEditor(m.canvases["c1"]!)
        let id = try #require(e.canvas.nodes.first { $0.value.text == from }?.key)
        e.setText(id, to)
        m.canvases["c1"] = e.canvas
        return m
    }

    struct S3Config: Codable {
        var id: String
        var prefix: String
        var recoveryKey: String
    }

    static func syncCenter(_ cfg: S3Config?) throws -> (SyncCenter, SyncLibrary) {
        let prefs = Preferences.isolated()
        prefs.set("network.enabled", true)
        prefs.set("network.sync", true)
        let center = SyncCenter(
            directory: dir.appending(path: "s3-mac-state"), secrets: MemorySecrets(),
            transport: ShareLive.RealNetwork(), prefs: prefs, networkLog: NetworkLog(file: nil))
        center.device = "Mac"
        var bucket = ShareDestination(id: "minio", kind: .s3, name: "MinIO")
        bucket.endpoint = s3
        bucket.bucket = "sync"
        bucket.prefix = cfg?.prefix ?? "ipad-\(UUID().uuidString.prefix(8))/"
        bucket.accessKey = "onxtest"
        let lib = SyncLibrary(
            id: cfg?.id ?? UUID().uuidString, name: "Live",
            folder: dir.appending(path: "s3-mac").path(percentEncoded: false), bucket: bucket)
        try center.save(lib, secret: "onxtest-secret-key", recoveryKey: cfg?.recoveryKey)
        return (center, lib)
    }

    /// Synced with nothing in the log flagged: a document's error leaves the status synced.
    static func synced(_ center: SyncCenter, _ lib: SyncLibrary) -> Bool {
        guard case .synced = center.status[lib.id] else { return false }
        return !center.log.contains(where: \.problem)
    }

    /// Step 1: the shared folder's map and the Mac's save of it; the S3 library pushed.
    @Test func macPrepares() async throws {
        let base = launchPlanDocument()
        try FileManager.default.createDirectory(
            at: Self.dir.appending(path: "folder"), withIntermediateDirectories: true)
        try NexusPackage.write(base, to: Self.dir.appending(path: "folder/Plan.nexus"))
        try NexusPackage.write(base, to: Self.dir.appending(path: "folder-base.nexus"))
        try NexusPackage.write(
            Self.renamed(base, "Pricing", "Pricing (Mac)"), to: Self.dir.appending(path: "folder-mac.nexus"))

        let (center, lib) = try Self.syncCenter(nil)
        try await DiskFolder(lib.folderURL).write("Plan.nexus", NexusPackage.files(for: base))
        await center.syncNow(lib.id)
        #expect(Self.synced(center, lib), "\(String(describing: center.status[lib.id])) \(center.log.map(\.text))")
        let cfg = S3Config(id: lib.id, prefix: lib.bucket.prefix, recoveryKey: try #require(center.recoveryKey(lib.id)))
        try JSONEncoder().encode(cfg).write(to: Self.dir.appending(path: "s3.json"))
    }

    /// Step 3: the iPad's save of the folder's map merges into the Mac's own unsaved edit;
    /// the Mac's offline edit and the iPad's pushed one merge in the S3 library.
    @Test func macMergesTheIPad() async throws {
        let base = try NexusPackage.read(from: Self.dir.appending(path: "folder-base.nexus"))
        let iPad = try NexusPackage.read(from: Self.dir.appending(path: "folder/Plan.nexus"))
        #expect(Self.texts(iPad).isSuperset(of: ["iPad idea", "Pricing (Mac)"]), "\(Self.texts(iPad))")
        // Another Mac had the map open with an edit of its own: the iPad's file merges in.
        let store = DocumentStore(model: try Self.renamed(base, "Channels", "Channels (Mac)"))
        let conflicts = store.mergeExternal(iPad, base: base, focus: "c1")
        #expect(conflicts.isEmpty)
        #expect(Self.texts(store.model).isSuperset(of: ["iPad idea", "Pricing (Mac)", "Channels (Mac)"]))

        let cfg = try JSONDecoder().decode(S3Config.self, from: Data(contentsOf: Self.dir.appending(path: "s3.json")))
        let (center, lib) = try Self.syncCenter(cfg)
        let folder = DiskFolder(lib.folderURL)
        let mine = try NexusPackage.read(files: try #require(try await folder.read("Plan.nexus")))
        try await folder.write(
            "Plan.nexus", NexusPackage.files(for: try Self.renamed(mine, "Timeline", "Timeline (Mac)")))
        let before = center.log.count
        await center.syncNow(lib.id)
        #expect(Self.synced(center, lib), "\(String(describing: center.status[lib.id])) \(center.log.map(\.text))")
        // The log is newest first.
        let added = center.log.prefix(center.log.count - before).map(\.text)
        #expect(added == ["Merged Plan.nexus"], "\(center.log.map(\.text))")
        let merged = try NexusPackage.read(files: try #require(try await folder.read("Plan.nexus")))
        #expect(Self.texts(merged).isSuperset(of: ["iPad risk", "Timeline (Mac)"]), "\(Self.texts(merged))")
    }

    /// Runs beside the iPad's `iPadJoinsAMacsSession`: hosts a session on the relay in
    /// Docker, waits for the iPad's topic, renames one of its own, and compares copies.
    @Test func macHostsASession() async throws {
        var d = ShareDestination(id: "server", kind: .server, name: "Docker")
        d.server = Self.env["OPENNEXUS_LIVE_SERVER"] ?? "http://127.0.0.1:18787"
        let mac = CollabMac(
            "Mac", transport: ShareLive.RealNetwork(), connector: LiveConnector(wire: Wire()), server: d,
            token: "test-upload-token-0123456789")
        mac.open(launchPlanDocument())
        _ = try await mac.start()
        let link = try #require(mac.controller.inviteLink(canEdit: true))
        let tmp = Self.dir.appending(path: "invite.tmp")
        try link.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: tmp, to: Self.dir.appending(path: "invite"))

        try await waitUntil("the iPad's topic", seconds: 300) { Self.texts(mac.store.model).contains("iPad live") }
        let pricing = try #require(mac.store.model.canvases["c1"]?.nodes.first { $0.value.text == "Pricing" }?.key)
        mac.rename(pricing, "Pricing (Mac live)")
        let theirs = Self.dir.appending(path: "ipad-canonical")
        try await waitUntil("the iPad's copy", seconds: 60) {
            FileManager.default.fileExists(atPath: theirs.path(percentEncoded: false))
        }
        let mine = sharedCanonical(mac.store.model)
        try mine.write(to: Self.dir.appending(path: "mac-canonical"), atomically: true, encoding: .utf8)
        #expect(mine == (try String(contentsOf: theirs, encoding: .utf8)), "the iPad and the Mac converge")
        await mac.controller.endCollab()
    }
}
