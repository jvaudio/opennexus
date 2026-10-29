import CryptoKit
import Foundation
import NexusCore
import NexusFormat

/// A place share links are stored (the plan's `ShareTarget`): put, update, delete, test.
protocol ShareTarget: Sendable {
    func create(_ body: Data, expires: Date?, client: HTTPClient) async throws -> NetReply
    func update(_ object: String, _ body: Data, writeSecret: String?, expires: Date?, client: HTTPClient) async throws
    func delete(_ object: String, writeSecret: String?, client: HTTPClient) async throws
    func test(origin: String?, client: HTTPClient) async throws -> String
}

/// A random object name: 16 bytes, base64url.
func randomName() -> String { Sealed.randomBytes(16).base64URL() }

func url(_ s: String) throws -> URL {
    guard let u = URL(string: s), u.host() != nil else { throw NetError.unexpected("“\(s)” isn’t an address") }
    return u
}

// MARK: S3-compatible

struct S3Target: ShareTarget {
    var d: ShareDestination
    var secret: String

    var signer: SigV4 {
        SigV4(accessKey: d.accessKey, secretKey: secret, region: d.region.isEmpty ? "us-east-1" : d.region)
    }

    /// The bucket's API address for `key` (empty for the bucket itself).
    func apiURL(_ key: String, query: String? = nil) throws -> URL {
        let base = try url(d.endpoint)
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let root = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        if d.pathStyle {
            c.path = root + "/" + d.bucket + (key.isEmpty ? "" : "/" + key)
        } else {
            c.host = "\(d.bucket).\(base.host() ?? "")"
            c.path = root + "/" + key
        }
        c.percentEncodedQuery = query
        guard let u = c.url else { throw NetError.unexpected("bad bucket address") }
        return u
    }

    /// Where readers fetch `key`.
    func publicURL(_ key: String) throws -> URL {
        guard !d.publicBase.isEmpty else { return try apiURL(key) }
        var base = d.publicBase
        if !base.hasSuffix("/") { base += "/" }
        return try url(base + key)
    }

    func key(_ name: String) -> String {
        var p = d.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !p.isEmpty { p += "/" }
        return p + name
    }

    func send(
        _ method: String, _ key: String, body: Data = Data(), headers: [String: String] = [:], query: String? = nil,
        client: HTTPClient
    ) async throws -> HTTPResponse {
        var r = HTTPRequest(method, try apiURL(key, query: query), headers: headers, body: body)
        signer.sign(&r)
        let response = try await client.send(r)
        guard response.ok else { throw NetError.status(response.status, Self.message(response)) }
        return response
    }

    /// S3's `<Message>`, if any.
    static func message(_ r: HTTPResponse) -> String {
        let t = r.text
        guard let a = t.range(of: "<Message>"), let b = t.range(of: "</Message>", range: a.upperBound..<t.endIndex)
        else { return t.count < 200 ? t : "" }
        return String(t[a.upperBound..<b.lowerBound])
    }

    static let objectHeaders = ["Content-Type": "application/octet-stream", "Cache-Control": "no-cache"]

    func create(_ body: Data, expires: Date?, client: HTTPClient) async throws -> NetReply {
        let k = key(randomName() + ".onx")
        _ = try await send("PUT", k, body: body, headers: Self.objectHeaders, client: client)
        return NetReply(ok: true, object: k, locator: try publicURL(k).absoluteString, source: .url)
    }

    func update(_ object: String, _ body: Data, writeSecret: String?, expires: Date?, client: HTTPClient) async throws {
        _ = try await send("PUT", object, body: body, headers: Self.objectHeaders, client: client)
    }

    func delete(_ object: String, writeSecret: String?, client: HTTPClient) async throws {
        _ = try await send("DELETE", object, client: client)
    }

