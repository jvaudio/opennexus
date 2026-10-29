import CryptoKit
import Foundation
import NexusCore
import NexusFormat
import NexusNet
import Testing

@testable import NexusSync

/// M45 against MinIO in Docker, through the real network service (`scripts/test-sync.sh`
/// starts it and sets `OPENNEXUS_LIVE_SYNC=1`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENNEXUS_LIVE_SYNC"] == "1"))
struct SyncLiveTests {
    static let env = ProcessInfo.processInfo.environment

    /// A fresh prefix in the test bucket, and its log.
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var entries: [NetLogEntry] = []
        func add(_ e: [NetLogEntry]) { lock.withLock { entries += e } }
        func reset() { lock.withLock { entries = [] } }
        var all: [NetLogEntry] { lock.withLock { entries } }
    }

    static func transport(_ log: Log, prefix: String = "live-\(UUID().uuidString.prefix(8))/") -> NetSyncTransport {
        var d = ShareDestination(id: "minio", kind: .s3, name: "MinIO")
        d.endpoint = env["OPENNEXUS_LIVE_S3"] ?? "http://127.0.0.1:19000"
        d.bucket = "sync"
        d.prefix = prefix
        d.accessKey = "onxtest"
        return NetSyncTransport(
            destination: d, secret: "onxtest-secret-key", allowedHosts: d.hosts,
            send: { await NetService().exchange($0, body: $1) }, onLog: log.add)
    }

    @Test func minioHonoursConditionalWrites() async throws {
        let r = await Self.transport(Log()).test()
        #expect(r.ok && r.conditionalWrites == true, "\(r.error ?? r.detail ?? "")")
    }

    /// A1 against MinIO: 50 seeds, each in its own prefix.
    @Test func randomEditsAndSyncOrderConvergeOnMinIO() async throws {
        let crypto = LibraryCrypto(key: Sealed.newKey())
        for seed in 0..<50 {
            let o = try await Convergence.run(seed: UInt64(seed), bucket: Self.transport(Log()), crypto: crypto)
            #expect(
                o.identical && o.unexplained.isEmpty && o.canvasClashes == 0,
                "seed \(seed): \(o)")
        }
    }

    /// A4 on MinIO: the request log shows one blob for a one-canvas edit; a 1,000-topic
    /// document pushes in under 2 s.
    @Test func uploadsAndSpeedOnMinIO() async throws {
        let log = Log()
        let bucket = Self.transport(log)
        let crypto = LibraryCrypto(key: Sealed.newKey())
        var doc = Fixtures.plan(id: "big")
        var e = CanvasEditor(doc.canvases["c1"]!)
        var parents = [e.canvas.root]
        for i in 0..<1_000 {
            let p = parents[i % parents.count]
            let id = try e.addChild(of: p, text: "Topic \(i)")
            if i % 7 == 0 { parents.append(id) }
        }
        doc.canvases["c1"] = e.canvas
        doc.add([
            Canvas(id: "x", title: "Roadmap", rootText: "Roadmap"), Canvas(id: "y", title: "Team", rootText: "Team"),
        ])
        doc.assets["logo.png"] = Data(repeating: 7, count: 200_000)
        #expect(doc.canvases["c1"]!.nodes.count > 1_000)

        let a = Replica("A", bucket, crypto: crypto)
        try await a.folder.write("Big.nexus", NexusPackage.files(for: doc))
        let clock = ContinuousClock()
        let took = try await clock.measure { _ = try await a.sync() }
        #expect(took < .seconds(2), "the first push took \(took)")
        print("1,000-topic document pushed in \(took)")

        log.reset()
        try await a.editCanvas("Big.nexus", "c2") { _ = try $0.addChild(of: $0.canvas.root, text: "Q3") }
        try await a.sync()
        let puts = log.all.filter { $0.method == "PUT" }
        #expect(puts.count == 3, "\(log.all.map { "\($0.method) \($0.sent)" })")
        #expect(puts.allSatisfy { $0.sent < 4_000 }, "only the canvas and the head records")

        // Another Mac gets it, byte for byte.
        let b = Replica("B", bucket, crypto: crypto)
        try await b.sync()
        let (pa, pb) = (await a.folder.packages, await b.folder.packages)
        #expect(pa == pb)
    }
}
