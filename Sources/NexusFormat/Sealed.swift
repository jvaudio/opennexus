import CommonCrypto
import Compression
import CryptoKit
import Foundation
import NexusCore

/// The envelope for everything that leaves the Mac (M44 share links; sync and co-editing
/// reuse it): readable by CryptoKit and by a browser's WebCrypto.
///
///     "ONX1" | header length (UInt32, big-endian) | header | nonce (12) | ciphertext | tag (16)
///
/// The header is compact canonical JSON: version, algorithm, content type, encoding,
/// bundle version, created, the optional expiry, and for a password the KDF's name,
/// iterations and salt. Everything before the nonce is the associated data, so the header
/// can be read without the key but not altered. A wrong key and an altered byte fail the
/// same way: the tag doesn't match.
public enum Sealed {
    public static let magic: [UInt8] = Array("ONX1".utf8)
    public static let version = 1
    public static let algorithm = "AES-256-GCM"
    /// A viewer bundle (`schema/viewer.schema.json`).
    public static let viewerType = "application/vnd.opennexus.viewer+json"
    /// Raw DEFLATE (RFC 1951): `DecompressionStream("deflate-raw")` in browsers.
    public static let deflate = "deflate-raw"
    public static let kdfName = "PBKDF2-SHA256"
    /// PBKDF2-SHA256 iterations for a password (D332): OWASP's figure, as for encrypted
    /// documents, and about half a second in a browser.
    public static let iterations = 600_000
    /// Headers are small; a longer length means the data isn't an envelope.
    public static let maxHeader = 4096
    /// Inflated content larger than this is refused (a deflate bomb).
    public static let maxContent = 256 * 1024 * 1024

    public enum SealError: Error, Equatable, CustomStringConvertible {
        /// Not an envelope, cut short, altered, or the wrong key.
        case damaged
        /// Written by a newer OpenNexus (its envelope or bundle version).
        case newer(Int)
        public var description: String {
            switch self {
            case .damaged: "The sealed data is damaged, or the key is wrong."
            case .newer(let v): "The sealed data was made by a newer OpenNexus (version \(v))."
            }
        }
    }

    public struct KDF: Equatable, Sendable {
        public var iterations: Int
        public var salt: Data
        public init(iterations: Int = Sealed.iterations, salt: Data) {
            self.iterations = iterations
            self.salt = salt
        }
        public static func random(iterations: Int = Sealed.iterations) -> KDF {
            KDF(iterations: iterations, salt: Sealed.randomBytes(16))
        }
    }

    public struct Header: Equatable, Sendable {
        public var version = Sealed.version
        public var algorithm = Sealed.algorithm
        public var type: String
        public var encoding: String?
        /// The viewer bundle's version, for a viewer bundle.
        public var bundle: Int?
        /// ISO 8601, UTC, to the second.
        public var created: String
        public var expires: String?
        public var kdf: KDF?

        public init(
            type: String = Sealed.viewerType, encoding: String? = Sealed.deflate, bundle: Int? = 1,
            created: Date = Date(), expires: Date? = nil, kdf: KDF? = nil
        ) {
            self.type = type
            self.encoding = encoding
            self.bundle = bundle
            self.created = Sealed.timestamp(created)
            self.expires = expires.map(Sealed.timestamp)
            self.kdf = kdf
        }

        public var json: JSONValue {
            var o: [String: JSONValue] = [
                "version": .number(Double(version)), "algorithm": .string(algorithm), "type": .string(type),
                "created": .string(created),
            ]
            if let encoding { o["encoding"] = .string(encoding) }
            if let bundle { o["bundle"] = .number(Double(bundle)) }
            if let expires { o["expires"] = .string(expires) }
            if let kdf {
                o["kdf"] = .object([
                    "name": .string(Sealed.kdfName), "iterations": .number(Double(kdf.iterations)),
                    "salt": .string(kdf.salt.base64EncodedString()),
                ])
            }
            return .object(o)
        }

        /// Reads a header, refusing anything this version can't open.
        init(json: JSONValue) throws {
            guard let o = json.objectValue, let v = Sealed.int(o["version"]), v >= 1,
                case .string(let type)? = o["type"], case .string(let created)? = o["created"]
            else { throw SealError.damaged }
            guard v <= Sealed.version else { throw SealError.newer(v) }
            guard o["algorithm"] == .string(Sealed.algorithm) else { throw SealError.damaged }
            self.type = type
            self.created = created
            switch o["encoding"] {
            case nil: encoding = nil
            case .string(Sealed.deflate)?: encoding = Sealed.deflate
            default: throw SealError.damaged
            }
            if let b = o["bundle"] {
                guard let n = Sealed.int(b) else { throw SealError.damaged }
                bundle = n
            }
            if let e = o["expires"] {
                guard case .string(let s) = e else { throw SealError.damaged }
                expires = s
            }
            if let k = o["kdf"] {
                // Bounded, so a crafted header can't make opening hang.
                guard let ko = k.objectValue, ko["name"] == .string(Sealed.kdfName),
                    let n = Sealed.int(ko["iterations"]), n >= 1, n <= 10_000_000,
                    case .string(let s)? = ko["salt"], let salt = Data(base64Encoded: s), !salt.isEmpty
                else { throw SealError.damaged }
                kdf = KDF(iterations: n, salt: salt)
            }
        }

