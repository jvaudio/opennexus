import CryptoKit
import Foundation
import NexusCore
import NexusFormat

/// The library's folder on this Mac: `.nexus` packages by relative path.
public protocol SyncFolder: Sendable {
    /// Every package's path relative to the folder, such as `Plans/Launch.nexus`.
    func documents() async throws -> [String]
    /// The package's files that sync carries (`SyncFiles.carried`); nil when it's gone.
    func read(_ path: String) async throws -> [String: Data]?
    /// Replaces the package with these files. With `expected`, only while the package still
    /// has those files (checked inside the coordinated write, so a save can't slip between):
    /// otherwise it throws `SyncError.changedHere`.
    func write(_ path: String, _ files: [String: Data], replacing expected: [String: Data]?) async throws
    /// Moves the package to the Trash (with `expected`, only while it still has those files).
    func trash(_ path: String, replacing expected: [String: Data]?) async throws
    func move(_ from: String, to: String) async throws
}

extension SyncFolder {
    public func write(_ path: String, _ files: [String: Data]) async throws {
        try await write(path, files, replacing: nil)
    }

    public func trash(_ path: String) async throws { try await trash(path, replacing: nil) }
}

public enum SyncFiles {
    /// What sync carries: the package without what the app derives on this Mac (Quick Look's
    /// preview, the viewer copy, recovery snapshots).
    public static func carried(_ path: String) -> Bool {
        !(path == NexusPackage.previewName || path.hasPrefix("render/") || path.hasPrefix("snapshots/")
            || path.hasSuffix(".DS_Store"))
    }

    /// The document's id: `documentID` in the manifest; for a password-protected package,
    /// one made from its key's salt (the manifest has no id).
    public static func documentID(_ files: [String: Data]) -> String? {
        guard let m = files["manifest.json"], let json = try? CanonicalJSON.parse(m), let o = json.objectValue else {
            return nil
        }
        if case .string(let s)? = o["documentID"], valid(s) { return s }
        if isOpaque(files), case .string(let salt)? = o["encryption"]?.objectValue?["salt"] {
            return "locked-" + LibraryCrypto.hex(Data(SHA256.hash(data: Data(salt.utf8)))).prefix(32)
        }
        return nil
    }

    /// Password-protected: synced whole.
    public static func isOpaque(_ files: [String: Data]) -> Bool { PackageCrypto.isEncrypted(files) }

    /// Ids become object keys: letters, digits, `-` and `_`.
    static func valid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
            }
    }

    /// The files with `documentID` set in the manifest.
    static func withID(_ files: [String: Data], _ id: String) -> [String: Data]? {
        guard let m = files["manifest.json"], var json = try? CanonicalJSON.parse(m), case .object(var o) = json
        else { return nil }
        o["documentID"] = .string(id)
        json = .object(o)
        var out = files
        out["manifest.json"] = CanonicalJSON.data(json)
        return out
    }
}

/// A folder on disk. Reads and writes go through `NSFileCoordinator`, so an open document
/// hears about them and merges (M45; `NexusDocument.presentedItemDidChange`).
public struct DiskFolder: SyncFolder {
    public let root: URL

    public init(_ root: URL) { self.root = root }

    func url(_ path: String) -> URL { root.appending(path: path, directoryHint: .isDirectory) }

    public func documents() async throws -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        guard
            let e = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        let base = root.standardizedFileURL.path(percentEncoded: false)
        while let u = e.nextObject() as? URL {
            guard u.pathExtension == NexusPackage.fileExtension else { continue }
            e.skipDescendants()
            var p = u.standardizedFileURL.path(percentEncoded: false)
            if p.hasPrefix(base) { p.removeFirst(base.count) }
            out.append(p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return out.sorted()
    }

    public func read(_ path: String) async throws -> [String: Data]? {
        let u = url(path)
        guard FileManager.default.fileExists(atPath: u.path(percentEncoded: false)) else { return nil }
        var result: [String: Data]?
        var failure: (any Error)?
        var ce: NSError?
        NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &ce) { u in
            do { result = try Self.carried(u) } catch { failure = error }
        }
        if let e = ce ?? failure { throw e }
        return result
    }

