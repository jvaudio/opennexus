import Foundation

/// A point in canvas coordinates. Stored positions are rounded to 0.5 pt so files
/// carry no floating-point noise.
public struct CanvasPoint: Hashable, Sendable, JSONRepresentable {
    public var x: Double
    public var y: Double
    public var extra: [String: JSONValue] = [:]

    public init(x: Double, y: Double) {
        self.x = CanvasPoint.round(x)
        self.y = CanvasPoint.round(y)
    }

    public static func round(_ v: Double) -> Double { (v * 2).rounded() / 2 }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        self.init(x: try r.optionalDouble("x") ?? 0, y: try r.optionalDouble("y") ?? 0)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("x", .number(CanvasPoint.round(x)))
        w.set("y", .number(CanvasPoint.round(y)))
        return w.value
    }
}

public struct Todo: Hashable, Sendable, JSONRepresentable {
    public var done: Bool
    public var extra: [String: JSONValue] = [:]

    public init(done: Bool) { self.done = done }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        done = try r.bool("done", default: false)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("done", .bool(done))
        return w.value
    }
}

public struct Note: Hashable, Sendable, JSONRepresentable {
    public var format: String
    public var text: String
    public var extra: [String: JSONValue] = [:]

    public init(format: String = "md", text: String) {
        self.format = format
        self.text = text
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        format = try r.optionalString("format") ?? "md"
        text = try r.optionalString("text") ?? ""
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("format", format)
        w.set("text", text)
        return w.value
    }
}

/// One topic. Every slot except text, role and children is optional.
public struct Node: Hashable, Sendable {
    public var text: String
    public var kind: NodeRole
    public var children: [NodeID]
    public var folded: Bool = false
    public var markers: [String] = []
    public var labels: [String] = []
    public var todo: Todo?
    public var note: Note?
    public var link: String?
    /// Node-level style override (highest priority in style resolution).
    public var style: TopicStyle?
    /// Applied quick style id (`very-important`, `done`, … or a custom one).
    public var quickStyle: String?
    /// Key-value fields (Data tab).
    public var metadata: [MetadataField] = []
    /// Created by AI and not yet edited by the user (shows a sparkle).
    public var ai: Bool = false
    /// Per-branch structure override (Option-Command-1…9).
    public var structure: LayoutStructure?
    /// Position for floating topics and free layout.
    public var position: CanvasPoint?
    /// Keys this version does not understand, written back unchanged.
    public var extra: [String: JSONValue] = [:]

    public init(text: String, kind: NodeRole = .topic, children: [NodeID] = []) {
        self.text = text
        self.kind = kind
        self.children = children
    }

    /// The priority marker (1–9), if any, stored as `priority-N`.
    public var priority: Int? {
        get {
            markers.lazy.compactMap { m -> Int? in
                guard m.hasPrefix("priority-") else { return nil }
                return Int(m.dropFirst("priority-".count))
            }.first
        }
        set {
            markers.removeAll { $0.hasPrefix("priority-") }
            if let newValue { markers.insert("priority-\(newValue)", at: 0) }
        }
    }
}

extension Node: JSONRepresentable {
    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        text = try r.optionalString("text") ?? ""
        kind = NodeRole(rawValue: try r.optionalString("kind") ?? "topic")
        children = try r.strings("children").map { NodeID($0) }
        folded = try r.bool("folded", default: false)
        markers = try r.strings("markers")
        labels = try r.strings("labels")
        if let t = r.raw("todo"), t != .null { todo = try Todo(json: t, path: "\(path).todo") }
        if let n = r.raw("note"), n != .null { note = try Note(json: n, path: "\(path).note") }
        link = try r.optionalString("link")
        if let s = r.raw("style"), s != .null {
            let st = try TopicStyle(json: s, path: "\(path).style")
            style = st.isEmpty ? nil : st
        }
        quickStyle = try r.optionalString("quickStyle")
        metadata = try r.array("metadata").enumerated().map {
            try MetadataField(json: $1, path: "\(path).metadata[\($0)]")
        }
        ai = try r.bool("ai", default: false)
        structure = try r.optionalString("structure").map(LayoutStructure.init(rawValue:))
        if let p = r.raw("position"), p != .null { position = try CanvasPoint(json: p, path: "\(path).position") }
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("text", text)
        w.set("kind", kind.rawValue)
        w.set("children", children.map(\.rawValue), omitEmpty: false)
        w.set("folded", folded, omitting: false)
        w.set("markers", markers, omitEmpty: true)
        w.set("labels", labels, omitEmpty: true)
        if let todo { w.set("todo", todo.json) }
        if let note { w.set("note", note.json) }
        w.set("link", link)
        if let style, !style.isEmpty { w.set("style", style.json) }
        w.set("quickStyle", quickStyle)
        if !metadata.isEmpty { w.set("metadata", .array(metadata.map(\.json))) }
        w.set("ai", ai, omitting: false)
        w.set("structure", structure?.rawValue)
        if let position { w.set("position", position.json) }
        return w.value
    }
}

/// A free connector between two nodes (Xmind's Relationship, a technical diagram's edge).
public struct Relationship: Hashable, Sendable, JSONRepresentable {
    public var id: String
    public var from: NodeID
    public var to: NodeID
    public var label: String
    public var line: String
    public var ends: [String]
    public var extra: [String: JSONValue] = [:]

    public init(
        id: String, from: NodeID, to: NodeID, label: String = "", line: String = "curved",
        ends: [String] = ["none", "arrow"]
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.line = line
        self.ends = ends
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        from = NodeID(try r.string("from"))
        to = NodeID(try r.string("to"))
        label = try r.optionalString("label") ?? ""
        line = try r.optionalString("line") ?? "curved"
        let e = try r.strings("ends")
        ends = e.isEmpty ? ["none", "arrow"] : e
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("from", from.rawValue)
        w.set("to", to.rawValue)
        w.set("label", label)
        w.set("line", line)
        w.set("ends", ends, omitEmpty: false)
        return w.value
    }
}
