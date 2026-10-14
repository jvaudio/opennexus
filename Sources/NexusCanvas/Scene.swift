import AppKit
import NexusCore
import NexusLayout
import NexusTheme

/// How one node is painted, resolved from theme, node style, role and branch colour.
public struct NodeLook: Equatable, Sendable {
    public var fill: RGBA
    public var text: RGBA
    public var borderWidth: Double
    public var borderColor: RGBA
    public var dashed: Bool
    public var cornerRadius: Double
    public var shadowOpacity: Double

    /// Outline (default node style) per P0's base look.
    public static func outline(role: NodeRoleStyle, branch: RGBA, theme: Theme) -> NodeLook {
        switch role {
        case .root:
            NodeLook(
                fill: theme.root.background, text: theme.root.foreground, borderWidth: theme.root.borderWidth,
                borderColor: theme.root.borderColor, dashed: false, cornerRadius: Tokens.Radius.root, shadowOpacity: 0)
        case .main, .floating:
            NodeLook(
                fill: theme.main.background, text: theme.main.foreground, borderWidth: 2, borderColor: branch,
                dashed: false, cornerRadius: Tokens.Radius.node, shadowOpacity: theme.nodeShadowOpacity)
        case .sub:
            NodeLook(
                fill: theme.sub.background, text: theme.sub.foreground, borderWidth: theme.sub.borderWidth,
                borderColor: theme.sub.borderColor, dashed: theme.sub.dashed, cornerRadius: 8, shadowOpacity: 0)
        }
    }
}

public struct SceneNode: Equatable {
    public var id: NodeID
    public var frame: NodeFrame
    public var role: NodeRoleStyle
    public var look: NodeLook
    public var textStyle: NodeTextStyle
    /// Text as drawn (the live edit text while editing, a placeholder when empty).
    public var displayText: String
    public var isPlaceholder: Bool
    public var branchColor: RGBA
    public var priority: Int?
    public var todo: Todo?
    public var hiddenCount: Int
    public var ai: Bool
    /// Inner rect of the text, relative to the node's top-left corner.
    public var textRect: CGRect
}

public struct SceneEdge: Equatable {
    public var parent: NodeID
    public var child: NodeID
    public var family: String
    public var color: RGBA
    public var width: CGFloat
}

/// Everything the view needs to draw one canvas.
public struct Scene {
    public var nodes: [NodeID: SceneNode] = [:]
    /// Draw order (parents before children).
    public var order: [NodeID] = []
    public var edges: [SceneEdge] = []
    public var theme: Theme = .classic

    public var bounds: CGRect {
        nodes.values.reduce(CGRect.null) { $0.union($1.frame.rect) }
    }
}

/// Builds a scene: measure → lay out → resolve looks. Pure apart from the measure cache.
@MainActor
public struct SceneBuilder {
    public var measurer: NodeMeasurer
    public var spacing: LayoutSpacing = .standard

    public init(measurer: NodeMeasurer) { self.measurer = measurer }

    /// Leading slot widths (P0): priority marker 24, to-do box 21.
    nonisolated static let priorityWidth: CGFloat = 24
    nonisolated static let todoWidth: CGFloat = 21

    public struct EditingState: Equatable {
        public var node: NodeID
        public var text: String
        public init(node: NodeID, text: String) {
            self.node = node
            self.text = text
        }
    }

