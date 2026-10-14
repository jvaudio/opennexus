import Foundation

public struct CanvasLayout: Hashable, Sendable, JSONRepresentable {
    public var mode: LayoutMode
    public var structure: LayoutStructure
    /// Advanced layout (FMT-3): drag branches freely, flexible floating topics, overlap.
    public var branchFreePositioning: Bool = false
    public var flexibleFloating: Bool = true
    public var allowOverlap: Bool = false
    public var extra: [String: JSONValue] = [:]

    public init(mode: LayoutMode = .auto, structure: LayoutStructure = .mindmapBalanced) {
        self.mode = mode
        self.structure = structure
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        mode = LayoutMode(rawValue: try r.optionalString("mode") ?? "auto")
        structure = LayoutStructure(
            rawValue: try r.optionalString("structure") ?? LayoutStructure.mindmapBalanced.rawValue)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("mode", mode.rawValue)
        w.set("structure", structure.rawValue)
        w.set("branchFreePositioning", branchFreePositioning, omitting: false)
        w.set("flexibleFloating", flexibleFloating, omitting: true)
        w.set("allowOverlap", allowOverlap, omitting: false)
        return w.value
    }
}

public struct CanvasStyle: Hashable, Sendable, JSONRepresentable {
    public var theme: String
    public var nodeStyle: String
    /// rainbow, multi, mono, gradient (FMT-3 › Colour theme).
    public var colorTheme: String
    /// Palette id (classic, sunset, ocean, pastel, earth, neon) or a custom one.
    public var palette: String
    /// Smart Color (⇧⌘R) rotation applied to the branch palette.
    public var paletteShift: Int = 0
    /// Colour each main branch; when off every branch uses `singleColor`.
    public var coloredBranch: Bool = true
    /// `ink` or hex, used when coloured branches are off.
    public var singleColor: String?
    /// Background override (hex) and pattern override (plain, dots, lines).
    public var background: String?
    public var pattern: String?
    /// Global diagram font and CJK font.
    public var font: String?
    public var cjkFont: String?
    /// thin, regular, bold, taper
    public var lineWidth: String?
    /// Branch line shape chosen by a skeleton (overrides the theme's).
    public var lineShape: String?
    public var autoBalance: Bool = true
    public var compact: Bool = false
    public var justify: Bool = false
    /// Update Style › "Apply to all level-N topics", keyed by depth.
    public var levels: [Int: TopicStyle] = [:]
    public var extra: [String: JSONValue] = [:]

    public init(
        theme: String = "classic", nodeStyle: String = "outline", colorTheme: String = "rainbow",
        palette: String = "theme"
    ) {
        self.theme = theme
        self.nodeStyle = nodeStyle
        self.colorTheme = colorTheme
        self.palette = palette
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        theme = try r.optionalString("theme") ?? "classic"
        nodeStyle = try r.optionalString("nodeStyle") ?? "outline"
        colorTheme = try r.optionalString("colorTheme") ?? "rainbow"
        palette = try r.optionalString("palette") ?? "theme"
        paletteShift = Int(try r.optionalDouble("paletteShift") ?? 0)
        coloredBranch = try r.bool("coloredBranch", default: true)
        singleColor = try r.optionalString("singleColor")
        background = try r.optionalString("background")
        pattern = try r.optionalString("pattern")
        font = try r.optionalString("font")
        cjkFont = try r.optionalString("cjkFont")
        lineWidth = try r.optionalString("lineWidth")
        lineShape = try r.optionalString("lineShape")
        autoBalance = try r.bool("autoBalance", default: true)
        compact = try r.bool("compact", default: false)
        justify = try r.bool("justify", default: false)
        for (k, v) in try r.object("levels") ?? [:] {
            guard let d = Int(k) else { continue }
            levels[d] = try TopicStyle(json: v, path: "\(path).levels.\(k)")
        }
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("theme", theme)
        w.set("nodeStyle", nodeStyle)
        w.set("colorTheme", colorTheme)
        w.set("palette", palette)
        if paletteShift != 0 { w.set("paletteShift", .number(Double(paletteShift))) }
        w.set("coloredBranch", coloredBranch, omitting: true)
        w.set("singleColor", singleColor)
        w.set("background", background)
        w.set("pattern", pattern)
        w.set("font", font)
        w.set("cjkFont", cjkFont)
        w.set("lineWidth", lineWidth)
        w.set("lineShape", lineShape)
        w.set("autoBalance", autoBalance, omitting: true)
        w.set("compact", compact, omitting: false)
        w.set("justify", justify, omitting: false)
        let lv = levels.filter { !$0.value.isEmpty }
        if !lv.isEmpty {
            w.set("levels", .object(Dictionary(uniqueKeysWithValues: lv.map { ("\($0.key)", $0.value.json) })))
        }
        return w.value
    }
}

