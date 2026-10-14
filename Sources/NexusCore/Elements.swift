import Foundation

/// A shape around one or more branches (⇧⌘B). In technical canvases it doubles as a
/// group, zone, VPC, subnet or trust boundary.
public struct Boundary: Hashable, Sendable, JSONRepresentable {
    /// A title or a technical meaning label sits in a band above the content.
    public var hasTitleBand: Bool { !title.isEmpty || meaning != "group" }

    public var id: String
    /// Topics whose whole branches the boundary wraps.
    public var nodes: [NodeID]
    public var title: String
    /// rounded, rectangle, stadium, ellipse, wave, scallop, polygon, dashed, corners
    public var shape: String = "rounded"
    /// group, zone, vpc, subnet, trust
    public var meaning: String = "group"
    /// high, medium, low (trust boundaries)
    public var trust: String?
    /// hex, or nil for the theme's ring colour
    public var color: String?
    public var fillOpacity: Double = 0.06
    /// solid, dashed, dotted
    public var dash: String?
    public var width: Double = 2
    /// top-left, top, top-right, bottom-left
    public var titlePosition: String = "top-left"
    /// Hatch pattern by trust level (never colour alone).
    public var hatch: Bool = true
    public var extra: [String: JSONValue] = [:]

    public init(id: String, nodes: [NodeID], title: String = "") {
        self.id = id
        self.nodes = nodes
        self.title = title
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        nodes = try r.strings("nodes").map { NodeID($0) }
        title = try r.optionalString("title") ?? ""
        shape = try r.optionalString("shape") ?? "rounded"
        meaning = try r.optionalString("meaning") ?? "group"
        trust = try r.optionalString("trust")
        color = try r.optionalString("color")
        fillOpacity = try r.optionalDouble("fillOpacity") ?? 0.06
        dash = try r.optionalString("dash")
        width = try r.optionalDouble("width") ?? 2
        titlePosition = try r.optionalString("titlePosition") ?? "top-left"
        hatch = try r.bool("hatch", default: true)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("nodes", nodes.map(\.rawValue), omitEmpty: false)
        w.set("title", title)
        if shape != "rounded" { w.set("shape", shape) }
        if meaning != "group" { w.set("meaning", meaning) }
        w.set("trust", trust)
        w.set("color", color)
        if fillOpacity != 0.06 { w.set("fillOpacity", .number(fillOpacity)) }
        w.set("dash", dash)
        if width != 2 { w.set("width", .number(width)) }
        if titlePosition != "top-left" { w.set("titlePosition", titlePosition) }
        w.set("hatch", hatch, omitting: true)
        return w.value
    }
}

/// A bracket over a run of siblings (⇧⌘]) that owns its own topic.
public struct Summary: Hashable, Sendable, JSONRepresentable {
    public var id: String
    public var parent: NodeID
    /// First and last sibling the bracket spans (inclusive).
    public var from: NodeID
    public var to: NodeID
    /// The summary topic (a node of kind `summary`, which can have children).
    public var topic: NodeID
    public var width: Double = 2
    /// hex, or nil for ink
    public var color: String?
    /// curly (default), square, round or line. Unknown values draw as curly.
    public var bracket: String = "curly"
    public var extra: [String: JSONValue] = [:]

    public init(id: String, parent: NodeID, from: NodeID, to: NodeID, topic: NodeID) {
        self.id = id
        self.parent = parent
        self.from = from
        self.to = to
        self.topic = topic
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        parent = NodeID(try r.string("parent"))
        from = NodeID(try r.string("from"))
        to = NodeID(try r.string("to"))
        topic = NodeID(try r.string("topic"))
        width = try r.optionalDouble("width") ?? 2
        color = try r.optionalString("color")
        bracket = try r.optionalString("bracket") ?? "curly"
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        if bracket != "curly" { w.set("bracket", bracket) }
        w.set("parent", parent.rawValue)
        w.set("from", from.rawValue)
        w.set("to", to.rawValue)
        w.set("topic", topic.rawValue)
        if width != 2 { w.set("width", .number(width)) }
        w.set("color", color)
        return w.value
    }
}

/// A speech bubble bound to a topic (⇧⌘C). The bubble's text is a node of kind `callout`.
public struct Callout: Hashable, Sendable, JSONRepresentable {
    public var id: String
    public var host: NodeID
    public var topic: NodeID
    /// rounded, ellipse, rectangle
    public var shape: String = "rounded"
    /// auto, top, right, below
    public var side: String = "auto"
    public var extra: [String: JSONValue] = [:]

    public init(id: String, host: NodeID, topic: NodeID) {
        self.id = id
        self.host = host
        self.topic = topic
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        host = NodeID(try r.string("host"))
        topic = NodeID(try r.string("topic"))
        shape = try r.optionalString("shape") ?? "rounded"
        side = try r.optionalString("side") ?? "auto"
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("host", host.rawValue)
        w.set("topic", topic.rawValue)
        if shape != "rounded" { w.set("shape", shape) }
        if side != "auto" { w.set("side", side) }
        return w.value
    }
}