        public var expiryDate: Date? { expires.flatMap(Sealed.date) }
    }

    // MARK: Sealing

    /// Seals `content` as it is (already encoded as `header.encoding` says).
    public static func seal(_ content: Data, header: Header, key: SymmetricKey, nonce: AES.GCM.Nonce = AES.GCM.Nonce())
        throws -> Data
    {
        let prefix = self.prefix(header)
        let box = try AES.GCM.seal(content, using: key, nonce: nonce, authenticating: prefix)
        return prefix + Data(box.nonce) + box.ciphertext + box.tag
    }

    /// A viewer bundle, deflated and sealed.
    public static func seal(bundle: JSONValue, header: Header, key: SymmetricKey) throws -> Data {
        try seal(deflate(Data(CanonicalJSON.compact(bundle).utf8)), header: header, key: key)
    }

    static func prefix(_ header: Header) -> Data {
        let h = Data(CanonicalJSON.compact(header.json).utf8)
        var out = Data(magic)
        withUnsafeBytes(of: UInt32(h.count).bigEndian) { out.append(contentsOf: $0) }
        return out + h
    }

    // MARK: Opening

    /// The header, readable without the key.
    public static func header(of data: Data) throws -> Header {
        try parts(data).header
    }

    /// The content, as sealed (still encoded).
    public static func open(_ data: Data, key: SymmetricKey) throws -> (header: Header, content: Data) {
        let p = try parts(data)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: p.nonce), ciphertext: p.body, tag: p.tag)
            return (p.header, try AES.GCM.open(box, using: key, authenticating: p.prefix))
        } catch {
            throw SealError.damaged
        }
    }

    /// A sealed viewer bundle, opened, inflated and parsed.
    public static func openBundle(_ data: Data, key: SymmetricKey) throws -> (header: Header, bundle: JSONValue) {
        let (header, content) = try open(data, key: key)
        guard header.type == viewerType else { throw SealError.damaged }
        if let b = header.bundle, b > 1 { throw SealError.newer(b) }
        let raw = header.encoding == deflate ? try inflate(content) : content
        guard let bundle = try? CanonicalJSON.parse(raw) else { throw SealError.damaged }
        return (header, bundle)
    }

    struct Parts {
        var prefix: Data
        var header: Header
        var nonce: Data
        var body: Data
        var tag: Data
    }

    static func parts(_ data: Data) throws -> Parts {
        let d = Data(data)  // indices from 0
        guard d.count >= 8, Array(d.prefix(4)) == magic else { throw SealError.damaged }
        let length = d[4..<8].reduce(0) { $0 << 8 | Int($1) }
        let end = 8 + length
        guard length > 0, length <= maxHeader, d.count >= end + 12 + 16 else { throw SealError.damaged }
        guard let json = try? CanonicalJSON.parse(d[8..<end]) else { throw SealError.damaged }
        let header = try Header(json: json)
        return Parts(
            prefix: d[0..<end], header: header, nonce: d[end..<(end + 12)], body: d[(end + 12)..<(d.count - 16)],
            tag: d[(d.count - 16)...])
    }

    // MARK: Keys

    public static func newKey() -> SymmetricKey { SymmetricKey(data: randomBytes(32)) }

    /// PBKDF2-SHA256 over the password's UTF-8, as WebCrypto's `deriveKey` computes it.
    public static func key(password: String, kdf: KDF) -> SymmetricKey {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        out.withUnsafeMutableBytes { o in
            kdf.salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                    s.bindMemory(to: UInt8.self).baseAddress, kdf.salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(kdf.iterations), o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return SymmetricKey(data: out)
    }

    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    // MARK: Encoding

    public static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }  // an empty final block
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    /// Inflates raw DEFLATE, refusing more than `limit` bytes.
    public static func inflate(_ data: Data, limit: Int = maxContent) throws -> Data {
        var out = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                if let chunk {
                    guard out.count + chunk.count <= limit else { throw SealError.damaged }
                    out.append(chunk)
                }
            }
            var i = data.startIndex
            while i < data.endIndex {
                let j = min(i + 65_536, data.endIndex)
                try filter.write(data[i..<j])
                i = j
            }
            try filter.finalize()
        } catch {
            throw SealError.damaged
        }
        return out
    }

    // MARK: Helpers

    static func int(_ v: JSONValue?) -> Int? {
        guard case .number(let n)? = v, n.isFinite, n == n.rounded(), abs(n) < 1e15 else { return nil }
        return Int(n)
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func timestamp(_ d: Date) -> String { iso.string(from: d) }
    public static func date(_ s: String) -> Date? { iso.date(from: s) }
}

extension Data {
    /// URL-safe base64 without padding (RFC 4648 §5), as share links carry keys.
    public func base64URL() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL s: String) {
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        self.init(base64Encoded: t)
    }
}
