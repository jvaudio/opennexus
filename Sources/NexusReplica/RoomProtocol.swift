import CryptoKit
import Foundation
import NexusCore
import NexusFormat

/// What a client and the relay say over a room's WebSocket (M46): JSON text frames. Every
/// `data` is a sealed envelope (D331) in base64, so the relay sees only the frame's own
/// fields: sequence numbers, member ids and sizes.
///
/// Client → relay: `hello` (a capability and the last sequence it has), `ops` (numbered by
/// the client, for the ack), `presence`, `snapshot` (the state up to a sequence) and `view`
/// (the join page's viewer bundle). Relay → client: `welcome`, `ops` (numbered by the
/// relay), `ack`, `presence`, `joined`, `left`, `snapshot` (send one, please), `ended` and
/// `error`.
public enum ClientFrame: Equatable, Sendable {
    case hello(cap: String, since: Int)
    case ops(id: Int, data: Data)
    case presence(Data)
    case snapshot(seq: Int, data: Data)
    case view(Data)

    public var json: JSONValue {
        switch self {
        case .hello(let cap, let since):
            .object(["t": "hello", "v": 1, "cap": .string(cap), "since": .number(Double(since))])
        case .ops(let id, let data):
            .object(["t": "ops", "id": .number(Double(id)), "data": .string(data.base64EncodedString())])
        case .presence(let data): .object(["t": "presence", "data": .string(data.base64EncodedString())])
        case .snapshot(let seq, let data):
            .object(["t": "snapshot", "seq": .number(Double(seq)), "data": .string(data.base64EncodedString())])
        case .view(let data): .object(["t": "view", "data": .string(data.base64EncodedString())])
        }
    }

    public var text: String { CanonicalJSON.compact(json) }

    public init?(text: String) {
        guard let o = try? CanonicalJSON.parse(Data(text.utf8)).objectValue, let t = o["t"]?.stringValue else {
            return nil
        }
        let data = o["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        switch t {
        case "hello":
            guard let cap = o["cap"]?.stringValue, let since = Frame.int(o["since"]) else { return nil }
            self = .hello(cap: cap, since: since)
        case "ops":
            guard let id = Frame.int(o["id"]), let data else { return nil }
            self = .ops(id: id, data: data)
        case "presence":
            guard let data else { return nil }
            self = .presence(data)
        case "snapshot":
            guard let seq = Frame.int(o["seq"]), let data else { return nil }
            self = .snapshot(seq: seq, data: data)
        case "view":
            guard let data else { return nil }
            self = .view(data)
        default: return nil
        }
    }
}

public enum RelayFrame: Equatable, Sendable {
    public struct Sequenced: Equatable, Sendable {
        public var seq: Int
        public var member: String
        public var data: Data
        public init(seq: Int, member: String, data: Data) {
            self.seq = seq
            self.member = member
            self.data = data
        }
    }

    public struct Welcome: Equatable, Sendable {
        public var role: RoomClient.Role
        /// This connection's member id.
        public var member: String
        /// Everyone else connected.
        public var members: [String]
        /// The stored snapshot and the sequence it covers, when the client is behind it.
        public var snapshot: (seq: Int, data: Data)?
        /// Op batches after the snapshot (or after the client's `since`).
        public var ops: [Sequenced]
        /// The room's latest sequence.
        public var seq: Int

        public init(
            role: RoomClient.Role, member: String, members: [String], snapshot: (seq: Int, data: Data)?,
            ops: [Sequenced], seq: Int
        ) {
            self.role = role
            self.member = member
            self.members = members
            self.snapshot = snapshot
            self.ops = ops
            self.seq = seq
        }

        public static func == (a: Welcome, b: Welcome) -> Bool {
            a.role == b.role && a.member == b.member && a.members == b.members && a.snapshot?.seq == b.snapshot?.seq
                && a.snapshot?.data == b.snapshot?.data && a.ops == b.ops && a.seq == b.seq
        }
    }

    case welcome(Welcome)
    case ops(Sequenced)
    case ack(id: Int, seq: Int)
    case presence(member: String, data: Data)
    case joined(String)
    case left(String)
    /// The relay asks for a snapshot (its tail is long).
    case snapshot
    case ended
    case error(code: String, message: String)