/// A frame for floating content (⌥⌘Z), never the main tree.
public struct Zone: Hashable, Sendable, JSONRepresentable {
    public var id: String
    public var title: String
    public var origin: CanvasPoint
    public var width: Double
    public var height: Double
    /// Floating topics inside the zone; they move with it.
    public var members: [NodeID] = []
    public var autoResize: Bool = true
    public var collapsed: Bool = false
    /// rounded, square, dashed
    public var frame: String = "rounded"
    /// hex, or nil for violet
    public var color: String?
    public var extra: [String: JSONValue] = [:]

    public static let minimumSize = 100.0

    public init(id: String, title: String, origin: CanvasPoint, width: Double = 420, height: Double = 240) {
        self.id = id
        self.title = title
        self.origin = origin
        self.width = max(Self.minimumSize, width)
        self.height = max(Self.minimumSize, height)
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        title = try r.optionalString("title") ?? ""
        origin =
            try r.raw("origin").map { try CanvasPoint(json: $0, path: "\(path).origin") } ?? CanvasPoint(x: 0, y: 0)
        width = max(Self.minimumSize, try r.optionalDouble("width") ?? 420)
        height = max(Self.minimumSize, try r.optionalDouble("height") ?? 240)
        members = try r.strings("members").map { NodeID($0) }
        autoResize = try r.bool("autoResize", default: true)
        collapsed = try r.bool("collapsed", default: false)
        frame = try r.optionalString("frame") ?? "rounded"
        color = try r.optionalString("color")
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("title", title)
        w.set("origin", origin.json)
        w.set("width", .number(CanvasPoint.round(width)))
        w.set("height", .number(CanvasPoint.round(height)))
        w.set("members", members.map(\.rawValue), omitEmpty: true)
        w.set("autoResize", autoResize, omitting: true)
        w.set("collapsed", collapsed, omitting: false)
        if frame != "rounded" { w.set("frame", frame) }
        w.set("color", color)
        return w.value
    }
}

// MARK: - Topic enrichments

/// A run of rich text inside a topic title (UTF-16 offsets, as AppKit uses).
public struct TextMark: Hashable, Sendable, JSONRepresentable {
    public var start: Int
    public var length: Int
    public var bold: Bool = false
    public var italic: Bool = false
    public var underline: Bool = false
    public var strikethrough: Bool = false
    public var link: String?
    public var extra: [String: JSONValue] = [:]

    public init(
        start: Int, length: Int, bold: Bool = false, italic: Bool = false, underline: Bool = false,
        strikethrough: Bool = false, link: String? = nil
    ) {
        self.start = start
        self.length = length
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.link = link
    }

    public var isPlain: Bool { !bold && !italic && !underline && !strikethrough && link == nil }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        start = Int(try r.optionalDouble("start") ?? 0)
        length = Int(try r.optionalDouble("length") ?? 0)
        bold = try r.bool("bold", default: false)
        italic = try r.bool("italic", default: false)
        underline = try r.bool("underline", default: false)
        strikethrough = try r.bool("strikethrough", default: false)
        link = try r.optionalString("link")
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("start", .number(Double(start)))
        w.set("length", .number(Double(length)))
        w.set("bold", bold, omitting: false)
        w.set("italic", italic, omitting: false)
        w.set("underline", underline, omitting: false)
        w.set("strikethrough", strikethrough, omitting: false)
        w.set("link", link)
        return w.value
    }
}

/// An image, sticker or attachment stored in the package's `assets/`.
public struct AssetRef: Hashable, Sendable, JSONRepresentable {
    /// Content-hashed file name under `assets/` (or a built-in sticker id).
    public var asset: String
    public var name: String?
    public var width: Double?
    public var height: Double?
    /// top, left, right, bottom
    public var position: String?
    public var extra: [String: JSONValue] = [:]

    public init(
        asset: String, name: String? = nil, width: Double? = nil, height: Double? = nil,
        position: String? = nil
    ) {
        self.asset = asset
        self.name = name
        self.width = width
        self.height = height
        self.position = position
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        asset = try r.optionalString("asset") ?? ""
        name = try r.optionalString("name")
        width = try r.optionalDouble("width")
        height = try r.optionalDouble("height")
        position = try r.optionalString("position")
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("asset", asset)
        w.set("name", name)
        w.set("width", width)
        w.set("height", height)
        w.set("position", position)
        return w.value
    }
}

/// An audio note recorded from the Mac's microphone; the transcript (M6) lives in the note.
public struct AudioNote: Hashable, Sendable, JSONRepresentable {
    public var asset: String
    public var duration: Double
    public var extra: [String: JSONValue] = [:]

    public init(asset: String, duration: Double) {
        self.asset = asset
        self.duration = duration
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        asset = try r.optionalString("asset") ?? ""
        duration = try r.optionalDouble("duration") ?? 0
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("asset", asset)
        w.set("duration", .number((duration * 10).rounded() / 10))
        return w.value
    }
}

/// Topic links: `nexus:topic/<canvas>/<node>`.
public enum TopicLink {
    public static func make(canvas: CanvasID, node: NodeID) -> String { "nexus:topic/\(canvas)/\(node)" }

    public static func parse(_ link: String) -> (canvas: CanvasID, node: NodeID)? {
        guard link.hasPrefix("nexus:topic/") else { return nil }
        let parts = link.dropFirst("nexus:topic/".count).split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (CanvasID(String(parts[0])), NodeID(String(parts[1])))
    }
}

extension NodeRole {
    public static let callout: NodeRole = "callout"
}
