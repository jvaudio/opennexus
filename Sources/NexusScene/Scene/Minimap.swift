import CoreGraphics
import Foundation

/// The minimap's picture of a scene.
public enum Minimap {
    /// The topics as a bitmap in the view's (flipped) coordinates.
    public static func render(_ scene: Scene, k: CGFloat, o: CGPoint, size: CGSize, scale: CGFloat) -> CGImage? {
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
}
