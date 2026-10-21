import AppKit
import NexusCore
import NexusLayout
import NexusTheme

/// Technical canvases (artboards 19–23): node-type looks, graph and sequence layouts,
/// tree edges as flows, and structure decor.
extension SceneBuilder {
    /// The style layer a node type adds under the topic's own style.
    static func typeLayer(_ info: NodeTypeInfo, diagram: DiagramType) -> TopicStyle {
        var t = TopicStyle()
        t.shape = info.shape
        t.fill = "solid"
        t.borderWidth = 1.5
        t.border = "solid"
        t.shadow = "none"
        t.fontWeight = "medium"
        switch info.look {
        case .terminal:
            t.shape = "pill"
            t.fillColor = "ink"
            t.textColor = "canvas"
            t.border = "none"
            t.fontWeight = "semibold"
        case .step, .io, .participant:
            t.fillColor = "canvas"
            t.textColor = "ink"
            t.borderColor = "ink"
            t.cornerRadius = info.look == .participant ? 8 : 4
            if info.look == .participant {
                t.borderWidth = 2
                t.fontWeight = "semibold"
            }
        case .decision:
            t.fillColor = "decision"
            t.border = "none"
            t.fontWeight = "semibold"
        case .entity:
            t.shape = "rectangle"
            t.fillColor = "entity"
            t.borderColor = "entityLine"
            t.borderWidth = 2
            t.shadow = "hard"
            t.shadowColor = "entityLine"
            t.fontWeight = "semibold"
        case .process:
            t.shape = "pill"
            t.fillColor = "process"
            t.borderColor = "processLine"
            t.borderWidth = 2
        case .store:
            t.shape = "rectangle"
            t.fillColor = "store"
            t.borderColor = "storeLine"
            t.border = "none"
            t.align = "left"
        case .threat:
            t.shape = "rounded"
            t.fillColor = "critical@0.1"
            t.borderColor = "critical"
            t.borderWidth = 2
            t.cornerRadius = 8
        case .mitigation:
            t.shape = "rounded"
            t.fillColor = "#2E8B57@0.1"
            t.borderColor = "#2E8B57"
            t.borderWidth = 2
            t.cornerRadius = 8
        case .asset:
            t.shape = "rounded"
            t.fillColor = "ai@0.08"
            t.borderColor = "ai"
            t.borderWidth = 2
            t.cornerRadius = 8
        case .icon:
            t.shape = "rectangle"
            t.fillColor = "mainBg"
            t.borderColor = "ink2"
            t.cornerRadius = 4
            t.font = "mono"
            t.align = "left"
        }
        return t
    }

    /// The root as the diagram's title (DFD, threat model, architecture, sequence).
    static let titleLayer: TopicStyle = {
        var t = TopicStyle()
        t.shape = "text"
        t.fill = "none"
        t.border = "none"
        t.shadow = "none"
        t.fontSize = 20
        t.fontWeight = "bold"
        t.textColor = "ink"
        t.align = "left"
        return t
    }()

    /// Decorations for one typed node.
    static func techDecor(
        _ id: NodeID, info: NodeTypeInfo, canvas: Canvas, numbers: [NodeID: String],
        threats: [NodeID: Stride.Threat], env: StyleEnvironment
    ) -> TechDecor {
        var d = TechDecor()
        let t = env.theme
        switch canvas.type {
        case .flowchart, .swimlane:
            d.caption = info.caption
            d.tint = t.ink2
        case .dfd, .threatModel:
            switch info.look {
            case .process:
                d.caption = "PROCESS"
                d.kicker = numbers[id]
                d.tint = t.processLine
            case .store:
                d.caption = Loc.t("DATA STORE")
                d.leadText = numbers[id]
                d.accent = t.storeLine
                d.tint = t.storeLine
            case .entity:
                d.caption = Loc.t("EXTERNAL ENTITY")
                d.tint = t.entityLine
            case .threat:
                d.icon = "threat"
                d.tint = t.critical
                if let th = threats[id] {
                    d.badge = String(th.risk.prefix(1))
                    d.badgeColor = th.risk == "High" ? t.critical : th.risk == "Low" ? t.ink2 : t.amber
                }
            case .mitigation:
                d.icon = "mitigation"
                d.tint = RGBA(hex: "#2E8B57")
            case .asset:
                d.icon = "asset"
                d.badge = "ASSET"
                d.tint = t.ai
                d.badgeColor = t.ai
            default:
                break
            }
        case .architecture:
            d.icon = info.icon
            d.kicker = info.caption
            d.tint = t.entityLine
        case .sequence:
            if let icon = info.icon, info.look == .icon {
                d.icon = icon
                d.tint = t.entityLine
            }
        default:
            break
        }
        return d
    }

