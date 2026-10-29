import Foundation

/// A bucket as sync needs it (M45): objects by key under the library's prefix, ETags, and
/// conditional writes. The app's goes through the network service (`NetSyncTransport`);
/// tests use `MemoryBucket`.
public protocol SyncTransport: Sendable {
    /// The object and its ETag. With `ifNoneMatch` (an ETag), `.notModified` when unchanged.
    func get(_ key: String, ifNoneMatch: String?) async throws -> SyncGet
    func put(_ key: String, _ data: Data, condition: SyncCondition) async throws -> SyncPut
    /// Deleting what isn't there is not an error.
    func delete(_ key: String) async throws
    /// Every key under `prefix`.
    func list(_ prefix: String) async throws -> [String]
}

public enum SyncGet: Sendable, Equatable {
    case found(Data, etag: String)
    case missing
    case notModified
}

public enum SyncCondition: Sendable, Equatable {
    case none
    /// Replace only this version (`If-Match`).
    case ifMatch(String)
    /// Create only (`If-None-Match: *`).
    case ifNoneMatch
}

public enum SyncPut: Sendable, Equatable {
    case stored(etag: String)
    /// Someone else wrote first.
    case conditionFailed
}

public enum SyncError: Error, Equatable, CustomStringConvertible {
    /// The bucket couldn't be reached or refused the request.
    case transport(String)
    /// The library's records don't open with this Mac's key.
    case wrongKey
    /// The library is encrypted and this Mac has no key, or the other way round.
    case encryptionMismatch(remoteEncrypted: Bool)
    /// Written by a newer OpenNexus.
    case newer(Int)
    case damaged(String)
    /// The package was saved on this Mac while sync worked on it (it starts again from the save).
    case changedHere

    public var description: String {
        switch self {
        case .transport(let why): why
        case .wrongKey: "This Mac’s recovery key doesn’t open this library."
        case .encryptionMismatch(let remote):
            remote
                ? "This library is encrypted: enter its recovery key."
                : "This library isn’t encrypted: turn encryption off for it."
        case .newer(let v): "This library was synced by a newer OpenNexus (version \(v))."
        case .damaged(let what): "Something in the library is damaged: \(what)."
        case .changedHere: "It changed on this Mac while syncing; it will sync next time."
        }
    }
}

/// A bucket in memory that honours conditions as S3 does, counts requests, and can fail on
/// cue (tests).
public actor MemoryBucket: SyncTransport {
    public struct Request: Equatable, Sendable {
        public var method: String
        public var key: String
        public var bytes: Int
    }

    public private(set) var objects: [String: (data: Data, etag: String)] = [:]
    public private(set) var requests: [Request] = []
    /// Off: conditions are ignored, as some providers do.
    public var honoursConditions: Bool
    /// Fails a request instead of doing it (a crash or a dropped connection).
    var failing: (@Sendable (Request) -> Bool)?
    var counter = 0

    public init(honoursConditions: Bool = true) {
        self.honoursConditions = honoursConditions
    }

    public func fail(when f: (@Sendable (Request) -> Bool)?) { failing = f }
    public func setHonoursConditions(_ on: Bool) { honoursConditions = on }
    public func resetRequests() { requests = [] }
    public var keys: [String] { objects.keys.sorted() }
    public func data(_ key: String) -> Data? { objects[key]?.data }

    func record(_ method: String, _ key: String, _ bytes: Int = 0) throws {
        let r = Request(method: method, key: key, bytes: bytes)
        if let failing, failing(r) { throw SyncError.transport("The test bucket failed \(method) \(key).") }
        requests.append(r)
    }

    public func get(_ key: String, ifNoneMatch: String?) async throws -> SyncGet {
        try record("GET", key)
        guard let o = objects[key] else { return .missing }
        if let ifNoneMatch, ifNoneMatch == o.etag { return .notModified }
        return .found(o.data, etag: o.etag)
    }

    public func put(_ key: String, _ data: Data, condition: SyncCondition) async throws -> SyncPut {
        try record("PUT", key, data.count)
        if honoursConditions {
            switch condition {
            case .none: break
            case .ifMatch(let e): if objects[key]?.etag != e { return .conditionFailed }
            case .ifNoneMatch: if objects[key] != nil { return .conditionFailed }
            }
        }
        counter += 1
        let etag = "\"\(counter)\""
        objects[key] = (data, etag)
        return .stored(etag: etag)
    }

    public func delete(_ key: String) async throws {
        try record("DELETE", key)
        objects[key] = nil
    }

    public func list(_ prefix: String) async throws -> [String] {
        try record("LIST", prefix)
        return objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