    /// Stores a probe, reads it back where readers will (as the viewer's origin, to see the
    /// CORS answer), and deletes it.
    func test(origin: String?, client: HTTPClient) async throws -> String {
        let k = key("probe-" + randomName() + ".txt")
        let probe = Data("OpenNexus destination test".utf8)
        _ = try await send("PUT", k, body: probe, headers: ["Content-Type": "text/plain"], client: client)
        var notes: [String] = []
        do {
            var headers: [String: String] = [:]
            if let origin { headers["Origin"] = origin }
            let read = try await client.send(HTTPRequest("GET", try publicURL(k), headers: headers))
            if !read.ok || read.body != probe {
                notes.append(
                    "Readers can’t fetch it (\(read.status)): make the bucket or its prefix publicly readable, or check the public address."
                )
            } else if let origin, read.headers["access-control-allow-origin"].map({ $0 != "*" && $0 != origin }) ?? true
            {
                notes.append("Readers’ browsers can’t open it yet: choose Set Up CORS.")
            }
        } catch {
            _ = try? await send("DELETE", k, client: client)
            throw error
        }
        _ = try await send("DELETE", k, client: client)
        return notes.isEmpty ? "Stored, read back and deleted a test file." : notes.joined(separator: " ")
    }

    /// Replaces the bucket's CORS rules with one that lets the viewer read objects.
    func setUpCORS(origin: String, client: HTTPClient) async throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><CORSRule>\
            <AllowedOrigin>\(origin)</AllowedOrigin><AllowedMethod>GET</AllowedMethod><AllowedMethod>HEAD</AllowedMethod>\
            <AllowedHeader>*</AllowedHeader><MaxAgeSeconds>3600</MaxAgeSeconds></CORSRule></CORSConfiguration>
            """
        let body = Data(xml.utf8)
        let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        _ = try await send(
            "PUT", "", body: body, headers: ["Content-Type": "application/xml", "Content-MD5": md5], query: "cors=",
            client: client)
    }
}

// MARK: GitHub Gist

struct GistTarget: ShareTarget {
    var token: String
    /// The one file in a share gist: the sealed bytes in base64 (gists hold text).
    static let file = "opennexus-share.b64"
    static let description = "OpenNexus share"

    var headers: [String: String] {
        [
            "Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "OpenNexus",
        ]
    }

    func send(_ method: String, _ path: String, json: JSONValue? = nil, client: HTTPClient) async throws -> HTTPResponse
    {
        var h = headers
        var body = Data()
        if let json {
            h["Content-Type"] = "application/json"
            body = Data(CanonicalJSON.compact(json).utf8)
        }
        let response = try await client.send(
            HTTPRequest(method, try url(ShareDestination.githubAPI + path), headers: h, body: body))
        guard response.ok else {
            let message = (try? CanonicalJSON.parse(response.body))?["message"]?.stringValue ?? ""
            throw NetError.status(response.status, message)
        }
        return response
    }

    static func gist(_ body: Data) -> JSONValue {
        .object([
            "description": .string(description), "public": .bool(false),
            "files": .object([file: .object(["content": .string(body.base64EncodedString())])]),
        ])
    }

    func create(_ body: Data, expires: Date?, client: HTTPClient) async throws -> NetReply {
        let r = try await send("POST", "/gists", json: Self.gist(body), client: client)
        guard let id = (try? CanonicalJSON.parse(r.body))?["id"]?.stringValue, Self.valid(id) else {
            throw NetError.unexpected("no gist id")
        }
        return NetReply(ok: true, object: id, locator: id, source: .gist)
    }

    func update(_ object: String, _ body: Data, writeSecret: String?, expires: Date?, client: HTTPClient) async throws {
        guard Self.valid(object) else { throw NetError.unexpected("bad gist id") }
        _ = try await send("PATCH", "/gists/\(object)", json: Self.gist(body), client: client)
    }

    func delete(_ object: String, writeSecret: String?, client: HTTPClient) async throws {
        guard Self.valid(object) else { throw NetError.unexpected("bad gist id") }
        _ = try await send("DELETE", "/gists/\(object)", client: client)
    }

    /// Creates and deletes a secret gist: the token can do what sharing needs.
    func test(origin: String?, client: HTTPClient) async throws -> String {
        let r = try await create(Data("OpenNexus destination test".utf8), expires: nil, client: client)
        try await delete(r.object ?? "", writeSecret: nil, client: client)
        return "Created and deleted a secret gist."
    }

    static func valid(_ id: String) -> Bool { !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isHexDigit } }
}

// MARK: OpenNexus Server

struct ServerTarget: ShareTarget {
    var d: ShareDestination
    var token: String

    func endpoint(_ path: String) throws -> URL {
        var base = d.server
        while base.hasSuffix("/") { base.removeLast() }
        return try url(base + path)
    }

    static func expiryHeader(_ d: Date?) -> [String: String] {
        d.map { ["X-OpenNexus-Expires": Sealed.timestamp($0)] } ?? [:]
    }

    func check(_ r: HTTPResponse) throws -> HTTPResponse {
        guard r.ok else {
            let message = (try? CanonicalJSON.parse(r.body))?["error"]?.stringValue ?? ""
            throw NetError.status(r.status, message)
        }
        return r
    }

    func create(_ body: Data, expires: Date?, client: HTTPClient) async throws -> NetReply {
        var h = ["Authorization": "Bearer \(token)", "Content-Type": "application/octet-stream"]
        h.merge(Self.expiryHeader(expires)) { $1 }
        let r = try check(await client.send(HTTPRequest("POST", try endpoint("/v1/shares"), headers: h, body: body)))
        guard let o = (try? CanonicalJSON.parse(r.body))?.objectValue, let id = o["id"]?.stringValue,
            let secret = o["secret"]?.stringValue, ShareID.valid(id)
        else { throw NetError.unexpected("no share id") }
        return NetReply(
            ok: true, object: id, locator: try endpoint("/v1/shares/\(id)").absoluteString, source: .url,
            writeSecret: secret)
    }

    func update(_ object: String, _ body: Data, writeSecret: String?, expires: Date?, client: HTTPClient) async throws {
        guard ShareID.valid(object) else { throw NetError.unexpected("bad share id") }
        var h = ["Authorization": "Bearer \(writeSecret ?? "")", "Content-Type": "application/octet-stream"]
        h.merge(Self.expiryHeader(expires)) { $1 }
        _ = try check(
            await client.send(HTTPRequest("PUT", try endpoint("/v1/shares/\(object)"), headers: h, body: body)))
    }

    func delete(_ object: String, writeSecret: String?, client: HTTPClient) async throws {
        guard ShareID.valid(object) else { throw NetError.unexpected("bad share id") }
        let h = ["Authorization": "Bearer \(writeSecret ?? "")"]
        let r = try await client.send(HTTPRequest("DELETE", try endpoint("/v1/shares/\(object)"), headers: h))
        // Already gone (expired, or deleted elsewhere) is what Revoke wants.
        if r.status != 404 { _ = try check(r) }
    }

    /// Asks the server what it is, then stores and deletes a probe with the upload token.
    /// The probe is sealed (with a key that's thrown away), since the server stores nothing
    /// else.
    func test(origin: String?, client: HTTPClient) async throws -> String {
        let health = try check(await client.send(HTTPRequest("GET", try endpoint("/v1/health"))))
        guard (try? CanonicalJSON.parse(health.body))?["service"]?.stringValue == "opennexus-server" else {
            throw NetError.unexpected("that address isn’t an OpenNexus Server")
        }
        let probe = try Sealed.seal(
            Data("OpenNexus destination test".utf8), header: .init(type: "text/plain", encoding: nil, bundle: nil),
            key: Sealed.newKey())
        let r = try await create(probe, expires: nil, client: client)
        try await delete(r.object ?? "", writeSecret: r.writeSecret, client: client)
        return "The server accepted the upload token; stored and deleted a test share."
    }
}

/// The server's share ids: 16 random bytes in base64url (22 characters).
enum ShareID {
    static func valid(_ id: String) -> Bool {
        id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
