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

/// A to-do, and with dates, an owner, progress or dependencies, a task (M11). Every
/// field but `done` is omitted when unset, so a plain to-do is still `{"done": …}`.
public struct Todo: Hashable, Sendable, JSONRepresentable {
    public var done: Bool
    /// First day of work. Calendar dates carry no time or time zone (D142).
    public var start: TaskDate?
    /// Last day of work, inclusive. A task with only `due` is a milestone.
    public var due: TaskDate?
    public var owner: String?
    /// Whole percent, 0–100 (nil is 0; see `Canvas.progress(of:)` for the effective value).
    public var progress: Int?
    /// Tasks this one waits for (stored on the successor, as Xmind does; D144).
    public var after: [TaskDependency] = []
    public var extra: [String: JSONValue] = [:]

    public init(done: Bool) { self.done = done }

    /// True when the to-do carries planning data, so it shows in the Gantt.
    public var isScheduled: Bool { start != nil || due != nil }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        done = try r.bool("done", default: false)
        start = try r.optionalString("start").map { try TaskDate(json: $0, path: "\(path).start") }
        due = try r.optionalString("due").map { try TaskDate(json: $0, path: "\(path).due") }
        owner = try r.optionalString("owner")
        progress = try r.optionalInt("progress", in: 0...100)
        after = try r.array("after").enumerated().map { try TaskDependency(json: $1, path: "\(path).after[\($0)]") }
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("done", .bool(done))
        w.set("start", start?.description)
        w.set("due", due?.description)
        w.set("owner", owner)
        if let progress, progress != 0 { w.set("progress", .number(Double(progress))) }
        if !after.isEmpty { w.set("after", .array(after.map(\.json))) }
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
    /// Rich-text runs over `text` (bold, italic, underline, strikethrough, link).
    public var marks: [TextMark] = []
    /// A sticker (built-in id or asset) shown beside the title.
    public var sticker: AssetRef?
    public var image: AssetRef?
    public var attachments: [AssetRef] = []
    public var audio: AudioNote?
    /// Created by AI and not yet edited by the user (shows a sparkle).
    public var ai: Bool = false
    /// Per-branch structure override (Option-Command-1…9).
    public var structure: LayoutStructure?
    /// Technical node type (process, decision, entity, store, db, …). Nil means the
    /// diagram infers one (`DiagramCatalog.effectiveType`).
    public var nodeType: NodeType?
    /// Label on the tree edge into this node: "Yes" / "No", a data flow, a protocol.
    public var edgeLabel: String?
    /// Swimlane id (`DiagramData.lanes`).
    public var lane: String?
    /// plain (default), math (LaTeX subset) or code.
    public var textFormat: String?
    /// Code block language, for highlighting.
    public var language: String?
    /// A DFD process drilled into (⌘.): the canvas holding its next level.
    public var subCanvas: CanvasID?
    /// Present mode: H hides this topic from slides.
    public var presentHidden: Bool = false
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
        marks = try r.array("marks").enumerated().map { try TextMark(json: $1, path: "\(path).marks[\($0)]") }
        if let st = r.raw("sticker"), st != .null { sticker = try AssetRef(json: st, path: "\(path).sticker") }
        if let im = r.raw("image"), im != .null { image = try AssetRef(json: im, path: "\(path).image") }
        attachments = try r.array("attachments").enumerated().map {
            try AssetRef(json: $1, path: "\(path).attachments[\($0)]")
        }
        if let a = r.raw("audio"), a != .null { audio = try AudioNote(json: a, path: "\(path).audio") }
        ai = try r.bool("ai", default: false)
        structure = try r.optionalString("structure").map(LayoutStructure.init(rawValue:))
        nodeType = try r.optionalString("nodeType").map(NodeType.init(rawValue:))
        edgeLabel = try r.optionalString("edgeLabel")
        lane = try r.optionalString("lane")
        textFormat = try r.optionalString("textFormat")
        language = try r.optionalString("language")
        subCanvas = try r.optionalString("subCanvas").map(CanvasID.init(rawValue:))
        presentHidden = try r.bool("presentHidden", default: false)
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
        if !marks.isEmpty { w.set("marks", .array(marks.map(\.json))) }
        if let sticker { w.set("sticker", sticker.json) }
        if let image { w.set("image", image.json) }
        if !attachments.isEmpty { w.set("attachments", .array(attachments.map(\.json))) }
        if let audio { w.set("audio", audio.json) }
        w.set("ai", ai, omitting: false)
        w.set("structure", structure?.rawValue)
        w.set("nodeType", nodeType?.rawValue)
        w.set("edgeLabel", edgeLabel)
        w.set("lane", lane)
        w.set("textFormat", textFormat)
        w.set("language", language)
        w.set("subCanvas", subCanvas?.rawValue)
        w.set("presentHidden", presentHidden, omitting: false)
        if let position { w.set("position", position.json) }
        return w.value
    }
}

