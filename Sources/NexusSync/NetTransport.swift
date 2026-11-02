import Foundation
import NexusFormat

/// A library's bucket through the network service (`OpenNexusNet.xpc`): each operation is
/// one `NetJob`, and every request it made comes back for the Privacy log.
public struct NetSyncTransport: SyncTransport {
    public typealias Send = @Sendable (NetJob, Data) async -> (reply: NetReply, body: Data)

    public var destination: ShareDestination
    public var secret: String
    /// The hosts sync may reach: every library's.
    public var allowedHosts: [String]
    public var purpose: String
    let send: Send
    let onLog: @Sendable ([NetLogEntry]) -> Void

    public init(
        destination: ShareDestination, secret: String, allowedHosts: [String], purpose: String = "Sync",
        send: @escaping Send, onLog: @escaping @Sendable ([NetLogEntry]) -> Void = { _ in }
    ) {
        self.destination = destination
        self.secret = secret
        self.allowedHosts = allowedHosts
        self.purpose = purpose
        self.send = send
        self.onLog = onLog
    }

    func job(_ action: NetJob.Action, _ object: String, ifMatch: String? = nil, ifNoneMatch: String? = nil) -> NetJob {
        NetJob(
            action: action, purpose: purpose, destination: destination, secret: secret, allowedHosts: allowedHosts,
            object: object, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
    }

    func run(_ job: NetJob, _ body: Data = Data()) async throws -> (reply: NetReply, body: Data) {
        let r = await send(job, body)
        onLog(r.reply.log)
        guard r.reply.ok else { throw SyncError.transport(r.reply.error ?? "The bucket didn’t answer.") }
        return r
    }

    public func get(_ key: String, ifNoneMatch: String?) async throws -> SyncGet {
        let r = try await run(job(.get, key, ifNoneMatch: ifNoneMatch))
        switch r.reply.status {
        case 304: return .notModified
        case 404: return .missing
        default: return .found(r.body, etag: r.reply.etag ?? "")
        }
    }

    public func put(_ key: String, _ data: Data, condition: SyncCondition) async throws -> SyncPut {
        let j: NetJob =
            switch condition {
            case .none: job(.put, key)
            case .ifMatch(let e): job(.put, key, ifMatch: e)
            case .ifNoneMatch: job(.put, key, ifNoneMatch: "*")
            }
        let r = try await run(j, data)
        return r.reply.status == 412 ? .conditionFailed : .stored(etag: r.reply.etag ?? "")
    }

    public func delete(_ key: String) async throws {
        _ = try await run(job(.delete, destination.objectKey(key)))
    }

    public func list(_ prefix: String) async throws -> [String] {
        try await run(job(.list, prefix)).reply.keys ?? []
    }

    /// Checks the bucket: the reply's `detail` and `conditionalWrites`.
    public func test() async -> NetReply {
        let r = await send(job(.syncTest, ""), Data())
        onLog(r.reply.log)
        return r.reply
    }
}
