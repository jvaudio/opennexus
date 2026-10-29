import Foundation
import NexusFormat

/// Everything `OpenNexusNet.xpc` does: one job in, one reply out, with a log entry for
/// every request it made. The XPC wrapper only decodes and forwards, so this is what the
/// tests exercise.
public struct NetService: Sendable {
    /// A stub for the network (tests); nil uses it.
    nonisolated(unsafe) public var protocolClasses: [AnyClass]?

    public init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    public func perform(_ job: NetJob, body: Data) async -> NetReply {
        await exchange(job, body: body).reply
    }

    /// The reply, and the bytes a `get` read.
    public func exchange(_ job: NetJob, body: Data) async -> (reply: NetReply, body: Data) {
        let client = HTTPClient(allowed: job.allowedHosts, purpose: job.purpose, protocolClasses: protocolClasses)
        var out = Data()
        do {
            // The destination itself must be on the list: nothing is sent otherwise.
            for host in job.destination.hosts where !job.allowedHosts.map({ $0.lowercased() }).contains(host) {
                throw NetError.notAllowed(host)
            }
            guard job.destination.isComplete else { throw NetError.unexpected("the destination isn’t set up") }
            let target = Self.target(job)
            var reply = NetReply(ok: true)
            switch job.action {
            case .create:
                reply = try await target.create(body, expires: job.expires, client: client)
            case .update:
                try await target.update(
                    try object(job), body, writeSecret: job.writeSecret, expires: job.expires, client: client)
            case .delete:
                try await target.delete(try object(job), writeSecret: job.writeSecret, client: client)
            case .test:
                reply.detail = try await target.test(origin: job.origin, client: client)
            case .setUpCORS:
                guard let s3 = target as? S3Target, let origin = job.origin else {
                    throw NetError.unexpected("only buckets have CORS rules")
                }
                try await s3.setUpCORS(origin: origin, client: client)
            case .get, .put, .list, .syncTest:
                guard let s3 = target as? S3Target else { throw NetError.unexpected("only buckets sync libraries") }
                switch job.action {
                case .get:
                    (reply, out) = try await s3.get(try object(job), ifNoneMatch: job.ifNoneMatch, client: client)
                case .put:
                    reply = try await s3.put(
                        try object(job), body, ifMatch: job.ifMatch, ifNoneMatch: job.ifNoneMatch, client: client)
                case .list: reply.keys = try await s3.list(job.object ?? "", client: client)
                default: reply = try await s3.syncTest(client: client)
                }
            }
            reply.log = await client.log
            return (reply, out)
        } catch {
            return (.failed(String(describing: error), log: await client.log), Data())
        }
    }

    func object(_ job: NetJob) throws -> String {
        guard let o = job.object, !o.isEmpty else { throw NetError.unexpected("no object to change") }
        return o
    }

    static func target(_ job: NetJob) -> any ShareTarget {
        switch job.destination.kind {
        case .s3: S3Target(d: job.destination, secret: job.secret)
        case .gist: GistTarget(token: job.secret)
        case .server: ServerTarget(d: job.destination, token: job.secret)
        }
    }
}
