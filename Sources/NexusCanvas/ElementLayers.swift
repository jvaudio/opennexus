import AppKit
import NexusCore
import NexusLayout
import NexusTheme
@preconcurrency import QuartzCore

/// Relationship geometry: a curve between two topics, clipped to their edges.
enum RelationshipGeometry {
    struct Result {
        var path: CGPath
        var start: CGPoint
        var end: CGPoint
        /// Direction of travel at each end (radians): start points away from the source,
        /// end points into the target.
        var startAngle: CGFloat
        var endAngle: CGFloat
        var control: CGPoint
        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }
    }

    static func clip(_ center: CGPoint, _ rect: CGRect, toward q: CGPoint, pad: CGFloat = 6) -> CGPoint {
        let vx = q.x - center.x
        let vy = q.y - center.y
        let t = min(
            (rect.width / 2 + pad) / max(abs(vx), 1e-6), (rect.height / 2 + pad) / max(abs(vy), 1e-6))
        return CGPoint(x: center.x + vx * min(t, 1), y: center.y + vy * min(t, 1))
    }

    /// `obstacles` are other topics: a curve bows to whichever side crosses fewer of them.
    static func make(_ r: Relationship, from a: CGRect, to b: CGRect, obstacles: [CGRect] = []) -> Result {
        let ca = CGPoint(x: a.midX, y: a.midY)
        let cb = CGPoint(x: b.midX, y: b.midY)
        let p = CGMutablePath()
        switch r.line {
        case "straight", "zigzag":
            let s = clip(ca, a, toward: cb)
            let e = clip(cb, b, toward: ca)
            p.move(to: s)
            if r.line == "zigzag" {
                let n = 5
                let dx = e.x - s.x
                let dy = e.y - s.y
                let len = max(hypot(dx, dy), 1)
                let nx = -dy / len * 5
                let ny = dx / len * 5
                for i in 1...n {
                    let t = CGFloat(i) / CGFloat(n)
                    let sign: CGFloat = i == n ? 0 : (i % 2 == 0 ? -1 : 1)
                    p.addLine(to: CGPoint(x: s.x + dx * t + nx * sign, y: s.y + dy * t + ny * sign))
                }
            } else {
                p.addLine(to: e)
            }
            let ang = atan2(e.y - s.y, e.x - s.x)
            return Result(
                path: p, start: s, end: e, startAngle: ang + .pi, endAngle: ang,
                control: CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2))
        case "flow-vh", "flow-hv":
            // Flowcharts (S5): a decision exits sideways then drops into its branch
            // (hv); a step drops then turns into a merge's side (vh).
            let below = b.minY > a.maxY - 4
            guard below else { return make(withLine(r, "elbow"), from: a, to: b, obstacles: obstacles) }
            if abs(cb.x - ca.x) < min(a.width, b.width) / 2 - 4 {
                return polyline([CGPoint(x: cb.x, y: a.maxY), CGPoint(x: cb.x, y: b.minY - 2)])
            }
            let right = cb.x > ca.x
            if r.line == "flow-hv" {
                return polyline([
                    CGPoint(x: right ? a.maxX : a.minX, y: ca.y), CGPoint(x: cb.x, y: ca.y),
                    CGPoint(x: cb.x, y: b.minY - 2),
                ])
            }
            return polyline([
                CGPoint(x: ca.x, y: a.maxY), CGPoint(x: ca.x, y: cb.y),
                CGPoint(x: right ? b.minX - 2 : b.maxX + 2, y: cb.y),
            ])
        case "elbow":
            // Stacked boxes connect top-to-bottom; otherwise side-to-side.
            let overlapX = b.minX < a.maxX - 8 && b.maxX > a.minX + 8
            if overlapX && (b.minY > a.maxY || b.maxY < a.minY) {
                let down = b.minY > a.maxY
                let s = CGPoint(x: ca.x, y: down ? a.maxY + 4 : a.minY - 4)
                let e = CGPoint(x: cb.x, y: down ? b.minY - 6 : b.maxY + 6)
                if abs(s.x - e.x) < 1 { return polyline([s, e]) }
                let my = (s.y + e.y) / 2
                return polyline([s, CGPoint(x: s.x, y: my), CGPoint(x: e.x, y: my), e])
            }
            let right = cb.x >= ca.x
            let s = CGPoint(x: right ? a.maxX + 4 : a.minX - 4, y: ca.y)
            let e = CGPoint(x: right ? b.minX - 6 : b.maxX + 6, y: cb.y)
            let mx = (s.x + e.x) / 2
            p.move(to: s)
            p.addLine(to: CGPoint(x: mx, y: s.y))
            p.addLine(to: CGPoint(x: mx, y: e.y))
            p.addLine(to: e)
            return Result(
                path: p, start: s, end: e, startAngle: right ? .pi : 0, endAngle: right ? 0 : .pi,
                control: CGPoint(x: mx, y: (s.y + e.y) / 2))
        default:  // curved
            let mid = CGPoint(x: (ca.x + cb.x) / 2, y: (ca.y + cb.y) / 2)
            let dx = cb.x - ca.x
            let dy = cb.y - ca.y
            let len = max(hypot(dx, dy), 1)
            let off = min(140, len * 0.35) + 30
            var c = CGPoint(x: mid.x - dy / len * off, y: mid.y + dx / len * off)
            if r.bend == nil, !obstacles.isEmpty {
                let flipped = CGPoint(x: mid.x + dy / len * off, y: mid.y - dx / len * off)
                if crossings(ca, c, cb, obstacles) > crossings(ca, flipped, cb, obstacles) { c = flipped }
            }
            if let bend = r.bend {
                c.x += bend.x
                c.y += bend.y
            }
            let s = clip(ca, a, toward: c)
            let e = clip(cb, b, toward: c)
            p.move(to: s)
            p.addQuadCurve(to: e, control: c)
            return Result(
                path: p, start: s, end: e, startAngle: atan2(s.y - c.y, s.x - c.x),
                endAngle: atan2(e.y - c.y, e.x - c.x), control: c)
        }
    }

    /// How many obstacles a quadratic curve passes through (sampled).
    static func crossings(_ s: CGPoint, _ c: CGPoint, _ e: CGPoint, _ obstacles: [CGRect]) -> Int {
        var hit = Set<Int>()
        for i in 1..<24 {
            let t = CGFloat(i) / 24
            let u = 1 - t
            let p = CGPoint(
                x: u * u * s.x + 2 * u * t * c.x + t * t * e.x, y: u * u * s.y + 2 * u * t * c.y + t * t * e.y)
            for (j, o) in obstacles.enumerated() where o.contains(p) { hit.insert(j) }
        }
        return hit.count
    }

    static func withLine(_ r: Relationship, _ line: String) -> Relationship {
        var x = r
        x.line = line
        return x
    }

    /// A polyline through `pts`; the label anchors at the middle segment.
    static func polyline(_ pts: [CGPoint]) -> Result {
        let p = CGMutablePath()
        guard let first = pts.first, let last = pts.last, pts.count >= 2 else {
            return Result(path: p, start: .zero, end: .zero, startAngle: 0, endAngle: 0, control: .zero)
        }
        p.move(to: first)
        for q in pts.dropFirst() { p.addLine(to: q) }
        let a = pts[1]
        let b = pts[pts.count - 2]
        let m = pts.count / 2
        let mid = CGPoint(x: (pts[m - 1].x + pts[m].x) / 2, y: (pts[m - 1].y + pts[m].y) / 2)
        // A quadratic through the midpoint with this control passes near it, so labels sit on the line.
        let control = CGPoint(x: 2 * mid.x - (first.x + last.x) / 2, y: 2 * mid.y - (first.y + last.y) / 2)
        return Result(
            path: p, start: first, end: last, startAngle: atan2(first.y - a.y, first.x - a.x),
            endAngle: atan2(last.y - b.y, last.x - b.x), control: pts.count == 2 ? mid : control)
    }

    /// The 11 end caps (FMT-2): none, arrow, filled-arrow, triangle, diamond,
    /// filled-diamond, dot, open-dot, bar, crows-foot, square.
    static func cap(_ kind: String, at tip: CGPoint, angle: CGFloat, width w: CGFloat) -> (CGPath?, filled: Bool) {
        guard kind != "none" else { return (nil, false) }
        let len = w * 3 + 6
        let half = w * 1.8 + 3
        func pt(_ back: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - back * cos(angle) - side * sin(angle), y: tip.y - back * sin(angle) + side * cos(angle))
        }
        let p = CGMutablePath()
        switch kind {
        case "arrow":
            p.move(to: pt(len, half))
            p.addLine(to: tip)
            p.addLine(to: pt(len, -half))
            return (p, false)
        case "filled-arrow", "triangle":
            p.move(to: tip)
            p.addLine(to: pt(len, half))
            p.addLine(to: pt(len, -half))
            p.closeSubpath()
            return (p, kind == "filled-arrow")
        case "diamond", "filled-diamond":
            p.move(to: tip)
            p.addLine(to: pt(len * 0.8, half * 0.8))
            p.addLine(to: pt(len * 1.6, 0))
            p.addLine(to: pt(len * 0.8, -half * 0.8))
            p.closeSubpath()
            return (p, kind == "filled-diamond")
        case "dot", "open-dot":
            let r = w * 1.4 + 2
            let c = pt(r, 0)
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            return (p, kind == "dot")
        case "bar":
            p.move(to: pt(w, half * 1.2))
            p.addLine(to: pt(w, -half * 1.2))
            return (p, false)
        case "crows-foot":
            for side in [-half * 1.3, 0, half * 1.3] {
                p.move(to: pt(len, 0))
                p.addLine(to: CGPoint(x: tip.x - side * sin(angle), y: tip.y + side * cos(angle)))
            }
            return (p, false)
        case "square":
            let s = w * 1.4 + 3
            let c = pt(s, 0)
            p.addRect(CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s))
            return (p, true)
        default:
            return (nil, false)
        }
    }
}