    public func build(_ canvas: Canvas, theme: Theme, editing: EditingState? = nil) -> Scene {
        var scene = Scene()
        scene.theme = theme
        let parents = canvas.parentMap()
        let structure = canvas.layout.structure
        let family = structure.family
        let mainIndex = Dictionary(
            uniqueKeysWithValues: (canvas.nodes[canvas.root]?.children ?? []).enumerated().map { ($1, $0) })

        var layoutNodes: [NodeID: LayoutNode] = [:]
        var pending:
            [NodeID: (
                role: NodeRoleStyle, style: NodeTextStyle, text: String, placeholder: Bool, lead: CGFloat,
                textSize: CGSize, typo: NodeTypography
            )] = [:]

        let tops = [canvas.root] + canvas.floating
        for top in tops {
            var stack: [(NodeID, Int)] = [(top, 0)]
            while let (id, depth) = stack.popLast() {
                guard let node = canvas.nodes[id] else { continue }
                let role: NodeRoleStyle =
                    if top != canvas.root { depth == 0 ? .floating : .sub } else if depth == 0 {
                        .root
                    } else if depth == 1 || family == "org" { .main } else { .sub }
                let typo = NodeTypography.for(role)
                let style = NodeTextStyle(typography: typo, monospaced: theme.monospaced)
                var text = node.text
                var placeholder = false
                if let editing, editing.node == id { text = editing.text }
                if text.isEmpty {
                    text = id == canvas.root ? "Name your idea" : "Topic"
                    placeholder = editing?.node == id
                    if !placeholder { text = id == canvas.root ? "Central Topic" : " " }
                }
                let textSize = measurer.textSize(text, style: style)
                var lead: CGFloat = 0
                if node.priority != nil { lead += Self.priorityWidth }
                if node.todo != nil { lead += Self.todoWidth }
                let w = max(CGFloat(typo.minWidth), textSize.width + lead + CGFloat(typo.paddingX) * 2 + 2)
                let h = textSize.height + CGFloat(typo.paddingY) * 2
                let kids = node.folded ? [] : node.children
                layoutNodes[id] = LayoutNode(
                    size: CGSize(width: w, height: h), children: kids, structure: node.structure)
                pending[id] = (role, style, text, placeholder, lead, textSize, typo)
                for k in kids.reversed() { stack.append((k, depth + 1)) }
            }
        }

        var frames: [NodeID: NodeFrame] = [:]
        var families: [NodeID: String] = [:]
        let rootLayout = TreeLayout.layout(
            root: canvas.root, nodes: layoutNodes, structure: structure, spacing: spacing)
        frames.merge(rootLayout.frames) { a, _ in a }
        families.merge(rootLayout.families) { a, _ in a }
        for f in canvas.floating {
            let origin = canvas.nodes[f]?.position.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
            let r = TreeLayout.layout(
                root: f, nodes: layoutNodes, structure: .logicRight, origin: origin, spacing: spacing)
            frames.merge(r.frames) { a, _ in a }
            families.merge(r.families) { a, _ in a }
        }

        for top in tops {
            for id in canvas.subtree(top, includeFolded: false) {
                guard let frame = frames[id], let p = pending[id], let node = canvas.nodes[id] else { continue }
                let branch: RGBA =
                    if p.role == .root {
                        theme.ring
                    } else if let m = canvas.mainBranch(of: id, parents: parents), let i = mainIndex[m] {
                        theme.branchColor(index: i, shift: canvas.style.paletteShift)
                    } else { theme.branchColor(index: 0, shift: canvas.style.paletteShift) }
                let look = NodeLook.outline(role: p.role, branch: branch, theme: theme)
                let textRect = CGRect(
                    x: (frame.size.width - p.textSize.width - p.lead) / 2 + p.lead,
                    y: (frame.size.height - p.textSize.height) / 2,
                    width: p.textSize.width, height: p.textSize.height)
                scene.nodes[id] = SceneNode(
                    id: id, frame: frame, role: p.role, look: look, textStyle: p.style, displayText: p.text,
                    isPlaceholder: p.placeholder, branchColor: branch, priority: node.priority, todo: node.todo,
                    hiddenCount: node.folded ? canvas.subtree(id).count - 1 : 0, ai: node.ai, textRect: textRect)
                scene.order.append(id)
                if let parent = parents[id], frames[parent] != nil {
                    scene.edges.append(
                        SceneEdge(
                            parent: parent, child: id, family: families[parent] ?? family, color: branch,
                            width: BranchLines.width(forChildDepth: frame.depth, family: families[parent] ?? family)))
                }
            }
        }
        return scene
    }
}
