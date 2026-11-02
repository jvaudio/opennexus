import Foundation
import NexusCore

/// A register: one value that the last writer (by stamp) sets.
public enum Slot: Hashable, Sendable {
    /// A top-level key of the document theme (`theme.json`).
    case theme(String)
    /// A top-level key of a canvas's settings (`title`, `type`, `root`, `legend`, …).
    case canvas(CanvasID, String)
    /// A key inside one of the canvas objects merged key by key (`layout`, `style`, …).
    case part(CanvasID, String, String)
    /// A topic's field (any key of its JSON but `children` and `comments`).
    case field(CanvasID, NodeID, String)
    /// An element's field: kind (`relationships`, …), id, key.
    case element(CanvasID, String, String, String)
    /// A comment's whole value, by the key its place has.
    case comment(CanvasID, NodeID, String)
}

/// A member of an ordered set, with its position (nil: removed).
public enum PlaceSlot: Hashable, Sendable {
    /// A canvas and its place in the tab order.
    case canvas(CanvasID)
    /// An element on a canvas: kind, id.
    case element(CanvasID, String, String)
    /// A comment on a topic, by a key from its content.
    case comment(CanvasID, NodeID, String)
}

/// Where a topic sits in its canvas's tree.
public enum Parent: Hashable, Sendable {
    case node(NodeID)
    /// The canvas's root topic sits here.
    case root
    /// Floating topics.
    case floating
    /// Summary and callout topics (their element says where they go).
    case attached
    /// Deleted topics, so undoing a delete is a move back.
    case trash

    var code: String {
        switch self {
        case .node(let id): id.rawValue
        case .root: "^root"
        case .floating: "^floating"
        case .attached: "^attached"
        case .trash: "^trash"
        }
    }

    init(code: String) {
        switch code {
        case "^root": self = .root
        case "^floating": self = .floating
        case "^attached": self = .attached
        case "^trash": self = .trash
        default: self = .node(NodeID(code))
        }
    }
}

/// One change in a session. Ops commute: a replica's state is a function of the set of
/// ops it has, whatever order they came in and however often.
public struct Op: Hashable, Sendable {
    public enum Change: Hashable, Sendable {
        /// Sets a register (nil: removes the key).
        case set(Slot, JSONValue?)
        /// Moves a topic (Kleppmann's move: applied in stamp order; a move that would make a
        /// cycle does nothing).
        case move(CanvasID, NodeID, Parent, String)
        /// Places an item in an ordered set at a position, or removes it (nil).
        case place(PlaceSlot, String?)
        /// Adds an asset (content-addressed, never removed).
        case asset(String, Data)
    }

    public var stamp: Stamp
    public var change: Change

    public init(_ stamp: Stamp, _ change: Change) {
        self.stamp = stamp
        self.change = change
    }
}

// MARK: Encoding

/// Ops as compact JSON arrays: `["s", stamp, slot…, value]`, `["m", stamp, canvas, node,
/// parent, position]`, `["p", stamp, place…, position]`, `["a", stamp, name, base64]`.
extension Op {
    public var json: JSONValue {
        let s = JSONValue.string(stamp.code)
        switch change {
        case .set(let slot, let v):
            return .array([.string("s"), s] + slot.json + [v.map { .array([$0]) } ?? .null])
        case .move(let c, let n, let p, let k):
            return .array([.string("m"), s, .string(c.rawValue), .string(n.rawValue), .string(p.code), .string(k)])
        case .place(let slot, let k):
            return .array([.string("p"), s] + slot.json + [k.map(JSONValue.string) ?? .null])
        case .asset(let name, let data):
            return .array([.string("a"), s, .string(name), .string(data.base64EncodedString())])
        }
    }

