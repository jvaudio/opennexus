import Foundation
import NexusCore

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

    /// A relationship between two outline topics, found by their text (the first in
    /// outline order).
    public struct Link: Sendable, Equatable {
        public var from: String
        public var to: String
        public var label: String
        /// A relationship kind, such as a sequence diagram's `return` message.
        public var kind: String?
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

    public var isBlank: Bool { outline.isEmpty }

    /// A new document: a Blank starter takes Settings › New documents and the default look;
    /// a template is built as written.
    @MainActor
    public func document(prefs: Preferences = .isolated()) -> DocumentModel {
        if isBlank { return CanvasController.newDocumentModel(prefs: prefs, type: type) }
        return DocumentModel(canvases: [canvas(id: "c1")])
    }

    /// The template's canvas, built through the same editor operations a user would.
    func canvas(id: CanvasID) -> Canvas {
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
    /// Reads a starter file. Throws when a field is missing or names an unknown category
    /// or shelf; `starter.schema.json` describes the format.
    init(json data: Data) throws {
        struct File: Decodable {
            var id, name, summary, kicker, category, type, title: String
            var order: Int
            var shelf: String?
            var aliases: [String]?
            var outline: [String]
            var relationships: [LinkFile]?
        }
        struct LinkFile: Decodable {
            var from, to: String
            var label: String?
            var kind: String?
        }
        let f = try JSONDecoder().decode(File.self, from: data)
        guard let category = StarterCategory(rawValue: f.category) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown category \(f.category)"))
        }
        let shelf = try f.shelf.map { s in
            guard let v = Shelf(rawValue: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown shelf \(s)"))
            }
            return v
        }
        self.init(
            id: f.id, name: f.name, summary: f.summary, kicker: f.kicker, category: category, shelf: shelf,
            aliases: f.aliases ?? [], type: DiagramType(rawValue: f.type), title: f.title, outline: f.outline,
            relationships: (f.relationships ?? []).map {
                Link(from: $0.from, to: $0.to, label: $0.label ?? "", kind: $0.kind)
            },
            order: f.order)
    }
}

/// The built-in starters: the templates, read from `Starters/`, and a Blank starter per
/// diagram type.
public enum StarterLibrary {
    /// The 25 templates, in shelf order.
    public static let templates: [Starter] = (try? load()) ?? []
    /// One Blank starter per diagram type, in `DiagramDescriptor.all`'s order.
    public static let blanks: [Starter] = DiagramDescriptor.all.map(Starter.blank)
    public static var all: [Starter] { blanks + templates }

    public static func starter(_ id: String) -> Starter? { all.first { $0.id == id } }

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
