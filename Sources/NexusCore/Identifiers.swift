import Foundation

/// A node id such as `n12`. Ids are sequential per canvas so files diff cleanly.
public struct NodeID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Numeric suffix of ids shaped like `n12`, used to seed new ids.
    public var sequence: Int? {
        let digits = rawValue.drop { !$0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Natural ordering: `n2` sorts before `n10`.
    public static func < (a: NodeID, b: NodeID) -> Bool {
        a.rawValue.compare(b.rawValue, options: .numeric) == .orderedAscending
    }
}

public struct CanvasID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static func < (a: CanvasID, b: CanvasID) -> Bool {
        a.rawValue.compare(b.rawValue, options: .numeric) == .orderedAscending
    }
}

/// An open string enumeration: known values are named constants, and unknown
/// values from newer files are kept as they are.
public protocol OpenEnum: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral
where RawValue == String {
    init(rawValue: String)
}

extension OpenEnum {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// Xmind's topic roles.
public struct NodeRole: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let root: NodeRole = "root"
    public static let topic: NodeRole = "topic"
    public static let floating: NodeRole = "floating"
    public static let summary: NodeRole = "summary"
}

/// The diagram type of a canvas. A view over the same graph, never a copy.
public struct DiagramType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let mindmap: DiagramType = "mindmap"
    public static let logic: DiagramType = "logic"
    public static let brace: DiagramType = "brace"
    public static let org: DiagramType = "org"
    public static let tree: DiagramType = "tree"
    public static let treeTable: DiagramType = "treeTable"
    public static let timeline: DiagramType = "timeline"
    public static let fishbone: DiagramType = "fishbone"
    public static let matrix: DiagramType = "matrix"
    public static let flowchart: DiagramType = "flowchart"
    public static let swimlane: DiagramType = "swimlane"
    public static let dfd: DiagramType = "dfd"
    public static let threatModel: DiagramType = "threatModel"
    public static let architecture: DiagramType = "architecture"
    public static let sequence: DiagramType = "sequence"
    public static let whiteboard: DiagramType = "whiteboard"
}

/// A layout structure, written `family.variant` (for example `mindmap.balanced`).
public struct LayoutStructure: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let mindmapBalanced: LayoutStructure = "mindmap.balanced"
    public static let mindmapRight: LayoutStructure = "mindmap.right"
    public static let mindmapLeft: LayoutStructure = "mindmap.left"
    public static let logicRight: LayoutStructure = "logic.right"
    public static let logicLeft: LayoutStructure = "logic.left"
    public static let braceRight: LayoutStructure = "brace.right"
    public static let orgDown: LayoutStructure = "org.down"
    public static let treeDown: LayoutStructure = "tree.down"
    public static let treeIndented: LayoutStructure = "tree.indented"
    public static let timelineHorizontal: LayoutStructure = "timeline.horizontal"
    public static let fishboneLeft: LayoutStructure = "fishbone.left"
    public static let matrix: LayoutStructure = "matrix.grid"
    public static let treeTable: LayoutStructure = "treeTable.rows"

    public var family: String { String(rawValue.split(separator: ".").first ?? "") }
}

public struct LayoutMode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let auto: LayoutMode = "auto"
    public static let free: LayoutMode = "free"
}
