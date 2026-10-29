import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import OpenNexusServer

/// A clock the tests move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_793_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

struct Server {
    let config: ServerConfig
    let storage: any ShareStorage
    let clock = TestClock()

    init(_ edit: (inout ServerConfig) -> Void = { _ in }, storage: any ShareStorage = MemoryStorage()) {
        var c = ServerConfig(uploadToken: Self.token)
        edit(&c)
        config = c
        self.storage = storage
    }

    static let token = "upload-token-0123456789"

    /// A sealed-looking body: the magic, then bytes the server can't read.
    static func sealed(_ n: Int = 200, fill: UInt8 = 7) -> ByteBuffer {
        ByteBuffer(bytes: Array("ONX1".utf8) + [UInt8](repeating: fill, count: n))
    }

    func test(_ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        let clock = clock
        let api = ShareAPI(config: config, storage: storage, now: { clock.now })
        try await Application(router: api.router()).test(.router, body)
    }
}

extension TestClientProtocol {
    func create(
        _ body: ByteBuffer = Server.sealed(), token: String = Server.token, headers: HTTPFields = [:]
    ) async throws -> (TestResponse, id: String, secret: String) {
        var h = headers
        h[.authorization] = "Bearer \(token)"
        let r = try await execute(uri: "/v1/shares", method: .post, headers: h, body: body)
        guard r.status == .created,
            let o = try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: String]
        else { return (r, "", "") }
        return (r, o["id"] ?? "", o["secret"] ?? "")
    }
}

@Suite struct ServerTests {
    @Test func healthSaysWhatItIs() async throws {
        try await Server().test { client in
            let r = try await client.execute(uri: "/v1/health", method: .get)
            #expect(r.status == .ok)
            #expect(String(buffer: r.body) == #"{"service":"opennexus-server","version":1}"#)
        }
    }

    @Test func creatingNeedsTheUploadToken() async throws {
        try await Server().test { client in
            #expect(try await client.create(token: "wrong").0.status == .unauthorized)
            let none = try await client.execute(uri: "/v1/shares", method: .post, body: Server.sealed())
            #expect(none.status == .unauthorized)
            let (r, id, secret) = try await client.create()
            #expect(r.status == .created)
            #expect(id.count == 22 && secret.count == 43)
        }
    }

    @Test func onlySealedSharesWithinTheLimit() async throws {
        try await Server({ $0.maxBytes = 1024 }).test { client in
            let html = try await client.create(
                ByteBuffer(string: "<html>not sealed</html>" + String(repeating: " ", count: 64)))
            #expect(html.0.status == .unsupportedMediaType)
            let short = try await client.create(Server.sealed(10))
            #expect(short.0.status == .unsupportedMediaType, "too short to be one")
            let large = try await client.create(Server.sealed(2000))
            #expect(large.0.status == .contentTooLarge)
            let fits = try await client.create(Server.sealed(1000))
            #expect(fits.0.status == .created)
        }
    }

    /// Anyone may read (any origin, no credentials); the response is never cached.
    @Test func readingNeedsNoCredentials() async throws {
        try await Server().test { client in
            let (_, id, _) = try await client.create(Server.sealed(64, fill: 9))
            let r = try await client.execute(
                uri: "/v1/shares/\(id)", method: .get, headers: [.origin: "https://viewer.example"])
            #expect(r.status == .ok)
            #expect(Data(buffer: r.body) == Data(buffer: Server.sealed(64, fill: 9)))
            #expect(r.headers[.accessControlAllowOrigin] == "*")
            #expect(r.headers[.cacheControl] == "no-store")
            #expect(r.headers[.contentType] == "application/octet-stream")
            #expect(r.headers[.xContentTypeOptions] == "nosniff")
            #expect(r.headers[.accessControlAllowCredentials] == nil)
            // Errors are readable too, so the viewer can tell "turned off" from "unreachable".
            let missing = try await client.execute(uri: "/v1/shares/AAAAAAAAAAAAAAAAAAAAAA", method: .get)
            #expect(missing.status == .notFound && missing.headers[.accessControlAllowOrigin] == "*")
            #expect(try await client.execute(uri: "/v1/shares/../../etc", method: .get).status == .notFound)
            let pre = try await client.execute(uri: "/v1/shares/\(id)", method: .options)
            #expect(pre.status == .noContent && pre.headers[.accessControlAllowMethods] == "GET")
        }
    }