/// Boundary outlines (FMT-2: 9 shapes).
enum BoundaryShapes {
    static func path(_ shape: String, in r: CGRect) -> CGPath {
        switch shape {
        case "rectangle", "corners":
            if shape == "corners" {
                let p = CGMutablePath()
                let k = min(18, r.width / 4, r.height / 4)
                for (o, dx, dy) in [
                    (CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                    (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0),
                ] {
                    p.move(to: CGPoint(x: o.x + k * dx, y: o.y))
                    p.addLine(to: o)
                    p.addLine(to: CGPoint(x: o.x, y: o.y + k * dy))
                }
                return p
            }
            return CGPath(rect: r, transform: nil)
        case "stadium":
            let k = min(r.width, r.height) / 2
            return CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
        case "ellipse":
            return CGPath(ellipseIn: r.insetBy(dx: -r.width * 0.06, dy: -r.height * 0.1), transform: nil)
        case "wave":
            let p = CGMutablePath()
            let amp: CGFloat = 5
            let n = max(2, Int(r.width / 48))
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            for i in 0..<n {
                let x0 = r.minX + r.width * CGFloat(i) / CGFloat(n)
                let x1 = r.minX + r.width * CGFloat(i + 1) / CGFloat(n)
                p.addQuadCurve(
                    to: CGPoint(x: x1, y: r.minY),
                    control: CGPoint(x: (x0 + x1) / 2, y: r.minY + (i % 2 == 0 ? -amp : amp) * 2))
            }
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            for i in (0..<n).reversed() {
                let x0 = r.minX + r.width * CGFloat(i + 1) / CGFloat(n)
                let x1 = r.minX + r.width * CGFloat(i) / CGFloat(n)
                p.addQuadCurve(
                    to: CGPoint(x: x1, y: r.maxY),
                    control: CGPoint(x: (x0 + x1) / 2, y: r.maxY + (i % 2 == 0 ? amp : -amp) * 2))
            }
            p.closeSubpath()
            return p
        case "scallop":
            let p = CGMutablePath()
            let bump: CGFloat = 16
            let nx = max(2, Int(r.width / bump))
            let ny = max(2, Int(r.height / bump))
            let sx = r.width / CGFloat(nx)
            let sy = r.height / CGFloat(ny)
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            for i in 0..<nx {
                p.addQuadCurve(
                    to: CGPoint(x: r.minX + sx * CGFloat(i + 1), y: r.minY),
                    control: CGPoint(x: r.minX + sx * (CGFloat(i) + 0.5), y: r.minY - 7))
            }
            for i in 0..<ny {
                p.addQuadCurve(
                    to: CGPoint(x: r.maxX, y: r.minY + sy * CGFloat(i + 1)),
                    control: CGPoint(x: r.maxX + 7, y: r.minY + sy * (CGFloat(i) + 0.5)))
            }
            for i in 0..<nx {
                p.addQuadCurve(
                    to: CGPoint(x: r.maxX - sx * CGFloat(i + 1), y: r.maxY),
                    control: CGPoint(x: r.maxX - sx * (CGFloat(i) + 0.5), y: r.maxY + 7))
            }
            for i in 0..<ny {
                p.addQuadCurve(
                    to: CGPoint(x: r.minX, y: r.maxY - sy * CGFloat(i + 1)),
                    control: CGPoint(x: r.minX - 7, y: r.maxY - sy * (CGFloat(i) + 0.5)))
            }
            p.closeSubpath()
            return p
        case "polygon":
            let k = min(22, r.width / 6)
            let p = CGMutablePath()
            p.addLines(between: [
                CGPoint(x: r.minX + k, y: r.minY), CGPoint(x: r.maxX - k, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                CGPoint(x: r.maxX - k, y: r.maxY), CGPoint(x: r.minX + k, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
            ])
            p.closeSubpath()
            return p
        default:  // rounded, dashed
            return CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)
        }
    }

    /// Diagonal hatching for medium and low trust (never colour alone).
    static func hatch(in r: CGRect, dense: Bool) -> CGPath {
        let p = CGMutablePath()
        let step: CGFloat = dense ? 7 : 12
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += step
        }
        return p
    }
}

/// One relationship: line, caps, label chip, selection halo.
final class RelationshipLayer: CALayer {
    let halo = CAShapeLayer()
    let line = CAShapeLayer()
    let startCap = CAShapeLayer()
    let endCap = CAShapeLayer()
    let labelBack = CAShapeLayer()
    let label = TextLayer()
    let flag = CAShapeLayer()
    let flagText = TextLayer()
    var labelRect: CGRect = .zero
    var hitPath: CGPath?