/// One end of a relationship: a topic or a zone (Xmind 26.03 connects both, D160).
public enum RelationshipEnd: Hashable, Sendable, CustomStringConvertible {
    case topic(NodeID)
    case zone(String)

    public var topic: NodeID? {
        if case .topic(let id) = self { return id }
        return nil
    }

    public var zone: String? {
        if case .zone(let id) = self { return id }
        return nil
    }

    /// The id as a file stores it in `from` / `to`.
    public var rawValue: String {
        switch self {
        case .topic(let id): id.rawValue
        case .zone(let id): id
        }
    }

    /// `topic` or `zone`, as a file stores it in `fromKind` / `toKind`.
    public var kind: String { zone == nil ? "topic" : "zone" }

    public init(kind: String?, id: String) {
        self = kind == "zone" ? .zone(id) : .topic(NodeID(id))
    }

    public var description: String { zone.map { "zone \($0)" } ?? rawValue }
}

/// A free connector between two topics or zones (Xmind's Relationship, a technical
/// diagram's edge).
public struct Relationship: Hashable, Sendable, JSONRepresentable {
    public var id: String
    public var from: RelationshipEnd
    public var to: RelationshipEnd
    public var label: String
    /// curved, straight, elbow, zigzag
    public var line: String
    /// Start and end caps: none, arrow, filled-arrow, triangle, diamond, filled-diamond,
    /// dot, open-dot, bar, crows-foot, square.
    public var ends: [String]
    /// solid, dashed, dotted
    public var dash: String = "dashed"
    public var width: Double = 2
    /// `source` (follow the source topic's branch colour), `theme`, or hex.
    public var color: String = "theme"
    /// start, middle, end
    public var labelPosition: String = "middle"
    /// pill, plain, boxed
    public var labelStyle: String = "pill"
    /// Technical type: relationship, dataflow, call, return, message, association…
    public var kind: String?
    /// Offset of the curve's control point from its automatic position (dragged by hand).
    public var bend: CanvasPoint?
    public var extra: [String: JSONValue] = [:]

    public init(
        id: String, from: RelationshipEnd, to: RelationshipEnd, label: String = "", line: String = "curved",
        ends: [String] = ["none", "arrow"]
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.line = line
        self.ends = ends
    }

    /// A relationship between two topics.
    public init(
        id: String, from: NodeID, to: NodeID, label: String = "", line: String = "curved",
        ends: [String] = ["none", "arrow"]
    ) {
        self.init(id: id, from: .topic(from), to: .topic(to), label: label, line: line, ends: ends)
    }

    /// Both topics when neither end is a zone (technical rules and text formats only
    /// know topic-to-topic edges).
    public var topics: (from: NodeID, to: NodeID)? {
        guard let a = from.topic, let b = to.topic else { return nil }
        return (a, b)
    }

    /// The topics among its ends.
    public var endTopics: [NodeID] { [from.topic, to.topic].compactMap(\.self) }

    /// The zones among its ends.
    public var endZones: [String] { [from.zone, to.zone].compactMap(\.self) }

    /// True when either end is the topic.
    public func touches(_ id: NodeID) -> Bool { from == .topic(id) || to == .topic(id) }

    /// True when either end is the zone.
    public func touches(zone id: String) -> Bool { from == .zone(id) || to == .zone(id) }

    /// True when both ends are topics in `keep`.
    public func connects(within keep: Set<NodeID>) -> Bool {
        guard let (a, b) = topics else { return false }
        return keep.contains(a) && keep.contains(b)
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        from = RelationshipEnd(kind: try r.optionalString("fromKind"), id: try r.string("from"))
        to = RelationshipEnd(kind: try r.optionalString("toKind"), id: try r.string("to"))
        label = try r.optionalString("label") ?? ""
        line = try r.optionalString("line") ?? "curved"
        let e = try r.strings("ends")
        ends = e.count == 2 ? e : ["none", "arrow"]
        dash = try r.optionalString("dash") ?? "dashed"
        width = try r.optionalDouble("width") ?? 2
        color = try r.optionalString("color") ?? "theme"
        labelPosition = try r.optionalString("labelPosition") ?? "middle"
        labelStyle = try r.optionalString("labelStyle") ?? "pill"
        kind = try r.optionalString("kind")
        if let b = r.raw("bend"), b != .null { bend = try CanvasPoint(json: b, path: "\(path).bend") }
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("from", from.rawValue)
        if from.zone != nil { w.set("fromKind", from.kind) }
        w.set("to", to.rawValue)
        if to.zone != nil { w.set("toKind", to.kind) }
        w.set("label", label)
        w.set("line", line)
        w.set("ends", ends, omitEmpty: false)
        if dash != "dashed" { w.set("dash", dash) }
        if width != 2 { w.set("width", .number(width)) }
        if color != "theme" { w.set("color", color) }
        if labelPosition != "middle" { w.set("labelPosition", labelPosition) }
        if labelStyle != "pill" { w.set("labelStyle", labelStyle) }
        w.set("kind", kind)
        if let bend { w.set("bend", bend.json) }
        return w.value
    }
}
