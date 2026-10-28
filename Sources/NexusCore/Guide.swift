import Foundation

/// A guide (M41): the steps toward a well-formed diagram of one type, each matched against
/// what the canvas already has. Guides are data (`Guides/<id>.json` in NexusCanvas, checked
/// by `schema/guide.schema.json`); titles and tips are English, shown through `Loc.t`.
/// A tip quotes commands as `{command.id}`, drawn with the active key profile's keys.
public struct Guide: Sendable, Equatable, Identifiable {
    public var id: String
    /// The diagram type it guides.
    public var type: DiagramType
    public var steps: [Step]
    /// An outline in the starter syntax, drawn above the steps for tree types.
    public var example: [String]

    public struct Step: Sendable, Equatable, Identifiable {
        public var id: String
        public var match: Match
        /// How many matches meet the step (with `each`, how many under every parent).
        public var min: Int
        public var optional: Bool
        public var title: String
        public var tip: String

        public init(id: String, match: Match, min: Int = 1, optional: Bool = false, title: String, tip: String = "") {
            self.id = id
            self.match = match
            self.min = min
            self.optional = optional
            self.title = title
            self.tip = tip
        }
    }

    /// What a step counts. Topic fields combine (all must hold); `edge`, `boundary` and
    /// `rules` count those instead of topics.
    public struct Match: Sendable, Equatable {
        /// Topics of one of these semantic types, inferred when untyped (`DiagramCatalog.effectiveType`).
        public var nodeTypes: [NodeType] = []
        /// Topics this deep: 0 the root, 1 main topics.
        public var depth: Int?
        /// Topics of this kind (`root`, `topic`, `floating`, `summary`).
        public var kind: NodeRole?
        /// Only topics given their own text, not a new topic's placeholder.
        public var named = false
        /// `min` matches under every topic one level up, rather than in all.
        public var each = false
        /// Data flows (technical types: tree links and relationships) or relationships.
        public var edge: Edge?
        /// Boundaries (trust boundaries on a threat model).
        public var boundary = false
        /// Met when this rule set finds nothing: `dfd` (`DFDRules`).
        public var rules: String?

        public struct Edge: Sendable, Equatable {
            public var labelled = false
            public init(labelled: Bool = false) { self.labelled = labelled }
        }

        public init(
            nodeTypes: [NodeType] = [], depth: Int? = nil, kind: NodeRole? = nil, named: Bool = false,
            each: Bool = false, edge: Edge? = nil, boundary: Bool = false, rules: String? = nil
        ) {
            self.nodeTypes = nodeTypes
            self.depth = depth
            self.kind = kind
            self.named = named
            self.each = each
            self.edge = edge
            self.boundary = boundary
            self.rules = rules
        }

        /// The node type a step's row shows, if it names one.
        public var glyph: NodeType? { nodeTypes.first }
    }

    public init(id: String, type: DiagramType, steps: [Step], example: [String] = []) {
        self.id = id
        self.type = type
        self.steps = steps
        self.example = example
    }
}

extension Guide {
    /// Reads a guide file's JSON (see `schema/guide.schema.json`).
    public init(json: JSONValue, path: String = "guide") throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        type = DiagramType(rawValue: try r.string("type"))
        example = try r.strings("example")
        steps = try r.array("steps").enumerated().map { i, s in
            let p = "\(path).steps[\(i)]"
            var r = try ObjectReader(s, path: p)
            var m = try ObjectReader(r.raw("match") ?? [:], path: "\(p).match")
            var match = Match()
            if let one = try? m.optionalString("nodeType") {
                match.nodeTypes = [NodeType(rawValue: one)]
            } else {
                match.nodeTypes = try m.strings("nodeType").map { NodeType(rawValue: $0) }
            }
            match.depth = try m.optionalInt("depth", in: 0...64)
            match.kind = try m.optionalString("kind").map { NodeRole(rawValue: $0) }
            match.named = try m.bool("named", default: false)
            match.each = try m.bool("each", default: false)
            if let e = m.raw("edge") {
                var er = try ObjectReader(e, path: "\(p).match.edge")
                match.edge = Match.Edge(labelled: try er.bool("labelled", default: false))
            }
            match.boundary = try m.bool("boundary", default: false)
            match.rules = try m.optionalString("rules")
            return Step(
                id: try r.string("id"), match: match, min: try r.optionalInt("min", in: 0...1000) ?? 1,
                optional: try r.bool("optional", default: false), title: try r.string("title"),
                tip: try r.optionalString("tip") ?? "")
        }
    }
}

