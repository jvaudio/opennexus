import AppKit
import NexusCore
import NexusLayout
import NexusTheme

public struct SceneNode: Equatable {
    public var id: NodeID
    public var frame: NodeFrame
    public var role: NodeRoleStyle
    public var appearance: NodeAppearance
    public var textStyle: NodeTextStyle
    /// Text as drawn (case-transformed, numbered, the live edit text while editing, or a
    /// placeholder when empty).
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
    public var line: BranchLineAppearance
    public var parentBaseline: Bool
    public var childBaseline: Bool

    public var color: RGBA { line.color }
    public var width: CGFloat { line.width }
}

/// Everything the view needs to draw one canvas.
public struct Scene {
    public var nodes: [NodeID: SceneNode] = [:]
    /// Draw order (parents before children).
    public var order: [NodeID] = []
    public var edges: [SceneEdge] = []
    public var theme: Theme = .classic
    /// Canvas colour after the Map tab's background override.
    public var canvasColor: RGBA = Theme.classic.canvas
    public var grid: Theme.Grid = Theme.classic.grid

    public var bounds: CGRect {
        nodes.values.reduce(CGRect.null) { $0.union($1.frame.rect) }
    }
}

/// Builds a scene: resolve styles → measure → lay out. Pure apart from the measure cache.
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

    private struct Pending {
        var role: NodeRoleStyle
        var depth: Int
        var appearance: NodeAppearance
        var style: NodeTextStyle
        var text: String
        var placeholder: Bool
        var lead: CGFloat
        var textSize: CGSize
        var branch: RGBA
        var line: LineStyle?
        var inherits: Bool
    }

    public func build(_ canvas: Canvas, env: StyleEnvironment, editing: EditingState? = nil) -> Scene {
        var scene = Scene()
        scene.theme = env.theme
        scene.canvasColor = env.canvas
        scene.grid =
            switch env.canvasStyle.pattern {
            case "plain"?: .none
            case "dots"?: .dots(color: env.theme.grid.color ?? env.theme.ink.alpha(0.12), spacing: 22)
            case "lines"?: .lines(color: env.theme.grid.color ?? env.theme.ink.alpha(0.06), spacing: 24)
            default: env.theme.grid
            }
        let parents = canvas.parentMap()
        let structure = canvas.layout.structure
        let family = structure.family
        let mains = canvas.nodes[canvas.root]?.children ?? []
        let mainIndex = Dictionary(uniqueKeysWithValues: mains.enumerated().map { ($1, $0) })

        var layoutNodes: [NodeID: LayoutNode] = [:]
        var pending: [NodeID: Pending] = [:]
        var numberLabels: [NodeID: String] = [:]

        let tops = [canvas.root] + canvas.floating
        for top in tops {
            var stack: [(NodeID, Int, Int)] = [(top, 0, 0)]  // id, depth, sibling index
            while let (id, depth, sibling) = stack.popLast() {
                guard let node = canvas.nodes[id] else { continue }
                let role: NodeRoleStyle =
                    if top != canvas.root { depth == 0 ? .floating : .sub } else if depth == 0 {
                        .root
                    } else if depth == 1 || family == "org" { .main } else { .sub }
                let branch: RGBA =
                    if role == .root {
                        env.theme.ring
                    } else if let m = canvas.mainBranch(of: id, parents: parents), let i = mainIndex[m] {
                        env.branchColor(mainIndex: i, count: mains.count, siblingIndex: depth > 1 ? sibling : nil)
                    } else { env.branchColor(mainIndex: 0, count: 1) }
                let merged = StyleResolver.merged(role: role, depth: depth, node: node, env: env)
                var appearance = StyleResolver.appearance(
                    role: role, depth: depth, node: node, branch: branch, env: env)
                if env.canvasStyle.font.map({ !$0.isEmpty && $0 != "system" }) == true, merged.font == env.theme.font {
                    appearance.font = env.canvasStyle.font!
                }
                let style = NodeTextStyle(appearance: appearance)
                var text = node.text
                var placeholder = false
                if let editing, editing.node == id { text = editing.text }
                if text.isEmpty {
                    placeholder = editing?.node == id
                    text =
                        placeholder
                        ? (id == canvas.root ? "Name your idea" : "Topic") : (id == canvas.root ? "Central Topic" : " ")
                }
                if !placeholder, editing?.node != id {
                    text = Self.applyCase(appearance.textCase, text)
                    if let n = numberLabels[id] { text = "\(n) \(text)" }
                }
                let textSize = measurer.textSize(text, style: style)
                var lead: CGFloat = 0
                if node.priority != nil { lead += Self.priorityWidth }
                if node.todo != nil { lead += Self.todoWidth }
                // Underline topics sit their text right on the line (padding below ≈ 4 pt).
                let padBottom =
                    appearance.isUnderline ? CGFloat(appearance.borderWidth) + 4 : CGFloat(appearance.paddingY)
                let content = CGSize(
                    width: max(
                        CGFloat(appearance.minWidth), textSize.width + lead + CGFloat(appearance.paddingX) * 2 + 2),
                    height: textSize.height + CGFloat(appearance.paddingY) + padBottom)
                let size = ShapeLibrary.size(for: appearance.shape, content: content)
                let kids = node.folded ? [] : node.children
                layoutNodes[id] = LayoutNode(
                    size: CGSize(width: ceil(size.width), height: ceil(size.height)), children: kids,
                    structure: node.structure, siblingGap: merged.siblingGap.map { CGFloat($0) },
                    levelGap: merged.levelGap.map { CGFloat($0) })
                pending[id] = Pending(
                    role: role, depth: depth, appearance: appearance, style: style, text: text,
                    placeholder: placeholder,
                    lead: lead, textSize: textSize, branch: branch, line: node.style?.line,
                    inherits: node.style?.line?.inherit ?? true)
                // Numbering on a topic numbers its children.
                if let num = merged.numbering, let fmt = num.format, fmt != "none" {
                    let prefix = (num.tiered ?? (fmt == "tiered")) ? numberLabels[id].map { "\($0)." } ?? "" : ""
                    for (i, k) in kids.enumerated() { numberLabels[k] = prefix + Self.number(i + 1, format: fmt) }
                }
                for (i, k) in kids.enumerated().reversed() { stack.append((k, depth + 1, i)) }
            }
        }

        // Justify topic alignment: siblings share one width.
        if env.canvasStyle.justify {
            for (_, n) in layoutNodes where n.children.count > 1 {
                let w = n.children.compactMap { layoutNodes[$0]?.size.width }.max() ?? 0
                for k in n.children { layoutNodes[k]?.size.width = w }
            }
        }

        var space = spacing
        // Auto balance (on by default) splits main topics by count, as P0 does; off keeps
        // them all on one side.
        space.balanceByHeight = false
        if env.canvasStyle.compact { space = space.compacted }
        let rootStructure: LayoutStructure =
            !env.canvasStyle.autoBalance && structure == .mindmapBalanced ? .mindmapRight : structure
        var frames: [NodeID: NodeFrame] = [:]
        var families: [NodeID: String] = [:]
        let rootLayout = TreeLayout.layout(
            root: canvas.root, nodes: layoutNodes, structure: rootStructure, spacing: space)
        frames.merge(rootLayout.frames) { a, _ in a }
        families.merge(rootLayout.families) { a, _ in a }
        for f in canvas.floating {
            let origin = canvas.nodes[f]?.position.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
            let r = TreeLayout.layout(
                root: f, nodes: layoutNodes, structure: .logicRight, origin: origin, spacing: space)
            frames.merge(r.frames) { a, _ in a }
            families.merge(r.families) { a, _ in a }
        }

        var inheritedLines: [NodeID: [LineStyle]] = [:]
        for top in tops {
            for id in canvas.subtree(top, includeFolded: false) {
                guard let frame = frames[id], let p = pending[id], let node = canvas.nodes[id] else { continue }
                let offset = ShapeLibrary.textOffset(for: p.appearance.shape, height: frame.size.height)
                let textY =
                    p.appearance.isUnderline
                    ? frame.size.height - p.textSize.height - CGFloat(p.appearance.borderWidth) - 4
                    : (frame.size.height - p.textSize.height) / 2 + offset
                let textRect = CGRect(
                    x: (frame.size.width - p.textSize.width - p.lead) / 2 + p.lead,
                    y: textY,
                    width: p.textSize.width, height: p.textSize.height)
                scene.nodes[id] = SceneNode(
                    id: id, frame: frame, role: p.role, appearance: p.appearance, textStyle: p.style,
                    displayText: p.text, isPlaceholder: p.placeholder, branchColor: p.branch, priority: node.priority,
                    todo: node.todo, hiddenCount: node.folded ? canvas.subtree(id).count - 1 : 0, ai: node.ai,
                    textRect: textRect)
                scene.order.append(id)
                if let parent = parents[id], frames[parent] != nil, let pp = pending[parent] {
                    let chain = inheritedLines[parent] ?? []
                    let fam = families[parent] ?? family
                    let line = StyleResolver.line(
                        childDepth: frame.depth, family: fam, branch: p.branch, parentLine: pp.line, inherited: chain,
                        env: env)
                    scene.edges.append(
                        SceneEdge(
                            parent: parent, child: id, family: fam, line: line,
                            parentBaseline: pp.appearance.isUnderline && pp.role != .root,
                            childBaseline: p.appearance.isUnderline))
                }
                // Lines this node passes down to its descendants.
                var mine = inheritedLines[parents[id] ?? id] ?? []
                if parents[id] == nil { mine = [] }
                if let l = p.line, p.inherits { mine = [l] + mine }
                inheritedLines[id] = mine
            }
        }
        return scene
    }

    static func applyCase(_ c: String, _ s: String) -> String {
        switch c {
        case "upper": s.uppercased()
        case "lower": s.lowercased()
        case "title": s.capitalized
        default: s
        }
    }

    /// Numbering labels (FMT-1: 1 2 3, 1.1 1.2, I II, A B C, a b c, ① ②, 一 二).
    nonisolated static func number(_ n: Int, format: String) -> String {
        switch format {
        case "roman":
            let table: [(Int, String)] = [
                (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
            ]
            var v = n
            var out = ""
            for (k, s) in table {
                while v >= k {
                    out += s
                    v -= k
                }
            }
            return out
        case "upper", "lower":
            var v = n
            var out = ""
            while v > 0 {
                v -= 1
                out = String(UnicodeScalar(UInt8((format == "upper" ? 65 : 97) + v % 26))) + out
                v /= 26
            }
            return out
        case "circled":
            return n <= 20 ? String(UnicodeScalar(0x2460 + n - 1)!) : "(\(n))"
        case "cjk":
            let d = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
            if n < 10 { return d[n] }
            if n < 20 { return "十" + d[n - 10] }
            if n < 100 { return d[n / 10] + "十" + d[n % 10] }
            return "\(n)"
        default:
            return "\(n)"
        }
    }
}
