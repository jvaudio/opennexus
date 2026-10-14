import AppKit
import NexusCore

/// Map Shot's frame on the canvas (artboard 51): the rest dims, the frame has eight
/// handles and a size badge. Drag inside to move, drag a handle to resize (⇧ or an
/// aspect preset keeps the ratio). The keyboard does the same from the canvas.
@MainActor
final class MapShotFrameView: NSView {
    weak var canvas: CanvasView?
    var state: MapShotState?
    private var drag: (handle: Int?, start: CGPoint, rect: CGRect)?

    override var isFlipped: Bool { true }

    var viewRect: CGRect {
        guard let s = state, let c = canvas else { return .zero }
        return c.camera.toView(s.rect)
    }

    func handles(_ r: CGRect) -> [CGRect] {
        let pts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
        return pts.map { CGRect(x: $0.x - 5, y: $0.y - 5, width: 10, height: 10) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = state else { return }
        let r = viewRect
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: r).reversed)
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let accent = NSColor(red: 0.345, green: 0.314, blue: 0.925, alpha: 1)
        accent.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()
        for h in handles(r) {
            NSColor.white.setFill()
            NSBezierPath(rect: h).fill()
            accent.setStroke()
            NSBezierPath(rect: h).stroke()
        }
        let px = "\(Int(s.rect.width)) × \(Int(s.rect.height)) @\(Int(s.scale))× · \(s.aspect.rawValue)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let size = (px as NSString).size(withAttributes: attrs)
        let badge = CGRect(x: r.minX, y: r.minY - size.height - 14, width: size.width + 16, height: size.height + 8)
        accent.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        (px as NSString).draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 4), withAttributes: attrs)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let r = viewRect
        if let i = handles(r).firstIndex(where: { $0.insetBy(dx: -4, dy: -4).contains(p) }) {
            drag = (i, p, state?.rect ?? .zero)
        } else if r.contains(p) {
            drag = (nil, p, state?.rect ?? .zero)
        } else {
            drag = nil
        }
        window?.makeFirstResponder(canvas)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag, var s = state, let c = canvas else { return }
        let p = convert(e.locationInWindow, from: nil)
        let z = c.camera.zoom
        let dx = (p.x - d.start.x) / z
        let dy = (p.y - d.start.y) / z
        var r = d.rect
        if let h = d.handle {
            // 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            if [0, 6, 7].contains(h) { minX += dx }
            if [2, 3, 4].contains(h) { maxX += dx }
            if [0, 1, 2].contains(h) { minY += dy }
            if [4, 5, 6].contains(h) { maxY += dy }
            r = CGRect(
                x: min(minX, maxX - 40), y: min(minY, maxY - 30), width: max(40, maxX - minX),
                height: max(30, maxY - minY))
            let ratio =
                s.aspect.ratio ?? (e.modifierFlags.contains(.shift) ? d.rect.width / max(d.rect.height, 1) : nil)
            if let k = ratio {
                if [1, 5].contains(h) { r.size.width = r.height * k } else { r.size.height = r.width / k }
                if [0, 1, 2].contains(h) { r.origin.y = d.rect.maxY - r.height }
                if [0, 6, 7].contains(h) { r.origin.x = d.rect.maxX - r.width }
            } else if s.aspect != .free {
                s.aspect = .free
            }
        } else {
            r = r.offsetBy(dx: dx, dy: dy)
        }
        s.rect = r.integral
        c.controller.setMapShot(s)
    }

    override func mouseUp(with e: NSEvent) { drag = nil }

    override func resetCursorRects() {
        let r = viewRect
        addCursorRect(r, cursor: .openHand)
        for h in handles(r) { addCursorRect(h.insetBy(dx: -4, dy: -4), cursor: .crosshair) }
    }
}
