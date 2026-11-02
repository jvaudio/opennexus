import Foundation
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene

/// A starter: a card in the starter picker (M40) and on Home's template shelf (artboard
/// 16). The built-in templates are JSON files in `Starters/`, checked against
/// `schema/starter.schema.json` (M39, D288); every diagram type also has a generated
/// Blank starter. Names, summaries and kickers are English, shown through `Loc.t`.
public struct Starter: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var kicker: String
    public var category: StarterCategory
    /// Home's shelf for the role picked in onboarding; nil for a Blank starter.
    public var shelf: Shelf?
    /// Search terms for the picker, in English (not localised).
    public var aliases: [String]
    public var type: DiagramType
    /// The canvas title; the root topic is the outline's first line.
    public var title: String
    /// `"Text"` or `"Text >nodeType"`, indented two spaces a level. Empty for a Blank starter.
    public var outline: [String]
    public var relationships: [Link]
    /// Position among the built-ins: Home's shelves keep this order.
    var order: Int
    /// The picker's shelf (M50); nil for a Blank starter.
    public var collection: StarterCollection?
    /// The root topic's note: how to use the starter.
    public var note: String?
    /// Notes, edge labels, markers and tasks on outline topics.
    public var details: [Detail] = []
    public var boundaries: [Grouping] = []
    /// A swimlane's lanes, top to bottom.
    public var lanes: [Grouping] = []
    /// The canvas's structure when it isn't the type's own.
    public var structure: LayoutStructure?
    /// A starter saved from a canvas (M50): its one-canvas document, in place of an outline.
    public var saved: DocumentModel?
    /// One of the user's own (My Starters), not a built-in.
    public var mine = false

    /// A relationship between two outline topics, found by their text (the first in
    /// outline order).
    public struct Link: Sendable, Equatable {
        public var from: String
        public var to: String
        public var label: String
        /// A relationship kind, such as a sequence diagram's `return` message.
        public var kind: String?
    }

    /// More about an outline topic, found by its text (the first in outline order).
    public struct Detail: Sendable, Equatable {
        public var topic: String
        public var note: String?
        /// The label on the edge into the topic.
        public var edge: String?
        public var markers: [String] = []
        public var done: Bool?
        public var progress: Int?
        /// A task's first day and length, counted from the day the starter is used.
        public var start: Int?
        public var days: Int?

        public init(topic: String) { self.topic = topic }

        var isTask: Bool { done != nil || progress != nil || start != nil || days != nil }
    }

    /// A boundary, or a swimlane's lane, around outline topics found by their text.
    public struct Grouping: Sendable, Equatable {
        public var title: String
        public var topics: [String]
        /// A boundary's meaning (group, zone, vpc, subnet, trust) and a trust boundary's level.
        public var meaning: String?
        public var trust: String?

        public init(title: String, topics: [String], meaning: String? = nil, trust: String? = nil) {
            self.title = title
            self.topics = topics
            self.meaning = meaning
            self.trust = trust
        }
    }

    /// Home's template shelves, one per role (artboard 16).
    public enum Shelf: String, CaseIterable, Sendable {
        case engineering, architecture, security, planning, learning

        public var title: String {
            switch self {
            case .engineering: Loc.t("Engineering")
            case .architecture: Loc.t("Architecture")
            case .security: Loc.t("Security")
            case .planning: Loc.t("Planning")
            case .learning: Loc.t("Learning")
            }
        }
    }

    public var isBlank: Bool { outline.isEmpty && saved == nil }

    /// A new document: a Blank starter takes Settings › New documents and the default look;
    /// a template is built as written; a saved starter is its document.
    @MainActor
    public func document(prefs: Preferences = .isolated(), today: TaskDate = .today()) -> DocumentModel {
        if isBlank { return CanvasController.newDocumentModel(prefs: prefs, type: type) }
        if let saved { return saved }
        return DocumentModel(canvases: [canvas(id: "c1", today: today)])
    }

    /// The canvas a template builds, or a saved starter's canvas; its assets come with it.
    func canvases(today: TaskDate = .today()) -> (canvases: [Canvas], assets: [String: Data]) {
        if let saved { return (saved.orderedCanvases, saved.assets) }
        return ([canvas(id: "c1", today: today)], [:])
    }

    /// The template's canvas, built through the same editor operations a user would.
    /// `today` anchors scheduled tasks.
    func canvas(id: CanvasID, today: TaskDate = .today()) -> Canvas {
        let rows = outline.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let rootText =
            rows.first?.trimmingCharacters(in: .whitespaces).split(separator: ">").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? title
        var c = Canvas(id: id, title: title, type: type, rootText: rootText)
        var undo = UndoStack()
        c.edit("Template", undo: &undo) { e in
            var made: [(text: String, id: NodeID)] = [(rootText, e.canvas.root)]
            var stack: [(Int, NodeID)] = [(0, e.canvas.root)]
            if let t = rows.first?.split(separator: ">").dropFirst().first {
                e.update(e.canvas.root) { $0.nodeType = NodeType(rawValue: t.trimmingCharacters(in: .whitespaces)) }
            }
            for r in rows.dropFirst() {
                let depth = r.prefix { $0 == " " }.count / 2
                let parts = r.trimmingCharacters(in: .whitespaces).split(separator: ">", maxSplits: 1)
                let text = parts[0].trimmingCharacters(in: .whitespaces)
                while let last = stack.last, last.0 >= depth { stack.removeLast() }
                let parent = stack.last?.1 ?? e.canvas.root
                guard let id = try? e.addChild(of: parent, text: text) else { continue }
                if parts.count > 1 {
                    e.update(id) { $0.nodeType = NodeType(rawValue: parts[1].trimmingCharacters(in: .whitespaces)) }
                }
                stack.append((depth, id))
                made.append((text, id))
            }
            for link in relationships {
                guard let a = made.first(where: { $0.text == link.from })?.id,
                    let b = made.first(where: { $0.text == link.to })?.id
                else { continue }
                let r = e.connect(a, to: b, label: link.label)
                if let kind = link.kind { e.updateRelationship(r) { $0.kind = kind } }
            }
            func node(_ text: String) -> NodeID? { made.first { $0.text == text }?.id }
            if let note { e.update(e.canvas.root) { $0.note = Note(text: note) } }
            for d in details {
                guard let id = node(d.topic) else { continue }
                e.update(id) { n in
                    if let t = d.note { n.note = Note(text: t) }
                    if let t = d.edge { n.edgeLabel = t }
                    n.markers += d.markers.filter { !n.markers.contains($0) }
                    if d.isTask {
                        var t = n.todo ?? Todo(done: d.done ?? false)
                        t.progress = d.progress
                        if let start = d.start {
                            t.start = TaskDate(day: today.day + start)
                            t.due = TaskDate(day: today.day + start + max((d.days ?? 1) - 1, 0))
                        } else if let days = d.days {
                            t.due = TaskDate(day: today.day + days)
                        }
                        n.todo = t
                    }
                }
            }
            for g in boundaries {
                guard let b = try? e.addBoundary(around: g.topics.compactMap(node), title: g.title) else { continue }
                e.updateBoundary(b) { x in
                    if let m = g.meaning { x.meaning = m }
                    x.trust = g.trust
                }
            }
            if !lanes.isEmpty {
                e.updateMeta {
                    $0.diagram.lanes = lanes.indices.map { Lane(id: "l\($0 + 1)", title: lanes[$0].title) }
                }
                // A topic takes the lane that lists it, else its parent's, else the first.
                let parents = e.canvas.parentMap()
                var lane: [NodeID: String] = [:]
                for (text, id) in made {
                    let listed = lanes.firstIndex { $0.topics.contains(text) }.map { "l\($0 + 1)" }
                    lane[id] = listed ?? parents[id].flatMap { lane[$0] } ?? "l1"
                    e.update(id) { $0.lane = lane[id] }
                }
            }
            if let structure { e.updateMeta { $0.layout.structure = structure } }
        }
        return c
    }

    /// The Blank starter for a diagram type.
    static func blank(_ d: DiagramDescriptor) -> Starter {
        Starter(
            id: "blank.\(d.type.rawValue)", name: d.name, summary: d.summary, kicker: "BLANK", category: d.category,
            shelf: nil, aliases: d.aliases, type: d.type, title: "", outline: [], relationships: [], order: 0)
    }
}

