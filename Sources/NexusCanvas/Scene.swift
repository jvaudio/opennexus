import AppKit
import NexusCore
import NexusLayout
import NexusTheme

/// Small icons at the end of a topic's title row (artboard 07 slot 6).
public enum Indicator: String, Sendable, CaseIterable {
    case note, comment, link, topicLink, file, attachment, audio, ai

    public var glyph: String {
        switch self {
        case .note: "≡"
        case .comment: "❝"
        case .link: "↗"
        case .topicLink: "⤳"
        case .file: "▤"
        case .attachment: "⎘"
        case .audio: "♪"
        case .ai: "✦"
        }
    }

    public var label: String {
        switch self {
        case .note: Loc.t("Note")
        case .comment: Loc.t("Comments")
        case .link: Loc.t("Web link")
        case .topicLink: Loc.t("Topic link")
        case .file: Loc.t("File link")
        case .attachment: Loc.t("Attachment")
        case .audio: Loc.t("Audio note")
        case .ai: Loc.t("Created by AI")
        }
    }
}

public struct ToDoProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
}

public struct SceneNode: Equatable {
    public var id: NodeID
    public var frame: NodeFrame
    public var role: NodeRoleStyle
    public var appearance: NodeAppearance
    public var textStyle: NodeTextStyle
    /// Text as drawn (case-transformed, numbered, the live edit text while editing, or a
    /// placeholder when empty).
    public var displayText: String
    /// Rich-text runs, offset to `displayText` (numbering prefix accounted for).
    public var marks: [TextMark]
    public var isPlaceholder: Bool
    public var branchColor: RGBA
    public var priority: Int?
    public var otherMarkers: [String]
    public var todo: Todo?
    public var progress: ToDoProgress?
    public var hiddenCount: Int
    public var ai: Bool
    public var labels: [String]
    public var indicators: [Indicator]
    public var sticker: String?
    public var image: AssetRef?
    public var pinned: [MetadataField]
    // Rects relative to the node's top-left corner.
    public var textRect: CGRect
    public var leadRect: CGRect
    public var stickerRect: CGRect
    public var imageRect: CGRect
    public var indicatorRects: [CGRect]
    public var labelRects: [CGRect]
    public var pinnedRect: CGRect
    /// Technical-diagram decorations (captions, kickers, icons, risk badges).
    public var tech = TechDecor()
    /// View state (focus, filters, search, tags, present): opacity, blur, glow and the
    /// matched substrings highlighted in the title.
    public var opacity: Double = 1
    public var blurred = false
    public var glow = false
    public var matchRanges: [NSRange] = []
    /// Comments on the topic, shown as a count on the comment indicator when above one (M14).
    public var commentCount = 0
    /// Where its branch lines leave it, relative to its top-left corner: the fold control
    /// and "+N" badge sit there (D250). Nil without children.
    public var junction: BranchJunction?
}

/// What the current view emphasises. Never stored in the document and never undone.
public struct SceneViewState: Equatable {
    /// Focus (⌘.): this branch is laid out as the whole map; the rest blurs.
    public var focus: NodeID?
    /// Topics drawn at reduced opacity (filter dim, tag highlight, present).
    public var dimmed: Set<NodeID> = []
    public var dimOpacity: Double = 0.3
    /// Topics hidden by a filter (drawn almost transparent so the layout stays put).
    public var hidden: Set<NodeID> = []
    /// Topics with a highlight glow (search hits, present step).
    public var glow: Set<NodeID> = []
    /// Matched substrings per topic (search).
    public var matches: [NodeID: [NSRange]] = [:]
    /// A flow drawn as the present step.
    public var flowGlow: String?
    /// AI ghosts: temporary children laid out with the map but never in the document.
    public var ghosts: [Ghost] = []
    public var ghostHighlight: Int?
    /// Settings: canvas background (plain, dots, lines; nil follows the theme), minimum
    /// text size at 100%, and patterns as well as colour.
    public var background: String?
    public var minFontSize: Double = 0
    public var patterns = true
    /// Export scope (branch, selection): only these topics and what lies wholly among them
    /// are drawn; positions come from the full layout.
    public var isolate: Set<NodeID>?
    /// Zone scope: this zone stays even if it is empty.
    public var isolateZone: String?
    /// Settings › Editing › Show task details on topics (M11), and the day that decides
    /// what's overdue.
    public var taskDetails = true
    public var today: TaskDate?
    /// Present draws the legend in a corner of the slide instead (M21).
    public var hideLegend = false

    public struct Ghost: Equatable {
        /// Under a real topic, or under an earlier ghost (by index).
        public var parent: NodeID?
        public var parentGhost: Int?
        public var idea: GhostIdea
        public init(parent: NodeID?, parentGhost: Int?, idea: GhostIdea) {
            self.parent = parent
            self.parentGhost = parentGhost
            self.idea = idea
        }
    }
    public init() {}
    public var isEmpty: Bool { self == SceneViewState() }
}

/// What a node type adds to a topic on technical canvases (artboards 19–23).
public struct TechDecor: Equatable {
    /// Small caps above the node, outside it (PROCESS, EXTERNAL ENTITY, START).
    public var caption: String?
    /// A line above the title inside the node (1.0, SERVICE).
    public var kicker: String?
    public var kickerRect: CGRect = .zero
    /// An icon from the technical set, before the title.
    public var icon: String?
    public var iconRect: CGRect = .zero
    /// Mono text before the title (D1).
    public var leadText: String?
    public var leadTextRect: CGRect = .zero
    /// A trailing pill (threat risk H / M / L, ASSET).
    public var badge: String?
    public var badgeColor: RGBA?
    public var badgeRect: CGRect = .zero
    /// A bar down the leading edge (data stores).
    public var accent: RGBA?
    /// The kicker / icon / caption colour.
    public var tint: RGBA?
    /// A rule check flags this node.
    public var flagged = false

    public init() {}
}

/// Paths a structure draws behind or between topics, recomputed from live frames.
public enum SceneDecor: Equatable {
    /// Brace map: one curly brace per parent spanning its children.
    case brace(parent: NodeID, children: [NodeID], color: RGBA, width: CGFloat)
    /// Matrix and tree-table cells, relative to their node's centre.
    case cell(node: NodeID, rect: CGRect, kind: LayoutCell.Kind, color: RGBA)
    /// A swimlane band (absolute) with its title.
    case band(rect: CGRect, title: String, color: RGBA)
    /// A sequence participant's dashed lifeline, down to `bottom`.
    case lifeline(node: NodeID, bottom: CGFloat, color: RGBA)
    /// An activation bar on a lifeline.
    case activation(node: NodeID, y0: CGFloat, y1: CGFloat, color: RGBA)
}