    @Test func changingNeedsTheWriteSecret() async throws {
        try await Server().test { client in
            let (_, id, secret) = try await client.create()
            let (_, other, _) = try await client.create()
            for wrong in ["", "Bearer nope", "Bearer \(Server.token)"] {
                let h: HTTPFields = wrong.isEmpty ? [:] : [.authorization: wrong]
                #expect(
                    try await client.execute(
                        uri: "/v1/shares/\(id)", method: .put, headers: h, body: Server.sealed(50, fill: 1)
                    ).status == .forbidden)
                #expect(
                    try await client.execute(uri: "/v1/shares/\(id)", method: .delete, headers: h).status == .forbidden)
            }
            // One share's secret doesn't open another.
            #expect(
                try await client.execute(
                    uri: "/v1/shares/\(other)", method: .delete, headers: [.authorization: "Bearer \(secret)"]
                ).status == .forbidden)
            let put = try await client.execute(
                uri: "/v1/shares/\(id)", method: .put, headers: [.authorization: "Bearer \(secret)"],
                body: Server.sealed(50, fill: 1))
            #expect(put.status == .noContent)
            #expect(
                Data(buffer: try await client.execute(uri: "/v1/shares/\(id)", method: .get).body)
                    == Data(buffer: Server.sealed(50, fill: 1)))
            #expect(
                try await client.execute(
                    uri: "/v1/shares/\(id)", method: .delete, headers: [.authorization: "Bearer \(secret)"]
                ).status == .noContent)
            #expect(try await client.execute(uri: "/v1/shares/\(id)", method: .get).status == .notFound)
            #expect(
                try await client.execute(
                    uri: "/v1/shares/\(id)", method: .delete, headers: [.authorization: "Bearer \(secret)"]
                ).status == .notFound)
            #expect(try await client.execute(uri: "/v1/shares/\(other)", method: .get).status == .ok)
        }
    }

    @Test func expiredSharesAreGone() async throws {
        let s = Server()
        try await s.test { client in
            let soon = Date(timeIntervalSince1970: 1_793_000_000 + 3600)
            let expires: HTTPFields = [ShareAPI.expiresHeader: ISO8601DateFormatter().string(from: soon)]
            let (r, id, _) = try await client.create(headers: expires)
            #expect(r.status == .created)
            let past: HTTPFields = [ShareAPI.expiresHeader: "2020-01-01T00:00:00Z"]
            #expect(try await client.create(headers: past).0.status == .badRequest)
            #expect(try await client.create(headers: [ShareAPI.expiresHeader: "tomorrow"]).0.status == .badRequest)
            #expect(try await client.execute(uri: "/v1/shares/\(id)", method: .get).status == .ok)
            s.clock.advance(3601)
            let gone = try await client.execute(uri: "/v1/shares/\(id)", method: .get)
            #expect(gone.status == .gone && gone.headers[.accessControlAllowOrigin] == "*")
            #expect(try await s.storage.meta(id) == nil, "deleted when found expired")
        }
    }

    @Test func aServerCanCapHowLongSharesLive() async throws {
        let s = Server({ $0.maxDays = 7 })
        try await s.test { client in
            let (_, id, _) = try await client.create()
            let meta = try #require(try await s.storage.meta(id))
            #expect(meta.expires == s.clock.now.addingTimeInterval(7 * 86_400), "no expiry asked: the cap")
            let late = s.clock.now.addingTimeInterval(8 * 86_400)
            #expect(
                try await client.create(headers: [ShareAPI.expiresHeader: ISO8601DateFormatter().string(from: late)]).0
                    .status == .badRequest)
        }
    }

    @Test func writesAndReadsAreRateLimited() async throws {
        let s = Server({
            $0.writesPerMinute = 2
            $0.readsPerMinute = 3
            $0.trustProxy = true
        })
        try await s.test { client in
            let a: HTTPFields = [ShareAPI.forwardedFor: "203.0.113.5, 10.0.0.1"]
            let (_, id, _) = try await client.create(headers: a)
            #expect(try await client.create(headers: a).0.status == .created)
            let third = try await client.create(headers: a).0
            #expect(third.status == .tooManyRequests)
            #expect(Int(third.headers[.retryAfter] ?? "") ?? 0 > 0)
            // Another address has its own allowance, and reads are counted apart from writes.
            #expect(try await client.create(headers: [ShareAPI.forwardedFor: "198.51.100.7"]).0.status == .created)
            for _ in 0..<3 {
                #expect(try await client.execute(uri: "/v1/shares/\(id)", method: .get, headers: a).status == .ok)
            }
            #expect(
                try await client.execute(uri: "/v1/shares/\(id)", method: .get, headers: a).status == .tooManyRequests)
            s.clock.advance(61)
            #expect(try await client.create(headers: a).0.status == .created)
        }
    }

    @Test func diskStorageKeepsNoSecrets() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onx-server-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try DiskStorage(directory: dir.path)
        let s = Server(storage: disk)
        try await s.test { client in
            let (_, id, secret) = try await client.create(headers: [ShareAPI.expiresHeader: "2026-10-26T08:33:20Z"])
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(files == ["\(id).json", "\(id).onx"])
            let meta = try String(contentsOf: dir.appendingPathComponent("\(id).json"), encoding: .utf8)
            #expect(!meta.contains(secret) && meta.contains(ShareAPI.digest(secret)))
            #expect(try await disk.ids() == [id])
            #expect(await Sweeper.sweep(disk, now: s.clock.now) == 0)
            #expect(await Sweeper.sweep(disk, now: s.clock.now.addingTimeInterval(7200)) == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        }
    }

    @Test func settingsComeFromTheEnvironment() throws {
        #expect(throws: ConfigError.self) { try ServerConfig.fromEnvironment([:]) }
        #expect(throws: ConfigError.self) { try ServerConfig.fromEnvironment(["OPENNEXUS_UPLOAD_TOKEN": "short"]) }
        let token = ["OPENNEXUS_UPLOAD_TOKEN": Server.token]
        let c = try ServerConfig.fromEnvironment(
            token.merging(["OPENNEXUS_PORT": "9999", "OPENNEXUS_MAX_DAYS": "30", "OPENNEXUS_TRUST_PROXY": "1"]) { $1 })
        #expect(c.port == 9999 && c.maxDays == 30 && c.trustProxy)
        guard case .disk("/data") = c.storage else { Issue.record("disk by default"); return }
        #expect(throws: ConfigError.self) {
            try ServerConfig.fromEnvironment(token.merging(["OPENNEXUS_STORAGE": "s3"]) { $1 })
        }
        let s3 = try ServerConfig.fromEnvironment(
            token.merging([
                "OPENNEXUS_STORAGE": "s3", "OPENNEXUS_S3_ENDPOINT": "http://minio:9000",
                "OPENNEXUS_S3_BUCKET": "shares",
                "OPENNEXUS_S3_ACCESS_KEY": "k", "OPENNEXUS_S3_SECRET_KEY": "s",
            ]) { $1 })
        guard case .s3(let b) = s3.storage else { Issue.record("s3"); return }
        #expect(b.bucket == "shares" && b.pathStyle && b.prefix == "shares/")
        #expect(throws: ConfigError.self) {
            try ServerConfig.fromEnvironment(token.merging(["OPENNEXUS_PORT": "0"]) { $1 })
        }
    }
}

