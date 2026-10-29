import Foundation

/// What the server keeps about a share besides its bytes. The write secret is kept only as
/// its SHA-256, so the stored files can't be used to change a share.
public struct ShareMeta: Codable, Equatable, Sendable {
    public var secret: String
    public var created: Date
    public var expires: Date?
    public var size: Int

    public func isExpired(_ now: Date) -> Bool { expires.map { $0 <= now } ?? false }
}

public protocol ShareStorage: Sendable {
    func put(_ id: String, _ data: Data, _ meta: ShareMeta) async throws
    func get(_ id: String) async throws -> Data?
    func meta(_ id: String) async throws -> ShareMeta?
    func delete(_ id: String) async throws
    /// Every stored share's id (the expiry sweep).
    func ids() async throws -> [String]
}

enum MetaCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Shares as files: `<id>.onx` and `<id>.json` in one directory (a Docker volume).
public struct DiskStorage: ShareStorage {
    public let directory: URL

    public init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func file(_ id: String, _ ext: String) -> URL { directory.appendingPathComponent("\(id).\(ext)") }

    public func put(_ id: String, _ data: Data, _ meta: ShareMeta) async throws {
        try data.write(to: file(id, "onx"), options: .atomic)
        try MetaCoding.encoder.encode(meta).write(to: file(id, "json"), options: .atomic)
    }

    public func get(_ id: String) async throws -> Data? { try? Data(contentsOf: file(id, "onx")) }

    public func meta(_ id: String) async throws -> ShareMeta? {
        guard let d = try? Data(contentsOf: file(id, "json")) else { return nil }
        return try MetaCoding.decoder.decode(ShareMeta.self, from: d)
    }

    public func delete(_ id: String) async throws {
        try? FileManager.default.removeItem(at: file(id, "onx"))
        try? FileManager.default.removeItem(at: file(id, "json"))
    }

    public func ids() async throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.map {
            String($0.dropLast(5))
        }
    }
}

/// Shares in memory (tests, and trying the server out).
public actor MemoryStorage: ShareStorage {
    var data: [String: Data] = [:]
    var metas: [String: ShareMeta] = [:]
    public init() {}
    public func put(_ id: String, _ d: Data, _ meta: ShareMeta) {
        data[id] = d
        metas[id] = meta
    }
    public func get(_ id: String) -> Data? { data[id] }
    public func meta(_ id: String) -> ShareMeta? { metas[id] }
    public func delete(_ id: String) {
        data[id] = nil
        metas[id] = nil
    }
    public func ids() -> [String] { metas.keys.sorted() }
}
