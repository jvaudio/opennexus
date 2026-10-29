import CryptoKit
import Foundation
import NexusFormat

/// How a library's objects are sealed and named (D348). Encrypted (the default): a random
/// 32-byte library key; HKDF gives a sealing key and a naming key; every object is a
/// `Sealed` envelope, and a blob's name is an HMAC of its content, so equal files are
/// stored once and names say nothing. Unencrypted: plain bytes and SHA-256 names.
public struct LibraryCrypto: Sendable {
    public static let recordType = "application/vnd.opennexus.sync+json"
    public static let blobType = "application/octet-stream"

    /// Nil for an unencrypted library.
    public let key: SymmetricKey?
    let sealing: SymmetricKey?
    let naming: SymmetricKey?

    public init(key: SymmetricKey?) {
        self.key = key
        if let key {
            sealing = Self.derive(key, "seal")
            naming = Self.derive(key, "name")
        } else {
            sealing = nil
            naming = nil
        }
    }

    public static let unencrypted = LibraryCrypto(key: nil)
    public var encrypted: Bool { key != nil }

    static func derive(_ key: SymmetricKey, _ use: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, salt: Data("OpenNexus sync 1".utf8), info: Data(use.utf8), outputByteCount: 32)
    }

    /// A blob's name: lower-case hex of its content's HMAC, or SHA-256 when unencrypted.
    public func name(_ content: Data) -> String {
        if let naming {
            return Self.hex(Data(HMAC<SHA256>.authenticationCode(for: content, using: naming)))
        }
        return Self.hex(Data(SHA256.hash(data: content)))
    }

    /// What's stored for `content`: deflated and sealed, or as it is.
    public func seal(_ content: Data, type: String) throws -> Data {
        guard let sealing else { return content }
        return try Sealed.seal(
            Sealed.deflate(content), header: .init(type: type, encoding: Sealed.deflate, bundle: nil), key: sealing)
    }

    public func open(_ stored: Data) throws -> Data {
        guard let sealing else {
            if Self.isSealed(stored) { throw SyncError.encryptionMismatch(remoteEncrypted: true) }
            return stored
        }
        guard Self.isSealed(stored) else { throw SyncError.encryptionMismatch(remoteEncrypted: false) }
        do {
            let (header, content) = try Sealed.open(stored, key: sealing)
            return header.encoding == Sealed.deflate ? try Sealed.inflate(content) : content
        } catch Sealed.SealError.newer(let v) {
            throw SyncError.newer(v)
        } catch {
            throw SyncError.wrongKey
        }
    }

    static func isSealed(_ d: Data) -> Bool { d.count >= 4 && Array(d.prefix(4)) == Sealed.magic }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

/// The library key as people copy it to another Mac: Crockford base32 of the key and a
/// two-byte checksum, in groups of five (`7K2QD-…`, 55 characters). Reading forgives case,
/// spaces, dashes, and I/L/O typed for 1 and 0.
public enum RecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func text(_ key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        let bytes = raw + Data(SHA256.hash(data: raw)).prefix(2)
        var bits = 0
        var acc = 0
        var chars: [Character] = []
        for b in bytes {
            acc = (acc << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(alphabet[(acc >> bits) & 31])
            }
            acc &= (1 << bits) - 1
        }
        if bits > 0 { chars.append(alphabet[(acc << (5 - bits)) & 31]) }
        return stride(from: 0, to: chars.count, by: 5).map { String(chars[$0..<min($0 + 5, chars.count)]) }
            .joined(separator: "-")
    }

    /// The key, or nil when the text isn't a recovery key (a typo fails the checksum).
    public static func key(_ text: String) -> SymmetricKey? {
        var acc = 0
        var bits = 0
        var bytes = Data()
        for c in text.uppercased() {
            if c == "-" || c == " " || c.isWhitespace { continue }
            let ch: Character =
                switch c {
                case "I", "L": "1"
                case "O": "0"
                default: c
                }
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            acc = (acc << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((acc >> bits) & 0xFF))
                acc &= (1 << bits) - 1
            }
        }
        guard bytes.count == 34 else { return nil }
        let raw = bytes.prefix(32)
        guard Data(SHA256.hash(data: raw)).prefix(2) == bytes.suffix(2) else { return nil }
        return SymmetricKey(data: raw)
    }
}
