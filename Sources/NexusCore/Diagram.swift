import Foundation

/// A swimlane (artboard 19: CUSTOMER · SUPPORT · FINANCE).
public struct Lane: Hashable, Sendable, JSONRepresentable {
    public var id: String
    public var title: String
    public var extra: [String: JSONValue] = [:]

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        title = try r.optionalString("title") ?? ""
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("title", title)
        return w.value
    }
}

/// Where a DFD level was drilled from (⌘.).
public struct LevelLink: Hashable, Sendable, JSONRepresentable {
    public var canvas: CanvasID
    public var node: NodeID
    public var extra: [String: JSONValue] = [:]

    public init(canvas: CanvasID, node: NodeID) {
        self.canvas = canvas
        self.node = node
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        canvas = CanvasID(try r.string("canvas"))
        node = NodeID(try r.string("node"))
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("canvas", canvas.rawValue)
        w.set("node", node.rawValue)
        return w.value
    }
}

/// Canvas-level technical-diagram state. Per-node facts (type, edge label, lane) live on
/// the nodes so they travel with copy, move and delete.
public struct DiagramData: Hashable, Sendable, JSONRepresentable {
    public var lanes: [Lane] = []
    /// Rule-check violations the user chose to ignore (`DFDRules.Violation.id`).
    public var ignoredRules: [String] = []
    /// For a drilled DFD level: the process it details, and that process's number
    /// (sub-processes number 2.1, 2.2 …).
    public var parent: LevelLink?
    public var levelNumber: String?
    /// DFD view: `level` (default) or `context` (Level 0).
    public var view: String = "level"
    /// Threat model: tint elements by their highest open risk.
    public var colorByRisk: Bool = false
    /// The hierarchy structure in use before converting to a technical type, restored
    /// when converting back.
    public var previousStructure: LayoutStructure?
    public var extra: [String: JSONValue] = [:]

    public init() {}

    public var isEmpty: Bool {
        lanes.isEmpty && ignoredRules.isEmpty && parent == nil && levelNumber == nil && view == "level" && !colorByRisk
            && previousStructure == nil && extra.isEmpty
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        lanes = try r.array("lanes").enumerated().map { try Lane(json: $1, path: "\(path).lanes[\($0)]") }
        ignoredRules = try r.strings("ignoredRules")
        if let p = r.raw("parent"), p != .null { parent = try LevelLink(json: p, path: "\(path).parent") }
        levelNumber = try r.optionalString("levelNumber")
        view = try r.optionalString("view") ?? "level"
        colorByRisk = try r.bool("colorByRisk", default: false)
        previousStructure = try r.optionalString("previousStructure").map(LayoutStructure.init(rawValue:))
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        if !lanes.isEmpty { w.set("lanes", .array(lanes.map(\.json))) }
        w.set("ignoredRules", ignoredRules, omitEmpty: true)
        if let parent { w.set("parent", parent.json) }
        w.set("levelNumber", levelNumber)
        if view != "level" { w.set("view", view) }
        w.set("colorByRisk", colorByRisk, omitting: false)
        w.set("previousStructure", previousStructure?.rawValue)
        return w.value
    }
}

// MARK: Node types

extension NodeType {
    // Flowchart (S5)
    public static let start: NodeType = "start"
    public static let end: NodeType = "end"
    public static let process: NodeType = "process"
    public static let decision: NodeType = "decision"
    public static let io: NodeType = "io"
    public static let document: NodeType = "document"
    // DFD (S6)
    public static let entity: NodeType = "entity"
    public static let store: NodeType = "store"
    // Threat model (S7)
    public static let threat: NodeType = "threat"
    public static let mitigation: NodeType = "mitigation"
    public static let asset: NodeType = "asset"
    // Sequence (S9)
    public static let participant: NodeType = "participant"
    public static let umlClass: NodeType = "class"
}

/// What a node type looks like and how it is named (artboards 13, 19–23).
public struct NodeTypeInfo: Sendable, Equatable {
    public var id: NodeType
    public var name: String
    /// Small caps label: outside the node in flowcharts and DFDs, inside (as a kicker)
    /// on architecture nodes.
    public var caption: String
    /// The slash-menu slug (`/db`).
    public var slug: String
    /// A shape from `ShapeLibrary`.
    public var shape: String
    /// Look family the renderer maps to theme colours.
    public var look: Look
    /// Icon from the technical icon set, if any.
    public var icon: String?
    public var category: String

    public enum Look: String, Sendable {
        case terminal, step, decision, io, entity, process, store, threat, mitigation, asset, icon, participant
    }
}