/// A canvas's guide state: only the steps skipped, and which guide they belong to. Visibility
/// is window state, and progress is read from the document, so neither is stored.
public struct GuideSettings: Hashable, Sendable, JSONRepresentable {
    public var id: String?
    public var skipped: [String] = []
    public var extra: [String: JSONValue] = [:]

    public init(id: String? = nil, skipped: [String] = []) {
        self.id = id
        self.skipped = skipped
    }

    public var isDefault: Bool { skipped.isEmpty && extra.isEmpty }

    /// The steps skipped in `guide` (none when they were skipped in another guide).
    public func skipped(in guide: String) -> Set<String> { id == guide ? Set(skipped) : [] }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.optionalString("id")
        skipped = try r.strings("skipped")
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("skipped", skipped, omitEmpty: true)
        return w.value
    }
}

extension CanvasEditor {
    /// Skip a guide step, or bring it back: an edit, so it saves and undoes (M41).
    public mutating func toggleGuideSkip(_ step: String, in guide: String) {
        updateMeta { c in
            if c.guide.id != guide { c.guide = GuideSettings(id: guide) }
            if let i = c.guide.skipped.firstIndex(of: step) {
                c.guide.skipped.remove(at: i)
            } else {
                c.guide.skipped.append(step)
            }
            if c.guide.skipped.isEmpty { c.guide = GuideSettings() }
        }
    }
}

/// Where a canvas stands in its guide.
public struct GuideProgress: Sendable, Equatable {
    public enum State: Sendable, Equatable { case upcoming, current, done, skipped }

    public struct Step: Sendable, Equatable {
        public var id: String
        public var state: State
        public var met: Bool
        public var optional: Bool
        /// Matches so far, and how many meet the step (with `each`: parents served, of all).
        public var count: Int
        public var needed: Int
        /// The topics it matched, in tree order (for an edge, the topic it reaches; for a
        /// rule, the topics it flags).
        public var nodes: [NodeID]
    }

    public var steps: [Step]
    /// The step the selection is on, or else the first one still to do.
    public var current: Int?

    /// Steps met or skipped.
    public var done: Int { steps.filter { $0.met || $0.state == .skipped }.count }
    public var total: Int { steps.count }
    /// Every required step is met or skipped.
    public var complete: Bool { steps.allSatisfy { $0.optional || $0.met || $0.state == .skipped } }

    /// The same progress with the current step for `selection`: the step whose matches
    /// include it, or else the first required step still to do, then the first optional one.
    public func focused(on selection: NodeID?) -> GuideProgress {
        var p = self
        for i in p.steps.indices where p.steps[i].state == .current {
            p.steps[i].state = p.steps[i].met ? .done : .upcoming
        }
        func open(_ i: Int) -> Bool { !p.steps[i].met && p.steps[i].state != .skipped }
        p.current =
            selection.flatMap { sel in
                p.steps.indices.first { p.steps[$0].state != .skipped && p.steps[$0].nodes.contains(sel) }
            }
            ?? p.steps.indices.first { open($0) && !p.steps[$0].optional }
            ?? p.steps.indices.first(where: open)
        if let c = p.current { p.steps[c].state = .current }
        return p
    }
}

/// Matches a guide against a canvas (M41). Pure, like `DFDRules.check`: the panel runs it
/// after edits and selection changes, never on the keystroke path.
public enum GuideMatcher {
    public static func progress(
        _ canvas: Canvas, _ guide: Guide, selection: NodeID? = nil, skipped: Set<String> = []
    ) -> GuideProgress {
        evaluate(canvas, guide, skipped: skipped).focused(on: selection)
    }

