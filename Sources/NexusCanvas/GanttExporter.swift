import CoreGraphics
import Foundation
import ImageIO
import NexusCore
import NexusScene

/// Gantt exports: PNG and JPEG bitmaps, and vector PDF pages with live text (D147).
public enum GanttExporter {
    public struct Options: Equatable, Sendable {
        public var scale: Double = 2
        /// Only the selected rows' branches.
        public var selectionOnly = false
        /// PDF: one page, or tiled over A4 / Letter landscape pages.
        public var paper = "fit"
        public init() {}
    }

    /// `canvas` is the (possibly masked) copy being exported.
    @MainActor
    static func renderer(_ c: CanvasController, _ canvas: Canvas, _ o: Options) -> GanttRenderer {
        var only: Set<NodeID>?
        if o.selectionOnly {
            var keep = Set<NodeID>()
            for id in c.selection.nodes + [c.selection.primary] {
                canvas.walk(from: id) { d, _, _ in keep.insert(d) }
                var cur = id
                while let p = canvas.parent(of: cur) {
                    keep.insert(p)
                    cur = p
                }
            }
            only = keep
        }
        var r = GanttRenderer(
            layout: GanttLayout(canvas: canvas, collapsed: [], scale: c.ganttScale, today: c.todayDate, only: only))
        r.colors = c.ganttColors
        r.title = canvas.title.isEmpty ? canvas.nodes[canvas.root]?.text : canvas.title
        return r
    }

    /// The bitmap's pixel size.
    @MainActor
    public static func pixelSize(_ c: CanvasController, _ canvas: Canvas, _ o: Options) -> CGSize {
        let s = renderer(c, canvas, o).layout.size
        let k = min(o.scale, 16_384 / max(s.width, s.height, 1))
        return CGSize(width: (s.width * k).rounded(), height: ((s.height - GanttLayout.bottomPad + 8) * k).rounded())
    }

    @MainActor
    public static func image(_ c: CanvasController, _ canvas: Canvas, _ o: Options) -> CGImage? {
        let r = renderer(c, canvas, o)
        let px = pixelSize(c, canvas, o)
        let k = px.width / max(r.layout.size.width, 1)
        guard px.width >= 1, px.height >= 1,
            let ctx = CGContext(
                data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: px.height)
        ctx.scaleBy(x: k, y: -k)
        r.draw(in: ctx, dirty: CGRect(origin: .zero, size: r.layout.size))
        return ctx.makeImage()
    }

    @MainActor
    public static func data(_ c: CanvasController, _ canvas: Canvas, _ o: Options, jpeg: Double? = nil) -> Data? {
        guard let img = image(c, canvas, o) else { return nil }
        // The resolution says the scale (144 dpi at 2×), as `NSBitmapImageRep` wrote it.
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * o.scale, kCGImagePropertyDPIHeight: 72 * o.scale,
        ]
        if let jpeg { props[kCGImageDestinationLossyCompressionQuality] = jpeg }
        let out = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                out, (jpeg == nil ? "public.png" : "public.jpeg") as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Paper sizes in points (landscape).
    static func paper(_ id: String) -> CGSize? {
        switch id {
        case "a4": CGSize(width: 842, height: 595)
        case "letter": CGSize(width: 792, height: 612)
        default: nil
        }
    }

    /// Vector PDF: fitted on one page, or tiled with the table repeated on every page.
    @MainActor
    public static func pdf(_ c: CanvasController, _ canvas: Canvas, _ o: Options) -> Data {
        let r = renderer(c, canvas, o)
        let full = r.layout.size
        let content = CGSize(width: full.width, height: full.height - GanttLayout.bottomPad + 8)
        let data = NSMutableData()
        let margin: CGFloat = 24
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(
            origin: .zero,
            size: paper(o.paper) ?? CGSize(width: content.width + margin * 2, height: content.height + margin * 2))
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        // Pages: columns of timeline after the table, rows of tasks under the header.
        let usable = CGSize(width: box.width - margin * 2, height: box.height - margin * 2)
        let fit = paper(o.paper) == nil
        let k: CGFloat = fit ? 1 : min(1, usable.height / max(content.height, 1), 1)
        let sliceW = fit ? content.width - r.layout.tableWidth : max(80, usable.width / k - r.layout.tableWidth)
        let sliceH =
            fit
            ? content.height - GanttLayout.headerHeight
            : max(GanttLayout.rowHeight, usable.height / k - GanttLayout.headerHeight)
        let timeline = content.width - r.layout.tableWidth
        let body = content.height - GanttLayout.headerHeight
        var y0: CGFloat = 0
        repeat {
            var x0: CGFloat = 0
            repeat {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.translateBy(x: margin, y: box.height - margin)
                ctx.scaleBy(x: k, y: -k)
                // Shift the slice under the pinned table and header.
                let viewport = CGRect(
                    x: r.layout.tableWidth + x0, y: GanttLayout.headerHeight + y0, width: sliceW, height: sliceH)
                ctx.saveGState()
                ctx.clip(
                    to: CGRect(
                        x: 0, y: 0, width: r.layout.tableWidth + sliceW, height: GanttLayout.headerHeight + sliceH))
                ctx.translateBy(x: -x0, y: -y0)
                r.draw(
                    in: ctx,
                    dirty: viewport.union(
                        CGRect(x: x0, y: y0, width: r.layout.tableWidth, height: GanttLayout.headerHeight)),
                    pin: CGPoint(x: x0, y: y0))
                ctx.restoreGState()
                ctx.restoreGState()
                ctx.endPDFPage()
                x0 += sliceW
            } while x0 < timeline - 0.5
            y0 += sliceH
        } while y0 < body - 0.5
        ctx.closePDF()
        return data as Data
    }
}

@MainActor
extension CanvasController {
    /// Bar colours: each task's branch colour from the map.
    public var ganttColors: [NodeID: CGColor] {
        var out: [NodeID: CGColor] = [:]
        let c = canvas
        for r in taskSchedule.rows {
            var cur = r.id
            while scene.nodes[cur] == nil, let p = c.parent(of: cur) { cur = p }
            if cur == c.root, r.id != c.root, let main = c.path(to: r.id).dropFirst().first { cur = main }
            if let b = scene.nodes[cur]?.branchColor {
                out[r.id] = CGColor(srgbRed: b.r, green: b.g, blue: b.b, alpha: 1)
            }
        }
        return out
    }
}
