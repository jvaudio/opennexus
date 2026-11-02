import Foundation
import NexusCore
import NexusLayout
import NexusScene
import NexusTheme

/// A skeleton pairs a structure with a node style and a branch line.
public struct Skeleton: Sendable, Identifiable, Equatable {
    public var id: String { "\(structure.rawValue)|\(nodeStyle.rawValue)|\(line)" }
    public var name: String
    public var structure: LayoutStructure
    public var nodeStyle: NodeStyle
    public var line: String
    public var icon: String

    static let icons: [String: String] = [
        "mindmap":
            "M28 20 m-6 0 a6 4 0 1 0 12 0 a6 4 0 1 0 -12 0 M34 20 L46 10 M34 20 L48 20 M34 20 L46 30 M22 20 L10 10 M22 20 L8 30",
        "logic": "M4 20 h10 M14 20 V8 h10 M14 20 h10 M14 20 V32 h10 M28 8 h20 M28 20 h20 M28 32 h20",
        "org":
            "M22 4 h12 v8 h-12 z M28 12 v6 M10 18 h36 M10 18 v6 M28 18 v6 M46 18 v6 M4 24 h12 v8 H4 z M22 24 h12 v8 H22 z M40 24 h12 v8 H40 z",
        "timeline": "M4 20 h48 M10 14 h10 v12 h-10 z M26 14 h10 v12 h-10 z M42 14 h10 v12 h-10 z",
        "fishbone": "M4 20 h38 M42 14 L50 20 L42 26 M16 20 L10 6 M30 20 L24 6 M16 20 L10 34 M30 20 L24 34",
        "matrix": "M4 4 h22 v14 H4 z M30 4 h22 v14 H30 z M4 22 h22 v14 H4 z M30 22 h22 v14 H30 z",
        "brace": "M10 20 q-6 0 -6 -6 v-6 M10 20 q-6 0 -6 6 v6 M14 6 h14 M14 20 h14 M14 34 h14 M32 6 h18",
        "tree": "M28 4 v32 M28 10 h-16 M28 20 h18 M28 30 h-14",
        "treeTable": "M8 6 h40 v28 H8 z M8 14 h40 M20 6 v28",
    ]

    /// FMT-3's nine, in its order.
    public static let featured: [Skeleton] = [
        Skeleton(
            name: Loc.t("Mind Map"), structure: .mindmapBalanced, nodeStyle: .outline, line: "curved",
            icon: icons["mindmap"]!),
        Skeleton(
            name: Loc.t("Logic Chart"), structure: .logicRight, nodeStyle: .soft, line: "curved", icon: icons["logic"]!),
        Skeleton(
            name: Loc.t("Org Chart"), structure: .orgDown, nodeStyle: .outline, line: "elbow", icon: icons["org"]!),
        Skeleton(
            name: Loc.t("Timeline"), structure: .timelineHorizontal, nodeStyle: .capsule, line: "straight",
            icon: icons["timeline"]!),
        Skeleton(
            name: Loc.t("Fishbone"), structure: .fishboneLeft, nodeStyle: .outline, line: "straight",
            icon: icons["fishbone"]!),
        Skeleton(
            name: Loc.t("Matrix"), structure: .matrix, nodeStyle: .solid, line: "straight", icon: icons["matrix"]!),
        Skeleton(
            name: Loc.t("Brace Map"), structure: .braceRight, nodeStyle: .minimal, line: "curved", icon: icons["brace"]!
        ),
        Skeleton(
            name: Loc.t("Tree Chart"), structure: .treeDown, nodeStyle: .underline, line: "elbow", icon: icons["tree"]!),
        Skeleton(
            name: Loc.t("Tree Table"), structure: .treeTable, nodeStyle: .brutal, line: "elbow",
            icon: icons["treeTable"]!),
    ]

    /// The full gallery of 24 (README §14: derived from structures × node styles × lines).
    public static let gallery: [Skeleton] =
        featured + [
            Skeleton(
                name: Loc.t("Mind Map · Soft"), structure: .mindmapBalanced, nodeStyle: .soft, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: Loc.t("Mind Map · Underline"), structure: .mindmapBalanced, nodeStyle: .underline, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: Loc.t("Mind Map · Sketch"), structure: .mindmapBalanced, nodeStyle: .sketch, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: Loc.t("Mind Map · Glow"), structure: .mindmapBalanced, nodeStyle: .glow, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: Loc.t("Mind Map · Minimal"), structure: .mindmapBalanced, nodeStyle: .minimal, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: Loc.t("Right Map · Capsule"), structure: .mindmapRight, nodeStyle: .capsule, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: Loc.t("Logic · Outline"), structure: .logicRight, nodeStyle: .outline, line: "rounded",
                icon: icons["logic"]!),
            Skeleton(
                name: Loc.t("Logic · Brutal"), structure: .logicRight, nodeStyle: .brutal, line: "elbow",
                icon: icons["logic"]!
            ),
            Skeleton(
                name: Loc.t("Logic · Underline"), structure: .logicRight, nodeStyle: .underline, line: "curved",
                icon: icons["logic"]!),
            Skeleton(
                name: Loc.t("Logic Left · Solid"), structure: .logicLeft, nodeStyle: .solid, line: "curved",
                icon: icons["logic"]!),
            Skeleton(
                name: Loc.t("Org · Solid"), structure: .orgDown, nodeStyle: .solid, line: "rounded", icon: icons["org"]!
            ),
            Skeleton(
                name: Loc.t("Org · Capsule"), structure: .orgDown, nodeStyle: .capsule, line: "elbow",
                icon: icons["org"]!),
            Skeleton(
                name: Loc.t("Tree · Minimal"), structure: .treeDown, nodeStyle: .minimal, line: "straight",
                icon: icons["tree"]!),
            Skeleton(
                name: Loc.t("Timeline · Solid"), structure: .timelineHorizontal, nodeStyle: .solid, line: "straight",
                icon: icons["timeline"]!),
            Skeleton(
                name: Loc.t("Fishbone · Brutal"), structure: .fishboneLeft, nodeStyle: .brutal, line: "straight",
                icon: icons["fishbone"]!),
        ]
}