    override init() {
        super.init()
        for l in [halo, line, startCap, endCap, labelBack] as [CAShapeLayer] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.actions = NodeLayer.noActions
            addSublayer(l)
        }
        label.actions = NodeLayer.noActions
        addSublayer(label)
        for l in [flag, flagText] as [CALayer] {
            l.actions = NodeLayer.noActions
            l.isHidden = true
            addSublayer(l)
        }
        actions = NodeLayer.noActions
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

/// Owns and updates every element layer on the canvas.
@MainActor
final class ElementRenderer {
    /// Settings › Appearance › Glow trail on new edges, and Flow dots in Present mode.
    var glowTrail = true
    var flowDots = true
    let zonesLayer = CALayer()
    let boundariesLayer = CALayer()
    let summariesLayer = CALayer()
    let relationshipsLayer = CALayer()
    let pointersLayer = CALayer()
    let overlayLayer = CALayer()

    private var relLayers: [String: RelationshipLayer] = [:]
    private var flaggedFlows = Set<String>()
    private var boundaryLayers: [String: CALayer] = [:]
    private var summaryLayers: [String: CAShapeLayer] = [:]
    private var zoneLayers: [String: CALayer] = [:]
    private var pointerLayers: [String: CAShapeLayer] = [:]
    private var hintLayers: [NodeID: CALayer] = [:]
    private let preview = CAShapeLayer()
    private let guides = CAShapeLayer()
    private let guideLabel = TextLayer()
    private var scene = Scene()
    /// The element whose text the editor overlay is drawing (its own text hides).
    var editingElement: ElementRef?
    var textScale: CGFloat = 2
    private var drawnRelationships = Set<String>()

