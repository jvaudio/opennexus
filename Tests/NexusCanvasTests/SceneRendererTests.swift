import AppKit
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusScene

/// The layer tree with no view (M47a A4): what exports draw is what the canvas draws.
@MainActor
struct SceneRendererTests {
    /// A renderer set up as the canvas's own: same scene, state, size, camera and scale.
    static func viewFree(_ h: CanvasHarness) -> SceneRenderer {
        let view = h.host.canvasView
        let r = SceneRenderer()
        r.backingScale = view.renderer.backingScale
        r.viewSize = view.bounds.size
        r.asset = { [weak c = h.controller] in c?.store.model.assets[$0] }
        r.update(h.controller.scene, state: h.controller.renderState(reduceMotion: true), animated: false)
        r.place(view.camera)
        return r
    }

    /// The renderer's pixels in the harness bitmap's format, row by row.
    static func render(_ r: SceneRenderer, like rep: NSBitmapImageRep) throws -> [[UInt8]] {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = try #require(rep.colorSpace.cgColorSpace)
        let ctx = try #require(
            CGContext(
                data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: CGFloat(w) / r.viewSize.width, y: CGFloat(h) / r.viewSize.height)
        r.render(in: ctx)
        return (0..<h).map { Array(bytes[$0 * w * 4..<($0 + 1) * w * 4]) }
    }

    static func rows(_ rep: NSBitmapImageRep) throws -> [[UInt8]] {
        let data = try #require(rep.bitmapData)
        let w = rep.pixelsWide * 4
        return (0..<rep.pixelsHigh).map { Array(UnsafeBufferPointer(start: data + $0 * rep.bytesPerRow, count: w)) }
    }

    @Test func viewFreeRenderMatchesTheCanvas() throws {
        #expect(StarterLibrary.templates.count == 25)
        for s in StarterLibrary.templates {
            let h = CanvasHarness(model: s.document(), width: 1000, height: 680)
            h.host.canvasView.fitToWindow()
            if let first = h.canvas.nodes[h.canvas.root]?.children.first { h.controller.select(first) }
            let rep = try #require(h.renderOffscreen(scale: 1))
            let canvas = try Self.rows(rep)
            let free = try Self.render(Self.viewFree(h), like: rep)
            let differing = zip(canvas, free).filter { $0 != $1 }.count
            #expect(differing == 0, "\(s.id): \(differing) rows differ")
        }
    }

    @Test func viewFreeRenderMatchesAtTwiceTheScale() throws {
        let s = try #require(StarterLibrary.starter("threat"))
        let h = CanvasHarness(model: s.document(), width: 700, height: 500)
        h.host.canvasView.fitToWindow()
        let rep = try #require(h.renderOffscreen(scale: 2))
        #expect(rep.pixelsWide == 1400)
        #expect(try Self.rows(rep) == Self.render(Self.viewFree(h), like: rep))
    }
}
