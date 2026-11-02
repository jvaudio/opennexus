import CryptoKit
import Foundation

/// AWS Signature Version 4, for S3-compatible buckets (AWS S3, Cloudflare R2, Backblaze
/// B2, Wasabi, MinIO). Headers only, no presigned URLs.
public struct SigV4: Sendable {
    public var accessKey: String
    public var secretKey: String
    public var region: String
    public var service = "s3"

    public init(accessKey: String, secretKey: String, region: String, service: String = "s3") {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
    }

    /// Adds `x-amz-date`, `x-amz-content-sha256` (unless `contentHash` is false) and
    /// `Authorization`. Every header already on the request is signed.
    public func sign(_ r: inout HTTPRequest, date: Date = Date(), contentHash: Bool = true) {
        let stamp = Self.stamp(date)
        let day = String(stamp.prefix(8))
        let payload = Self.hex(SHA256.hash(data: r.body))
        r.headers["x-amz-date"] = stamp
        if contentHash { r.headers["x-amz-content-sha256"] = payload }
        var headers: [String: String] = [:]
        for (k, v) in r.headers {
            headers[k.lowercased()] = v.trimmingCharacters(in: .whitespaces).split(
                separator: " ", omittingEmptySubsequences: true
            )
            .joined(separator: " ")
        }
        headers["host"] = Self.host(r.url)
        let names = headers.keys.sorted()
        let canonical = [
            r.method,
            Self.canonicalPath(r.url),
            Self.canonicalQuery(r.url),
            names.map { "\($0):\(headers[$0]!)\n" }.joined(),
            names.joined(separator: ";"),
            payload,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(
            separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
        r.headers["Authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(names.joined(separator: ";")), Signature=\(signature)"
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    /// The Host header as the request sends it: with the port unless it's the scheme's own.
    static func host(_ url: URL) -> String {
        let h = url.host() ?? ""
        guard let p = url.port else { return h }
        return (url.scheme == "https" && p == 443) || (url.scheme == "http" && p == 80) ? h : "\(h):\(p)"
    }

    /// S3 encodes each path segment once, keeping `/`.
    static func canonicalPath(_ url: URL) -> String {
        let p = url.path(percentEncoded: false)
        guard !p.isEmpty else { return "/" }
        return p.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(
            separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return "" }
        return q.map { (encode($0.name), encode($0.value ?? "")) }.sorted { $0 < $1 }.map { "\($0.0)=\($0.1)" }.joined(
            separator: "&")
    }

    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex(_ d: some Sequence<UInt8>) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }
}