    init() {
        for l in [zonesLayer, boundariesLayer, summariesLayer, relationshipsLayer, pointersLayer, overlayLayer] {
            l.actions = NodeLayer.noActions
        }
        preview.fillColor = nil
        preview.lineDashPattern = [5, 4]
        preview.lineWidth = 2
        preview.actions = NodeLayer.noActions
        overlayLayer.addSublayer(preview)
        guides.fillColor = nil
        guides.lineDashPattern = [4, 3]
        guides.lineWidth = 1
        guides.strokeColor = RGBA(hex: "#E2408C").cgColor
        guides.actions = NodeLayer.noActions
        overlayLayer.addSublayer(guides)
        guideLabel.actions = NodeLayer.noActions
        overlayLayer.addSublayer(guideLabel)
    }

    // MARK: Sync

    func update(
        scene: Scene, selected: ElementRef?, connect: ConnectState?, frame: (NodeID) -> CGRect?,
        animated: Bool
    ) {
        self.scene = scene
        let theme = scene.theme
        syncZones(scene, selected: selected)
        syncBoundaries(scene, selected: selected)
        syncSummaries(scene, selected: selected)
        syncRelationships(scene, selected: selected, frame: frame, animated: animated)
        syncPointers(scene, frame: frame)
        syncConnect(connect, theme: theme, frame: frame)
    }

    /// Per-frame geometry for things tied to animated topic frames.
    func updateGeometry(selected: ElementRef?, connect: ConnectState?, frame: (NodeID) -> CGRect?) {
        for r in scene.relationships {
            guard let l = relLayers[r.relationship.id], let a = frame(r.relationship.from),
                let b = frame(r.relationship.to)
            else { continue }
            layoutRelationship(l, r, a, b, selected: selected == .relationship(r.relationship.id))
        }
        syncPointers(scene, frame: frame)
        layoutConnect(connect, frame: frame)
    }

    private func syncZones(_ scene: Scene, selected: ElementRef?) {
        var seen = Set<String>()
        for (i, z) in scene.zones.enumerated() {
            seen.insert(z.zone.id)
            let l = zoneLayers[z.zone.id] ?? makeGroup(in: zonesLayer) { zoneLayers[z.zone.id] = $0 }
            l.zPosition = CGFloat(i)
            let shape = l.sublayers![0] as! CAShapeLayer
            let title = l.sublayers![1] as! TextLayer
            let rect = z.rect
            let radius: CGFloat = z.zone.frame == "square" ? 2 : 14
            shape.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            shape.fillColor = z.color.alpha(0.06).cgColor
            let on = selected == .zone(z.zone.id)
            shape.strokeColor = (on ? scene.theme.ring : z.color.alpha(0.6)).cgColor
            shape.lineWidth = on ? 2.5 : 1.5
            shape.lineDashPattern = z.zone.frame == "dashed" ? [5, 4] : nil
            let caret = z.zone.collapsed ? "▸" : "▾"
            var t = "\(caret) \(z.zone.title)"
            let detail =
                z.zone.collapsed
                ? " · " + Loc.f("%lld hidden", z.hidden) : z.zone.autoResize ? " · " + Loc.t("auto-size") : ""
            let s = NSMutableAttributedString(
                string: t,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor(cgColor: z.color.cgColor)!,
                ])
            s.append(
                NSAttributedString(
                    string: detail,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor(cgColor: z.color.alpha(0.7).cgColor)!,
                    ]))
            t = s.string
            title.attributed = s
            title.contentsScale = textScale
            title.frame = CGRect(x: rect.minX + 14, y: rect.minY + 10, width: max(10, rect.width - 28), height: 20)
        }
        for (id, l) in zoneLayers where !seen.contains(id) {
            l.removeFromSuperlayer()
            zoneLayers[id] = nil
        }
    }

    private func makeGroup(in parent: CALayer, _ store: (CALayer) -> Void) -> CALayer {
        let g = CALayer()
        g.actions = NodeLayer.noActions
        let shape = CAShapeLayer()
        shape.actions = NodeLayer.noActions
        g.addSublayer(shape)
        let title = TextLayer()
        title.actions = NodeLayer.noActions
        g.addSublayer(title)
        let hatch = CAShapeLayer()
        hatch.actions = NodeLayer.noActions
        hatch.fillColor = nil
        g.addSublayer(hatch)
        parent.addSublayer(g)
        store(g)
        return g
    }