    public init?(json: JSONValue) {
        guard let a = json.arrayValue, a.count >= 3, let kind = a[0].stringValue, let code = a[1].stringValue,
            let stamp = Stamp(code: code)
        else { return nil }
        let rest = Array(a[2...])
        switch kind {
        case "s":
            guard let last = rest.last, let slot = Slot(json: rest.dropLast()) else { return nil }
            let value: JSONValue?
            if last == .null {
                value = nil
            } else if let w = last.arrayValue, w.count == 1 {
                value = w[0]
            } else {
                return nil
            }
            self.init(stamp, .set(slot, value))
        case "m":
            guard rest.count == 4, let c = rest[0].stringValue, let n = rest[1].stringValue,
                let p = rest[2].stringValue, let k = rest[3].stringValue
            else { return nil }
            self.init(stamp, .move(CanvasID(c), NodeID(n), Parent(code: p), k))
        case "p":
            guard let last = rest.last, let slot = PlaceSlot(json: rest.dropLast()) else { return nil }
            if last == .null {
                self.init(stamp, .place(slot, nil))
            } else {
                guard let k = last.stringValue else { return nil }
                self.init(stamp, .place(slot, k))
            }
        case "a":
            guard rest.count == 2, let name = rest[0].stringValue, let b = rest[1].stringValue,
                let data = Data(base64Encoded: b)
            else { return nil }
            self.init(stamp, .asset(name, data))
        default:
            return nil
        }
    }

    /// A list of ops as one JSON array.
    public static func encode(_ ops: [Op]) -> JSONValue { .array(ops.map(\.json)) }

    /// Nil if any op is unreadable.
    public static func decode(_ json: JSONValue) -> [Op]? {
        guard let a = json.arrayValue else { return nil }
        var out: [Op] = []
        out.reserveCapacity(a.count)
        for v in a {
            guard let op = Op(json: v) else { return nil }
            out.append(op)
        }
        return out
    }
}

extension Slot {
    var json: [JSONValue] {
        switch self {
        case .theme(let k): [.string("t"), .string(k)]
        case .canvas(let c, let k): [.string("c"), .string(c.rawValue), .string(k)]
        case .part(let c, let p, let k): [.string("pt"), .string(c.rawValue), .string(p), .string(k)]
        case .field(let c, let n, let k): [.string("f"), .string(c.rawValue), .string(n.rawValue), .string(k)]
        case .element(let c, let kind, let id, let k):
            [.string("e"), .string(c.rawValue), .string(kind), .string(id), .string(k)]
        case .comment(let c, let n, let k): [.string("cm"), .string(c.rawValue), .string(n.rawValue), .string(k)]
        }
    }

    init?(json: ArraySlice<JSONValue>) {
        let s = json.compactMap(\.stringValue)
        guard s.count == json.count, let tag = s.first else { return nil }
        switch (tag, s.count) {
        case ("t", 2): self = .theme(s[1])
        case ("c", 3): self = .canvas(CanvasID(s[1]), s[2])
        case ("pt", 4): self = .part(CanvasID(s[1]), s[2], s[3])
        case ("f", 4): self = .field(CanvasID(s[1]), NodeID(s[2]), s[3])
        case ("e", 5): self = .element(CanvasID(s[1]), s[2], s[3], s[4])
        case ("cm", 4): self = .comment(CanvasID(s[1]), NodeID(s[2]), s[3])
        default: return nil
        }
    }
}

extension PlaceSlot {
    var json: [JSONValue] {
        switch self {
        case .canvas(let c): [.string("c"), .string(c.rawValue)]
        case .element(let c, let kind, let id): [.string("e"), .string(c.rawValue), .string(kind), .string(id)]
        case .comment(let c, let n, let k): [.string("cm"), .string(c.rawValue), .string(n.rawValue), .string(k)]
        }
    }

    init?(json: ArraySlice<JSONValue>) {
        let s = json.compactMap(\.stringValue)
        guard s.count == json.count, let tag = s.first else { return nil }
        switch (tag, s.count) {
        case ("c", 2): self = .canvas(CanvasID(s[1]))
        case ("e", 4): self = .element(CanvasID(s[1]), s[2], s[3])
        case ("cm", 4): self = .comment(CanvasID(s[1]), NodeID(s[2]), s[3])
        default: return nil
        }
    }
}