/// One canvas (an Xmind "sheet"): a graph of nodes and edges with a diagram type.
///
/// Elements that later milestones type out (boundaries, summaries, callouts, zones,
/// diagram metadata) are kept in `extra` until then, so they already round-trip.
public struct Canvas: Hashable, Sendable {
    public var id: CanvasID
    public var title: String
    public var type: DiagramType
    public var layout: CanvasLayout
    public var style: CanvasStyle
    public var root: NodeID
    public var nodes: [NodeID: Node]
    public var floating: [NodeID] = []
    public var relationships: [Relationship] = []
    public var boundaries: [Boundary] = []
    public var summaries: [Summary] = []
    public var callouts: [Callout] = []
    /// Zones in z-order (back to front).
    public var zones: [Zone] = []
    /// Technical-diagram state: lanes, DFD levels, ignored rule checks.
    public var diagram = DiagramData()
    /// Saved filters (filter bar › Save as …).
    public var filters: [NodeFilter] = []
    /// Present mode deck settings.
    public var presentation = PresentationSettings()
    public var extra: [String: JSONValue] = [:]

    /// Next sequence number for new node ids. Not stored; derived on load.
    public var nextSequence: Int

    public init(id: CanvasID, title: String, type: DiagramType = .mindmap, rootText: String = "Central Topic") {
        self.id = id
        self.title = title
        self.type = type
        self.layout = CanvasLayout(structure: type.defaultStructure)
        self.style = CanvasStyle()
        self.root = "n1"
        self.nodes = ["n1": Node(text: rootText, kind: .root)]
        self.nextSequence = 2
    }

    public init(
        id: CanvasID, title: String, type: DiagramType, layout: CanvasLayout, style: CanvasStyle,
        root: NodeID, nodes: [NodeID: Node]
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.layout = layout
        self.style = style
        self.root = root
        self.nodes = nodes
        self.nextSequence = Canvas.seed(for: nodes.keys)
    }

    static func seed(for ids: some Sequence<NodeID>) -> Int {
        (ids.compactMap(\.sequence).max() ?? 0) + 1
    }

    /// Returns a fresh id that is not in use.
    public mutating func makeNodeID() -> NodeID {
        var id = NodeID("n\(nextSequence)")
        while nodes[id] != nil {
            nextSequence += 1
            id = NodeID("n\(nextSequence)")
        }
        nextSequence += 1
        return id
    }

    public static func == (a: Canvas, b: Canvas) -> Bool {
        a.id == b.id && a.title == b.title && a.type == b.type && a.layout == b.layout && a.style == b.style
            && a.root == b.root && a.nodes == b.nodes && a.floating == b.floating
            && a.relationships == b.relationships && a.boundaries == b.boundaries && a.summaries == b.summaries
            && a.callouts == b.callouts && a.zones == b.zones && a.diagram == b.diagram
            && a.filters == b.filters && a.presentation == b.presentation && a.extra == b.extra
    }

    public func hash(into h: inout Hasher) {
        h.combine(id)
        h.combine(root)
        h.combine(nodes.count)
    }
}