public struct SceneEdge: Equatable {
    public var opacity: Double = 1
    public var parent: NodeID
    public var child: NodeID
    public var family: String
    public var line: BranchLineAppearance
    public var parentBaseline: Bool
    public var childBaseline: Bool

    public var color: RGBA { line.color }
    public var width: CGFloat { line.width }
}

public struct SceneRelationship: Equatable {
    public var relationship: Relationship
    public var color: RGBA
    /// A tree edge drawn as a flow (technical canvases); its id is `t:<child>` and its
    /// label is the child's `edgeLabel`.
    public var isVirtual = false
    /// A DFD rule check flags this flow (red, dashed, "!" badge).
    public var flagged = false
    /// Fixed geometry (sequence messages): start and end in canvas coordinates.
    public var points: [CGPoint]?
    public var opacity: Double = 1
    /// The present step's flow: drawn thicker in the accent colour.
    public var glow = false
}

public struct SceneBoundary: Equatable {
    public var boundary: Boundary
    public var rect: CGRect
    public var color: RGBA
    /// Nesting level (0 = innermost), for region › VPC › subnet padding.
    public var level: Int
}

public struct SceneSummary: Equatable {
    public var summary: Summary
    /// The bracket's box: it spans the range vertically and opens toward the range.
    public var bracket: CGRect
    public var side: Side
    public var color: RGBA
}

public struct SceneZone: Equatable {
    public var zone: Zone
    public var rect: CGRect
    public var hidden: Int
    public var color: RGBA
}

public struct SceneCallout: Equatable {
    public var callout: Callout
    /// top, right or below (auto resolved).
    public var side: String
}

/// Everything the view needs to draw one canvas.
public struct Scene {
    public var nodes: [NodeID: SceneNode] = [:]
    /// Draw order (parents before children).
    public var order: [NodeID] = []
    public var edges: [SceneEdge] = []
    public var relationships: [SceneRelationship] = []
    public var boundaries: [SceneBoundary] = []
    public var summaries: [SceneSummary] = []
    public var zones: [SceneZone] = []
    public var callouts: [SceneCallout] = []
    /// The marker legend, when the canvas shows one and the whole canvas is drawn (M14).
    public var legend: SceneLegend?
    public var decor: [SceneDecor] = []
    /// DFD rule checks for this canvas.
    public var violations: [DFDRules.Violation] = []
    public var theme: Theme = .classic
    /// Canvas colour after the Map tab's background override.
    public var canvasColor: RGBA = Theme.classic.canvas
    public var grid: Theme.Grid = Theme.classic.grid

    /// Where a relationship end sits: its topic's frame, its zone's or boundary's
    /// rectangle, or a summary's bracket.
    public func rect(of end: RelationshipEnd) -> CGRect? {
        switch end {
        case .topic(let id): nodes[id]?.frame.rect
        case .zone(let id): zones.first { $0.zone.id == id }?.rect
        case .boundary(let id): boundaries.first { $0.boundary.id == id }?.rect
        case .summary(let id): summaries.first { $0.summary.id == id }?.bracket
        }
    }

    /// The colour a relationship takes from its source end ("source" colour).
    func sourceColor(_ end: RelationshipEnd) -> RGBA? {
        switch end {
        case .topic(let id): nodes[id]?.branchColor
        case .zone(let id): zones.first { $0.zone.id == id }?.color
        case .boundary(let id): boundaries.first { $0.boundary.id == id }?.color
        case .summary(let id): summaries.first { $0.summary.id == id }?.color
        }
    }

    public var bounds: CGRect {
        var b = nodes.values.reduce(CGRect.null) { $0.union($1.frame.rect) }
        for z in zones { b = b.union(z.rect) }
        for bd in boundaries { b = b.union(bd.rect) }
        if let l = legend { b = b.union(l.rect) }
        for d in decor {
            if case .band(let r, _, _) = d { b = b.union(r) }
        }
        return b
    }
}

/// Builds a scene: resolve styles → measure → lay out → place elements.
@MainActor
public struct SceneBuilder {
    public var measurer: NodeMeasurer
    public var spacing: LayoutSpacing = .standard
    /// Resolves a DFD process's drilled-down canvas (for the levels-balanced rule).
    public var levels: (CanvasID) -> Canvas? = { _ in nil }

    public init(measurer: NodeMeasurer) { self.measurer = measurer }

