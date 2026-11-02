import Foundation
import Testing

@testable import NexusFormat
@testable import NexusNet

/// A bucket as S3 answers (M45): ETags, `If-Match` and `If-None-Match`, 304, 404, and
/// listings two keys a page.
final class FakeS3: @unchecked Sendable {
    let lock = NSLock()
    var objects: [String: (Data, String)] = [:]
    var n = 0
    var honours = true

    func answer(_ s: Stub.Seen) -> Stub.Answer {
        lock.withLock {
            let path = s.url.path(percentEncoded: false)
            guard path.hasPrefix("/maps") else { return (404, [:], Data()) }
            let key = String(path.dropFirst("/maps/".count))
            let query = URLComponents(url: s.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch s.method {
            case "GET" where key.isEmpty:
                let prefix = query.first { $0.name == "prefix" }?.value ?? ""
                let all = objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
                let start = Int(query.first { $0.name == "continuation-token" }?.value ?? "0") ?? 0
                let page = all.dropFirst(start).prefix(2)
                let more = start + 2 < all.count
                let xml =
                    "<ListBucketResult><IsTruncated>\(more)</IsTruncated>"
                    + page.map { "<Contents><Key>\($0.replacingOccurrences(of: "&", with: "&amp;"))</Key></Contents>" }
                    .joined() + (more ? "<NextContinuationToken>\(start + 2)</NextContinuationToken>" : "")
                    + "</ListBucketResult>"
                return (200, [:], Data(xml.utf8))
            case "GET":
                guard let (d, e) = objects[key] else { return (404, [:], Data("<Error/>".utf8)) }
                if s.header("If-None-Match") == e { return (304, ["ETag": e], Data()) }
                return (200, ["ETag": e], d)
            case "PUT":
                if honours {
                    if let m = s.header("If-Match"), objects[key]?.1 != m { return (412, [:], Data()) }
                    if s.header("If-None-Match") == "*", objects[key] != nil { return (412, [:], Data()) }
                }
                n += 1
                objects[key] = (s.body, "\"e\(n)\"")
                return (200, ["ETag": "\"e\(n)\""], Data())
            case "DELETE":
                objects[key] = nil
                return (204, [:], Data())
            default:
                return (405, [:], Data())
            }
        }
    }
}

extension NexusNetTests {
    static func syncJob(_ action: NetJob.Action, _ object: String?, ifMatch: String? = nil, ifNoneMatch: String? = nil)
        -> NetJob
    {
        NetJob(
            action: action, purpose: "Sync", destination: bucket, secret: "s3cret", allowedHosts: bucket.hosts,
            object: object, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
    }

    @Test func bucketOperationsForSync() async throws {
        let s3 = FakeS3()
        Stub.reset { s3.answer($0) }
        let svc = Self.service
        // A missing object is an answer, not an error.
        var (r, body) = await svc.exchange(Self.syncJob(.get, "library.json"), body: Data())
        #expect(r.ok && r.status == 404 && body.isEmpty)
        // Create only.
        r = await svc.exchange(Self.syncJob(.put, "library.json", ifNoneMatch: "*"), body: Data("v1".utf8)).reply
        let e1 = try #require(r.etag)
        #expect(r.ok && r.status == 200)
        #expect(Stub.requests.last?.url.path() == "/maps/opennexus/library.json")
        #expect(Stub.requests.last?.header("If-None-Match") == "*")
        r = await svc.exchange(Self.syncJob(.put, "library.json", ifNoneMatch: "*"), body: Data("v2".utf8)).reply
        #expect(r.ok && r.status == 412)
        // Replace only this version.
        r = await svc.exchange(Self.syncJob(.put, "library.json", ifMatch: "\"stale\""), body: Data("v2".utf8)).reply
        #expect(r.ok && r.status == 412)
        r = await svc.exchange(Self.syncJob(.put, "library.json", ifMatch: e1), body: Data("v2".utf8)).reply
        let e2 = try #require(r.etag)
        #expect(r.status == 200 && e2 != e1)
        (r, body) = await svc.exchange(Self.syncJob(.get, "library.json"), body: Data())
        #expect(r.status == 200 && r.etag == e2 && body == Data("v2".utf8))
        (r, body) = await svc.exchange(Self.syncJob(.get, "library.json", ifNoneMatch: e2), body: Data())
        #expect(r.status == 304 && body.isEmpty)

        // Listing pages through, and keys come back without the prefix.
        for k in ["docs/a/head.json", "docs/a/blobs/1", "docs/a/blobs/2", "docs/b/head.json", "docs/a&b/x"] {
            _ = await svc.exchange(Self.syncJob(.put, k), body: Data("x".utf8))
        }
        r = await svc.exchange(Self.syncJob(.list, "docs/a/"), body: Data()).reply
        #expect(r.ok && r.keys == ["docs/a/blobs/1", "docs/a/blobs/2", "docs/a/head.json"])
        #expect(Stub.requests.last?.url.query()?.contains("continuation-token=2") == true)
        r = await svc.exchange(Self.syncJob(.list, "docs/a&b/"), body: Data()).reply
        #expect(r.keys == ["docs/a&b/x"])

        // Delete takes the full key, as share links do.
        r = await svc.exchange(Self.syncJob(.delete, Self.bucket.objectKey("docs/b/head.json")), body: Data()).reply
        #expect(r.ok && s3.objects["opennexus/docs/b/head.json"] == nil)

        // Every request is in the log, with its purpose.
        #expect(r.log.allSatisfy { $0.purpose == "Sync" && $0.host == "s3.eu-west-1.amazonaws.com" })

        // Errors are errors: a refused request says why.
        Stub.reset { _ in (403, [:], Data("<Error><Message>Access Denied</Message></Error>".utf8)) }
        r = await svc.exchange(Self.syncJob(.get, "library.json"), body: Data()).reply
        #expect(!r.ok && r.error?.contains("Access Denied") == true)
    }

    @Test func syncTestFindsWhetherConditionsHold() async throws {
        let s3 = FakeS3()
        Stub.reset { s3.answer($0) }
        var r = await Self.service.perform(Self.syncJob(.syncTest, nil), body: Data())
        #expect(r.ok && r.conditionalWrites == true && s3.objects.isEmpty)
        s3.honours = false
        r = await Self.service.perform(Self.syncJob(.syncTest, nil), body: Data())
        #expect(r.ok && r.conditionalWrites == false && r.detail?.contains("reading it back") == true)
        // Only buckets sync.
        r = await Self.service.perform(
            NetJob(
                action: .get, purpose: "Sync", destination: Self.gist, secret: "t", allowedHosts: Self.gist.hosts,
                object: "x"), body: Data())
        #expect(!r.ok)
    }

    /// Sync's hosts are the libraries' (an allow-list like sharing's).
    @Test func syncJobsKeepToTheirHosts() async throws {
        Stub.reset { _ in (200, [:], Data()) }
        let r = await Self.service.perform(
            NetJob(
                action: .get, purpose: "Sync", destination: Self.bucket, secret: "s", allowedHosts: ["other.example"],
                object: "library.json"), body: Data())
        #expect(!r.ok && Stub.requests.isEmpty)
    }
}
