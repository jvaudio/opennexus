import CommonCrypto
import CryptoKit
import Foundation
import NexusCore

/// Password-protected packages (File › Set Password…, artboard 50).
///
/// An encrypted `.nexus` keeps a readable `manifest.json` (format, schema version, the
/// canvas ids, `"encrypted": true`, and an `encryption` block with the algorithm, KDF
/// parameters, salt and the optional hint) and one `encrypted.bin`: AES-256-GCM over a
/// zip of the ordinary package. The key comes from PBKDF2-SHA256. Nothing else is
/// written, so no topic text, asset or chat is readable without the password.
public enum PackageCrypto {
    public static let iterations = 600_000
    public static let payload = "encrypted.bin"

    public struct Info: Sendable, Equatable {
        public var salt: Data
        public var iterations: Int
        public var hint: String?
        public init(salt: Data, iterations: Int = PackageCrypto.iterations, hint: String? = nil) {
            self.salt = salt
            self.iterations = iterations
            self.hint = hint
        }

        /// A stable id for the Keychain entry (the salt is random per document).
        public var keychainAccount: String { salt.base64EncodedString() }
    }

    public enum CryptoError: Error, Equatable, CustomStringConvertible {
        case wrongPassword
        case damaged
        public var description: String {
            switch self {
            case .wrongPassword: "The password is incorrect."
            case .damaged: "The encrypted document is damaged."
            }
        }
    }

    /// A derived key, kept in memory so autosave doesn't re-run the KDF.
    public struct Key: Sendable {
        public let info: Info
        let key: SymmetricKey
    }

    public static func newInfo(hint: String?) -> Info {
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return Info(salt: salt, hint: hint?.isEmpty == true ? nil : hint)
    }

    public static func derive(password: String, info: Info) -> Key {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        out.withUnsafeMutableBytes { o in
            info.salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                    s.bindMemory(to: UInt8.self).baseAddress, info.salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(info.iterations), o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return Key(info: info, key: SymmetricKey(data: out))
    }

    /// The encrypted package for `files` (an ordinary package's files).
    public static func encrypt(_ files: [String: Data], with key: Key) throws -> [String: Data] {
        var z = ZipWriter()
        for name in files.keys.sorted() { z.add(name, files[name]!) }
        let sealed = try AES.GCM.seal(z.finish(), using: key.key)
        guard let combined = sealed.combined else { throw CryptoError.damaged }
        var manifest: [String: JSONValue] = [
            "format": "opennexus", "schemaVersion": 1, "encrypted": true,
            "encryption": .object([
                "algorithm": "AES-256-GCM", "kdf": "PBKDF2-SHA256", "iterations": .number(Double(key.info.iterations)),
                "salt": .string(key.info.salt.base64EncodedString()),
            ]),
        ]
        if let ids = try? manifestCanvases(files) { manifest["canvases"] = .array(ids.map { .string($0) }) }
        if let h = key.info.hint { manifest["hint"] = .string(h) }
        return ["manifest.json": CanonicalJSON.data(.object(manifest)), payload: combined]
    }

    static func manifestCanvases(_ files: [String: Data]) throws -> [String] {
        guard let m = files["manifest.json"],
            case .array(let ids)? = try CanonicalJSON.parse(m).objectValue?["canvases"]
        else { return [] }
        return ids.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    public static func isEncrypted(_ files: [String: Data]) -> Bool { files[payload] != nil }

    /// The encryption parameters (and hint) from an encrypted package's manifest.
    public static func info(_ files: [String: Data]) -> Info? {
        guard let m = files["manifest.json"], let o = try? CanonicalJSON.parse(m).objectValue,
            let e = o["encryption"]?.objectValue, case .string(let salt)? = e["salt"], let s = Data(base64Encoded: salt)
        else { return nil }
        var iterations = PackageCrypto.iterations
        if case .number(let n)? = e["iterations"] { iterations = Int(n) }
        var hint: String?
        if case .string(let h)? = o["hint"] { hint = h }
        return Info(salt: s, iterations: iterations, hint: hint)
    }

    /// The ordinary package inside.
    public static func decrypt(_ files: [String: Data], with key: Key) throws -> [String: Data] {
        guard let blob = files[payload] else { return files }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: blob)
        } catch {
            throw CryptoError.damaged
        }
        let zip: Data
        do {
            zip = try AES.GCM.open(box, using: key.key)
        } catch {
            throw CryptoError.wrongPassword
        }
        do {
            return try Zip.read(zip)
        } catch {
            throw CryptoError.damaged
        }
    }

