import AppKit
import NexusCore
import NexusLayout
import NexusTheme

/// Draws structure decor (braces, matrix and tree-table cells, swimlane bands, sequence
/// lifelines and activation bars) from live node frames, so it follows the spring
/// animation like branch lines do.
@MainActor
final class DecorRenderer {
    /// Swimlane bands, below everything.
    let bandsLayer = CALayer()
    /// Cells, braces, lifelines: above boundaries, below branch lines.
    let layer = CALayer()
    private var shapes: [CAShapeLayer] = []
    private var bandShapes: [CAShapeLayer] = []
    private var bandTitles: [TextLayer] = []
    private var decor: [SceneDecor] = []
    var textScale: CGFloat = 2

    init() {
        layer.actions = NodeLayer.noActions
        bandsLayer.actions = NodeLayer.noActions
    }

    func update(scene: Scene, frame: (NodeID) -> CGRect?) {
        decor = scene.decor
        let bands = decor.filter { if case .band = $0 { true } else { false } }
        let rest = decor.filter { if case .band = $0 { false } else { true } }
        sync(&shapes, count: rest.count, in: layer)
        sync(&bandShapes, count: bands.count, in: bandsLayer)
        while bandTitles.count < bands.count {
            let t = TextLayer()
            t.actions = NodeLayer.noActions
            bandsLayer.addSublayer(t)
            bandTitles.append(t)
        }
        while bandTitles.count > bands.count { bandTitles.removeLast().removeFromSuperlayer() }
        for (i, d) in bands.enumerated() {
            guard case .band(let rect, let title, let color) = d else { continue }
            let s = bandShapes[i]
            s.path = CGPath(rect: rect, transform: nil)
            s.fillColor = color.alpha(i % 2 == 0 ? 0.05 : 0.08).cgColor
            s.strokeColor = color.alpha(0.25).cgColor
            s.lineWidth = 1
            let t = bandTitles[i]
            t.attributed = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: NSColor(cgColor: color.cgColor) ?? .secondaryLabelColor, .kern: 1.2,
                ])
            t.contentsScale = textScale
            t.frame = CGRect(x: rect.minX + 16, y: rect.minY + 12, width: 260, height: 16)
            t.setNeedsDisplay()
        }
        for (i, d) in rest.enumerated() { style(shapes[i], d, scene: scene) }
        updateGeometry(frame: frame)
    }

    func updateGeometry(frame: (NodeID) -> CGRect?) {
        let rest = decor.filter { if case .band = $0 { false } else { true } }
        for (i, d) in rest.enumerated() where i < shapes.count {
            shapes[i].path = path(d, frame: frame)
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

    private func style(_ s: CAShapeLayer, _ d: SceneDecor, scene: Scene) {
        s.lineDashPattern = nil
        s.lineCap = .round
        s.lineJoin = .round
        switch d {
        case .brace(_, _, let color, let width):
            s.fillColor = nil
            s.strokeColor = color.cgColor
            s.lineWidth = width
        case .cell(_, _, let kind, let color):
            switch kind {
            case .matrixCell:
                s.fillColor = scene.theme.isDark ? color.alpha(0.08).cgColor : RGBA.white.alpha(0.9).cgColor
                s.strokeColor = color.alpha(0.35).cgColor
                s.lineWidth = 1
            case .tableRow:
                s.fillColor = color.alpha(0.05).cgColor
                s.strokeColor = scene.theme.ink2.alpha(0.25).cgColor
                s.lineWidth = 1
            case .tableCell:
                s.fillColor = nil
                s.strokeColor = scene.theme.ink2.alpha(0.2).cgColor
                s.lineWidth = 1
            }
        case .lifeline(_, _, let color):
            s.fillColor = nil
            s.strokeColor = color.alpha(0.6).cgColor
            s.lineWidth = 1.2
            s.lineDashPattern = [5, 5]
        case .activation(_, _, _, let color):
            s.fillColor = color.alpha(0.14).cgColor
            s.strokeColor = color.cgColor
            s.lineWidth = 1.2
        case .band:
            break
        }
    }

    private func path(_ d: SceneDecor, frame: (NodeID) -> CGRect?) -> CGPath? {
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
            case .tableRow:
                let m = CGMutablePath()
                m.addRect(r)
                m.addRect(CGRect(x: r.minX, y: r.minY, width: 4, height: r.height))
                return m
            case .tableCell: return CGPath(rect: r, transform: nil)
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
}
