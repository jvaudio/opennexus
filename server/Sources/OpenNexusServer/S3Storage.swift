import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// Shares in an S3-compatible bucket: `<prefix><id>.onx` and `<prefix><id>.json`. The
/// bucket stays private; readers fetch through the server.
public struct S3Storage: ShareStorage {
    public let config: S3Config
    let client: HTTPClient
    let signer: SigV4

    public init(_ config: S3Config, client: HTTPClient = .shared) {
        self.config = config
        self.client = client
        signer = SigV4(accessKey: config.accessKey, secretKey: config.secretKey, region: config.region)
    }

    func url(_ key: String, query: String? = nil) -> URL {
        var base = config.endpoint
        while base.hasSuffix("/") { base.removeLast() }
        let path = key.split(separator: "/", omittingEmptySubsequences: false).map { SigV4.encode(String($0)) }.joined(
            separator: "/")
        var s: String
        if config.pathStyle {
            s = "\(base)/\(config.bucket)/\(path)"
        } else {
            var c = URLComponents(string: base)!
            c.host = "\(config.bucket).\(c.host ?? "")"
            s = "\(c.string!)/\(path)"
        }
        if let query { s += "?\(query)" }
        return URL(string: s)!
    }

    struct Failure: Error, CustomStringConvertible {
        var status: UInt
        var body: String
        var description: String { "S3 answered \(status): \(body.prefix(200))" }
    }

    /// One signed request; nil for 404.
    func send(_ method: HTTPMethod, _ url: URL, body: Data = Data(), headers: [String: String] = [:]) async throws
        -> Data?
    {
        var r = HTTPClientRequest(url: url.absoluteString)
        r.method = method
        let all = headers.merging(
            signer.sign(method: method.rawValue, url: url, headers: headers, body: body), uniquingKeysWith: { $1 })
        for (k, v) in all { r.headers.add(name: k, value: v) }
        if !body.isEmpty { r.body = .bytes(ByteBuffer(bytes: body)) }
        let response = try await client.execute(r, timeout: .seconds(60))
        let data = Data(buffer: try await response.body.collect(upTo: 512 * 1024 * 1024))
        if response.status.code == 404 { return nil }
        guard (200..<300).contains(response.status.code) else {
            throw Failure(status: response.status.code, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func key(_ id: String, _ ext: String) -> String { "\(config.prefix)\(id).\(ext)" }

    public func put(_ id: String, _ data: Data, _ meta: ShareMeta) async throws {
        _ = try await send(.PUT, url(key(id, "onx")), body: data, headers: ["Content-Type": "application/octet-stream"])
        _ = try await send(
            .PUT, url(key(id, "json")), body: try MetaCoding.encoder.encode(meta),
            headers: ["Content-Type": "application/json"])
    }

    public func get(_ id: String) async throws -> Data? { try await send(.GET, url(key(id, "onx"))) }

    public func meta(_ id: String) async throws -> ShareMeta? {
        guard let d = try await send(.GET, url(key(id, "json"))) else { return nil }
        return try MetaCoding.decoder.decode(ShareMeta.self, from: d)
    }

    public func delete(_ id: String) async throws {
        _ = try await send(.DELETE, url(key(id, "onx")))
        _ = try await send(.DELETE, url(key(id, "json")))
    }

    /// ListObjectsV2 under the prefix, every page.
    public func ids() async throws -> [String] {
        var out: [String] = []
        var token: String?
        repeat {
            var q = "list-type=2&prefix=\(SigV4.encode(config.prefix))"
            if let token { q += "&continuation-token=\(SigV4.encode(token))" }
            let xml = String(decoding: try await send(.GET, url("", query: q)) ?? Data(), as: UTF8.self)
            out += Self.values(xml, "Key").filter { $0.hasSuffix(".json") }.map {
                String($0.dropFirst(config.prefix.count).dropLast(5))
            }
            token = Self.values(xml, "NextContinuationToken").first
        } while token != nil
        return out
    }

    /// The text of each `<tag>` in a ListObjectsV2 reply (keys are XML-escaped).
    static func values(_ xml: String, _ tag: String) -> [String] {
        var out: [String] = []
        var rest = xml[...]
        while let a = rest.range(of: "<\(tag)>"),
            let b = rest.range(of: "</\(tag)>", range: a.upperBound..<rest.endIndex)
        {
            out.append(
                String(rest[a.upperBound..<b.lowerBound]).replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&"))
            rest = rest[b.upperBound...]
        }
        return out
    }
}
