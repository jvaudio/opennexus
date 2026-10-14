import Foundation

/// How a node is drawn, by role. Values come from the P0 prototype's `measure()`
/// table, which is the reference for feel (see docs/DECISIONS.md).
public enum NodeRoleStyle: String, Sendable, CaseIterable {
    case root, main, sub, floating
}

public struct NodeTypography: Sendable, Equatable {
    public enum Weight: Sendable, Equatable { case regular, medium, semibold, bold, heavy }

    public var fontSize: Double
    public var weight: Weight
    public var lineHeight: Double
    public var paddingX: Double
    public var paddingY: Double
    public var minWidth: Double
    /// Wrap width. Users can drag a node edge to change it per node (M2).
    public var maxWidth: Double

    public static func `for`(_ role: NodeRoleStyle) -> NodeTypography {
        switch role {
        case .root:
            NodeTypography(
                fontSize: 20, weight: .bold, lineHeight: 26, paddingX: 22, paddingY: 13, minWidth: 130, maxWidth: 300)
        case .main, .floating:
            NodeTypography(
                fontSize: 15, weight: .medium, lineHeight: 20, paddingX: 16, paddingY: 9, minWidth: 72, maxWidth: 240)
        case .sub:
            NodeTypography(
                fontSize: 13.5, weight: .regular, lineHeight: 18, paddingX: 12, paddingY: 7, minWidth: 52, maxWidth: 220
            )
        }
    }

    public var cornerRadius: Double {
        switch fontSize {
        case 20...: Tokens.Radius.root
        case 15...: Tokens.Radius.node
        default: 8
        }
    }
}