    // MARK: Layout

    struct TechLayout {
        var frames: [NodeID: NodeFrame] = [:]
        var decor: [SceneDecor] = []
        /// Sequence message endpoints by relationship id.
        var messagePoints: [String: [CGPoint]] = [:]
    }

    /// Lays out a technical canvas. `included` are the nodes in the graph, in tree order.
    func techLayout(
        _ canvas: Canvas, sizes: [NodeID: CGSize], order: [NodeID], parents: [NodeID: NodeID], env: StyleEnvironment
    ) -> TechLayout {
        var out = TechLayout()
        let type = canvas.type
        let titleRoot = DiagramCatalog.rootIsTitle(type)
        let included = order.filter { !(titleRoot && $0 == canvas.root) && sizes[$0] != nil }
        let set = Set(included)

        if type == .sequence {
            let ps = (canvas.nodes[canvas.root]?.children ?? []).filter { set.contains($0) }
            let msgs = canvas.relationships.filter { $0.connects(within: Set(ps)) }
            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            var numbered = 0
            let messages = msgs.enumerated().map { i, r -> SequenceLayout.Message in
                let isReturn = r.kind == "return"
                if !isReturn { numbered += 1 }
                let text = isReturn ? r.label : "\(i + 1) · \(r.label)"
                let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
                return SequenceLayout.Message(from: r.from.topic!, to: r.to.topic!, isReturn: isReturn, labelWidth: w)
            }
            let r = SequenceLayout.layout(participants: ps, sizes: sizes, messages: messages)
            out.frames = r.frames
            for (i, m) in msgs.enumerated() {
                guard let (from, to) = m.topics, let a = r.frames[from], let b = r.frames[to] else { continue }
                let y = r.messageY[i]
                let half = SequenceLayout.activationWidth / 2
                if m.from == m.to {
                    out.messagePoints[m.id] = [
                        CGPoint(x: a.center.x + half, y: y), CGPoint(x: a.center.x + 46, y: y),
                        CGPoint(x: a.center.x + 46, y: y + 22), CGPoint(x: a.center.x + half, y: y + 22),
                    ]
                } else {
                    let dir: CGFloat = b.center.x > a.center.x ? 1 : -1
                    out.messagePoints[m.id] = [
                        CGPoint(x: a.center.x + dir * half, y: y), CGPoint(x: b.center.x - dir * half, y: y),
                    ]
                }
            }
            for p in ps {
                out.decor.append(.lifeline(node: p, bottom: r.lifelineBottom, color: env.theme.ink2))
                for a in r.activations[p] ?? [] {
                    out.decor.append(.activation(node: p, y0: a.lowerBound, y1: a.upperBound, color: env.theme.ring))
                }
            }
        } else {
            var edges: [(NodeID, NodeID)] = []
            for id in included {
                if let p = parents[id], set.contains(p) { edges.append((p, id)) }
            }
            for r in canvas.relationships {
                // Returns and feedback loops shouldn't pull ranks backwards.
                guard let (from, to) = r.topics, set.contains(from) && set.contains(to) else { continue }
                edges.append((from, to))
            }
            var o = GraphLayout.Options()
            o.direction = type == .flowchart ? .down : .right
            o.rankGap = type == .flowchart ? 64 : type == .architecture ? 110 : 120
            o.nodeGap = type == .flowchart ? 64 : 56
            for (i, b) in canvas.boundaries.enumerated() {
                for n in b.nodes where set.contains(n) { o.groups[n] = i }
            }
            if type == .swimlane {
                let lanes = canvas.diagram.lanes
                let index = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
                var laneOf: [NodeID: Int] = [:]
                for id in included {
                    // A step without a lane inherits its parent's.
                    var cur: NodeID? = id
                    var lane: Int?
                    while let c = cur, lane == nil {
                        lane = canvas.nodes[c]?.lane.flatMap { index[$0] }
                        cur = parents[c]
                    }
                    laneOf[id] = lane ?? 0
                }
                o.lanes = laneOf
                o.laneCount = max(lanes.count, 1)
            }
            let r = GraphLayout.layout(nodes: sizes, order: included, edges: edges, options: o)
            out.frames = r.frames
            let laneColors = [env.theme.entityLine, env.theme.ai, env.theme.storeLine, env.theme.amber]
            for (i, band) in r.bands.enumerated() {
                let title = i < canvas.diagram.lanes.count ? canvas.diagram.lanes[i].title : Loc.f("Lane %lld", i + 1)
                out.decor.append(.band(rect: band, title: title.uppercased(), color: laneColors[i % laneColors.count]))
            }
        }
        // The title sits above the diagram's top-left corner.
        if titleRoot, let s = sizes[canvas.root] {
            let b = out.frames.values.reduce(CGRect.null) { $0.union($1.rect) }
            let origin = b.isNull ? CGPoint.zero : CGPoint(x: b.minX, y: b.minY - 56)
            out.frames[canvas.root] = NodeFrame(
                center: CGPoint(x: origin.x + s.width / 2, y: origin.y - s.height / 2), size: s, side: .right,
                depth: 0)
        }
        return out
    }