extension Starter {
    /// Reads a starter file. Throws when a field is missing or names an unknown category,
    /// shelf or collection; `starter.schema.json` describes the format.
    init(json data: Data) throws {
        struct File: Decodable {
            var id, name, summary, kicker, category, type, title: String
            var order: Int
            var shelf, collection, note, structure: String?
            var aliases: [String]?
            var outline: [String]?
            var relationships: [LinkFile]?
            var details: [DetailFile]?
            var boundaries, lanes: [GroupFile]?
        }
        struct LinkFile: Decodable {
            var from, to: String
            var label: String?
            var kind: String?
        }
        struct DetailFile: Decodable {
            var topic: String
            var note, edge: String?
            var markers: [String]?
            var done: Bool?
            var progress, start, days: Int?
        }
        struct GroupFile: Decodable {
            var title: String?
            var topics: [String]
            var meaning, trust: String?
        }
        func bad(_ why: String) -> DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: why)) }
        let f = try JSONDecoder().decode(File.self, from: data)
        guard let category = StarterCategory(rawValue: f.category) else { throw bad("unknown category \(f.category)") }
        let shelf = try f.shelf.map { s in
            guard let v = Shelf(rawValue: s) else { throw bad("unknown shelf \(s)") }
            return v
        }
        let collection = try f.collection.map { s in
            guard let v = StarterCollection(rawValue: s) else { throw bad("unknown collection \(s)") }
            return v
        }
        // A saved starter's canvas comes as a whole one-canvas document (M50).
        var saved: DocumentModel?
        if let d = try CanonicalJSON.parse(data)["document"] {
            let doc = try DocumentJSON.parse(CanonicalJSON.data(d), name: f.name)
            guard doc.canvasOrder.count == 1 else { throw bad("a starter's document holds one canvas") }
            saved = doc
        }
        guard (f.outline ?? []).isEmpty != (saved == nil) else { throw bad("a starter has an outline or a document") }
        self.init(
            id: f.id, name: f.name, summary: f.summary, kicker: f.kicker, category: category, shelf: shelf,
            aliases: f.aliases ?? [], type: DiagramType(rawValue: f.type), title: f.title, outline: f.outline ?? [],
            relationships: (f.relationships ?? []).map {
                Link(from: $0.from, to: $0.to, label: $0.label ?? "", kind: $0.kind)
            },
            order: f.order, collection: collection, note: f.note,
            details: (f.details ?? []).map {
                var d = Detail(topic: $0.topic)
                d.note = $0.note
                d.edge = $0.edge
                d.markers = $0.markers ?? []
                d.done = $0.done
                d.progress = $0.progress
                d.start = $0.start
                d.days = $0.days
                return d
            },
            boundaries: (f.boundaries ?? []).map {
                Grouping(title: $0.title ?? "", topics: $0.topics, meaning: $0.meaning, trust: $0.trust)
            },
            lanes: (f.lanes ?? []).map { Grouping(title: $0.title ?? "", topics: $0.topics) },
            structure: f.structure.map(LayoutStructure.init(rawValue:)), saved: saved)
    }

    /// The starter as a file, canonical JSON in `starter.schema.json`'s format: what My
    /// Starters keeps and Export Starter… writes.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "summary": .string(summary), "kicker": .string(kicker),
            "category": .string(category.rawValue), "type": .string(type.rawValue), "title": .string(title),
            "order": .number(Double(order)),
        ]
        if let shelf { o["shelf"] = .string(shelf.rawValue) }
        if let collection { o["collection"] = .string(collection.rawValue) }
        if !aliases.isEmpty { o["aliases"] = .array(aliases.map(JSONValue.string)) }
        if !outline.isEmpty { o["outline"] = .array(outline.map(JSONValue.string)) }
        if let note { o["note"] = .string(note) }
        if let structure { o["structure"] = .string(structure.rawValue) }
        if !relationships.isEmpty {
            o["relationships"] = .array(
                relationships.map { l in
                    var r: [String: JSONValue] = ["from": .string(l.from), "to": .string(l.to)]
                    if !l.label.isEmpty { r["label"] = .string(l.label) }
                    if let k = l.kind { r["kind"] = .string(k) }
                    return .object(r)
                })
        }
        if !details.isEmpty {
            o["details"] = .array(
                details.map { d in
                    var r: [String: JSONValue] = ["topic": .string(d.topic)]
                    if let v = d.note { r["note"] = .string(v) }
                    if let v = d.edge { r["edge"] = .string(v) }
                    if !d.markers.isEmpty { r["markers"] = .array(d.markers.map(JSONValue.string)) }
                    if let v = d.done { r["done"] = .bool(v) }
                    if let v = d.progress { r["progress"] = .number(Double(v)) }
                    if let v = d.start { r["start"] = .number(Double(v)) }
                    if let v = d.days { r["days"] = .number(Double(v)) }
                    return .object(r)
                })
        }
        func groups(_ gs: [Grouping]) -> JSONValue {
            .array(
                gs.map { g in
                    var r: [String: JSONValue] = ["topics": .array(g.topics.map(JSONValue.string))]
                    if !g.title.isEmpty { r["title"] = .string(g.title) }
                    if let v = g.meaning { r["meaning"] = .string(v) }
                    if let v = g.trust { r["trust"] = .string(v) }
                    return .object(r)
                })
        }
        if !boundaries.isEmpty { o["boundaries"] = groups(boundaries) }
        if !lanes.isEmpty { o["lanes"] = groups(lanes) }
        if let saved, let d = try? CanonicalJSON.parse(Data(DocumentJSON.export(saved, assets: true).utf8)) {
            o["document"] = d
        }
        return .object(o)
    }
}

