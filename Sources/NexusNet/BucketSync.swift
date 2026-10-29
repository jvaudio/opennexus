import Foundation
import NexusFormat

/// A sync library's bucket operations (M45): objects by key under the prefix, with ETags
/// and conditional writes. A missing object, an unchanged one and a failed condition are
/// answers (404, 304, 412), not errors.
extension S3Target {
    /// Signs and sends without treating a non-2xx answer as an error.
    func raw(
        _ method: String, _ key: String, body: Data = Data(), headers: [String: String] = [:], query: String? = nil,
        client: HTTPClient
    ) async throws -> HTTPResponse {
        var r = HTTPRequest(method, try apiURL(key, query: query), headers: headers, body: body)
        signer.sign(&r)
        return try await client.send(r)
    }

    func get(_ name: String, ifNoneMatch: String?, client: HTTPClient) async throws -> (NetReply, Data) {
        let headers = ifNoneMatch.map { ["If-None-Match": $0] } ?? [:]
        let r = try await raw("GET", key(name), headers: headers, client: client)
        switch r.status {
        case 200: return (NetReply(ok: true, status: 200, etag: r.headers["etag"]), r.body)
        case 304: return (NetReply(ok: true, status: 304, etag: ifNoneMatch), Data())
        case 404: return (NetReply(ok: true, status: 404), Data())
        default: throw NetError.status(r.status, Self.message(r))
        }
    }

    func put(_ name: String, _ body: Data, ifMatch: String?, ifNoneMatch: String?, client: HTTPClient) async throws
        -> NetReply
    {
        var headers = Self.objectHeaders
        if let ifMatch { headers["If-Match"] = ifMatch }
        if let ifNoneMatch { headers["If-None-Match"] = ifNoneMatch }
        let r = try await raw("PUT", key(name), body: body, headers: headers, client: client)
        switch r.status {
        case 200..<300: return NetReply(ok: true, status: 200, etag: r.headers["etag"])
        // 409: S3's answer when another conditional write to the key is in flight.
        case 412, 409: return NetReply(ok: true, status: 412)
        default: throw NetError.status(r.status, Self.message(r))
        }
    }

    /// Every key under `name` (ListObjectsV2, a page at a time), without the destination's prefix.
    func list(_ name: String, client: HTTPClient) async throws -> [String] {
        let full = key(name)
        let strip = key("")
        var keys: [String] = []
        var token: String?
        repeat {
            var q = "list-type=2&prefix=\(SigV4.encode(full))"
            if let token { q += "&continuation-token=\(SigV4.encode(token))" }
            let r = try await send("GET", "", query: q, client: client)
            let xml = String(decoding: r.body, as: UTF8.self)
            keys += Self.elements("Key", in: xml).map { $0.hasPrefix(strip) ? String($0.dropFirst(strip.count)) : $0 }
            token =
                Self.elements("IsTruncated", in: xml).first == "true"
                ? Self.elements("NextContinuationToken", in: xml).first : nil
        } while token != nil
        return keys
    }

    /// Stores a probe, checks both conditions are refused when they should be, reads the
    /// probe back and deletes it.
    func syncTest(client: HTTPClient) async throws -> NetReply {
        let name = "probe-" + randomName() + ".txt"
        let probe = Data("OpenNexus sync test".utf8)
        let first = try await put(name, probe, ifMatch: nil, ifNoneMatch: "*", client: client)
        do {
            guard first.status == 200 else {
                throw NetError.unexpected("the bucket refused a new object")
            }
            let again = try await put(name, probe, ifMatch: nil, ifNoneMatch: "*", client: client)
            let stale = try await put(name, probe, ifMatch: "\"0-stale\"", ifNoneMatch: nil, client: client)
            let (read, body) = try await get(name, ifNoneMatch: nil, client: client)
            guard read.status == 200, body == probe else { throw NetError.unexpected("the probe didn’t read back") }
            _ = try await send("DELETE", key(name), client: client)
            let conditional = again.status == 412 && stale.status == 412
            var reply = NetReply(
                ok: true,
                detail: conditional
                    ? "Stored, read back and deleted a test file; the bucket honours conditional writes."
                    : "Stored, read back and deleted a test file. The bucket ignores conditional writes, so OpenNexus checks each write by reading it back."
            )
            reply.conditionalWrites = conditional
            return reply
        } catch {
            _ = try? await send("DELETE", key(name), client: client)
            throw error
        }
    }

    /// The text of each `<tag>…</tag>`, with XML's entities decoded.
    static func elements(_ tag: String, in xml: String) -> [String] {
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