    /// Leading slot widths (P0): priority marker 24, to-do box 21, progress ring 22.
    nonisolated static let priorityWidth: CGFloat = 24
    nonisolated static let todoWidth: CGFloat = 21
    nonisolated static let markerWidth: CGFloat = 22
    nonisolated static let stickerWidth: CGFloat = 30
    nonisolated static var kickerFont: NSFont { .monospacedSystemFont(ofSize: 10.5, weight: .semibold) }
    nonisolated static var badgeFont: NSFont { .monospacedSystemFont(ofSize: 10.5, weight: .bold) }
    nonisolated static let kickerHeight: CGFloat = 15
    nonisolated static let boundaryPad: CGFloat = 14
    nonisolated static let boundaryTitle: CGFloat = 16
    nonisolated static let indicatorWidth: CGFloat = 18
    nonisolated static let labelHeight: CGFloat = 18
    nonisolated static var labelFont: NSFont { NSFont.systemFont(ofSize: 11, weight: .medium) }

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
        var appearance: NodeAppearance
        var style: NodeTextStyle
        var text: String
        var marks: [TextMark]
        var placeholder: Bool
        var branch: RGBA
        var line: LineStyle?
        var inherits: Bool
        var labels: [String]
        var indicators: [Indicator]
        var sticker: String?
        var progress: ToDoProgress?
        var others: [String]
        var pinned: [MetadataField]
        var image: AssetRef?
        // Relative rects, computed against the content box.
        var textRect: CGRect
        var leadRect: CGRect
        var stickerRect: CGRect
        var imageRect: CGRect
        var indicatorRects: [CGRect]
        var labelRects: [CGRect]
        var pinnedRect: CGRect
        var tech = TechDecor()
    }

    /// Default looks for the summary and callout topics (artboard 07: "Summary dashed,
    /// owns children"; artboard 08: callouts are soft yellow bubbles).
    static let summaryLayer: TopicStyle = {
        var t = TopicStyle()
        t.border = "dashed"
        t.borderColor = "ink"
        t.borderWidth = 2
        t.fill = "solid"
        t.fillColor = "mainBg"
        t.fontWeight = "semibold"
        return t
    }()

    /// `/code` blocks: a dark rounded panel, left-aligned monospace (artboard 12).
    static let codeLayer: TopicStyle = {
        var t = TopicStyle()
        t.fill = "solid"
        t.fillColor = "#17171C"
        t.textColor = "#E8E8EE"
        t.border = "none"
        t.shape = "rounded"
        t.cornerRadius = 8
        t.align = "leading"
        t.shadow = "none"
        t.autoContrast = false
        return t
    }()

    static let calloutLayer: TopicStyle = {
        var t = TopicStyle()
        t.fill = "solid"
        t.fillColor = "#FFF6D6"
        t.border = "solid"
        t.borderColor = "#E0A100"
        t.borderWidth = 1.5
        t.textColor = "#17171C"
        t.cornerRadius = 10
        t.fontSize = 13.5
        t.shadow = "none"
        return t
    }()

    public func build(
        _ source: Canvas, env: StyleEnvironment, editing: EditingState? = nil, view: SceneViewState = SceneViewState()
    ) -> Scene {
        let canvas =
            view.ghosts.isEmpty ? source : Self.inject(view.ghosts, highlight: view.ghostHighlight, into: source)
        let focus = view.focus.flatMap { canvas.nodes[$0] != nil && $0 != canvas.root ? $0 : nil }
        let focusSet = focus.map { Set(canvas.subtree($0, includeFolded: false)) } ?? []
        let focusDepth = focus.map { canvas.depth(of: $0) } ?? 0
        var scene = Scene()
        scene.theme = env.theme
        scene.canvasColor = env.canvas
        scene.grid =
            switch env.canvasStyle.pattern ?? view.background {
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
        let summaryTopics = Set(canvas.summaries.map(\.topic))
        let calloutTopics = Set(canvas.callouts.map(\.topic))
        let collapsedMembers = Set(canvas.zones.filter(\.collapsed).flatMap(\.members))
        // Technical canvases: node types, numbering, threats.
        let diagramType = canvas.type
        let technical = DiagramCatalog.isTechnical(diagramType)
        let titleRoot = DiagramCatalog.rootIsTitle(diagramType)
        var nodeTypes: [NodeID: NodeType] = [:]
        if technical {
            for id in canvas.nodes.keys {
                if let t = DiagramCatalog.effectiveType(id, in: canvas, parents: parents) { nodeTypes[id] = t }
            }
        }
        let isDFD = diagramType == .dfd || diagramType == .threatModel
        let dfdNumbers = isDFD ? DFDRules.numbers(canvas) : [:]
        let threatList = diagramType == .threatModel ? Stride.threats(canvas) : []
        let threats = Dictionary(threatList.map { ($0.node, $0) }, uniquingKeysWith: { a, _ in a })
        // Colour by risk: each element's highest open risk.
        var riskOf: [NodeID: String] = [:]
        if canvas.diagram.colorByRisk {
            let rank = ["High": 3, "Med": 2, "Low": 1]
            for t in threatList where t.status != "Mitigated" {
                guard let e = t.element else { continue }
                if (rank[t.risk] ?? 0) > (rank[riskOf[e] ?? ""] ?? 0) { riskOf[e] = t.risk }
            }
        }

        var layoutNodes: [NodeID: LayoutNode] = [:]
        // Boundary targets → whether that boundary has a title band.
        var boundaryTargets: [NodeID: Bool] = [:]
        for b in canvas.boundaries {
            for n in b.nodes { boundaryTargets[n] = (boundaryTargets[n] ?? false) || b.hasTitleBand }
        }
        var pending: [NodeID: Pending] = [:]
        var numberLabels: [NodeID: String] = [:]

        let tops = canvas.tops.filter { !collapsedMembers.contains($0) }
        for top in tops {
            let topKind: String =
                top == canvas.root
                ? "root"
                : summaryTopics.contains(top)
                    ? "summary"
                    : calloutTopics.contains(top)
                        ? "callout" : "floating"
            var stack: [(NodeID, Int, Int)] = [(top, 0, 0)]  // id, depth, sibling index
            while let (id, depth, sibling) = stack.popLast() {
                guard var node = canvas.nodes[id] else { continue }
                var role: NodeRoleStyle =
                    switch topKind {
                    case "root" where focusSet.contains(id):
                        // The focused branch is drawn as a map of its own.
                        depth == focusDepth ? .root : depth == focusDepth + 1 ? .main : .sub
                    case "root": depth == 0 ? .root : depth == 1 ? .main : .sub
                    case "summary": depth == 0 ? .main : .sub
                    case "callout": .sub
                    default: depth == 0 ? .floating : .sub
                    }
                if depth == 0 && topKind == "summary" {
                    node.style = (node.style ?? TopicStyle()).merged(over: Self.summaryLayer)
                }
                if topKind == "callout" { node.style = (node.style ?? TopicStyle()).merged(over: Self.calloutLayer) }
                if node.textFormat == "code" {
                    node.style = (node.style ?? TopicStyle()).merged(over: Self.codeLayer)
                }
                var tech = TechDecor()
                if technical {
                    // Sequence diagrams show participants; deeper topics stay in the outline.
                    if diagramType == .sequence && depth >= 2 && topKind == "root" { continue }
                    if role != .root { role = .main }
                    if titleRoot && id == canvas.root {
                        node.style = (node.style ?? TopicStyle()).merged(over: Self.titleLayer)
                    } else if let t = nodeTypes[id], let info = DiagramCatalog.info(t, in: diagramType) {
                        node.style = (node.style ?? TopicStyle()).merged(
                            over: Self.typeLayer(info, diagram: diagramType))
                        tech = Self.techDecor(
                            id, info: info, canvas: canvas, numbers: dfdNumbers, threats: threats, env: env)
                        if let risk = riskOf[id] {
                            var r = TopicStyle()
                            r.borderColor = risk == "High" ? "critical" : risk == "Med" ? "amber" : "ink2"
                            r.borderWidth = 3
                            node.style = r.merged(over: node.style ?? TopicStyle())
                        }
                    }
                }
                let branch: RGBA =
                    if role == .root {
                        env.theme.ring
                    } else if let m = canvas.mainBranch(of: id, parents: parents), let i = mainIndex[m] {
                        env.branchColor(mainIndex: i, count: mains.count, siblingIndex: depth > 1 ? sibling : nil)
                    } else { env.theme.ink2 }
                let merged = StyleResolver.merged(role: role, depth: depth, node: node, env: env)
                var appearance = StyleResolver.appearance(
                    role: role, depth: depth, node: node, branch: branch, env: env)
                if env.canvasStyle.font.map({ !$0.isEmpty && $0 != "system" }) == true, merged.font == env.theme.font {
                    appearance.font = env.canvasStyle.font!
                }
                // Settings › Appearance / Accessibility: text never smaller than this at 100%.
                if view.minFontSize > 0, appearance.fontSize < view.minFontSize {
                    appearance.lineHeight *= view.minFontSize / appearance.fontSize
                    appearance.fontSize = view.minFontSize
                }
                var style = NodeTextStyle(appearance: appearance)
                // Equations and code typeset their source, except while it's being edited.
                if editing?.node != id {
                    style.format = node.textFormat
                    style.language = node.language
                }
                if node.textFormat == "code" { style.maxWidth = max(style.maxWidth, 560) }
                var text = node.text
                var marks = node.marks
                var placeholder = false
                if let editing, editing.node == id {
                    text = editing.text
                    marks = []
                }
                if text.isEmpty {
                    placeholder = editing?.node == id
                    text =
                        placeholder
                        ? (id == canvas.root ? "Name your idea" : "Topic") : (id == canvas.root ? "Central Topic" : " ")
                }
                if !placeholder, editing?.node != id {
                    text = Self.applyCase(appearance.textCase, text)
                    if let n = numberLabels[id] {
                        let prefix = "\(n) "
                        text = prefix + text
                        let shift = (prefix as NSString).length
                        marks = marks.map {
                            var m = $0; m.start += shift; return m
                        }
                    }
                }
                let textSize = measurer.textSize(text, style: style, marks: marks)

                // Decorations.
                let progress = Self.progress(of: id, in: canvas)
                let others = node.markers.filter { !$0.hasPrefix("priority-") }
                var lead: CGFloat = 0
                if progress != nil { lead += Self.markerWidth }
                if node.priority != nil { lead += Self.priorityWidth }
                if node.todo != nil { lead += Self.todoWidth }
                lead += CGFloat(others.count) * Self.markerWidth
                let markerLead = lead
                let iconW: CGFloat = tech.icon != nil ? 24 : 0
                let leadTextW: CGFloat =
                    tech.leadText.map {
                        ceil(($0 as NSString).size(withAttributes: [.font: Self.kickerFont]).width) + 10
                    } ?? 0
                lead += iconW + leadTextW
                var indicators: [Indicator] = []
                if node.note != nil { indicators.append(.note) }
                if !node.comments.isEmpty { indicators.append(.comment) }
                if let link = node.link {
                    indicators.append(
                        TopicLink.parse(link) != nil ? .topicLink : link.hasPrefix("file:") ? .file : .link)
                }
                if !node.attachments.isEmpty { indicators.append(.attachment) }
                if node.audio != nil { indicators.append(.audio) }
                if node.ai { indicators.append(.ai) }
                let badgeW: CGFloat =
                    tech.badge.map {
                        ceil(($0 as NSString).size(withAttributes: [.font: Self.badgeFont]).width) + 14
                    } ?? 0
                let trail = CGFloat(indicators.count) * Self.indicatorWidth + (badgeW > 0 ? badgeW + 8 : 0)
                let stickerW: CGFloat = node.sticker != nil ? Self.stickerWidth : 0
                let rowWidth = lead + stickerW + textSize.width + trail
                let rowHeight = max(textSize.height, node.sticker != nil ? 26 : 0)

                // Labels row.
                var labelWidths: [CGFloat] = []
                for l in node.labels {
                    let w = ceil((l as NSString).size(withAttributes: [.font: Self.labelFont]).width) + 14
                    labelWidths.append(w)
                }
                let labelsRow = labelWidths.reduce(0, +) + CGFloat(max(0, labelWidths.count - 1)) * 4
                // Pinned metadata row.
                var pinned = node.metadata.filter(\.pinned)
                // A task's owner, dates and progress share the pinned row (D147).
                if view.taskDetails, node.todo != nil,
                    let line = TaskFormat.line(canvas, id, today: view.today ?? TaskDate.today())
                {
                    pinned.append(MetadataField(key: "◷", value: line, pinned: true))
                }
                let pinnedText = pinned.map { "\($0.key) \($0.value)" }.joined(separator: "  ·  ")
                let pinnedW =
                    pinned.isEmpty
                    ? 0
                    : ceil(
                        (pinnedText as NSString).size(withAttributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
                        ]).width)
                // Image (above or beside the title).
                var imageSize = CGSize.zero
                if let img = node.image {
                    let w = min(img.width ?? 160, 240)
                    let h = img.height.map { $0 * w / max(img.width ?? w, 1) } ?? w * 0.62
                    imageSize = CGSize(width: w, height: h)
                }
                let imagePos = node.image?.position ?? merged.imagePosition ?? "top"
                let imageSide = imagePos == "left" || imagePos == "right"

                let px = CGFloat(appearance.paddingX)
                let py = CGFloat(appearance.paddingY)
                let padBottom = appearance.isUnderline ? CGFloat(appearance.borderWidth) + 4 : py
                let kickerW: CGFloat =
                    tech.kicker.map { ceil(($0 as NSString).size(withAttributes: [.font: Self.kickerFont]).width) }
                    ?? 0
                var innerW = max(rowWidth, labelsRow, pinnedW, kickerW)
                var innerH = rowHeight
                if tech.kicker != nil { innerH += Self.kickerHeight }
                if !node.labels.isEmpty { innerH += 6 + Self.labelHeight }
                if !pinned.isEmpty { innerH += 4 + 14 }
                if node.image != nil {
                    if imageSide {
                        innerW += imageSize.width + 10
                        innerH = max(innerH, imageSize.height)
                    } else {
                        innerW = max(innerW, imageSize.width)
                        innerH += imageSize.height + 8
                    }
                }
                let content = CGSize(
                    width: max(CGFloat(appearance.minWidth), innerW + px * 2 + 2), height: innerH + py + padBottom)
                let size = ShapeLibrary.size(for: appearance.shape, content: content)
                let w = ceil(size.width)
                let h = ceil(size.height)

                // Relative rects inside the final size.
                let contentX = (w - innerW) / 2
                var cursorY = (h - innerH) / 2 + ShapeLibrary.textOffset(for: appearance.shape, height: h)
                if appearance.isUnderline { cursorY = h - padBottom - innerH }
                var imageRect = CGRect.zero
                var rowX = contentX
                if tech.kicker != nil {
                    let align = appearance.align
                    let kx = align == "left" ? contentX + lead : (w - kickerW) / 2
                    tech.kickerRect = CGRect(x: kx, y: cursorY, width: kickerW, height: Self.kickerHeight - 2)
                    cursorY += Self.kickerHeight
                }
                if node.image != nil {
                    switch imagePos {
                    case "left":
                        imageRect = CGRect(x: contentX, y: cursorY, width: imageSize.width, height: imageSize.height)
                        rowX += imageSize.width + 10
                    case "right":
                        imageRect = CGRect(
                            x: contentX + innerW - imageSize.width, y: cursorY, width: imageSize.width,
                            height: imageSize.height)
                    case "bottom": break
                    default:
                        imageRect = CGRect(
                            x: (w - imageSize.width) / 2, y: cursorY, width: imageSize.width, height: imageSize.height)
                        cursorY += imageSize.height + 8
                    }
                }
                let rowW = imageSide ? innerW - imageSize.width - 10 : innerW
                let rowStart = rowX + (rowW - rowWidth) / 2
                let leadRect = CGRect(x: rowStart, y: cursorY + (rowHeight - 18) / 2, width: markerLead, height: 18)
                if iconW > 0 {
                    tech.iconRect = CGRect(
                        x: rowStart + markerLead, y: cursorY + (rowHeight - 18) / 2, width: 18, height: 18)
                }
                if leadTextW > 0 {
                    tech.leadTextRect = CGRect(
                        x: rowStart + markerLead + iconW, y: cursorY + (rowHeight - 14) / 2, width: leadTextW - 6,
                        height: 14)
                }
                let stickerRect = CGRect(
                    x: rowStart + lead, y: cursorY + (rowHeight - 26) / 2, width: stickerW, height: 26)
                let textRect = CGRect(
                    x: rowStart + lead + stickerW, y: cursorY + (rowHeight - textSize.height) / 2,
                    width: textSize.width, height: textSize.height)
                let indicatorRects = indicators.enumerated().map { i, _ in
                    CGRect(
                        x: textRect.maxX + 2 + CGFloat(i) * Self.indicatorWidth, y: textRect.midY - 9,
                        width: Self.indicatorWidth, height: 18)
                }
                if badgeW > 0 {
                    let x = (indicatorRects.last?.maxX ?? textRect.maxX) + 8
                    tech.badgeRect = CGRect(x: x, y: cursorY + (rowHeight - 18) / 2, width: badgeW, height: 18)
                }
                cursorY += rowHeight
                var labelRects: [CGRect] = []
                if !node.labels.isEmpty {
                    cursorY += 6
                    var x = rowX + (rowW - labelsRow) / 2
                    for lw in labelWidths {
                        labelRects.append(CGRect(x: x, y: cursorY, width: lw, height: Self.labelHeight))
                        x += lw + 4
                    }
                    cursorY += Self.labelHeight
                }
                var pinnedRect = CGRect.zero
                if !pinned.isEmpty {
                    cursorY += 4
                    pinnedRect = CGRect(x: rowX + (rowW - pinnedW) / 2, y: cursorY, width: pinnedW, height: 14)
                    cursorY += 14
                }
                if node.image != nil, imagePos == "bottom" {
                    imageRect = CGRect(
                        x: (w - imageSize.width) / 2, y: cursorY + 8, width: imageSize.width, height: imageSize.height)
                }

                let kids = node.folded ? [] : node.children
                // Branches wrapped in a boundary reserve its padding (and title band) so
                // the boundary never covers a neighbouring topic.
                let wraps = boundaryTargets[id]
                layoutNodes[id] = LayoutNode(
                    size: CGSize(width: w, height: h), children: kids, structure: node.structure,
                    siblingGap: merged.siblingGap.map { CGFloat($0) }, levelGap: merged.levelGap.map { CGFloat($0) },
                    margin: wraps == nil ? 0 : Self.boundaryPad,
                    marginBefore: wraps.map { Self.boundaryPad + ($0 ? Self.boundaryTitle : 0) },
                    folded: node.folded && !node.children.isEmpty)
                pending[id] = Pending(
                    role: role, appearance: appearance, style: style, text: text, marks: marks,
                    placeholder: placeholder, branch: branch, line: node.style?.line,
                    inherits: node.style?.line?.inherit ?? true, labels: node.labels, indicators: indicators,
                    sticker: node.sticker?.asset, progress: progress, others: others, pinned: pinned,
                    image: node.image, textRect: textRect, leadRect: leadRect, stickerRect: stickerRect,
                    imageRect: imageRect, indicatorRects: indicatorRects, labelRects: labelRects,
                    pinnedRect: pinnedRect,
                    tech: tech
                )
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
        var cells: [NodeID: LayoutCell] = [:]
        func merge(_ r: LayoutResult) {
            frames.merge(r.frames) { a, _ in a }
            families.merge(r.families) { a, _ in a }
            cells.merge(r.cells) { a, _ in a }
        }
        var techResult: TechLayout?
        if technical {
            var order: [NodeID] = []
            for top in tops where top == canvas.root || canvas.floating.contains(top) {
                for id in canvas.subtree(top, includeFolded: false) where layoutNodes[id] != nil { order.append(id) }
            }
            let sizes = layoutNodes.mapValues(\.size)
            let t = techLayout(canvas, sizes: sizes, order: order, parents: parents, env: env)
            frames = t.frames
            scene.decor += t.decor
            techResult = t
        } else {
            merge(TreeLayout.layout(root: canvas.root, nodes: layoutNodes, structure: rootStructure, spacing: space))
            for f in canvas.floating where !collapsedMembers.contains(f) {
                let origin = canvas.nodes[f]?.position.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
                merge(
                    TreeLayout.layout(
                        root: f, nodes: layoutNodes, structure: .logicRight, origin: origin, spacing: space))
            }
        }
        // Focus: lay the branch out as a whole map where it stands.
        if let f = focus, !technical, let at = frames[f] {
            let s = canvas.nodes[f]?.structure ?? .mindmapBalanced
            let r = TreeLayout.layout(root: f, nodes: layoutNodes, structure: s, origin: at.center, spacing: space)
            frames.merge(r.frames) { _, b in b }
            families.merge(r.families) { _, b in b }
            cells.merge(r.cells) { _, b in b }
        }
        // A structure may widen a topic (matrix and tree-table header bars): re-centre its content.
        for (id, f) in frames {
            guard let measured = layoutNodes[id]?.size, f.size.width > measured.width + 0.5, var p = pending[id]
            else { continue }
            let dx = (f.size.width - measured.width) / 2
            p.textRect = p.textRect.offsetBy(dx: dx, dy: 0)
            p.leadRect = p.leadRect.offsetBy(dx: dx, dy: 0)
            p.stickerRect = p.stickerRect.offsetBy(dx: dx, dy: 0)
            p.imageRect = p.imageRect.offsetBy(dx: dx, dy: 0)
            p.indicatorRects = p.indicatorRects.map { $0.offsetBy(dx: dx, dy: 0) }
            p.labelRects = p.labelRects.map { $0.offsetBy(dx: dx, dy: 0) }
            p.pinnedRect = p.pinnedRect.offsetBy(dx: dx, dy: 0)
            pending[id] = p
        }

        // Summaries: bracket beside the range, topic beyond the bracket.
        for s in canvas.summaries {
            guard let kids = canvas.nodes[s.parent]?.children, !(canvas.nodes[s.parent]?.folded ?? true),
                let lo = kids.firstIndex(of: s.from), let hi = kids.firstIndex(of: s.to),
                let first = frames[s.from], layoutNodes[s.topic] != nil
            else { continue }
            var rect = CGRect.null
            for k in kids[min(lo, hi)...max(lo, hi)] {
                for d in canvas.subtree(k, includeFolded: false) {
                    if let f = frames[d] { rect = rect.union(f.rect) }
                }
            }
            guard !rect.isNull else { continue }
            // Brackets sit outside any boundary drawn around the range or its parent.
            var ancestors = Set<NodeID>()
            var cursor: NodeID? = s.parent
            while let c = cursor {
                ancestors.insert(c)
                cursor = parents[c]
            }
            let rangeSet = Set(kids[min(lo, hi)...max(lo, hi)].flatMap { canvas.subtree($0, includeFolded: false) })
            let enclosing = canvas.boundaries.filter { b in
                b.nodes.contains { ancestors.contains($0) || rangeSet.contains($0) }
            }.count
            if enclosing > 0 {
                let out = Self.boundaryPad + CGFloat(enclosing - 1) * 12 + 2
                // Widen across the bracket axis only; the bracket still spans the range itself.
                rect = first.side == .down ? rect.insetBy(dx: 0, dy: -out) : rect.insetBy(dx: -out, dy: 0)
            }
            let side: Side = first.side == .left ? .left : first.side == .down ? .down : .right
            let bracket: CGRect
            let origin: CGPoint
            let tw = layoutNodes[s.topic]!.size.width
            switch side {
            case .left:
                bracket = CGRect(x: rect.minX - 22, y: rect.minY, width: 12, height: rect.height)
                origin = CGPoint(x: bracket.minX - 16 - tw / 2, y: rect.midY)
            case .down:
                bracket = CGRect(x: rect.minX, y: rect.maxY + 10, width: rect.width, height: 12)
                origin = CGPoint(x: rect.midX, y: bracket.maxY + 16 + layoutNodes[s.topic]!.size.height / 2)
            case .right:
                bracket = CGRect(x: rect.maxX + 10, y: rect.minY, width: 12, height: rect.height)
                origin = CGPoint(x: bracket.maxX + 16 + tw / 2, y: rect.midY)
            }
            var r = TreeLayout.layout(
                root: s.topic, nodes: layoutNodes, structure: side == .left ? .logicLeft : .logicRight,
                origin: origin, spacing: space)
            if side == .left { r.frames[s.topic]?.side = .left }
            merge(r)
            // The canvas's summary default, where it has one, before the theme's (D245).
            let color =
                s.color.flatMap(RGBA.init(hexString:))
                ?? canvas.style.elements.summary.color.flatMap(RGBA.init(hexString:)) ?? env.theme.ink2
            scene.summaries.append(SceneSummary(summary: s, bracket: bracket, side: side, color: color))
        }

        // Callouts: bubble beside its host; the pointer is drawn by the view.
        for k in canvas.callouts {
            guard let host = frames[k.host], let size = layoutNodes[k.topic]?.size else { continue }
            let side = k.side == "auto" ? "top" : k.side
            let center: CGPoint =
                switch side {
                case "right": CGPoint(x: host.rect.maxX + 30 + size.width / 2, y: host.center.y)
                case "below": CGPoint(x: host.center.x, y: host.rect.maxY + 24 + size.height / 2)
                default:
                    CGPoint(x: host.rect.maxX - 24 + size.width / 2, y: host.rect.minY - 24 - size.height / 2)
                }
            merge(
                TreeLayout.layout(
                    root: k.topic, nodes: layoutNodes, structure: .logicRight, origin: center, spacing: space))
            scene.callouts.append(SceneCallout(callout: k, side: side))
        }

        // Nodes and branch lines.
        var inheritedLines: [NodeID: [LineStyle]] = [:]
        let allParents = parents
        for top in tops {
            for id in canvas.subtree(top, includeFolded: false) {
                guard let frame = frames[id], let p = pending[id], let node = canvas.nodes[id] else { continue }
                scene.nodes[id] = SceneNode(
                    id: id, frame: frame, role: p.role, appearance: p.appearance, textStyle: p.style,
                    displayText: p.text, marks: p.marks, isPlaceholder: p.placeholder, branchColor: p.branch,
                    priority: node.priority, otherMarkers: p.others, todo: node.todo, progress: p.progress,
                    hiddenCount: node.folded ? canvas.subtree(id).count - 1 : 0, ai: node.ai, labels: p.labels,
                    indicators: p.indicators, sticker: p.sticker, image: p.image, pinned: p.pinned,
                    textRect: p.textRect, leadRect: p.leadRect, stickerRect: p.stickerRect, imageRect: p.imageRect,
                    indicatorRects: p.indicatorRects, labelRects: p.labelRects, pinnedRect: p.pinnedRect,
                    tech: p.tech)
                scene.nodes[id]?.commentCount = node.comments.count
                if !technical, !node.children.isEmpty {
                    let child = node.folded ? nil : node.children.lazy.compactMap { frames[$0] }.first
                    let j = BranchLines.junction(
                        of: frame, family: families[id] ?? family, child: child,
                        parent: allParents[id].flatMap { frames[$0] },
                        baseline: p.appearance.isUnderline && p.role != .root)
                    let o = frame.rect.origin
                    scene.nodes[id]?.junction = BranchJunction(CGPoint(x: j.point.x - o.x, y: j.point.y - o.y), j.edge)
                }
                scene.order.append(id)
                if technical {
                    if let parent = allParents[id], frames[parent] != nil, !(titleRoot && parent == canvas.root),
                        diagramType != .sequence
                    {
                        scene.relationships.append(
                            virtualFlow(parent: parent, child: id, canvas: canvas, types: nodeTypes, env: env))
                    }
                } else if let parent = allParents[id], frames[parent] != nil, let pp = pending[parent] {
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
                var mine = allParents[id].flatMap { inheritedLines[$0] } ?? []
                if let l = p.line, p.inherits { mine = [l] + mine }
                inheritedLines[id] = mine
            }
        }

        // Zones (back to front), before relationships so those can end on them.
        for z in canvas.zones {
            var rect = CGRect(x: z.origin.x, y: z.origin.y, width: z.width, height: z.height)
            var hidden = 0
            if z.collapsed {
                rect.size.height = 40
                hidden = z.members.reduce(0) { $0 + canvas.subtree($1).count }
            } else if z.autoResize, !z.members.isEmpty {
                var content = CGRect.null
                for m in z.members {
                    for d in canvas.subtree(m, includeFolded: false) {
                        if let f = frames[d] { content = content.union(f.rect) }
                    }
                }
                if !content.isNull {
                    let fit = CGRect(
                        x: content.minX - 24, y: content.minY - 44, width: content.width + 48,
                        height: content.height + 68)
                    rect = rect.union(fit)
                    rect.size.width = max(rect.width, Zone.minimumSize)
                    rect.size.height = max(rect.height, Zone.minimumSize)
                }
            }
            let color = z.color.flatMap(RGBA.init(hexString:)) ?? RGBA(hex: "#7A4CC2")
            scene.zones.append(SceneZone(zone: z, rect: rect, hidden: hidden, color: color))
        }
        // Boundaries around their branches (outer ones pad around inner ones), before
        // relationships so those can end on them.
        var boxes: [(Boundary, Set<NodeID>, CGRect)] = []
        for b in canvas.boundaries {
            var members = Set<NodeID>()
            var rect = CGRect.null
            for n in b.nodes {
                for d in canvas.subtree(n, includeFolded: false) {
                    members.insert(d)
                    if let f = frames[d] { rect = rect.union(f.rect) }
                }
            }
            if !rect.isNull { boxes.append((b, members, rect)) }
        }
        for (b, members, rect) in boxes {
            let level = boxes.filter { $0.0.id != b.id && $0.1.isSubset(of: members) && $0.1 != members }.count
            let pad = Self.boundaryPad + CGFloat(level) * 12
            var r = rect.insetBy(dx: -pad, dy: -pad)
            if b.hasTitleBand {
                r.origin.y -= Self.boundaryTitle
                r.size.height += Self.boundaryTitle
            }
            let color: RGBA =
                b.color.flatMap(RGBA.init(hexString:))
                ?? (b.meaning == "trust"
                    ? env.theme.critical
                    : b.meaning == "vpc" || b.meaning == "subnet"
                        ? env.theme.entityLine
                        : canvas.style.elements.boundary.color.flatMap(RGBA.init(hexString:)) ?? env.theme.ring)
            scene.boundaries.append(SceneBoundary(boundary: b, rect: r, color: color, level: level))
        }
        scene.boundaries.sort { $0.level > $1.level }
        var messageIndex = 0
        // Relationships between visible topics, zones, boundaries and summaries.
        let relationshipColor =
            canvas.style.elements.relationship.color.flatMap(RGBA.init(hexString:)) ?? env.theme.relationship
        for r in canvas.relationships where scene.rect(of: r.from) != nil && scene.rect(of: r.to) != nil {
            let color: RGBA =
                switch r.color {
                case "source": scene.sourceColor(r.from) ?? relationshipColor
                case "theme": relationshipColor
                default: RGBA(hexString: r.color) ?? relationshipColor
                }
            var sr = SceneRelationship(relationship: r, color: color)
            sr.points = techResult?.messagePoints[r.id]
            if technical {
                // Technical canvases draw relationships as flows: neutral arrows, quiet labels.
                if r.color == "theme" { sr.color = env.theme.arrow }
                if r.labelStyle == "pill" {
                    sr.relationship.labelStyle = diagramType == .architecture ? "boxed" : "plain"
                }
                if diagramType == .flowchart && (r.line == "elbow" || r.line == "curved") {
                    sr.relationship.line = "flow-vh"
                }
            }
            if diagramType == .sequence, sr.points != nil {
                // Messages: solid calls numbered in time order, dashed returns with open arrows.
                let isReturn = r.kind == "return"
                messageIndex += 1
                sr.relationship.label = isReturn || r.label.isEmpty ? r.label : "\(messageIndex) · \(r.label)"
                sr.relationship.dash = isReturn ? "dashed" : "solid"
                sr.relationship.ends = ["none", isReturn ? "arrow" : "filled-arrow"]
                sr.relationship.labelStyle = "plain"
                sr.relationship.width = 1.5
                sr.color = r.color == "theme" ? env.theme.ink : color
            }
            scene.relationships.append(sr)
        }
        if !technical {
            scene.decor += Self.structureDecor(
                families: families, cells: cells, canvas: canvas, frames: frames,
                branch: { pending[$0]?.branch ?? env.theme.ink2 }, env: env)
        }
        // DFD rule checks flag their flows and nodes.
        if isDFD {
            let v = DFDRules.check(canvas, level: levels)
            scene.violations = v
            var flaggedFlows = Set<String>()
            for x in v where x.severity == .error {
                switch x.subject {
                case .flow(let f): flaggedFlows.insert(f)
                case .node(let n): scene.nodes[n]?.tech.flagged = true
                }
            }
            for i in scene.relationships.indices where flaggedFlows.contains(scene.relationships[i].relationship.id) {
                scene.relationships[i].flagged = true
                scene.relationships[i].color = env.theme.critical
                scene.relationships[i].relationship.dash = "dashed"
            }
        }

        // The legend lists the canvas's own markers and labels (never ghosts'), beside the
        // map unless dragged; branch, selection and zone exports leave it out.
        if let legend = source.legend, legend.visible, view.isolate == nil, !view.hideLegend {
            scene.legend = SceneLegend.make(legend, canvas: source, content: scene.bounds)
        }
        if !view.isEmpty || focus != nil { Self.apply(view, focusSet: focusSet, to: &scene) }
        if !view.ghosts.isEmpty {
            for i in scene.edges.indices where CanvasController.ghostIndex(scene.edges[i].child) != nil {
                scene.edges[i].line.color = env.theme.ai
                scene.edges[i].line.dash = "dashed"
            }
        }
        if let keep = view.isolate { Self.isolate(keep, root: canvas.root, zone: view.isolateZone, in: &scene) }
        if !view.patterns {
            for i in scene.boundaries.indices { scene.boundaries[i].boundary.hatch = false }
        }
        return scene
    }

    static func isolate(_ keep: Set<NodeID>, root: NodeID, zone: String? = nil, in scene: inout Scene) {
        scene.nodes = scene.nodes.filter { keep.contains($0.key) }
        scene.order = scene.order.filter(keep.contains)
        scene.edges = scene.edges.filter { keep.contains($0.parent) && keep.contains($0.child) }
        let zones = scene.zones.filter {
            $0.zone.id == zone || (!$0.zone.members.isEmpty && Set($0.zone.members).isSubset(of: keep))
        }
        scene.boundaries = scene.boundaries.filter {
            !$0.boundary.nodes.isEmpty && Set($0.boundary.nodes).isSubset(of: keep)
        }
        scene.summaries = scene.summaries.filter {
            keep.contains($0.summary.topic) && keep.contains($0.summary.from) && keep.contains($0.summary.to)
        }
        scene.zones = zones
        // A relationship stays when both its ends do.
        let s = scene
        scene.relationships = scene.relationships.filter {
            s.rect(of: $0.relationship.from) != nil && s.rect(of: $0.relationship.to) != nil
        }
        scene.callouts = scene.callouts.filter { keep.contains($0.callout.host) && keep.contains($0.callout.topic) }
        // Structure decor (timeline spines, lanes) belongs to the whole map.
        if !keep.contains(root) { scene.decor = [] }
    }

    /// Ghost suggestions styled dashed teal (artboard 28); the highlighted one is stronger
    /// and carries a ⌃↩ badge.
    static func inject(_ ghosts: [SceneViewState.Ghost], highlight: Int?, into c: Canvas) -> Canvas {
        var c = c
        for (i, g) in ghosts.enumerated() {
            let id = CanvasController.ghostID(i)
            let parent = g.parentGhost.map { CanvasController.ghostID($0) } ?? g.parent ?? c.root
            guard c.nodes[parent] != nil else { continue }
            var n = Node(text: g.idea.text, kind: .topic)
            n.markers = g.idea.markers
            n.labels = g.idea.labels
            if g.idea.todo { n.todo = Todo(done: false) }
            var st = TopicStyle()
            st.shape = "rounded"
            st.fill = "solid"
            st.fillColor = i == highlight ? "ai@0.16" : "ai@0.07"
            st.border = "dashed"
            st.borderColor = "ai"
            st.borderWidth = i == highlight ? 2.5 : 1.5
            st.textColor = "ai"
            st.shadow = "none"
            n.style = st
            c.nodes[id] = n
            c.nodes[parent]?.children.append(id)
            c.nodes[parent]?.folded = false
        }
        return c
    }

    /// Applies view state: dimming, hiding, focus blur, glows and search matches.
    static func apply(_ view: SceneViewState, focusSet: Set<NodeID>, to scene: inout Scene) {
        let focusing = !focusSet.isEmpty
        for id in scene.nodes.keys {
            var o = 1.0
            if view.hidden.contains(id) { o = 0.05 } else if view.dimmed.contains(id) { o = view.dimOpacity }
            if focusing && !focusSet.contains(id) {
                o = min(o, 0.22)
                scene.nodes[id]?.blurred = true
            }
            scene.nodes[id]?.opacity = o
            scene.nodes[id]?.glow = view.glow.contains(id)
            scene.nodes[id]?.matchRanges = view.matches[id] ?? []
        }
        func opacity(_ id: NodeID) -> Double { scene.nodes[id]?.opacity ?? 1 }
        func opacity(_ end: RelationshipEnd) -> Double { end.topic.map(opacity) ?? 1 }
        for i in scene.edges.indices {
            scene.edges[i].opacity = min(opacity(scene.edges[i].parent), opacity(scene.edges[i].child))
        }
        for i in scene.relationships.indices {
            let r = scene.relationships[i].relationship
            scene.relationships[i].opacity = min(opacity(r.from), opacity(r.to))
            if r.id == view.flowGlow {
                scene.relationships[i].glow = true
                scene.relationships[i].opacity = 1
            }
        }
    }

    /// To-do progress summed from a topic's direct children (EN).
    static func progress(of id: NodeID, in canvas: Canvas) -> ToDoProgress? {
        guard let kids = canvas.nodes[id]?.children else { return nil }
        let todos = kids.compactMap { canvas.nodes[$0]?.todo }
        guard !todos.isEmpty else { return nil }
        return ToDoProgress(done: todos.filter(\.done).count, total: todos.count)
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
