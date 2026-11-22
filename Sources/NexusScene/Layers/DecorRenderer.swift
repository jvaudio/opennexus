import CoreGraphics
import Foundation
import NexusCore
import NexusLayout
import NexusTheme
@preconcurrency import QuartzCore

/// Draws structure decor (braces, matrix and tree-table cells, swimlane bands, sequence
/// lifelines and activation bars, and the trunks sibling branch lines share) from live
/// node frames, so it follows the spring animation like branch lines do.
@MainActor
package final class DecorRenderer {
    /// Swimlane bands, below everything.
    package let bandsLayer = CALayer()
    /// Cells, braces, lifelines, trunks: above boundaries, below branch lines.
    package let layer = CALayer()
    private var shapes: [CAShapeLayer] = []
    /// A second fill over each piece of decor (a tree-table row's branch stripe), a
    /// sublayer of its shape.
    private var accents: [CAShapeLayer] = []
    private var trunkShapes: [CAShapeLayer] = []
    private var bandShapes: [CAShapeLayer] = []
    private var bandTitles: [TextLayer] = []
    /// The swimlane pool's outline and the dividers between its lanes, over the lane fills.
    private let pool = CAShapeLayer()
    private var decor: [SceneDecor] = []
    private var trunks: [Trunk] = []
    package var textScale: CGFloat = 2

    package init() {
        layer.actions = NodeLayer.noActions
        bandsLayer.actions = NodeLayer.noActions
        pool.actions = NodeLayer.noActions
        pool.zPosition = 1
        pool.fillColor = nil
        pool.lineWidth = 1
        bandsLayer.addSublayer(pool)
    }

    package func update(scene: Scene, frame: (NodeID) -> CGRect?) {
        decor = scene.decor
        let bands = decor.filter { if case .band = $0 { true } else { false } }
        let rest = decor.filter { if case .band = $0 { false } else { true } }
        trunks = Self.trunks(scene)
        sync(&shapes, count: rest.count, in: layer)
        // Each shape carries its accent as a sublayer, so the stripe stays over its own row.
        while accents.count < shapes.count {
            let a = CAShapeLayer()
            a.actions = NodeLayer.noActions
            shapes[accents.count].addSublayer(a)
            accents.append(a)
        }
        while accents.count > shapes.count { accents.removeLast().removeFromSuperlayer() }
        sync(&trunkShapes, count: trunks.count, in: layer)
        sync(&bandShapes, count: bands.count, in: bandsLayer)
        while bandTitles.count < bands.count {
            let t = TextLayer()
            t.actions = NodeLayer.noActions
            bandsLayer.addSublayer(t)
            bandTitles.append(t)
        }
        while bandTitles.count > bands.count { bandTitles.removeLast().removeFromSuperlayer() }
        let rects = bands.compactMap { if case .band(let r, _, _) = $0 { r } else { nil } }
        let lanes = Self.pool(rects)
        pool.path = lanes.map {
            let m = CGMutablePath()
            m.addPath($0.outline)
            m.addPath($0.dividers)
            return m
        }
        pool.strokeColor = Self.poolLine(scene.theme).cgColor
        for (i, d) in bands.enumerated() {
            guard case .band(let rect, let title, let color) = d else { continue }
            let s = bandShapes[i]
            // Each lane's tint, inside the pool's rounded corners; the pool draws the lines.
            s.path = lanes.map { CGPath(rect: rect, transform: nil).intersection($0.outline) }
            s.fillColor = color.alpha(i % 2 == 0 ? 0.05 : 0.08).cgColor
            s.strokeColor = nil
            let t = bandTitles[i]
            t.attributed = StyledText(
                title, TextAttributes(font: Fonts.mono(11.5, .semibold), color: .fixed(color.cgColor), kern: 1.2))
            t.contentsScale = textScale
            t.frame = CGRect(x: rect.minX + 16, y: rect.minY + 12, width: 260, height: 16)
            t.setNeedsDisplay()
        }
        let incoming = Self.incomingColors(scene)
        for (i, d) in rest.enumerated() {
            let p = Self.paint(d, scene: scene, incoming: incoming)
            style(shapes[i], p)
            accents[i].fillColor = p.accent?.cgColor
        }
        for (i, t) in trunks.enumerated() {
            style(trunkShapes[i], t.paint)
            // Over the cells and braces in the same layer, whatever order they were added in.
            trunkShapes[i].zPosition = 1
            trunkShapes[i].opacity = Float(t.opacity)
        }
        updateGeometry(frame: frame)
    }

    package func updateGeometry(frame: (NodeID) -> CGRect?) {
        let rest = decor.filter { if case .band = $0 { false } else { true } }
        for (i, d) in rest.enumerated() where i < shapes.count {
            shapes[i].path = Self.path(d, frame: frame)
            accents[i].path = Self.accentPath(d, frame: frame)
        }
        for (i, t) in trunks.enumerated() where i < trunkShapes.count {
            trunkShapes[i].path = Self.path(t, frame: frame)
        }
    }

    private func sync(_ list: inout [CAShapeLayer], count: Int, in parent: CALayer) {
        while list.count < count {
            let s = CAShapeLayer()
            s.actions = NodeLayer.noActions
            parent.addSublayer(s)
            list.append(s)
        }
        while list.count > count { list.removeLast().removeFromSuperlayer() }
    }

    private func style(_ s: CAShapeLayer, _ p: Paint) {
        s.fillColor = p.fill?.cgColor
        s.strokeColor = p.stroke?.cgColor
        s.lineWidth = p.width
        s.lineDashPattern = p.dash?.map { NSNumber(value: Double($0)) }
        s.lineCap = .round
        s.lineJoin = .round
    }

    /// How a piece of decor is painted (the SVG export draws it the same way).
    package struct Paint {
        package var fill: RGBA?
        package var stroke: RGBA?
        package var width: CGFloat = 1
        package var dash: [CGFloat]?
        /// The fill of `accentPath` (a tree-table row's branch stripe).
        package var accent: RGBA?
    }

    /// `paint(_:theme:)` with the scene's edges: a brace is a trunk its children share,
    /// so it takes the trunk's colour (ink at the central topic) rather than the first
    /// child's branch colour.
    package static func paint(_ d: SceneDecor, scene: Scene, incoming: [NodeID: RGBA]? = nil) -> Paint {
        var p = paint(d, theme: scene.theme)
        if case .brace(let parent, _, _, _) = d {
            p.stroke = trunkColor(parent, family: "brace", scene: scene, incoming: incoming)
        }
        return p
    }

    package static func paint(_ d: SceneDecor, theme: Theme) -> Paint {
        // Cells are white cards with hairline borders; the branch shows in the stripe and
        // the topic's own text.
        let cellFill = theme.isDark ? theme.ink.alpha(0.04) : RGBA.white
        switch d {
        case .brace(_, _, let color, let width):
            return Paint(stroke: color, width: width)
        case .cell(_, _, let kind, let color):
            switch kind {
            case .matrixCell: return Paint(fill: cellFill, stroke: theme.ink2.alpha(0.2))
            case .tableRow: return Paint(fill: cellFill, stroke: theme.ink2.alpha(0.2), accent: color)
            case .tableCell: return Paint(fill: cellFill, stroke: theme.ink2.alpha(0.2))
            }
        case .lifeline(_, _, let color):
            return Paint(stroke: color.alpha(0.6), width: 1.2, dash: [5, 5])
        case .activation(_, _, _, let color):
            return Paint(fill: color.alpha(0.14), stroke: color, width: 1.2)
        case .band:
            return Paint()
        }
    }

    package static func path(_ d: SceneDecor, frame: (NodeID) -> CGRect?) -> CGPath? {
        switch d {
        case .brace(let parent, let children, _, _):
            guard let p = frame(parent) else { return nil }
            let rects = children.compactMap(frame)
            guard !rects.isEmpty else { return nil }
            let top = rects.map(\.minY).min()!
            let bottom = rects.map(\.maxY).max()!
            let right = rects[0].midX > p.midX
            let near = right ? rects.map(\.minX).min()! - 10 : rects.map(\.maxX).max()! + 10
            let tip = right ? near - 14 : near + 14
            let r = CGRect(x: min(near, tip), y: top, width: 14, height: max(bottom - top, 20))
            let m = CGMutablePath()
            m.addPath(ElementRenderer.bracket(r, side: right ? .left : .right, shape: "curly"))
            // The stem from the parent to the brace's point.
            m.move(to: CGPoint(x: right ? p.maxX : p.minX, y: p.midY))
            m.addLine(to: CGPoint(x: tip, y: (top + bottom) / 2))
            return m
        case .cell(let node, let rect, let kind, _):
            guard let f = frame(node) else { return nil }
            let r = rect.offsetBy(dx: f.midX, dy: f.midY)
            switch kind {
            case .matrixCell: return CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
            case .tableRow, .tableCell: return CGPath(rect: r, transform: nil)
            }
        case .lifeline(let node, let bottom, _):
            guard let f = frame(node) else { return nil }
            let m = CGMutablePath()
            m.move(to: CGPoint(x: f.midX, y: f.maxY))
            m.addLine(to: CGPoint(x: f.midX, y: bottom))
            return m
        case .activation(let node, let y0, let y1, _):
            guard let f = frame(node) else { return nil }
            let w = SequenceLayout.activationWidth
            return CGPath(rect: CGRect(x: f.midX - w / 2, y: y0, width: w, height: y1 - y0), transform: nil)
        case .band:
            return nil
        }
    }

    /// The second fill over a piece of decor, painted `Paint.accent`: a tree-table row's
    /// 4 pt branch stripe down its left edge.
    package static func accentPath(_ d: SceneDecor, frame: (NodeID) -> CGRect?) -> CGPath? {
        guard case .cell(let node, let rect, .tableRow, _) = d, let f = frame(node) else { return nil }
        let r = rect.offsetBy(dx: f.midX, dy: f.midY)
        return CGPath(rect: CGRect(x: r.minX, y: r.minY, width: 4, height: r.height), transform: nil)
    }

    // MARK: Swimlane pool

    /// The lanes wrapped in one rounded pool: its outline, and one divider where each lane
    /// meets the next. Nil without lanes.
    package static func pool(_ lanes: [CGRect]) -> (outline: CGPath, dividers: CGPath)? {
        guard let first = lanes.first else { return nil }
        let bounds = lanes.dropFirst().reduce(first) { $0.union($1) }
        let outline = CGMutablePath()
        outline.addRoundedRect(in: bounds, cornerWidth: 14, cornerHeight: 14)
        let dividers = CGMutablePath()
        for (a, b) in zip(lanes, lanes.dropFirst()) {
            if abs(a.maxY - b.minY) < 1 {
                dividers.move(to: CGPoint(x: max(a.minX, b.minX), y: b.minY))
                dividers.addLine(to: CGPoint(x: min(a.maxX, b.maxX), y: b.minY))
            } else if abs(a.maxX - b.minX) < 1 {
                dividers.move(to: CGPoint(x: b.minX, y: max(a.minY, b.minY)))
                dividers.addLine(to: CGPoint(x: b.minX, y: min(a.maxY, b.maxY)))
            }
        }
        return (outline, dividers)
    }

    /// The pool's outline and dividers: a neutral hairline, whatever the lanes' tints.
    package static func poolLine(_ theme: Theme) -> RGBA { theme.ink2.alpha(0.2) }

    // MARK: Trunks

    /// The line a parent's branch lines share (`BranchLines.trunk`: the org chart's bus,
    /// the timeline's axis, the fishbone's spine), drawn once rather than once per child in
    /// each child's colour.
    package struct Trunk {
        package var parent: NodeID
        package var children: [NodeID]
        package var family: String
        package var shape: BranchLineShape
        package var paint: Paint
        /// The most opaque of the lines that share it.
        package var opacity: Double
        /// Each end's side, to rebuild its frame from a live rectangle.
        var sides: [NodeID: Side]
    }

    /// Every trunk in the scene, in its edges' order.
    package static func trunks(_ scene: Scene) -> [Trunk] {
        var out: [Trunk] = []
        var index: [String: Int] = [:]
        let incoming = incomingColors(scene)
        for e in scene.edges {
            guard let pf = scene.nodes[e.parent]?.frame, let cf = scene.nodes[e.child]?.frame else { continue }
            let shape = BranchLineShape(name: e.line.shape)
            guard BranchLines.trunk(from: pf, to: cf, family: e.family, shape: shape) != nil else { continue }
            // Children drawn in different shapes each get a trunk that meets their stem.
            let key = "\(e.parent)|\(e.family)|\(shape)"
            if let i = index[key] {
                out[i].children.append(e.child)
                out[i].sides[e.child] = cf.side
                out[i].paint.width = max(out[i].paint.width, e.width)
                out[i].opacity = max(out[i].opacity, e.opacity)
                continue
            }
            index[key] = out.count
            let dash: [CGFloat]? = e.line.dash == "dashed" ? [6, 5] : e.line.dash == "dotted" ? [1.5, 4] : nil
            out.append(
                Trunk(
                    parent: e.parent, children: [e.child], family: e.family, shape: shape,
                    paint: Paint(
                        stroke: trunkColor(e.parent, family: e.family, scene: scene, incoming: incoming),
                        width: e.width,
                        dash: dash),
                    opacity: e.opacity, sides: [e.parent: pf.side, e.child: cf.side]))
        }
        return out
    }

    /// A trunk's colour: the parent's own branch colour when it has one (a branch drawn as
    /// a fishbone or org chart in a mind map), otherwise ink; an org chart's bus, a
    /// reporting line, is the lighter ink.
    static func trunkColor(
        _ parent: NodeID, family: String, scene: Scene, incoming: [NodeID: RGBA]? = nil
    ) -> RGBA {
        let own = incoming.map { $0[parent] } ?? scene.edges.first { $0.child == parent }?.color
        if let own { return own }
        return family == "org" ? scene.theme.ink2.alpha(0.55) : scene.theme.ink
    }

    /// Each topic's incoming branch colour (its first edge), looked up once per pass.
    package static func incomingColors(_ scene: Scene) -> [NodeID: RGBA] {
        Dictionary(scene.edges.map { ($0.child, $0.color) }, uniquingKeysWith: { first, _ in first })
    }

    /// A trunk's path from live frames, with the fishbone's arrowhead into its head.
    package static func path(_ t: Trunk, frame: (NodeID) -> CGRect?) -> CGPath? {
        func live(_ id: NodeID) -> NodeFrame? {
            frame(id).map {
                NodeFrame(
                    center: CGPoint(x: $0.midX, y: $0.midY), size: $0.size, side: t.sides[id] ?? .right, depth: 0)
            }
        }
        guard let pf = live(t.parent) else { return nil }
        let m = CGMutablePath()
        var bodySides = Set<Bool>()
        for c in t.children {
            guard let cf = live(c), let line = BranchLines.trunk(from: pf, to: cf, family: t.family, shape: t.shape)
            else { continue }
            m.addPath(line)
            bodySides.insert(cf.side == .left)
        }
        if t.family == "fishbone" {
            for left in bodySides {
                m.addPath(BranchLines.fishboneArrow(head: pf, bodyLeft: left, width: t.paint.width))
            }
        }
        return m.isEmpty ? nil : m
    }
}