    public init?(text: String) {
        guard let o = try? CanonicalJSON.parse(Data(text.utf8)).objectValue, let t = o["t"]?.stringValue else {
            return nil
        }
        func sequenced(_ v: JSONValue?) -> Sequenced? {
            guard let o = v?.objectValue, let seq = Frame.int(o["seq"]), let m = o["member"]?.stringValue,
                let d = o["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            return Sequenced(seq: seq, member: m, data: d)
        }
        switch t {
        case "welcome":
            guard let role = o["role"]?.stringValue.flatMap(RoomClient.Role.init(rawValue:)),
                let member = o["member"]?.stringValue, let seq = Frame.int(o["seq"])
            else { return nil }
            let members = o["members"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var snapshot: (Int, Data)?
            if let s = o["snapshot"]?.objectValue, let n = Frame.int(s["seq"]),
                let d = s["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) })
            {
                snapshot = (n, d)
            }
            let ops = o["ops"]?.arrayValue?.compactMap(sequenced) ?? []
            self = .welcome(
                Welcome(role: role, member: member, members: members, snapshot: snapshot, ops: ops, seq: seq))
        case "ops":
            guard let s = sequenced(.object(o)) else { return nil }
            self = .ops(s)
        case "ack":
            guard let id = Frame.int(o["id"]), let seq = Frame.int(o["seq"]) else { return nil }
            self = .ack(id: id, seq: seq)
        case "presence":
            guard let m = o["member"]?.stringValue, let d = o["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            self = .presence(member: m, data: d)
        case "joined":
            guard let m = o["member"]?.stringValue else { return nil }
            self = .joined(m)
        case "left":
            guard let m = o["member"]?.stringValue else { return nil }
            self = .left(m)
        case "snapshot": self = .snapshot
        case "ended": self = .ended
        case "error":
            self = .error(code: o["code"]?.stringValue ?? "error", message: o["message"]?.stringValue ?? "")
        default: return nil
        }
    }

    public var json: JSONValue {
        func seq(_ s: Sequenced) -> JSONValue {
            .object([
                "seq": .number(Double(s.seq)), "member": .string(s.member),
                "data": .string(s.data.base64EncodedString()),
            ])
        }
        switch self {
        case .welcome(let w):
            var o: [String: JSONValue] = [
                "t": "welcome", "role": .string(w.role.rawValue), "member": .string(w.member),
                "members": .array(w.members.map { .string($0) }), "ops": .array(w.ops.map(seq)),
                "seq": .number(Double(w.seq)),
            ]
            if let s = w.snapshot {
                o["snapshot"] = .object(["seq": .number(Double(s.seq)), "data": .string(s.data.base64EncodedString())])
            }
            return .object(o)
        case .ops(let s):
            guard case .object(var o) = seq(s) else { return .null }
            o["t"] = "ops"
            return .object(o)
        case .ack(let id, let s): return .object(["t": "ack", "id": .number(Double(id)), "seq": .number(Double(s))])
        case .presence(let m, let d):
            return .object(["t": "presence", "member": .string(m), "data": .string(d.base64EncodedString())])
        case .joined(let m): return .object(["t": "joined", "member": .string(m)])
        case .left(let m): return .object(["t": "left", "member": .string(m)])
        case .snapshot: return .object(["t": "snapshot"])
        case .ended: return .object(["t": "ended"])
        case .error(let c, let m): return .object(["t": "error", "code": .string(c), "message": .string(m)])
        }
    }

    public var text: String { CanonicalJSON.compact(json) }
}

enum Frame {
    static func int(_ v: JSONValue?) -> Int? {
        guard case .number(let n)? = v, n.isFinite, n == n.rounded(), n >= 0, n < 9e15 else { return nil }
        return Int(n)
    }
}

// MARK: Sealed payloads

/// Someone in the room: who, in which colour, and where they are.
public struct Presence: Equatable, Sendable {
    public var replica: String
    public var name: String
    /// `#rrggbb`, from the replica id.
    public var colour: String
    public var canvas: String?
    public var selection: [String]
    /// The topic they're typing in.
    public var editing: String?
    /// The visible part of the canvas: x, y, width, height.
    public var viewport: [Double]?
    public var pointer: [Double]?

    public init(
        replica: String, name: String, colour: String? = nil, canvas: String? = nil, selection: [String] = [],
        editing: String? = nil, viewport: [Double]? = nil, pointer: [Double]? = nil
    ) {
        self.replica = replica
        self.name = name
        self.colour = colour ?? Self.colour(for: replica)
        self.canvas = canvas
        self.selection = selection
        self.editing = editing
        self.viewport = viewport
        self.pointer = pointer
    }

    /// Eight colours that read on light and dark canvases, and against each other.
    public static let palette = [
        "#d9480f", "#1971c2", "#2f9e44", "#ae3ec9", "#e8590c", "#0c8599", "#c2255c", "#5c940d",
    ]

    public static func colour(for replica: String) -> String {
        let h = Array(SHA256.hash(data: Data(replica.utf8)))[0]
        return palette[Int(h) % palette.count]
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "replica": .string(replica), "name": .string(name), "colour": .string(colour),
            "selection": .array(selection.map { .string($0) }),
        ]
        if let canvas { o["canvas"] = .string(canvas) }
        if let editing { o["editing"] = .string(editing) }
        if let viewport { o["viewport"] = .array(viewport.map { .number($0) }) }
        if let pointer { o["pointer"] = .array(pointer.map { .number($0) }) }
        return .object(o)
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue, let replica = o["replica"]?.stringValue, let name = o["name"]?.stringValue
        else { return nil }
        self.replica = replica
        self.name = String(name.prefix(80))
        let c = o["colour"]?.stringValue ?? ""
        colour = Self.palette.contains(c) ? c : Self.colour(for: replica)
        canvas = o["canvas"]?.stringValue
        selection = o["selection"]?.arrayValue?.compactMap(\.stringValue) ?? []
        editing = o["editing"]?.stringValue
        func numbers(_ v: JSONValue?, _ n: Int) -> [Double]? {
            guard let a = v?.arrayValue, a.count == n else { return nil }
            let d = a.compactMap { v -> Double? in if case .number(let x) = v, x.isFinite { x } else { nil } }
            return d.count == n ? d : nil
        }
        viewport = numbers(o["viewport"], 4)
        pointer = numbers(o["pointer"], 2)
    }
}

/// Sealing and opening the room's messages with the room key. Each kind has its own
/// content type in the envelope's header, so one can't be passed off as another.
public enum RoomSeal {
    public static let opsType = "application/vnd.opennexus.ops+json"
    public static let presenceType = "application/vnd.opennexus.presence+json"
    public static let snapshotType = "application/vnd.opennexus.snapshot+json"

    public static func seal(_ json: JSONValue, type: String, key: SymmetricKey, deflate: Bool = true) throws -> Data {
        let raw = Data(CanonicalJSON.compact(json).utf8)
        return try Sealed.seal(
            deflate ? Sealed.deflate(raw) : raw,
            header: .init(type: type, encoding: deflate ? Sealed.deflate : nil, bundle: nil), key: key)
    }

    public static func open(_ data: Data, type: String, key: SymmetricKey) throws -> JSONValue {
        let (header, content) = try Sealed.open(data, key: key)
        guard header.type == type else { throw Sealed.SealError.damaged }
        let raw = header.encoding == Sealed.deflate ? try Sealed.inflate(content) : content
        guard let json = try? CanonicalJSON.parse(raw) else { throw Sealed.SealError.damaged }
        return json
    }

    /// An op batch: `{replica, seq, ops}`.
    public static func sealOps(_ ops: [Op], replica: String, seq: Int, key: SymmetricKey) throws -> Data {
        try seal(
            .object(["replica": .string(replica), "seq": .number(Double(seq)), "ops": Op.encode(ops)]), type: opsType,
            key: key)
    }

    public static func openOps(_ data: Data, key: SymmetricKey) throws -> [Op] {
        guard let ops = try open(data, type: opsType, key: key)["ops"].flatMap(Op.decode) else {
            throw Sealed.SealError.damaged
        }
        return ops
    }

    public static func sealSnapshot(_ ops: [Op], key: SymmetricKey) throws -> Data {
        try seal(.object(["ops": Op.encode(ops)]), type: snapshotType, key: key)
    }

    public static func openSnapshot(_ data: Data, key: SymmetricKey) throws -> [Op] {
        guard let ops = try open(data, type: snapshotType, key: key)["ops"].flatMap(Op.decode) else {
            throw Sealed.SealError.damaged
        }
        return ops
    }

    public static func sealPresence(_ p: Presence, key: SymmetricKey) throws -> Data {
        try seal(p.json, type: presenceType, key: key, deflate: false)
    }

    public static func openPresence(_ data: Data, key: SymmetricKey) throws -> Presence {
        guard let p = Presence(json: try open(data, type: presenceType, key: key)) else {
            throw Sealed.SealError.damaged
        }
        return p
    }
}