public enum DiagramCatalog {
    /// The 32 technical icons (artboard 13), with slugs and categories.
    public static let icons: [NodeTypeInfo] = {
        let rows: [(String, String, String, String)] = [
            ("client", "Client", "client", "Clients"), ("mobile", "Mobile", "mobile", "Clients"),
            ("actor", "User", "actor", "Clients"), ("service", "Service", "service", "Compute"),
            ("gateway", "API Gateway", "gateway", "Compute"), ("lb", "Load Balancer", "lb", "Network"),
            ("fn", "Function", "fn", "Compute"), ("container", "Container", "container", "Compute"),
            ("cluster", "Cluster", "cluster", "Compute"), ("host", "Server", "host", "Compute"),
            ("db", "Database", "db", "Data"), ("cache", "Cache", "cache", "Data"), ("queue", "Queue", "queue", "Data"),
            ("stream", "Event Stream", "stream", "Data"), ("storage", "Object Storage", "storage", "Data"),
            ("doc", "Document", "doc", "Data"), ("cloud", "Cloud", "cloud", "Network"),
            ("region", "Region", "region", "Network"), ("saas", "External SaaS", "saas", "Network"),
            ("router", "Router", "router", "Network"), ("switch", "Switch", "switch", "Network"),
            ("firewall", "Firewall", "firewall", "Network"), ("auth", "Lock · Auth", "auth", "Security"),
            ("secret", "Secret", "secret", "Security"), ("threat", "Threat", "threat", "Security"),
            ("mitigation", "Mitigation", "mitigation", "Security"), ("asset", "Asset", "asset", "Security"),
            ("monitor", "Monitoring", "monitor", "Compute"), ("process", "Process", "process", "Diagram"),
            ("entity", "External Entity", "entity", "Diagram"), ("store", "Data Store", "store", "Diagram"),
            ("decision", "Decision", "decision", "Diagram"),
        ]
        let captions: [String: String] = [
            "gateway": "API GATEWAY", "saas": "EXT. SAAS", "db": "DATABASE", "fn": "FUNCTION", "lb": "LOAD BALANCER",
            "host": "SERVER", "actor": "USER", "doc": "DOCUMENT", "stream": "STREAM", "storage": "STORAGE",
            "monitor": "MONITORING", "auth": "AUTH", "entity": "EXTERNAL ENTITY", "store": "DATA STORE",
        ]
        return rows.map { id, name, icon, cat in
            NodeTypeInfo(
                id: NodeType(rawValue: id), name: name, caption: captions[id] ?? name.uppercased(), slug: id,
                shape: "rectangle", look: .icon, icon: icon, category: cat)
        }
    }()

    static let flowTypes: [NodeTypeInfo] = [
        NodeTypeInfo(
            id: .start, name: "Start", caption: "START", slug: "start", shape: "stadium", look: .terminal, icon: nil,
            category: "Flow"),
        NodeTypeInfo(
            id: .process, name: "Process", caption: "PROCESS", slug: "step", shape: "rectangle", look: .step,
            icon: nil, category: "Flow"),
        NodeTypeInfo(
            id: .decision, name: "Decision", caption: "DECISION", slug: "decision", shape: "diamond",
            look: .decision, icon: nil, category: "Flow"),
        NodeTypeInfo(
            id: .io, name: "Input / output", caption: "I/O", slug: "io", shape: "parallelogram", look: .io,
            icon: nil, category: "Flow"),
        NodeTypeInfo(
            id: .document, name: "Document", caption: "DOCUMENT", slug: "document", shape: "document", look: .io,
            icon: nil, category: "Flow"),
        NodeTypeInfo(
            id: .end, name: "End", caption: "END", slug: "end", shape: "stadium", look: .terminal, icon: nil,
            category: "Flow"),
    ]

    static let dfdTypes: [NodeTypeInfo] = [
        NodeTypeInfo(
            id: .entity, name: "External entity", caption: "EXTERNAL ENTITY", slug: "entity", shape: "rectangle",
            look: .entity, icon: nil, category: "Data flow"),
        NodeTypeInfo(
            id: .process, name: "Process", caption: "PROCESS", slug: "process", shape: "stadium", look: .process,
            icon: nil, category: "Data flow"),
        NodeTypeInfo(
            id: .store, name: "Data store", caption: "DATA STORE", slug: "store", shape: "rectangle", look: .store,
            icon: nil, category: "Data flow"),
    ]

    static let threatTypes: [NodeTypeInfo] =
        dfdTypes + [
            NodeTypeInfo(
                id: .threat, name: "Threat", caption: "THREAT", slug: "threat", shape: "rounded", look: .threat,
                icon: "threat", category: "Threats"),
            NodeTypeInfo(
                id: .mitigation, name: "Mitigation", caption: "MITIGATION", slug: "mitigation", shape: "rounded",
                look: .mitigation, icon: "mitigation", category: "Threats"),
            NodeTypeInfo(
                id: .asset, name: "Asset", caption: "ASSET", slug: "asset", shape: "rounded", look: .asset,
                icon: "asset", category: "Threats"),
        ]

