import Foundation

/// The objects a library keeps under its prefix:
///
/// ```
/// library.json                  documents and tombstones
/// docs/<id>/head.json           the current revision (a HeadRecord)
/// docs/<id>/heads/<rev>.json    every revision (history)
/// docs/<id>/blobs/<name>        every file once, named by its content
/// ```
///
/// Each is sealed with the library key, or plain JSON for an unencrypted library.
enum Layout {
    static let library = "library.json"
    static func docs(_ id: String) -> String { "docs/\(id)/" }
    static func head(_ id: String) -> String { "docs/\(id)/head.json" }
    static func history(_ id: String, _ rev: String) -> String { "docs/\(id)/heads/\(rev).json" }
    static func blob(_ id: String, _ name: String) -> String { "docs/\(id)/blobs/\(name)" }
}

/// `library.json`: which documents the library has, and which were deleted when.
public struct LibraryRecord: Codable, Equatable, Sendable {
    public static let formatName = "opennexus-sync"
    public static let version = 1

    public struct Entry: Codable, Equatable, Sendable {
        /// Set when the document was deleted; its objects stay until the purge.
        public var deleted: Date?
        /// The document's path and the Mac that deleted it, for the remote trash.
        public var path: String?
        public var device: String?
        public init(deleted: Date? = nil, path: String? = nil, device: String? = nil) {
            self.deleted = deleted
            self.path = path
            self.device = device
        }
    }

    public var format = LibraryRecord.formatName
    public var version = LibraryRecord.version
    public var documents: [String: Entry] = [:]

    public init() {}
}

/// One revision of a document: `head.json`, and its copy in `heads/` for history.
public struct HeadRecord: Codable, Equatable, Sendable {
    public var revision: String
    /// The revisions this one follows: none for the first, two for a merge.
    public var parents: [String]
    public var device: String
    public var date: Date
    /// Where the document is in the library folder, such as `Plans/Launch.nexus`.
    public var path: String
    /// Each package file's blob name.
    public var files: [String: String]
    /// A password-protected document, synced whole (it can't be merged without its password).
    public var opaque: Bool?
    /// How many clashes this revision's merge kept this Mac's side of.
    public var clashes: Int?

    public init(
        revision: String, parents: [String], device: String, date: Date, path: String, files: [String: String],
        opaque: Bool? = nil, clashes: Int? = nil
    ) {
        self.revision = revision
        self.parents = parents
        self.device = device
        self.date = date
        self.path = path
        self.files = files
        self.opaque = opaque
        self.clashes = clashes
    }
}

/// What this Mac remembers about a library, in the app's container: per document, the last
/// head it synced (the merge base) and any clashes waiting in Resolve Conflicts. Written
/// only after a head write succeeds.
struct LibraryState: Codable, Equatable {
    struct Doc: Codable, Equatable {
        var head: HeadRecord
        /// `head.json`'s ETag when it was synced.
        var etag: String
    }

    /// A merge whose clashes kept this Mac's side, until the user resolves them.
    struct Conflict: Codable, Equatable {
        var base: [String: String]?
        var mine: [String: String]
        var theirs: [String: String]
        /// What the merge wrote.
        var merged: [String: String]
        var theirsDevice: String
        var date: Date
        var path: String
    }

    var docs: [String: Doc] = [:]
    var conflicts: [String: Conflict] = [:]
    var library: LibraryRecord?
    var libraryETag: String?
}

enum Coding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func encode(_ v: some Encodable) throws -> Data { try encoder.encode(v) }

    static func decode<T: Decodable>(_ t: T.Type, _ d: Data, _ what: String) throws -> T {
        do {
            return try decoder.decode(t, from: d)
        } catch {
            throw SyncError.damaged(what)
        }
    }
}
