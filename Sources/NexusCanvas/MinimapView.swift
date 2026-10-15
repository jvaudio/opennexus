import AppKit
import NexusCore

/// The minimap (Settings › Appearance › Minimap): every topic in miniature with the
/// visible area outlined. Click or drag to move there. Shows while panning, always, or never.
@MainActor
final class MinimapView: NSView {
    weak var canvas: CanvasView?
    private var hideTimer: Timer?
    static let size = CGSize(width: 190, height: 124)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    /// Called when the camera or the scene changes.
    func refresh(panning: Bool) {
        guard let c = canvas else { return }
        let mode = c.controller.prefs.string("appearance.minimap")
        let big = c.controller.scene.nodes.count > 1
        switch mode {
        case "always": isHidden = !big
        case "never": isHidden = true
        default:
            if panning && big {
                isHidden = false
                hideTimer?.invalidate()
                hideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isHidden = true }
                }
            } else if !panning && hideTimer == nil {
                isHidden = true
            }
        }
        needsDisplay = true
    }

    /// World → minimap transform, from the map's bounds (cached per scene), so it stays
    /// put while the view pans and the topics' bitmap can be reused.
    func mapping() -> (CGFloat, CGPoint, CGRect)? {
        guard let c = canvas else { return nil }
        let rev = c.controller.sceneRevision
        if boundsCache?.0 != rev { boundsCache = (rev, c.controller.scene.bounds) }
        guard var b = boundsCache?.1, !b.isNull else { return nil }
        let view = CGRect(
            origin: c.camera.toWorld(.zero),
            size: CGSize(width: c.bounds.width / c.camera.zoom, height: c.bounds.height / c.camera.zoom))
        b = b.insetBy(dx: -40, dy: -40)
        let inner = bounds.insetBy(dx: 8, dy: 8)
        let k = min(inner.width / b.width, inner.height / b.height)
        let o = CGPoint(x: inner.midX - b.midX * k, y: inner.midY - b.midY * k)
        return (k, o, view)
    }

    private var boundsCache: (Int, CGRect)?

    private var cache: (key: String, image: CGImage?)?

    /// The topics as a bitmap in the view's (flipped) coordinates.
    static func render(_ scene: Scene, k: CGFloat, o: CGPoint, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        guard w > 0, h > 0,
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Flip so y grows downwards, matching the view.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        for n in scene.nodes.values {
            let r = n.frame.rect
            let m = CGRect(
                x: o.x + r.minX * k, y: o.y + r.minY * k, width: max(2, r.width * k), height: max(1.5, r.height * k))
            ctx.setFillColor(n.branchColor.cgColor.copy(alpha: 0.8) ?? n.branchColor.cgColor)
            ctx.addPath(CGPath(roundedRect: m, cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.stroke()
        guard let c = canvas, let (k, o, view) = mapping() else { return }
        // The topics are drawn once per scene and mapping, then reused while panning: a
        // 5,000-topic map would otherwise be redrawn on every scroll step (M10).
        let key = "\(c.controller.sceneRevision)|\(k)|\(o)|\(bounds.size)"
        if cache?.key != key {
            cache = (
                key,
                Self.render(c.controller.scene, k: k, o: o, size: bounds.size, scale: window?.backingScaleFactor ?? 2)
            )
        }
        if let img = cache?.image, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: bounds)
            ctx.restoreGState()
        }
        let v = CGRect(x: o.x + view.minX * k, y: o.y + view.minY * k, width: view.width * k, height: view.height * k)
            .intersection(bounds.insetBy(dx: 2, dy: 2))
        guard !v.isNull else { return }
        let vp = NSBezierPath(roundedRect: v, xRadius: 3, yRadius: 3)
        NSColor(red: 0.345, green: 0.314, blue: 0.925, alpha: 0.12).setFill()
        vp.fill()
        NSColor(red: 0.345, green: 0.314, blue: 0.925, alpha: 1).setStroke()
        vp.lineWidth = 1.5
        vp.stroke()
    }

    override func mouseDown(with e: NSEvent) { jump(e) }
    override func mouseDragged(with e: NSEvent) { jump(e) }

    func jump(_ e: NSEvent) {
        guard let c = canvas, let (k, o, _) = mapping() else { return }
        let p = convert(e.locationInWindow, from: nil)
        let world = CGPoint(x: (p.x - o.x) / k, y: (p.y - o.y) / k)
        var cam = c.camera
        cam.offset = CGPoint(x: c.bounds.midX - world.x * cam.zoom, y: c.bounds.midY - world.y * cam.zoom)
        c.setCamera(cam, animated: false)
    }
}