    static let sequenceTypes: [NodeTypeInfo] = [
        NodeTypeInfo(
            id: .participant, name: "Participant", caption: "PARTICIPANT", slug: "participant", shape: "rounded",
            look: .participant, icon: nil, category: "Sequence"),
        NodeTypeInfo(
            id: .umlClass, name: "Class", caption: "CLASS", slug: "class", shape: "rectangle", look: .participant,
            icon: nil, category: "Sequence"),
    ]

    /// Node types a diagram offers in pickers and the slash menu.
    public static func nodeTypes(for type: DiagramType) -> [NodeTypeInfo] {
        switch type {
        case .flowchart, .swimlane: flowTypes
        case .dfd: dfdTypes
        case .threatModel: threatTypes
        case .architecture: icons
        case .sequence: sequenceTypes + icons.filter { ["actor", "client", "service", "db"].contains($0.slug) }
        default: []
        }
    }

    public static func info(_ t: NodeType, in type: DiagramType) -> NodeTypeInfo? {
        nodeTypes(for: type).first { $0.id == t } ?? icons.first { $0.id == t }
            ?? (flowTypes + threatTypes).first { $0.id == t }
    }

    // MARK: Diagram traits

    /// Hierarchy types convert losslessly with no questions; technical ones carry node
    /// types and graph layouts.
    public static func isTechnical(_ t: DiagramType) -> Bool {
        [.flowchart, .swimlane, .dfd, .threatModel, .architecture, .sequence].contains(t)
    }

    /// Converting to these asks the user to confirm first-level node types (artboard 10).
    public static func asksForNodeTypes(_ t: DiagramType) -> Bool {
        [.dfd, .threatModel, .architecture].contains(t)
    }

    /// In these the central topic is the diagram's title, not a node in the graph.
    public static func rootIsTitle(_ t: DiagramType) -> Bool {
        [.dfd, .threatModel, .architecture, .sequence].contains(t)
    }

    /// The structure a type lays out with.
    public static func structure(for t: DiagramType) -> LayoutStructure { t.defaultStructure }

    /// The type a node has in this diagram: explicit, else inferred.
    public static func effectiveType(_ id: NodeID, in canvas: Canvas, parents: [NodeID: NodeID]? = nil) -> NodeType? {
        guard let node = canvas.nodes[id] else { return nil }
        if let t = node.nodeType { return t }
        let type = canvas.type
        guard isTechnical(type) else { return nil }
        let isRoot = id == canvas.root
        switch type {
        case .flowchart, .swimlane:
            if isRoot { return .start }
            let text = node.text.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("?") { return .decision }
            if node.children.isEmpty, NodeTypeSuggester.looksTerminal(text) { return .end }
            return .process
        case .dfd, .threatModel:
            return isRoot ? nil : NodeTypeSuggester.dfd(node.text)
        case .architecture:
            return isRoot ? nil : NodeTypeSuggester.architecture(node.text)
        case .sequence:
            guard !isRoot else { return nil }
            let p = parents ?? canvas.parentMap()
            return p[id] == canvas.root ? .participant : nil
        default:
            return nil
        }
    }
}

/// Heuristic node-type suggestions (✦). Deterministic and local; M6 swaps in the
/// on-device model and keeps these as the fallback.
public enum NodeTypeSuggester {
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static func matches(_ text: String, _ keys: [String]) -> Bool {
        let lower = text.lowercased()
        let w = words(text)
        return keys.contains { k in k.contains(" ") ? lower.contains(k) : w.contains(k) }
    }

    static func looksTerminal(_ text: String) -> Bool {
        matches(text, ["done", "end", "finish", "finished", "stop", "complete", "completed", "refunded", "exit"])
    }

    /// External entity, process or data store.
    public static func dfd(_ text: String) -> NodeType {
        if matches(
            text,
            [
                "db", "database", "store", "table", "tables", "repository", "ledger", "tokens", "bucket", "storage",
                "warehouse", "orders db", "log", "logs", "cache", "queue",
            ])
        {
            return .store
        }
        if matches(
            text,
            [
                "customer", "customers", "user", "users", "client", "provider", "bank", "partner", "vendor", "admin",
                "external", "merchant", "supplier", "visitor", "browser", "regulator", "courier",
            ])
        {
            return .entity
        }
        return .process
    }