    private func syncBoundaries(_ scene: Scene, selected: ElementRef?) {
        var seen = Set<String>()
        for b in scene.boundaries {
            seen.insert(b.boundary.id)
            let g =
                boundaryLayers[b.boundary.id] ?? makeGroup(in: boundariesLayer) { boundaryLayers[b.boundary.id] = $0 }
            let shape = g.sublayers![0] as! CAShapeLayer
            let title = g.sublayers![1] as! TextLayer
            let hatch = g.sublayers![2] as! CAShapeLayer
            let bd = b.boundary
            let path = BoundaryShapes.path(bd.shape, in: b.rect)
            shape.path = path
            let on = selected == .boundary(bd.id)
            shape.fillColor = bd.shape == "corners" ? nil : b.color.alpha(bd.fillOpacity).cgColor
            shape.strokeColor = (on ? scene.theme.ring : b.color).cgColor
            shape.lineWidth = on ? bd.width + 1.5 : bd.width
            let dash =
                bd.dash
                ?? (bd.meaning == "trust" || bd.meaning == "subnet" || bd.shape == "dashed" ? "dashed" : "solid")
            shape.lineDashPattern =
                switch dash {
                case "dashed": [6, 4]
                case "dotted": [1.5, 3.5]
                default: nil
                }
            shape.lineCap = dash == "dotted" ? .round : .butt
            // Trust level adds a pattern: high = none, medium = hatch, low = dense hatch.
            if bd.hatch, let trust = bd.trust, trust != "high" {
                hatch.isHidden = false
                hatch.path = BoundaryShapes.hatch(in: b.rect, dense: trust == "low")
                hatch.strokeColor = b.color.alpha(0.18).cgColor
                hatch.lineWidth = 1
                let mask = CAShapeLayer()
                mask.path = path
                hatch.mask = mask
            } else {
                hatch.isHidden = true
            }
            let prefix: String =
                switch bd.meaning {
                case "vpc": "VPC"
                case "subnet": "SUBNET"
                case "trust": "TRUST BOUNDARY"
                case "zone": "ZONE"
                default: ""
                }
            let parts = [prefix, bd.title].filter { !$0.isEmpty }
            let text = parts.joined(separator: " · ")
            title.isHidden = text.isEmpty
            title.attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: NSColor(cgColor: b.color.cgColor)!,
                ])
            title.contentsScale = textScale
            title.frame = CGRect(x: b.rect.minX + 12, y: b.rect.minY + 6, width: max(10, b.rect.width - 24), height: 16)
        }
        for (id, l) in boundaryLayers where !seen.contains(id) {
            l.removeFromSuperlayer()
            boundaryLayers[id] = nil
        }
    }

    private func syncSummaries(_ scene: Scene, selected: ElementRef?) {
        var seen = Set<String>()
        for s in scene.summaries {
            seen.insert(s.summary.id)
            let l =
                summaryLayers[s.summary.id]
                ?? {
                    let c = CAShapeLayer()
                    c.fillColor = nil
                    c.lineCap = .round
                    c.lineJoin = .round
                    c.actions = NodeLayer.noActions
                    summariesLayer.addSublayer(c)
                    summaryLayers[s.summary.id] = c
                    return c
                }()
            l.path = Self.bracket(s.bracket, side: s.side, shape: s.summary.bracket)
            let on = selected == .summary(s.summary.id)
            l.strokeColor = (on ? scene.theme.ring : s.color).cgColor
            l.lineWidth = on ? s.summary.width + 1.5 : s.summary.width
        }
        for (id, l) in summaryLayers where !seen.contains(id) {
            l.removeFromSuperlayer()
            summaryLayers[id] = nil
        }
    }

    /// A curly brace opening toward the range.
    /// The summary bracket in `r`, opening toward the range. Built in (along, across)
    /// terms: along runs the length of the range, across from the range (0) to the topic.
    static func bracket(_ r: CGRect, side: Side, shape: String = "curly") -> CGPath {
        let down = side == .down
        let length = down ? r.width : r.height
        let depth = down ? r.height : r.width
        func pt(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            switch side {
            case .down: CGPoint(x: r.minX + along, y: r.minY + across)
            case .left: CGPoint(x: r.maxX - across, y: r.minY + along)
            default: CGPoint(x: r.minX + across, y: r.minY + along)
            }
        }
        let mid = depth / 2
        let half = length / 2
        let p = CGMutablePath()
        switch shape {
        case "square":
            p.move(to: pt(0, 0))
            p.addLine(to: pt(0, mid))
            p.addLine(to: pt(length, mid))
            p.addLine(to: pt(length, 0))
            p.move(to: pt(half, mid))
            p.addLine(to: pt(half, depth))
        case "round":
            p.move(to: pt(0, 0))
            p.addQuadCurve(to: pt(length, 0), control: pt(half, depth * 2))
        case "line":
            p.move(to: pt(0, mid))
            p.addLine(to: pt(length, mid))
            p.move(to: pt(half, mid))
            p.addLine(to: pt(half, depth))
        default:  // curly
            let k = min(depth, 10, length / 4)
            p.move(to: pt(0, 0))
            p.addQuadCurve(to: pt(k, mid), control: pt(0, mid))
            p.addLine(to: pt(half - k, mid))
            p.addQuadCurve(to: pt(half, depth), control: pt(half, mid))
            p.addQuadCurve(to: pt(half + k, mid), control: pt(half, mid))
            p.addLine(to: pt(length - k, mid))
            p.addQuadCurve(to: pt(length, 0), control: pt(length, mid))
        }
        return p
    }

    private func syncRelationships(_ scene: Scene, selected: ElementRef?, frame: (NodeID) -> CGRect?, animated: Bool) {
        var seen = Set<String>()
        for r in scene.relationships {
            let id = r.relationship.id
            seen.insert(id)
            let isNew = relLayers[id] == nil
            let l =
                relLayers[id]
                ?? {
                    let n = RelationshipLayer()
                    relationshipsLayer.addSublayer(n)
                    relLayers[id] = n
                    return n
                }()
            guard let a = frame(r.relationship.from), let b = frame(r.relationship.to) else { continue }
            layoutRelationship(l, r, a, b, selected: selected == .relationship(id))
            if isNew && animated && !drawnRelationships.contains(id) {
                // The edge draws on from source to target, with a brief glow trail.
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = Motion.connectDraw
                draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
                l.line.add(draw, forKey: "draw")
            }
            if isNew && animated && !drawnRelationships.contains(id) && glowTrail {
                l.line.shadowColor = r.color.cgColor
                l.line.shadowRadius = 5
                l.line.shadowOffset = .zero
                let glow = CABasicAnimation(keyPath: "shadowOpacity")
                glow.fromValue = 0.9
                glow.toValue = 0
                glow.duration = 0.6
                l.line.add(glow, forKey: "glow")
            }
            drawnRelationships.insert(id)
            // A newly broken rule shakes its flow once (artboard 20).
            if r.flagged && !flaggedFlows.contains(id) && animated {
                let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                shake.values = [0, -7, 7, -5, 5, -2, 0]
                shake.duration = 0.42
                l.add(shake, forKey: "shake")
            }
        }
        flaggedFlows = Set(scene.relationships.filter(\.flagged).map(\.relationship.id))
        for (id, l) in relLayers where !seen.contains(id) {
            l.removeFromSuperlayer()
            relLayers[id] = nil
        }
    }

    private func layoutRelationship(
        _ l: RelationshipLayer, _ r: SceneRelationship, _ a: CGRect, _ b: CGRect,
        selected: Bool
    ) {
        let rel = r.relationship
        let g: RelationshipGeometry.Result
        if let pts = r.points {
            g = RelationshipGeometry.polyline(pts)
        } else {
            let obstacles = scene.nodes.values.map(\.frame.rect).filter { !$0.intersects(a) && !$0.intersects(b) }
            g = RelationshipGeometry.make(rel, from: a, to: b, obstacles: obstacles)
        }
        let w = CGFloat(rel.width) * (r.glow ? 2 : 1)
        l.opacity = Float(r.opacity)
        l.line.path = g.path
        l.line.strokeColor = (r.glow ? scene.theme.ai : r.color).cgColor
        l.line.lineWidth = w
        if r.glow {
            l.line.shadowColor = scene.theme.ai.cgColor
            l.line.shadowOpacity = 0.9
            l.line.shadowRadius = 6
            l.line.shadowOffset = .zero
        } else if l.line.animation(forKey: "glow") == nil {
            l.line.shadowOpacity = 0
        }
        l.line.lineDashPattern =
            switch rel.dash {
            case "dashed": [NSNumber(value: Double(w) * 3), NSNumber(value: Double(w) * 2.5)]
            case "dotted": [0.01, NSNumber(value: Double(w) * 2.4)]
            default: nil
            }
        // Present's step flow: dots travel along it.
        if r.glow && flowDots {
            l.line.lineDashPattern = [0.01, NSNumber(value: Double(w) * 3)]
            l.line.lineCap = .round
            if l.line.animation(forKey: "flow") == nil {
                let a = CABasicAnimation(keyPath: "lineDashPhase")
                a.fromValue = 0
                a.toValue = -Double(w) * 3 * 4
                a.duration = 0.9
                a.repeatCount = .infinity
                l.line.add(a, forKey: "flow")
            }
        } else {
            l.line.removeAnimation(forKey: "flow")
        }
        l.halo.path = g.path
        l.halo.strokeColor = scene.theme.ringSoft.cgColor
        l.halo.lineWidth = w + 8
        l.halo.isHidden = !selected
        for (cap, kind, tip, angle) in [
            (l.startCap, rel.ends.first ?? "none", g.start, g.startAngle),
            (l.endCap, rel.ends.last ?? "arrow", g.end, g.endAngle),
        ] {
            let (path, filled) = RelationshipGeometry.cap(kind, at: tip, angle: angle, width: w)
            cap.path = path
            cap.isHidden = path == nil
            cap.strokeColor = r.color.cgColor
            cap.lineWidth = w
            cap.fillColor =
                filled
                ? r.color.cgColor
                : (kind == "triangle" || kind == "diamond" || kind == "open-dot" ? scene.canvasColor.cgColor : nil)
        }
        l.hitPath = g.path.copy(strokingWithWidth: max(12, w + 10), lineCap: .round, lineJoin: .round, miterLimit: 4)
        // Label chip, nudged off any topic it would cover.
        let text = rel.label
        let t: CGFloat = rel.labelPosition == "start" ? 0.22 : rel.labelPosition == "end" ? 0.78 : 0.5
        guard !text.isEmpty || selected else {
            l.label.isHidden = true
            l.labelBack.isHidden = true
            l.labelRect = CGRect(origin: g.point(at: t), size: .zero).insetBy(dx: -30, dy: -11)
            return
        }
        let font = NSFont.systemFont(ofSize: 12, weight: rel.labelStyle == "plain" ? .medium : .semibold)
        let ink = rel.labelStyle == "pill" ? Contrast.adjusted(RGBA(hex: "#17171C"), on: r.color) : r.color
        let attr = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(
                    cgColor: (rel.labelStyle == "pill" ? ink : Contrast.adjusted(ink, on: scene.canvasColor)).cgColor)!,
                .paragraphStyle: NodeLayer.centered,
            ])
        let size = CGSize(width: ceil(attr.size().width) + 18, height: 22)
        var center = g.point(at: t)
        // Sequence messages read like UML: the label sits above the arrow.
        if r.points != nil { center.y -= 13 }
        let tangent = CGPoint(
            x: g.point(at: min(1, t + 0.01)).x - g.point(at: max(0, t - 0.01)).x,
            y: g.point(at: min(1, t + 0.01)).y - g.point(at: max(0, t - 0.01)).y)
        let tl = max(hypot(tangent.x, tangent.y), 1e-3)
        let normal = CGPoint(x: -tangent.y / tl, y: tangent.x / tl)
        let blockers = scene.nodes.values.map { $0.frame.rect.insetBy(dx: -4, dy: -4) }
        for k in [0, 1, -1, 2, -2, 3, -3] as [CGFloat] {
            let c = CGPoint(x: center.x + normal.x * 18 * k, y: center.y + normal.y * 18 * k)
            let rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            if !blockers.contains(where: { $0.intersects(rect) }) {
                center = c
                break
            }
        }
        let rect = CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        l.labelRect = rect
        // Plain labels keep a canvas-coloured chip so the line doesn't strike through them.
        l.labelBack.isHidden = false
        l.labelBack.path = CGPath(
            roundedRect: rect, cornerWidth: rel.labelStyle == "boxed" ? 4 : 11,
            cornerHeight: rel.labelStyle == "boxed" ? 4 : 11, transform: nil)
        l.labelBack.fillColor = (rel.labelStyle == "pill" ? r.color : scene.canvasColor).cgColor
        l.labelBack.strokeColor =
            selected ? scene.theme.ring.cgColor : rel.labelStyle == "boxed" ? r.color.cgColor : nil
        l.labelBack.lineWidth = selected ? 2 : 1
        l.label.isHidden = text.isEmpty || editingElement == .relationship(rel.id)
        l.label.attributed = attr
        l.label.contentsScale = textScale
        l.label.frame = rect.insetBy(dx: 4, dy: 3).offsetBy(dx: 0, dy: 0)
        // A rule violation: red boxed chip with a "!" badge (artboard 20).
        if r.flagged {
            l.labelBack.isHidden = false
            l.labelBack.fillColor = scene.theme.critical.alpha(0.12).cgColor
            l.labelBack.strokeColor = scene.theme.critical.cgColor
            l.labelBack.lineWidth = 1.5
            l.labelBack.path = CGPath(
                roundedRect: rect.insetBy(dx: 0, dy: 0).union(rect.offsetBy(dx: 18, dy: 0)), cornerWidth: 5,
                cornerHeight: 5, transform: nil)
            l.flag.isHidden = false
            l.flag.path = CGPath(
                ellipseIn: CGRect(x: rect.maxX + 18 - 22, y: rect.midY - 8, width: 16, height: 16), transform: nil)
            l.flag.fillColor = scene.theme.critical.cgColor
            l.flagText.isHidden = false
            l.flagText.attributed = NSAttributedString(
                string: "!",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.white,
                    .paragraphStyle: NodeLayer.centered,
                ])
            l.flagText.contentsScale = textScale
            l.flagText.frame = CGRect(x: rect.maxX + 18 - 22, y: rect.midY - 7, width: 16, height: 15)
            l.flagText.setNeedsDisplay()
            l.labelRect = rect.union(rect.offsetBy(dx: 18, dy: 0))
        } else {
            l.flag.isHidden = true
            l.flagText.isHidden = true
        }
    }

    private func syncPointers(_ scene: Scene, frame: (NodeID) -> CGRect?) {
        var seen = Set<String>()
        for k in scene.callouts {
            guard let host = frame(k.callout.host), let bubble = frame(k.callout.topic),
                let n = scene.nodes[k.callout.topic]
            else { continue }
            seen.insert(k.callout.id)
            let l =
                pointerLayers[k.callout.id]
                ?? {
                    let c = CAShapeLayer()
                    c.actions = NodeLayer.noActions
                    c.lineJoin = .round
                    pointersLayer.addSublayer(c)
                    pointerLayers[k.callout.id] = c
                    return c
                }()
            // A tail from the bubble's edge to the host's edge.
            let hc = CGPoint(x: host.midX, y: host.midY)
            let bc = CGPoint(x: bubble.midX, y: bubble.midY)
            let tip = RelationshipGeometry.clip(hc, host, toward: bc, pad: 2)
            let base = RelationshipGeometry.clip(bc, bubble, toward: hc, pad: -6)
            let dx = tip.x - base.x
            let dy = tip.y - base.y
            let len = max(hypot(dx, dy), 1)
            let half: CGFloat = 7
            let p = CGMutablePath()
            p.move(to: CGPoint(x: base.x - dy / len * half, y: base.y + dx / len * half))
            p.addLine(to: tip)
            p.addLine(to: CGPoint(x: base.x + dy / len * half, y: base.y - dx / len * half))
            p.closeSubpath()
            l.path = p
            l.fillColor = n.appearance.fill.representative?.cgColor ?? RGBA(hex: "#FFF6D6").cgColor
            l.strokeColor = n.appearance.borderColor.cgColor
            l.lineWidth = CGFloat(n.appearance.borderWidth)
        }
        for (id, l) in pointerLayers where !seen.contains(id) {
            l.removeFromSuperlayer()
            pointerLayers[id] = nil
        }
    }

    // MARK: Connect mode

    private var lastConnect: ConnectState?

    private func syncConnect(_ c: ConnectState?, theme: Theme, frame: (NodeID) -> CGRect?) {
        let fresh = c?.source != lastConnect?.source
        lastConnect = c
        guard let c else {
            for l in hintLayers.values { l.removeFromSuperlayer() }
            hintLayers.removeAll()
            preview.isHidden = true
            return
        }
        let visible = Set(c.matchedHints ? c.matches.map(\.node) : c.matches.map(\.node))
        for cand in c.candidates {
            let show = visible.contains(cand.node) && c.matchedHints
            if show {
                let chip =
                    hintLayers[cand.node]
                    ?? {
                        let g = CALayer()
                        g.actions = NodeLayer.noActions
                        g.cornerRadius = 5
                        let t = TextLayer()
                        t.actions = NodeLayer.noActions
                        g.addSublayer(t)
                        overlayLayer.addSublayer(g)
                        hintLayers[cand.node] = g
                        if fresh {
                            // Chips pop in nearest-first, 40 ms apart.
                            let pop = CABasicAnimation(keyPath: "transform.scale")
                            pop.fromValue = 0.2
                            pop.toValue = 1
                            pop.duration = 0.18
                            pop.beginTime =
                                CACurrentMediaTime() + min(Double(cand.rank) * Motion.connectHintStagger, 0.6)
                            pop.fillMode = .backwards
                            g.add(pop, forKey: "pop")
                        }
                        return g
                    }()
                let on = c.target?.node == cand.node
                chip.backgroundColor = (on ? theme.amber : RGBA(hex: "#FFE3A3")).cgColor
                chip.borderColor = RGBA(hex: "#17171C").alpha(0.15).cgColor
                chip.borderWidth = 0.5
                let t = chip.sublayers![0] as! TextLayer
                let attr = NSAttributedString(
                    string: cand.hint,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1),
                        .paragraphStyle: NodeLayer.centered,
                    ])
                t.attributed = attr
                t.contentsScale = textScale
                let w = max(18, ceil(attr.size().width) + 8)
                chip.bounds = CGRect(x: 0, y: 0, width: w, height: 18)
                t.frame = CGRect(x: 0, y: 2, width: w, height: 14)
            } else if let chip = hintLayers[cand.node] {
                chip.removeFromSuperlayer()
                hintLayers[cand.node] = nil
            }
        }
        preview.strokeColor = theme.amber.cgColor
        layoutConnect(c, frame: frame)
    }

    private func layoutConnect(_ c: ConnectState?, frame: (NodeID) -> CGRect?) {
        guard let c else { return }
        for (id, chip) in hintLayers {
            if let r = frame(id) { chip.position = CGPoint(x: r.minX + 2, y: r.minY + 2) }
        }
        if let t = c.target, let a = frame(c.source), let b = frame(t.node) {
            let s = RelationshipGeometry.clip(CGPoint(x: a.midX, y: a.midY), a, toward: CGPoint(x: b.midX, y: b.midY))
            let e = RelationshipGeometry.clip(CGPoint(x: b.midX, y: b.midY), b, toward: CGPoint(x: a.midX, y: a.midY))
            let p = CGMutablePath()
            p.move(to: s)
            p.addLine(to: e)
            if let (cap, _) = RelationshipGeometry.cap(
                "filled-arrow", at: e, angle: atan2(e.y - s.y, e.x - s.x), width: 2) as (CGPath?, Bool)?, let cap
            {
                p.addPath(cap)
            }
            preview.path = p
            preview.isHidden = false
        } else {
            preview.isHidden = true
        }
    }

    /// Moves a zone's frame while it is dragged (members move with their springs).
    func offsetZone(_ id: String, by d: CGSize) {
        zoneLayers[id]?.setAffineTransform(CGAffineTransform(translationX: d.width, y: d.height))
    }

    // MARK: Smart guides

    func showGuides(_ lines: [(CGPoint, CGPoint)], label: String?, at point: CGPoint?) {
        let p = CGMutablePath()
        for (a, b) in lines {
            p.move(to: a)
            p.addLine(to: b)
        }
        guides.path = p
        guides.isHidden = lines.isEmpty
        if let label, let point {
            guideLabel.isHidden = false
            let attr = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
                    .paragraphStyle: NodeLayer.centered,
                ])
            guideLabel.attributed = attr
            guideLabel.backgroundColor = RGBA(hex: "#E2408C").cgColor
            guideLabel.cornerRadius = 4
            guideLabel.contentsScale = textScale
            let w = ceil(attr.size().width) + 10
            guideLabel.frame = CGRect(x: point.x - w / 2, y: point.y - 8, width: w, height: 16)
        } else {
            guideLabel.isHidden = true
        }
    }

    // MARK: Hit testing and editor anchors

    func hitTest(_ p: CGPoint) -> ElementRef? {
        for (id, l) in relLayers {
            if l.labelRect.contains(p) || (l.hitPath?.contains(p) ?? false) { return .relationship(id) }
        }
        for s in scene.summaries where s.bracket.insetBy(dx: -8, dy: -4).contains(p) { return .summary(s.summary.id) }
        for z in scene.zones.reversed()
        where CGRect(x: z.rect.minX, y: z.rect.minY, width: z.rect.width, height: 34).contains(p) {
            return .zone(z.zone.id)
        }
        for b in scene.boundaries.reversed() where b.rect.contains(p) {
            let inner = b.rect.insetBy(dx: 10, dy: 10)
            let titleBar = CGRect(x: b.rect.minX, y: b.rect.minY, width: b.rect.width, height: 26)
            if !inner.contains(p) || titleBar.contains(p) { return .boundary(b.boundary.id) }
        }
        for z in scene.zones.reversed() where z.rect.contains(p) { return .zone(z.zone.id) }
        return nil
    }

    /// Where the label / title editor sits for an element (world coordinates).
    func editorRect(for ref: ElementRef) -> CGRect? {
        switch ref {
        case .relationship(let id):
            guard let l = relLayers[id] else { return nil }
            return l.labelRect.insetBy(dx: -20, dy: 0)
        case .zone(let id):
            guard let z = scene.zones.first(where: { $0.zone.id == id }) else { return nil }
            return CGRect(x: z.rect.minX + 26, y: z.rect.minY + 10, width: max(140, z.rect.width - 60), height: 20)
        case .boundary(let id):
            guard let b = scene.boundaries.first(where: { $0.boundary.id == id }) else { return nil }
            return CGRect(x: b.rect.minX + 12, y: b.rect.minY + 4, width: max(140, b.rect.width - 24), height: 18)
        default:
            return nil
        }
    }
}
