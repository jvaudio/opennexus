import Foundation

/// When an op happened, as a hybrid logical clock: wall-clock milliseconds, a counter for
/// ops in the same millisecond (or while the clock runs ahead of the wall), and the replica
/// that made it. Stamps order every op in a session totally, and the same way everywhere.
public struct Stamp: Hashable, Comparable, Sendable {
    public var time: Int64
    public var count: Int
    public var replica: String

    public init(time: Int64, count: Int, replica: String) {
        self.time = time
        self.count = count
        self.replica = replica
    }

    public static func < (a: Stamp, b: Stamp) -> Bool {
        (a.time, a.count, a.replica) < (b.time, b.count, b.replica)
    }

    /// Before every real stamp (registers nobody has written).
    public static let zero = Stamp(time: 0, count: 0, replica: "")

    /// 16 characters of the position alphabet: the time (7), the counter (3) and the
    /// replica (6). Sorting codes sorts stamps, and a position key ends with one so keys
    /// are unique (`Position`).
    public var code: String {
        Position.encode(UInt64(max(0, time)), width: 7) + Position.encode(UInt64(count), width: 3) + replica
    }

    public init?(code: String) {
        let chars = Array(code.utf8)
        guard chars.count == 16, let t = Position.decode(chars[0..<7]), let c = Position.decode(chars[7..<10]),
            ReplicaID.isValid(String(decoding: chars[10...], as: UTF8.self))
        else { return nil }
        self.init(time: Int64(t), count: Int(c), replica: String(decoding: chars[10...], as: UTF8.self))
    }
}

/// A replica's id: six characters from `0-9a-z`, the last never `0` (so a position key,
/// which ends with one, never ends with the alphabet's first digit; `Position.between`
/// relies on that). New per join; it's also the suffix of ids made during the session.
public enum ReplicaID {
    static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    public static func make() -> String {
        var g = SystemRandomNumberGenerator()
        return make(using: &g)
    }

    public static func make(using g: inout some RandomNumberGenerator) -> String {
        var s = String((0..<5).map { _ in alphabet.randomElement(using: &g)! })
        s.append(alphabet.dropFirst().randomElement(using: &g)!)
        return s
    }

    public static func isValid(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy { alphabet.contains($0) } && s.last != "0"
    }

    /// The suffix for ids made by this replica (`n12-k3x9qa`).
    public static func suffix(_ id: String) -> String { "-" + id }
}

/// The clock that stamps this replica's ops: never behind any stamp it has seen, so an op
/// always sorts after everything its author knew about.
public struct HybridClock: Sendable {
    public let replica: String
    public private(set) var last: Stamp
    /// Milliseconds since 1970 (tests pass a fake).
    var now: @Sendable () -> Int64

    public init(replica: String, now: @escaping @Sendable () -> Int64 = HybridClock.wallClock) {
        self.replica = replica
        self.now = now
        last = Stamp(time: 0, count: 0, replica: replica)
    }

    public static let wallClock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The counter's room: three position digits.
    static let maxCount = 62 * 62 * 62 - 1

    public mutating func tick() -> Stamp {
        let t = now()
        if t > last.time {
            last = Stamp(time: t, count: 0, replica: replica)
        } else if last.count < Self.maxCount {
            last = Stamp(time: last.time, count: last.count + 1, replica: replica)
        } else {
            last = Stamp(time: last.time + 1, count: 0, replica: replica)
        }
        return last
    }

    /// Moves past a stamp from elsewhere.
    public mutating func observe(_ s: Stamp) {
        if (s.time, s.count) > (last.time, last.count) {
            last = Stamp(time: s.time, count: s.count, replica: replica)
        }
    }
}
