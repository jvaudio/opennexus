import CryptoKit
import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusNet

/// M44: the network service. Its requests go to `Stub`; MinIO and the server in Docker are
/// `ShareLiveTests` (NexusCanvasTests).
@Suite(.serialized) struct NexusNetTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")))
    }

    static let bucket: ShareDestination = {
        var d = ShareDestination(id: "b", kind: .s3, name: "Bucket")
        d.endpoint = "https://s3.eu-west-1.amazonaws.com"
        d.region = "eu-west-1"
        d.bucket = "maps"
        d.accessKey = "AKIDEXAMPLE"
        d.publicBase = "https://maps.example.org/"
        return d
    }()

    static let server: ShareDestination = {
        var d = ShareDestination(id: "s", kind: .server, name: "Home")
        d.server = "https://share.example.net/"
        return d
    }()

    static let gist = ShareDestination(id: "g", kind: .gist, name: "GitHub")

    static func job(_ action: NetJob.Action, _ d: ShareDestination, allowed: [String]? = nil, object: String? = nil)
        -> NetJob
    {
        NetJob(
            action: action, purpose: "Share link", destination: d, secret: "s3cret", allowedHosts: allowed ?? d.hosts,
            object: object, writeSecret: "w", origin: "https://jvaudio.github.io")
    }

    static let service = NetService(protocolClasses: [Stub.self])

    // MARK: SigV4

    /// AWS's Signature Version 4 test suite, "get-vanilla".
    @Test func sigV4GetVanilla() throws {
        var r = HTTPRequest("GET", URL(string: "https://example.amazonaws.com/")!)
        SigV4(
            accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", region: "us-east-1",
            service: "service"
        )
        .sign(&r, date: Date(timeIntervalSince1970: 1_440_938_160), contentHash: false)
        #expect(r.headers["x-amz-date"] == "20150830T123600Z")
        #expect(
            r.headers["Authorization"]
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    /// The S3 documentation's GET Object example (with a Range header).
    @Test func sigV4S3GetObject() throws {
        var r = HTTPRequest(
            "GET", URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, headers: ["Range": "bytes=0-9"])
        SigV4(
            accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1"
        )
        .sign(&r, date: Date(timeIntervalSince1970: 1_369_353_600))
        #expect(r.headers["x-amz-content-sha256"] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            r.headers["Authorization"]
                == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    @Test func sigV4EncodesPathsAndQueries() {
        #expect(SigV4.canonicalPath(URL(string: "https://h/b/a%20b/c+d~e")!) == "/b/a%20b/c%2Bd~e")
        #expect(SigV4.canonicalPath(URL(string: "https://h")!) == "/")
        #expect(SigV4.canonicalQuery(URL(string: "https://h/b?cors=")!) == "cors=")
        #expect(SigV4.canonicalQuery(URL(string: "https://h/b?z=1&a=x%2Fy")!) == "a=x%2Fy&z=1")
        #expect(SigV4.host(URL(string: "http://localhost:9000/x")!) == "localhost:9000")
        #expect(SigV4.host(URL(string: "https://h:443/x")!) == "h")
    }

    // MARK: The allow-list and the log

    /// A job whose destination isn't on the list sends nothing at all.
    @Test func refusesADestinationThatIsntConfigured() async throws {
        Stub.reset { _ in (200, [:], Data()) }
        let reply = await Self.service.perform(
            Self.job(.create, Self.bucket, allowed: ["maps.example.org"]), body: Data("x".utf8))
        #expect(!reply.ok && reply.error?.contains("s3.eu-west-1.amazonaws.com") == true)
        #expect(Stub.requests.isEmpty)
        let none = await Self.service.perform(Self.job(.create, Self.server, allowed: []), body: Data())
        #expect(!none.ok && Stub.requests.isEmpty)
    }

    /// Plain HTTP only to this Mac: a destination elsewhere needs https, and the service
    /// won't follow a redirect down to http.
    @Test func plainHTTPOnlyToThisMac() async throws {
        var d = Self.server
        for (address, ok) in [
            ("https://share.example.net", true), ("http://127.0.0.1:18787", true), ("http://localhost:8787", true),
            ("http://[::1]:8787", true), ("http://share.example.net", false), ("http://zima.local:8787", false),
            ("ftp://share.example.net", false),
        ] {
            d.server = address
            #expect(d.isComplete == ok && d.hasInsecureAddress == (address.hasPrefix("http:") && !ok), "\(address)")
        }
        Stub.reset { seen in
            seen.url.scheme == "https"
                ? (301, ["Location": "http://share.example.net/v1/shares"], Data()) : (201, [:], Data())
        }
        let reply = await Self.service.perform(Self.job(.create, Self.server), body: Data("sealed".utf8))
        #expect(!reply.ok && Stub.requests.count == 1)
        d.server = "http://share.example.net"
        Stub.reset { _ in (201, [:], Data()) }
        let plain = await Self.service.perform(Self.job(.create, d), body: Data("sealed".utf8))
        #expect(!plain.ok && Stub.requests.isEmpty)
    }

    /// A redirect to a host that isn't on the list is refused (and logged as refused);
    /// credentials never follow a redirect.
    @Test func refusesARedirectElsewhere() async throws {
        Stub.reset { seen in
            seen.url.host() == "share.example.net"
                ? (307, ["Location": "https://evil.example/v1/shares"], Data()) : (201, [:], Data("{}".utf8))
        }
        let reply = await Self.service.perform(Self.job(.create, Self.server), body: Data("sealed".utf8))
        #expect(!reply.ok && reply.error?.contains("evil.example") == true)
        #expect(Stub.requests.map(\.url.host) == ["share.example.net"])
        #expect(reply.log.map(\.host) == ["share.example.net", "evil.example"])
        #expect(reply.log[1].purpose == "Share link (refused)" && reply.log[1].status == 0 && reply.log[1].sent == 0)

        // Within the list, a redirect is followed, without the token if the host changes.
        Stub.reset { seen in
            seen.url.host() == "share.example.net"
                ? (308, ["Location": "https://maps.example.org/v1/shares"], Data())
                : (201, [:], Data(#"{"id":"AAAAAAAAAAAAAAAAAAAAAA","secret":"s"}"#.utf8))
        }
        let followed = await Self.service.perform(
            Self.job(.create, Self.server, allowed: ["share.example.net", "maps.example.org"]),
            body: Data("sealed".utf8))
        #expect(followed.ok)
        #expect(Stub.requests.map { $0.header("Authorization") } == ["Bearer s3cret", nil])
        #expect(Stub.requests.map(\.body) == [Data("sealed".utf8), Data("sealed".utf8)])
    }

    /// Every request is in the reply's log with its bytes; failed ones too.
    @Test func everyRequestIsLogged() async throws {
        Stub.reset { seen in
            seen.method == "GET"
                ? (200, ["Access-Control-Allow-Origin": "*"], Data("OpenNexus destination test".utf8))
                : (200, [:], Data())
        }
        let reply = await Self.service.perform(Self.job(.test, Self.bucket), body: Data())
        #expect(reply.ok, "\(reply.error ?? "")")
        #expect(reply.log.map(\.method) == ["PUT", "GET", "DELETE"])
        #expect(
            reply.log.map(\.host) == ["s3.eu-west-1.amazonaws.com", "maps.example.org", "s3.eu-west-1.amazonaws.com"])
        #expect(reply.log.map(\.sent) == [26, 0, 0] && reply.log.map(\.received) == [0, 26, 0])
        #expect(reply.log.allSatisfy { $0.purpose == "Share link" && $0.status == 200 })

        Stub.reset { _ in (403, [:], Data("<Error><Message>Access Denied</Message></Error>".utf8)) }
        let denied = await Self.service.perform(Self.job(.create, Self.bucket), body: Data("abc".utf8))
        #expect(!denied.ok && denied.error?.contains("Access Denied") == true)
        #expect(denied.log.count == 1 && denied.log[0].status == 403 && denied.log[0].sent == 3)
    }

    // MARK: Destinations

    @Test func s3StoresSignedObjects() async throws {
        Stub.reset { _ in (200, [:], Data()) }
        let body = Data("sealed bytes".utf8)
        let reply = await Self.service.perform(Self.job(.create, Self.bucket), body: body)
        #expect(reply.ok && reply.source == .url)
        let put = try #require(Stub.requests.first)
        let object = try #require(reply.object)
        #expect(object.hasPrefix("opennexus/") && object.hasSuffix(".onx") && object.count == 36)
        #expect(put.method == "PUT" && put.url.absoluteString == "https://s3.eu-west-1.amazonaws.com/maps/\(object)")
        #expect(reply.locator == "https://maps.example.org/\(object)")
        #expect(put.header("x-amz-content-sha256") == SigV4.hex(SHA256.hash(data: body)))
        #expect(put.header("Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/") == true)
        #expect(put.header("Authorization")?.contains("/eu-west-1/s3/aws4_request") == true)
        #expect(put.header("Cache-Control") == "no-cache" && put.body == body)

        Stub.reset { _ in (204, [:], Data()) }
        #expect(await Self.service.perform(Self.job(.update, Self.bucket, object: object), body: body).ok)
        #expect(await Self.service.perform(Self.job(.delete, Self.bucket, object: object), body: Data()).ok)
        #expect(Stub.requests.map(\.method) == ["PUT", "DELETE"])
        #expect(Stub.requests.allSatisfy { $0.url.path() == "/maps/\(object)" })
    }

    @Test func s3VirtualHostsAndCORS() async throws {
        var d = Self.bucket
        d.pathStyle = false
        d.publicBase = ""
        Stub.reset { _ in (200, [:], Data()) }
        let reply = await Self.service.perform(
            Self.job(.create, d, allowed: ["maps.s3.eu-west-1.amazonaws.com"] + d.hosts), body: Data("x".utf8))
        #expect(reply.ok, "\(reply.error ?? "")")
        #expect(Stub.requests.first?.url.host() == "maps.s3.eu-west-1.amazonaws.com")
        #expect(reply.locator?.hasPrefix("https://maps.s3.eu-west-1.amazonaws.com/opennexus/") == true)

        Stub.reset { _ in (200, [:], Data()) }
        #expect(await Self.service.perform(Self.job(.setUpCORS, Self.bucket), body: Data()).ok)
        let put = try #require(Stub.requests.first)
        #expect(put.url.absoluteString == "https://s3.eu-west-1.amazonaws.com/maps?cors=")
        let xml = String(decoding: put.body, as: UTF8.self)
        #expect(
            xml.contains("<AllowedOrigin>https://jvaudio.github.io</AllowedOrigin><AllowedMethod>GET</AllowedMethod>"))
        #expect(put.header("Content-MD5") == Data(Insecure.MD5.hash(data: put.body)).base64EncodedString())

        // A readable bucket without CORS: the test says what to do.
        Stub.reset { seen in
            seen.method == "GET" ? (200, [:], Data("OpenNexus destination test".utf8)) : (200, [:], Data())
        }
        let test = await Self.service.perform(Self.job(.test, Self.bucket), body: Data())
        #expect(test.ok && test.detail?.contains("Set Up CORS") == true)
        #expect(Stub.requests[1].header("Origin") == "https://jvaudio.github.io")
    }

    /// GitHub's API, answered with fixtures in its documented shape.
    @Test func gists() async throws {
        let created = try Self.fixture("gist-created")
        Stub.reset { seen in
            switch (seen.method, seen.url.path()) {
            case ("POST", "/gists"): (201, ["Content-Type": "application/json"], created)
            case ("PATCH", "/gists/aa5a315d61ae9438b18d"): (200, [:], created)
            case ("DELETE", "/gists/aa5a315d61ae9438b18d"): (204, [:], Data())
            default: (404, [:], Data())
            }
        }
        let body = Data((0..<300).map { UInt8($0 & 0xFF) })
        let reply = await Self.service.perform(Self.job(.create, Self.gist), body: body)
        #expect(
            reply.ok && reply.object == "aa5a315d61ae9438b18d" && reply.locator == reply.object && reply.source == .gist
        )
        let post = try #require(Stub.requests.first)
        #expect(post.url.absoluteString == "https://api.github.com/gists")
        #expect(post.header("Authorization") == "Bearer s3cret" && post.header("User-Agent") == "OpenNexus")
        #expect(post.header("X-GitHub-Api-Version") == "2022-11-28")
        let json = try CanonicalJSON.parse(post.body)
        #expect(json["public"] == .bool(false) && json["description"] == .string("OpenNexus share"))
        #expect(json["files"]?["opennexus-share.b64"]?["content"] == .string(body.base64EncodedString()))

        Stub.reset { seen in
            seen.method == "PATCH" ? (200, [:], created) : (204, [:], Data())
        }
        #expect(await Self.service.perform(Self.job(.update, Self.gist, object: "aa5a315d61ae9438b18d"), body: body).ok)
        #expect(
            await Self.service.perform(Self.job(.delete, Self.gist, object: "aa5a315d61ae9438b18d"), body: Data()).ok)
        #expect(Stub.requests.map(\.method) == ["PATCH", "DELETE"])
        #expect(!(await Self.service.perform(Self.job(.delete, Self.gist, object: "../user"), body: Data())).ok)

        let unauthorized = try Self.fixture("gist-401")
        Stub.reset { _ in (401, [:], unauthorized) }
        let bad = await Self.service.perform(Self.job(.test, Self.gist), body: Data())
        #expect(!bad.ok && bad.error?.contains("Bad credentials") == true)
    }

    @Test func server() async throws {
        Stub.reset { seen in
            switch (seen.method, seen.url.path()) {
            case ("GET", "/v1/health"): (200, [:], Data(#"{"service":"opennexus-server","version":1}"#.utf8))
            case ("POST", "/v1/shares"): (201, [:], Data(#"{"id":"Abcdefghijklmnopqrstuv","secret":"ws"}"#.utf8))
            case ("DELETE", _): (204, [:], Data())
            case ("PUT", _): (204, [:], Data())
            default: (404, [:], Data())
            }
        }
        var job = Self.job(.create, Self.server)
        job.expires = Date(timeIntervalSince1970: 1_793_000_000)
        let reply = await Self.service.perform(job, body: Data("x".utf8))
        #expect(reply.ok && reply.object == "Abcdefghijklmnopqrstuv" && reply.writeSecret == "ws")
        #expect(reply.locator == "https://share.example.net/v1/shares/Abcdefghijklmnopqrstuv")
        #expect(Stub.requests[0].header("X-OpenNexus-Expires") == "2026-10-26T07:33:20Z")
        #expect(Stub.requests[0].header("Authorization") == "Bearer s3cret")

        #expect(
            await Self.service.perform(Self.job(.update, Self.server, object: "Abcdefghijklmnopqrstuv"), body: Data())
                .ok)
        #expect(
            await Self.service.perform(Self.job(.delete, Self.server, object: "Abcdefghijklmnopqrstuv"), body: Data())
                .ok)
        #expect(Stub.requests.suffix(2).allSatisfy { $0.header("Authorization") == "Bearer w" })
        let test = await Self.service.perform(Self.job(.test, Self.server), body: Data())
        #expect(test.ok && Stub.requests.suffix(3).map(\.method) == ["GET", "POST", "DELETE"])

        Stub.reset { _ in (200, [:], Data(#"{"hello":"world"}"#.utf8)) }
        let other = await Self.service.perform(Self.job(.test, Self.server), body: Data())
        #expect(!other.ok && other.error?.contains("isn’t an OpenNexus Server") == true)
    }
}