    /// What each step matches, with no current step yet: the costly half, which the panel
    /// keeps per document revision so moving the selection only refocuses it.
    /// `types`: each topic's effective type, when the caller has them (the scene does).
    public static func evaluate(
        _ canvas: Canvas, _ guide: Guide, skipped: Set<String> = [], types known: [NodeID: NodeType]? = nil
    ) -> GuideProgress {
        let parents = canvas.parentMap()
        // Every attached topic in tree order, with its depth. Depths count from the root:
        // a floating or summary topic isn't the central topic, nor its children main topics.
        var order: [(id: NodeID, depth: Int)] = []
        var rootTree = Set<NodeID>()
        order.reserveCapacity(canvas.nodes.count)
        for top in canvas.tops {
            var stack = [(top, 0)]
            while let (id, d) = stack.popLast() {
                guard let n = canvas.nodes[id] else { continue }
                order.append((id, d))
                if top == canvas.root { rootTree.insert(id) }
                stack.append(contentsOf: n.children.reversed().map { ($0, d + 1) })
            }
        }
        var types: [NodeID: NodeType?] = [:]
        func type(_ id: NodeID) -> NodeType? {
            if let known { return known[id] }
            if let t = types[id] { return t }
            let t = DiagramCatalog.effectiveType(id, in: canvas, parents: parents)
            types[id] = t
            return t
        }
        func named(_ id: NodeID, depth: Int) -> Bool {
            let text = canvas.nodes[id]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return false }
            let placeholders: Set<String> =
                id == canvas.root
                ? ["Central Topic", DiagramDescriptor[canvas.type].rootText]
                : ["Floating Topic", defaultTopicText(type: canvas.type, depth: depth)]
            return !placeholders.contains(text)
        }
        func topicMatches(_ m: Guide.Match, _ id: NodeID, _ depth: Int) -> Bool {
            if let d = m.depth, d != depth || !rootTree.contains(id) { return false }
            if let k = m.kind, canvas.nodes[id]?.kind != k { return false }
            if !m.nodeTypes.isEmpty, !(type(id).map(m.nodeTypes.contains) ?? false) { return false }
            if m.named, !named(id, depth: depth) { return false }
            return true
        }
        let technical = DiagramCatalog.isTechnical(canvas.type)
        var graph: FlowGraph?

        let steps: [GuideProgress.Step] = guide.steps.map { s in
            let m = s.match
            var count = 0
            var needed = s.min
            var nodes: [NodeID] = []
            var met: Bool
            if let rules = m.rules {
                var flagged: [NodeID] = []
                if rules == "dfd" {
                    if graph == nil { graph = FlowGraph(canvas, types: known) }
                    let from = Dictionary(graph!.flows.map { ($0.id, $0.from) }, uniquingKeysWith: { a, _ in a })
                    flagged = DFDRules.check(canvas, graph: graph).compactMap {
                        switch $0.subject {
                        case .node(let id): id
                        case .flow(let f): from[f]
                        }
                    }
                }
                count = flagged.count
                needed = 0
                nodes = flagged
                // Nothing to check yet isn't a pass.
                met = flagged.isEmpty && order.count > 2
            } else if let e = m.edge {
                if technical {
                    if graph == nil { graph = FlowGraph(canvas, types: known) }
                    for f in graph!.flows where !e.labelled || !f.label.trimmingCharacters(in: .whitespaces).isEmpty {
                        count += 1
                        nodes.append(f.to)
                    }
                } else {
                    for r in canvas.relationships
                    where !e.labelled || !r.label.trimmingCharacters(in: .whitespaces).isEmpty {
                        count += 1
                        if let t = r.to.topic { nodes.append(t) }
                    }
                }
                met = count >= s.min
            } else if m.boundary {
                count = canvas.boundaries.count
                nodes = canvas.boundaries.flatMap(\.nodes)
                met = count >= s.min
            } else if m.each, let d = m.depth, d > 0 {
                // Every topic a level up has `min` matching children.
                let hosts = order.filter { $0.depth == d - 1 && rootTree.contains($0.id) }
                needed = hosts.count
                for h in hosts {
                    let kids = (canvas.nodes[h.id]?.children ?? []).filter { topicMatches(m, $0, d) }
                    if kids.count >= s.min { count += 1 }
                    nodes += kids
                }
                met = needed > 0 && count == needed
            } else {
                for (id, d) in order where topicMatches(m, id, d) {
                    count += 1
                    nodes.append(id)
                }
                met = count >= s.min
            }
            return GuideProgress.Step(
                id: s.id, state: skipped.contains(s.id) && !met ? .skipped : met ? .done : .upcoming, met: met,
                optional: s.optional, count: count, needed: needed, nodes: nodes)
        }

        return GuideProgress(steps: steps, current: nil)
    }
}