/// The starter picker's shelves (M50): a third grouping beside the categories (For You)
/// and Home's role shelves. English; the UI looks each up in the string catalog.
public enum StarterCollection: String, CaseIterable, Sendable {
    case business, engineering, product, process, planning, thinking, security, architecture, personal, meetings

    public var title: String {
        switch self {
        case .business: "Business and strategy"
        case .engineering: "Engineering and software"
        case .product: "Product and design"
        case .process: "Process and operations"
        case .planning: "Planning and projects"
        case .thinking: "Thinking and learning"
        case .security: "Security and risk"
        case .architecture: "Architecture and cloud"
        case .personal: "Personal and life"
        case .meetings: "Meetings and teams"
        }
    }
}

/// The built-in starters: the templates, read from `Starters/`, and a Blank starter per
/// diagram type.
public enum StarterLibrary {
    /// The built-in templates, in shelf order.
    public static let templates: [Starter] = (try? load()) ?? []
    /// One Blank starter per diagram type, in `DiagramDescriptor.all`'s order.
    public static let blanks: [Starter] = DiagramDescriptor.all.map(Starter.blank)
    public static var all: [Starter] { blanks + templates }

    /// A built-in, else one of the user's own.
    public static func starter(_ id: String, mine: MyStarters = .shared) -> Starter? {
        all.first { $0.id == id } ?? mine.starter(id)
    }