    static func carried(_ u: URL) throws -> [String: Data] {
        NexusPackage.flatten(try FileWrapper(url: u, options: [.immediate])).filter { SyncFiles.carried($0.key) }
    }

    /// Inside a coordinated write: the package still has `expected` (or there's nothing to check).
    static func unchanged(_ u: URL, _ expected: [String: Data]?) -> Bool {
        guard let expected else { return true }
        return (try? carried(u)) == expected
    }

    public func write(_ path: String, _ files: [String: Data], replacing expected: [String: Data]?) async throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var failure: (any Error)?
        var ce: NSError?
        NSFileCoordinator().coordinate(writingItemAt: u, options: [.forReplacing], error: &ce) { u in
            guard Self.unchanged(u, expected) else { return failure = SyncError.changedHere }
            do {
                try NexusPackage.directoryWrapper(from: files).write(
                    to: u, options: [.atomic], originalContentsURL: nil)
            } catch {
                failure = error
            }
        }
        if let e = ce ?? failure { throw e }
    }

    public func trash(_ path: String, replacing expected: [String: Data]?) async throws {
        let u = url(path)
        var failure: (any Error)?
        var ce: NSError?
        NSFileCoordinator().coordinate(writingItemAt: u, options: [.forDeleting], error: &ce) { u in
            guard Self.unchanged(u, expected) else { return failure = SyncError.changedHere }
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) } catch { failure = error }
        }
        if let e = ce ?? failure { throw e }
    }

    public func move(_ from: String, to: String) async throws {
        let a = url(from)
        let b = url(to)
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        var failure: (any Error)?
        var ce: NSError?
        let c = NSFileCoordinator()
        c.coordinate(writingItemAt: a, options: [.forMoving], writingItemAt: b, options: [.forReplacing], error: &ce) {
            a, b in
            do {
                c.item(at: a, willMoveTo: b)
                try FileManager.default.moveItem(at: a, to: b)
                c.item(at: a, didMoveTo: b)
            } catch {
                failure = error
            }
        }
        if let e = ce ?? failure { throw e }
    }
}

/// A folder in memory (tests).
public actor MemoryFolder: SyncFolder {
    public private(set) var packages: [String: [String: Data]] = [:]
    public private(set) var trashed: [String] = []

    public init() {}

    /// A save that lands just before sync's next write to that package (tests).
    var saveBeforeWrite: (path: String, change: @Sendable ([String: Data]) -> [String: Data])?

    public func set(_ path: String, _ files: [String: Data]?) { packages[path] = files }

    public func saveBeforeNextWrite(to path: String, _ change: @escaping @Sendable ([String: Data]) -> [String: Data]) {
        saveBeforeWrite = (path, change)
    }

    public func documents() async throws -> [String] { packages.keys.sorted() }
    public func read(_ path: String) async throws -> [String: Data]? { packages[path] }

    func check(_ path: String, _ expected: [String: Data]?) throws {
        if let s = saveBeforeWrite, s.path == path, let files = packages[path] {
            packages[path] = s.change(files)
            saveBeforeWrite = nil
        }
        if let expected, packages[path] != expected { throw SyncError.changedHere }
    }

    public func write(_ path: String, _ files: [String: Data], replacing expected: [String: Data]?) async throws {
        try check(path, expected)
        packages[path] = files
    }

    public func trash(_ path: String, replacing expected: [String: Data]?) async throws {
        try check(path, expected)
        packages[path] = nil
        trashed.append(path)
    }

    public func move(_ from: String, to: String) async throws {
        packages[to] = packages[from]
        packages[from] = nil
    }
}
