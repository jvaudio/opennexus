import Foundation
import NexusCore
import NexusFormat

/// A replica saved in the app container between launches (M46, A8): its id, its clock and
/// its state as a snapshot. Undo history isn't kept, as the app's isn't across launches.
extension Replica {
    public enum DecodingError: Error { case unreadable }

    public func encoded() throws -> Data {
        let o: JSONValue = .object([
            "format": .string("opennexus-replica"), "version": .number(1), "id": .string(id),
            "clock": .string(clock.last.code), "ops": Op.encode(snapshot()),
        ])
        return Data(CanonicalJSON.compact(o).utf8)
    }

    public init(decoding data: Data, now: (@Sendable () -> Int64)? = nil) throws {
        guard let o = try? CanonicalJSON.parse(data).objectValue, o["format"] == .string("opennexus-replica"),
            let id = o["id"]?.stringValue, ReplicaID.isValid(id), let c = o["clock"]?.stringValue,
            let last = Stamp(code: c), let opsJSON = o["ops"], let ops = Op.decode(opsJSON)
        else { throw DecodingError.unreadable }
        self.init(id: id, clock: HybridClock(replica: id, now: now ?? HybridClock.wallClock))
        _ = receive(ops)
        clock.observe(last)
    }
}