@Suite struct S3StorageTests {
    /// AWS's Signature Version 4 test suite, "get-vanilla" (the app's signer passes the same).
    @Test func signsLikeAWS() {
        let h = SigV4(
            accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", region: "us-east-1",
            service: "service"
        )
        .sign(
            method: "GET", url: URL(string: "https://example.amazonaws.com/")!, headers: [:], body: Data(),
            date: Date(timeIntervalSince1970: 1_440_938_160), contentHash: false)
        #expect(
            h["Authorization"]?.hasSuffix("Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
                == true)
        let s3 = SigV4(
            accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1"
        )
        .sign(
            method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
            headers: ["Range": "bytes=0-9"],
            body: Data(), date: Date(timeIntervalSince1970: 1_369_353_600))
        #expect(
            s3["Authorization"]?.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
                == true)
    }

    @Test func addressesAndListings() {
        var c = S3Config()
        c.endpoint = "http://minio:9000/"
        c.bucket = "maps"
        let path = S3Storage(c)
        #expect(path.url("shares/a b.onx").absoluteString == "http://minio:9000/maps/shares/a%20b.onx")
        c.pathStyle = false
        c.endpoint = "https://s3.example.com"
        #expect(
            S3Storage(c).url("x.json", query: "list-type=2").absoluteString
                == "https://maps.s3.example.com/x.json?list-type=2")
        let xml =
            "<ListBucketResult><Contents><Key>shares/a.json</Key></Contents><Contents><Key>shares/a.onx</Key></Contents><NextContinuationToken>t&amp;1</NextContinuationToken></ListBucketResult>"
        #expect(S3Storage.values(xml, "Key") == ["shares/a.json", "shares/a.onx"])
        #expect(S3Storage.values(xml, "NextContinuationToken") == ["t&1"])
    }

    /// Against a real bucket when one is set up (scripts/test-share.sh starts MinIO).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENNEXUS_TEST_S3_ENDPOINT"] != nil))
    func storesInABucket() async throws {
        let env = ProcessInfo.processInfo.environment
        var c = S3Config()
        c.endpoint = env["OPENNEXUS_TEST_S3_ENDPOINT"]!
        c.bucket = env["OPENNEXUS_TEST_S3_BUCKET"] ?? "shares"
        c.accessKey = env["OPENNEXUS_TEST_S3_ACCESS_KEY"] ?? "minioadmin"
        c.secretKey = env["OPENNEXUS_TEST_S3_SECRET_KEY"] ?? "minioadmin"
        c.prefix = "test-\(UUID().uuidString)/"
        let s = S3Storage(c)
        let meta = ShareMeta(secret: "ab", created: Date(timeIntervalSince1970: 1_793_000_000), expires: nil, size: 3)
        try await s.put("AAAAAAAAAAAAAAAAAAAAAA", Data([1, 2, 3]), meta)
        #expect(try await s.get("AAAAAAAAAAAAAAAAAAAAAA") == Data([1, 2, 3]))
        #expect(try await s.meta("AAAAAAAAAAAAAAAAAAAAAA") == meta)
        #expect(try await s.ids() == ["AAAAAAAAAAAAAAAAAAAAAA"])
        try await s.delete("AAAAAAAAAAAAAAAAAAAAAA")
        #expect(try await s.get("AAAAAAAAAAAAAAAAAAAAAA") == nil)
        #expect(try await s.ids().isEmpty)
    }
}
