import Foundation

/// What a starter or diagram type is for, in the starter picker (M40).
public enum StarterCategory: String, CaseIterable, Sendable {
    case thinking, planning, process, architecture, security, software

    /// English; the UI looks it up in the string catalog.
    public var title: String {
        switch self {
        case .thinking: "Thinking"
        case .planning: "Planning"
        case .process: "Process"
        case .architecture: "Architecture"
        case .security: "Security"
        case .software: "Software"
        }
    }
}

/// Everything a diagram type says about itself, in one table (M39, D286). Layouts,
/// rendering and the file-format mappings still branch on the type where a feature
/// belongs to one type; per-type traits and lists of every type read from here.
public struct DiagramDescriptor: Sendable {
    /// The node types a diagram offers in pickers and the slash menu.
    public enum Palette: Sendable { case none, flow, dfd, threat, icons, sequence }
    /// How an untyped node gets a type (`DiagramCatalog.effectiveType`).
    public enum Inference: Sendable { case none, flow, dfd, architecture, sequence }

    public var type: DiagramType
    /// English; the UI looks it up in the string catalog.
    public var name: String
    /// One line for the picker card.
    public var summary: String
    public var category: StarterCategory
    /// Search terms for the picker, in English (not localised).
    public var aliases: [String]
    public var structure: LayoutStructure
    /// The root topic of a new canvas.
    public var rootText: String
    /// A new topic's text at depth 1, and deeper; nil uses "Main Topic" and "Subtopic".
    public var mainTopicText: String?
    public var subtopicText: String?
    /// The type's colour on cards, recents and tabs (artboard 16).
    public var tint: String
    /// Technical types carry node types and graph layouts; hierarchy types convert
    /// losslessly with no questions.
    public var technical = false
    /// Converting to these asks the user to confirm first-level node types (artboard 10).
    public var asksForNodeTypes = false
    /// In these the central topic is the diagram's title, not a node in the graph.
    public var rootIsTitle = false
    public var palette = Palette.none
    public var inference = Inference.none

    /// A new topic's text at `depth`. A floating topic (depth 0) takes the subtopic text
    /// where the type names one, else "Main Topic".
    public func topicText(depth: Int) -> String {
        switch depth {
        case 1: mainTopicText ?? "Main Topic"
        case 2...: subtopicText ?? "Subtopic"
        default: subtopicText ?? "Main Topic"
        }
    }

    static let teal = "#0F9F9A"
    static let violet = "#9B51E0"
    static let gold = "#E0A300"