    public static func decrypt(_ files: [String: Data], password: String) throws -> [String: Data] {
        guard let info = info(files) else { throw CryptoError.damaged }
        return try decrypt(files, with: derive(password: password, info: info))
    }

    /// Opaque bytes for a recovery snapshot of an encrypted document (same key).
    public static func seal(_ data: Data, with key: Key) throws -> Data {
        guard let c = try AES.GCM.seal(data, using: key.key).combined else { throw CryptoError.damaged }
        return c
    }

    public static func open(_ data: Data, with key: Key) throws -> Data {
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key.key)
        } catch {
            throw CryptoError.wrongPassword
        }
    }
}

// MARK: Recovery snapshots

/// Recovery snapshots (Settings › Files & Backup, File › Revert To › Browse Recovery
/// Snapshots…): zipped copies of the package in Application Support, newest first.
public struct RecoverySnapshot: Sendable, Equatable, Identifiable {
    public var url: URL
    public var date: Date
    public var topics: Int
    public var encrypted: Bool
    public var id: URL { url }
}

public enum SnapshotStore {
    public static let keep = 20

    public static func directory(documentID: String, base: URL? = nil) -> URL {
        let root =
            base
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
                path: "OpenNexus")
        return root.appending(path: "Snapshots").appending(path: documentID)
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()

    /// Writes a snapshot (`<UTC time>_<topics>t.nexuszip`, or `.nexuslock` when sealed with
    /// the document's key) and prunes to the newest `keep`.
    @discardableResult
    public static func write(
        _ files: [String: Data], documentID: String, topics: Int, date: Date = Date(), key: PackageCrypto.Key? = nil,
        base: URL? = nil
    ) throws -> URL {
        let dir = directory(documentID: documentID, base: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var z = ZipWriter()
        for name in files.keys.sorted() { z.add(name, files[name]!) }
        var data = z.finish()
        if let key { data = try PackageCrypto.seal(data, with: key) }
        let url = dir.appending(path: "\(stamp.string(from: date))_\(topics)t.\(key == nil ? "nexuszip" : "nexuslock")")
        try data.write(to: url, options: .atomic)
        prune(documentID: documentID, base: base)
        return url
    }

    public static func list(documentID: String, base: URL? = nil) -> [RecoverySnapshot] {
        let dir = directory(documentID: documentID, base: base)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { u in
            guard ["nexuszip", "nexuslock"].contains(u.pathExtension) else { return nil }
            let parts = u.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count == 2, let d = stamp.date(from: String(parts[0])) else { return nil }
            return RecoverySnapshot(
                url: u, date: d, topics: Int(parts[1].dropLast()) ?? 0, encrypted: u.pathExtension == "nexuslock")
        }
        .sorted { $0.date > $1.date }
    }

    public static func prune(documentID: String, keep: Int = SnapshotStore.keep, base: URL? = nil) {
        for s in list(documentID: documentID, base: base).dropFirst(keep) {
            try? FileManager.default.removeItem(at: s.url)
        }
    }

    public static func read(_ s: RecoverySnapshot, key: PackageCrypto.Key? = nil) throws -> [String: Data] {
        var data = try Data(contentsOf: s.url)
        if s.encrypted {
            guard let key else { throw PackageCrypto.CryptoError.wrongPassword }
            data = try PackageCrypto.open(data, with: key)
        }
        return try Zip.read(data)
    }
}