    public static func shelf(_ shelf: Starter.Shelf) -> [Starter] { templates.filter { $0.shelf == shelf } }

    static var folder: URL? { Bundle.module.url(forResource: "Starters", withExtension: nil) }

    /// Every starter file in the bundle, in order. Throws on the first that doesn't read,
    /// so a broken built-in fails the tests instead of vanishing from Home.
    static func load() throws -> [Starter] {
        guard let folder else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try files.map { try Starter(json: Data(contentsOf: $0)) }.sorted { $0.order < $1.order }
    }

    /// The tour's starting document for a role (lesson 1 names the root).
    public static func tourDocument(_ role: Role) -> DocumentModel {
        DocumentModel(canvases: [Canvas(id: "c1", title: "My first map", rootText: "")])
    }
}

/// The roles from the role picker (artboard 15).
public enum Role: String, CaseIterable, Sendable {
    case engineer, architect, security, planner

    public var title: String {
        switch self {
        case .engineer: Loc.t("Engineer")
        case .architect: Loc.t("Architect")
        case .security: Loc.t("Security")
        case .planner: "Planner · Student"
        }
    }

    public var blurb: String {
        switch self {
        case .engineer: Loc.t("Systems, APIs, incidents and sprints")
        case .architect: Loc.t("Platforms, migrations and decisions")
        case .security: Loc.t("Threats, data and access")
        case .planner: Loc.t("Projects, notes and ideas")
        }
    }

    /// The tour's example topic.
    public var tourExample: String {
        switch self {
        case .engineer: "Checkout service"
        case .architect: "Cloud migration"
        case .security: "Payment flow"
        case .planner: "Weekend trip"
        }
    }

    /// Lesson 5 converts the tour map to this.
    public var tourConversion: DiagramType {
        switch self {
        case .engineer: .flowchart
        case .architect: .architecture
        case .security: .dfd
        case .planner: .timeline
        }
    }

    public var conversionTitle: String {
        switch self {
        case .engineer: Loc.t("Flowchart")
        case .architect: Loc.t("Architecture")
        case .security: Loc.t("Data Flow + STRIDE")
        case .planner: "Timeline"
        }
    }

    public var shelfSummary: String {
        switch self {
        case .engineer: Loc.t("C4, API flow, retro")
        case .architect: Loc.t("Reference arch, ADR, capability map")
        case .security: Loc.t("Threat model, attack tree, IR runbook")
        case .planner: Loc.t("Roadmap, SWOT, book notes")
        }
    }

    public var shelf: Starter.Shelf {
        switch self {
        case .engineer: .engineering
        case .architect: .architecture
        case .security: .security
        case .planner: .planning
        }
    }

    /// "Templates for engineers".
    public var shelfTitle: String {
        switch self {
        case .engineer: Loc.t("Templates for engineers")
        case .architect: Loc.t("Templates for architects")
        case .security: Loc.t("Templates for security")
        case .planner: Loc.t("Templates for planners")
        }
    }
}