    /// Every type, in `DiagramType`'s order.
    public static let all: [DiagramDescriptor] = [
        DiagramDescriptor(
            type: .mindmap, name: "Mind Map", summary: "Ideas branching out from one central topic",
            category: .thinking, aliases: ["mind map", "mindmap", "brainstorm"], structure: .mindmapBalanced,
            rootText: "Central Topic", tint: teal),
        DiagramDescriptor(
            type: .logic, name: "Logic Chart", summary: "A hierarchy that reads from left to right",
            category: .thinking, aliases: ["logic chart", "logic", "outline"], structure: .logicRight,
            rootText: "Central Topic", tint: teal),
        DiagramDescriptor(
            type: .brace, name: "Brace Map", summary: "A whole and its parts, grouped by braces", category: .thinking,
            aliases: ["brace map", "brace", "parts"], structure: .braceRight, rootText: "Central Topic", tint: teal),
        DiagramDescriptor(
            type: .org, name: "Org Chart", summary: "Teams and who reports to whom, top down", category: .planning,
            aliases: ["org chart", "organisation", "organization", "reporting"], structure: .orgDown,
            rootText: "Central Topic", mainTopicText: "Lead", subtopicText: "Member", tint: teal),
        DiagramDescriptor(
            type: .tree, name: "Tree Chart", summary: "An indented hierarchy, like folders in a file tree",
            category: .thinking, aliases: ["tree chart", "tree", "hierarchy"], structure: .treeIndented,
            rootText: "Central Topic", tint: teal),
        DiagramDescriptor(
            type: .treeTable, name: "Tree Table", summary: "A hierarchy laid out as the rows of a table",
            category: .planning, aliases: ["tree table", "table", "wbs", "work breakdown"], structure: .treeTable,
            rootText: "Central Topic", tint: gold),
        DiagramDescriptor(
            type: .timeline, name: "Timeline", summary: "Events in order along a line", category: .planning,
            aliases: ["timeline", "roadmap", "history"], structure: .timelineHorizontal, rootText: "Timeline",
            mainTopicText: "Event", tint: gold),
        DiagramDescriptor(
            type: .fishbone, name: "Fishbone", summary: "The causes behind one effect", category: .process,
            aliases: ["fishbone", "ishikawa", "root cause", "cause and effect"], structure: .fishboneLeft,
            rootText: "Central Topic", tint: teal),
        DiagramDescriptor(
            type: .matrix, name: "Matrix", summary: "Topics in a grid of rows and columns", category: .thinking,
            aliases: ["matrix", "grid", "2x2", "swot"], structure: .matrix, rootText: "Central Topic", tint: teal),
        DiagramDescriptor(
            type: .flowchart, name: "Flowchart", summary: "Steps and decisions from start to finish",
            category: .process, aliases: ["flowchart", "flow", "process", "workflow"], structure: .flowDown,
            rootText: "Start", mainTopicText: "Step", subtopicText: "Step", tint: violet, technical: true,
            palette: .flow, inference: .flow),
        DiagramDescriptor(
            type: .swimlane, name: "Swimlane", summary: "A process split into lanes by who does each step",
            category: .process, aliases: ["swimlane", "swim lane", "cross-functional", "lanes"], structure: .swimlanes,
            rootText: "Central Topic", mainTopicText: "Step", subtopicText: "Step", tint: violet, technical: true,
            palette: .flow, inference: .flow),
        DiagramDescriptor(
            type: .dfd, name: "Data Flow", summary: "Processes, data stores and the data that moves between them",
            category: .security, aliases: ["dfd", "data flow", "context diagram"], structure: .graphRight,
            rootText: "Context", mainTopicText: "Process", subtopicText: "Data", tint: violet, technical: true,
            asksForNodeTypes: true, rootIsTitle: true, palette: .dfd, inference: .dfd),
        DiagramDescriptor(
            type: .threatModel, name: "Threat Model", summary: "A data flow with STRIDE threats for each element",
            category: .security, aliases: ["threat model", "threat", "stride", "security"], structure: .graphRight,
            rootText: "System", tint: "#D93A3F", technical: true, asksForNodeTypes: true, rootIsTitle: true,
            palette: .threat, inference: .dfd),
        DiagramDescriptor(
            type: .architecture, name: "Architecture", summary: "Services, data stores and networks, drawn as icons",
            category: .architecture, aliases: ["architecture", "system design", "c4", "cloud", "infrastructure"],
            structure: .graphRight, rootText: "Platform", tint: "#1E8BE0", technical: true, asksForNodeTypes: true,
            rootIsTitle: true, palette: .icons, inference: .architecture),
        DiagramDescriptor(
            type: .sequence, name: "Sequence", summary: "Messages between participants, in order",
            category: .software, aliases: ["sequence", "uml", "lifeline", "messages"], structure: .sequence,
            rootText: "Sequence", tint: teal, technical: true, rootIsTitle: true, palette: .sequence,
            inference: .sequence),
        DiagramDescriptor(
            type: .whiteboard, name: "Whiteboard", summary: "A plain canvas for loose ideas", category: .thinking,
            aliases: ["whiteboard", "freeform", "sketch"], structure: .mindmapBalanced, rootText: "Central Topic",
            tint: teal),
    ]

    static let byType: [DiagramType: DiagramDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })

    /// A type's descriptor. A type from a newer file reads as a mind map named after its id.
    public static subscript(_ type: DiagramType) -> DiagramDescriptor {
        byType[type]
            ?? DiagramDescriptor(
                type: type, name: type.rawValue, summary: "", category: .thinking, aliases: [],
                structure: .mindmapBalanced, rootText: "Central Topic", tint: teal)
    }

    /// The hierarchy type a structure family belongs to (⌥⌘1–9 names its structures by
    /// it): the first hierarchy type laid out in that family, else Mind Map.
    public static func hierarchyType(for structure: LayoutStructure) -> DiagramType {
        all.first { !$0.technical && $0.structure.family == structure.family }?.type ?? .mindmap
    }
}