    /// One of the 32 architecture icons.
    public static func architecture(_ text: String) -> NodeType {
        let rules: [(String, [String])] = [
            (
                "db",
                ["db", "database", "postgres", "postgresql", "mysql", "sql", "mongo", "mongodb", "dynamo", "sqlite"]
            ),
            ("cache", ["cache", "redis", "memcached", "sessions"]),
            ("stream", ["kafka", "kinesis", "stream", "streams"]),
            ("queue", ["queue", "rabbitmq", "sqs", "amqp", "events", "order-events"]),
            ("storage", ["s3", "bucket", "blob", "storage", "files"]),
            ("gateway", ["gateway", "gw", "edge-gw", "ingress", "api gateway"]),
            ("lb", ["lb", "alb", "nlb", "balancer", "load balancer"]),
            ("fn", ["lambda", "function", "fn", "functions"]),
            ("container", ["worker", "container", "pod", "docker", "job", "fulfil-worker"]),
            ("cluster", ["cluster", "k8s", "kubernetes"]),
            ("mobile", ["ios", "android", "mobile"]),
            ("client", ["web", "client", "browser", "frontend", "spa", "web app"]),
            ("actor", ["user", "users", "customer", "customers", "admin", "person", "people"]),
            ("saas", ["stripe", "twilio", "saas", "payments", "provider", "third-party", "paypal"]),
            ("monitor", ["monitor", "monitoring", "metrics", "grafana", "datadog", "logging"]),
            ("auth", ["auth", "login", "identity", "sso", "oauth"]),
            ("secret", ["secret", "secrets", "vault", "kms"]),
            ("firewall", ["firewall", "waf"]), ("router", ["router"]), ("switch", ["switch"]),
            ("region", ["region"]), ("cloud", ["cloud"]), ("doc", ["doc", "document", "pdf", "report"]),
            ("host", ["server", "host", "vm", "ec2"]),
        ]
        for (icon, keys) in rules where matches(text, keys) { return NodeType(rawValue: icon) }
        return "service"
    }

    /// A suggestion for the Convert dialog's "Confirm node types" step.
    public static func suggest(_ text: String, for type: DiagramType) -> NodeType {
        type == .architecture ? architecture(text) : dfd(text)
    }
}

// MARK: Convert (⌥⌘T)

extension CanvasEditor {
    /// Changes the diagram type in one step. Content (nodes, text, hierarchy,
    /// relationships, elements) is never touched; confirmed node types are set only
    /// where given. Converting back to a hierarchy type restores the structure in use
    /// before the first technical conversion.
    public mutating func convert(to type: DiagramType, nodeTypes: [NodeID: NodeType] = [:]) {
        let from = canvas.type
        guard from != type || !nodeTypes.isEmpty else { return }
        for (id, t) in nodeTypes where self[id] != nil && self[id]?.nodeType != t {
            update(id) { $0.nodeType = t }
        }
        updateMeta { c in
            let wasTechnical = DiagramCatalog.isTechnical(c.type)
            let toTechnical = DiagramCatalog.isTechnical(type)
            if !wasTechnical && toTechnical {
                c.diagram.previousStructure = c.layout.structure
            }
            c.type = type
            if toTechnical {
                c.layout.structure = type.defaultStructure
            } else if let previous = c.diagram.previousStructure,
                previous.family == type.defaultStructure.family
                    || (type == .mindmap && previous.family == "mindmap")
            {
                c.layout.structure = previous
                c.diagram.previousStructure = nil
            } else {
                c.layout.structure = type.defaultStructure
                c.diagram.previousStructure = nil
            }
            if type == .swimlane && c.diagram.lanes.isEmpty {
                c.diagram.lanes = [Lane(id: "l1", title: "Lane 1"), Lane(id: "l2", title: "Lane 2")]
            }
        }
    }
}

// MARK: Protocol labels (architecture, artboard 22)

extension DiagramCatalog {
    /// The protocol an edge into a node of this type defaults to.
    public static func defaultProtocol(for t: NodeType?) -> String? {
        switch t?.rawValue {
        case "db": "SQL · 5432"
        case "cache": "RESP"
        case "queue", "stream": "AMQP"
        case "saas", "client", "actor", "mobile", "gateway", "lb", "storage", "cloud": "HTTPS"
        case "service", "fn", "container", "cluster", "host", "auth", "monitor", "secret": "gRPC"
        default: nil
        }
    }

    /// Suggestions while editing an architecture edge label, best first for the target.
    public static func protocolSuggestions(for t: NodeType?) -> [String] {
        let all = ["HTTPS", "gRPC", "SQL · 5432", "RESP", "AMQP", "Kafka", "WebSocket", "GraphQL", "SMTP", "SSH"]
        guard let d = defaultProtocol(for: t) else { return all }
        return [d] + all.filter { $0 != d }
    }
}