extension Canvas: JSONRepresentable {
    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = CanvasID(try r.string("id"))
        title = try r.optionalString("title") ?? ""
        type = DiagramType(rawValue: try r.optionalString("type") ?? "mindmap")
        layout = try r.raw("layout").map { try CanvasLayout(json: $0, path: "\(path).layout") } ?? CanvasLayout()
        style = try r.raw("style").map { try CanvasStyle(json: $0, path: "\(path).style") } ?? CanvasStyle()
        root = NodeID(try r.string("root"))
        var nodes: [NodeID: Node] = [:]
        for (key, value) in try r.object("nodes") ?? [:] {
            nodes[NodeID(key)] = try Node(json: value, path: "\(path).nodes.\(key)")
        }
        self.nodes = nodes
        floating = try r.strings("floating").map { NodeID($0) }
        relationships = try r.array("relationships").enumerated().map {
            try Relationship(json: $1, path: "\(path).relationships[\($0)]")
        }
        boundaries = try r.array("boundaries").enumerated().map {
            try Boundary(json: $1, path: "\(path).boundaries[\($0)]")
        }
        summaries = try r.array("summaries").enumerated().map {
            try Summary(json: $1, path: "\(path).summaries[\($0)]")
        }
        callouts = try r.array("callouts").enumerated().map { try Callout(json: $1, path: "\(path).callouts[\($0)]") }
        zones = try r.array("zones").enumerated().map { try Zone(json: $1, path: "\(path).zones[\($0)]") }
        diagram = try r.raw("diagram").map { try DiagramData(json: $0, path: "\(path).diagram") } ?? DiagramData()
        filters = try r.array("filters").enumerated().map { try NodeFilter(json: $1, path: "\(path).filters[\($0)]") }
        presentation =
            try r.raw("presentation").map { try PresentationSettings(json: $0, path: "\(path).presentation") }
            ?? PresentationSettings()
        extra = r.leftovers
        nextSequence = Canvas.seed(for: nodes.keys)
        guard nodes[root] != nil else { throw ModelDecodingError(path: "\(path).root", "root node \(root) is missing") }
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id.rawValue)
        w.set("title", title)
        w.set("type", type.rawValue)
        w.set("layout", layout.json)
        w.set("style", style.json)
        w.set("root", root.rawValue)
        w.set("nodes", .object(Dictionary(uniqueKeysWithValues: nodes.map { ($0.key.rawValue, $0.value.json) })))
        w.set("floating", floating.map(\.rawValue), omitEmpty: false)
        w.set("relationships", .array(relationships.map(\.json)))
        if !boundaries.isEmpty { w.set("boundaries", .array(boundaries.map(\.json))) }
        if !summaries.isEmpty { w.set("summaries", .array(summaries.map(\.json))) }
        if !callouts.isEmpty { w.set("callouts", .array(callouts.map(\.json))) }
        if !zones.isEmpty { w.set("zones", .array(zones.map(\.json))) }
        if !diagram.isEmpty { w.set("diagram", diagram.json) }
        if !filters.isEmpty { w.set("filters", .array(filters.map(\.json))) }
        if !presentation.isDefault { w.set("presentation", presentation.json) }
        return w.value
    }
}

extension DiagramType {
    public var defaultStructure: LayoutStructure {
        switch self {
        case .logic: .logicRight
        case .brace: .braceRight
        case .org: .orgDown
        case .tree: .treeIndented
        case .treeTable: .treeTable
        case .timeline: .timelineHorizontal
        case .fishbone: .fishboneLeft
        case .matrix: .matrix
        case .flowchart: .flowDown
        case .swimlane: .swimlanes
        case .sequence: .sequence
        case .dfd, .threatModel, .architecture: .graphRight
        default: .mindmapBalanced
        }
    }

    public var displayName: String {
        switch self {
        case .mindmap: "Mind Map"
        case .logic: "Logic Chart"
        case .brace: "Brace Map"
        case .org: "Org Chart"
        case .tree: "Tree Chart"
        case .treeTable: "Tree Table"
        case .timeline: "Timeline"
        case .fishbone: "Fishbone"
        case .matrix: "Matrix"
        case .flowchart: "Flowchart"
        case .swimlane: "Swimlane"
        case .dfd: "Data Flow"
        case .threatModel: "Threat Model"
        case .architecture: "Architecture"
        case .sequence: "Sequence"
        case .whiteboard: "Whiteboard"
        default: rawValue
        }
    }
}