    // MARK: Flows

    /// A tree edge drawn as a flow.
    func virtualFlow(
        parent: NodeID, child: NodeID, canvas: Canvas, types: [NodeID: NodeType], env: StyleEnvironment
    ) -> SceneRelationship {
        let node = canvas.nodes[child]
        let t = env.theme
        var r = Relationship(
            id: FlowGraph.treeFlowID(child), from: parent, to: child, label: node?.edgeLabel ?? "")
        r.dash = "solid"
        r.width = 1.5
        r.ends = ["none", "filled-arrow"]
        r.labelStyle = "plain"
        var color = t.arrow
        switch canvas.type {
        case .flowchart:
            r.line = types[parent] == .decision ? "flow-hv" : "flow-vh"
            if types[parent] == .decision { r.labelPosition = "start" }
        case .swimlane:
            r.line = "elbow"
            let lane: (NodeID) -> String? = { canvas.nodes[$0]?.lane }
            if r.label.isEmpty, let a = lane(parent), let b = lane(child), a != b { r.label = "HAND-OFF" }
        case .architecture:
            r.line = "elbow"
            r.labelStyle = "boxed"
        case .threatModel:
            r.line = "elbow"
            switch types[child] {
            case .threat?:
                // A threat points at the element it threatens.
                r.from = .topic(child)
                r.to = .topic(parent)
                r.dash = "dashed"
                color = t.critical
                r.line = "curved"
            case .mitigation?:
                r.ends = ["none", "none"]
                color = RGBA(hex: "#2E8B57")
                r.line = "straight"
            case .asset?:
                r.ends = ["none", "none"]
                r.dash = "dotted"
                color = t.ai
                r.line = "straight"
            default:
                break
            }
        default:
            r.line = "elbow"
        }
        r.color = color.hex
        return SceneRelationship(relationship: r, color: color, isVirtual: true)
    }

    // MARK: Decor from structure layouts

    static func structureDecor(
        families: [NodeID: String], cells: [NodeID: LayoutCell], canvas: Canvas, frames: [NodeID: NodeFrame],
        branch: (NodeID) -> RGBA, env: StyleEnvironment
    ) -> [SceneDecor] {
        var out: [SceneDecor] = []
        for (id, fam) in families.sorted(by: { $0.key < $1.key }) where fam == "brace" {
            let kids = (canvas.nodes[id]?.children ?? []).filter { frames[$0] != nil }
            guard !kids.isEmpty, canvas.nodes[id]?.folded != true else { continue }
            out.append(.brace(parent: id, children: kids, color: branch(kids[0]), width: 1.6))
        }
        for (id, c) in cells.sorted(by: { $0.key < $1.key }) where frames[id] != nil {
            out.append(.cell(node: id, rect: c.rect, kind: c.kind, color: branch(id)))
        }
        return out
    }
}
