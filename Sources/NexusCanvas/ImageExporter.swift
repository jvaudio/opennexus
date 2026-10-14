import AppKit
import NexusCore
import NexusTheme
import UniformTypeIdentifiers

/// Visual exports (artboards 30 and 51): PNG, JPEG, PDF (single page or tiled for print)
/// and the scope helpers. Everything renders offscreen through the same layers as the
/// canvas, so exports look exactly like the map. No watermark, ever.
@MainActor
public enum ImageExporter {
    public enum Scope: String, CaseIterable, Sendable {
        case canvas, selection, branch
        public var title: String { rawValue.capitalized }
    }

    public enum Background: String, CaseIterable, Sendable {
        case theme, white, transparent
        public var title: String { rawValue.capitalized }
    }

    public struct Options: Equatable, Sendable {
        public var scope: Scope = .canvas
        /// Topics for selection scope; the branch top for branch scope.
        public var selection: [NodeID] = []
        public var scale: Double = 2
        public var background: Background = .theme
        public var padding: Double = 48
        /// Render with another theme (nil keeps the canvas theme).
        public var theme: String?
        public init() {}
    }

    /// Largest bitmap edge (Core Graphics and most viewers cope; beyond this, use PDF or SVG).
    public static let maxPixels = 16_384

    /// The topics a scope draws (nil: everything).
    public static func keep(_ c: Canvas, _ o: Options) -> Set<NodeID>? {
        switch o.scope {
        case .canvas: return nil
        case .branch:
            guard let top = o.selection.first, c.nodes[top] != nil else { return nil }
            return Set(c.subtree(top))
        case .selection:
            let ids = o.selection.filter { c.nodes[$0] != nil }
            return ids.isEmpty ? nil : Set(ids)
        }
    }

    /// An offscreen controller showing `canvas` with the export's scope and theme.
    static func controller(_ model: DocumentModel, canvas id: CanvasID, _ o: Options) -> CanvasController {
        var m = model
        if let t = o.theme { m.canvases[id]?.style.theme = t }
        let controller = CanvasController(store: DocumentStore(model: m))
        controller.switchCanvas(to: id)
        controller.isolate = keep(controller.canvas, o)
        controller.rebuildScene()
        return controller
    }

    /// The content rectangle (world points) including padding.
    public static func contentRect(_ model: DocumentModel, canvas id: CanvasID, _ o: Options) -> CGRect {
        let b = controller(model, canvas: id, o).scene.bounds
        return b.isNull
            ? CGRect(x: 0, y: 0, width: 200, height: 120) : b.insetBy(dx: -o.padding, dy: -o.padding).integral
    }

    /// Pixel size an export will have.
    public static func pixelSize(_ model: DocumentModel, canvas id: CanvasID, _ o: Options) -> CGSize {
        let r = contentRect(model, canvas: id, o)
        let k = effectiveScale(r, o.scale)
        return CGSize(width: (r.width * k).rounded(), height: (r.height * k).rounded())
    }

    static func effectiveScale(_ r: CGRect, _ scale: Double) -> CGFloat {
        let s = CGFloat(min(max(scale, 0.1), 8))
        return min(s, CGFloat(maxPixels) / max(r.width, r.height, 1))
    }

    /// Renders the export as a bitmap. `crop` (world points) overrides the content rect,
    /// as Map Shot does.
    public static func image(_ model: DocumentModel, canvas id: CanvasID, _ o: Options, crop: CGRect? = nil) -> CGImage?
    {
        let controller = controller(model, canvas: id, o)
        let b = controller.scene.bounds
        let rect =
            crop
            ?? (b.isNull
                ? CGRect(x: 0, y: 0, width: 200, height: 120) : b.insetBy(dx: -o.padding, dy: -o.padding).integral)
        let k = effectiveScale(rect, o.scale)
        let size = CGSize(width: (rect.width * k).rounded(), height: (rect.height * k).rounded())
        guard size.width >= 1, size.height >= 1 else { return nil }
        let view = CanvasView(controller: controller)
        view.reduceMotionOverride = true
        view.exportMode = true
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        // The view lays itself out at zoom k, so text rasterises at the export's resolution.
        view.setCamera(Camera(offset: CGPoint(x: -rect.minX * k, y: -rect.minY * k), zoom: k), animated: false)
        view.layoutSubtreeIfNeeded()
        let bg: RGBA? =
            switch o.background {
            case .theme: controller.scene.canvasColor
            case .white: RGBA(r: 1, g: 1, b: 1, a: 1)
            case .transparent: nil
            }
        let img = draw(view, size: size, background: bg)
        window.contentView = nil
        return img
    }

    static func draw(_ view: CanvasView, size: CGSize, background: RGBA?) -> CGImage? {
        guard
            let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let root = view.sceneLayer
        root.isGeometryFlipped = true
        root.layoutIfNeeded()
        // The background is ours to paint (or leave transparent).
        let rootBackground = root.backgroundColor
        root.backgroundColor = nil
        defer { root.backgroundColor = rootBackground }
        func redraw(_ l: CALayer) {
            if l is TextLayer || l is DecorLayer {
                l.setNeedsDisplay()
                l.displayIfNeeded()
            }
            l.sublayers?.forEach(redraw)
        }
        redraw(root)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        root.render(in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: Encoders

    public static func png(_ img: CGImage) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// JPEG has no alpha: transparent areas become `matte`.
    public static func jpeg(_ img: CGImage, quality: Double, matte: RGBA = RGBA(r: 1, g: 1, b: 1, a: 1)) -> Data {
        let w = img.width
        let h = img.height
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return Data() }
        ctx.setFillColor(matte.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(
            dest, flat, [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.05), 1)] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    // MARK: Split by main branch (artboard 51)

    /// One PNG per first-level branch, named `01-positioning.png`, with the same options.
    public static func splitByBranch(_ model: DocumentModel, canvas id: CanvasID, _ o: Options) -> [(
        name: String, png: Data
    )] {
        guard let c = model.canvases[id] else { return [] }
        var out: [(String, Data)] = []
        for (i, b) in (c.nodes[c.root]?.children ?? []).enumerated() {
            var bo = o
            bo.scope = .branch
            bo.selection = [b]
            guard let img = image(model, canvas: id, bo) else { continue }
            out.append((String(format: "%02d-%@.png", i + 1, slug(c.nodes[b]?.text ?? "branch")), png(img)))
        }
        return out
    }

    public static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let parts = folded.split { !$0.isLetter && !$0.isNumber }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "branch" : String(joined.prefix(48))
    }
}

// MARK: PDF and print (artboard 50)

@MainActor
public enum PrintLayout {
    public enum Content: String, CaseIterable, Sendable {
        case canvas, branch, outline
        public var title: String { rawValue.capitalized }
    }

    public enum Paper: String, CaseIterable, Sendable {
        case a4 = "A4", letter = "Letter", a3 = "A3", legal = "Legal"
        public var size: CGSize {
            switch self {
            case .a4: CGSize(width: 595, height: 842)
            case .letter: CGSize(width: 612, height: 792)
            case .a3: CGSize(width: 842, height: 1191)
            case .legal: CGSize(width: 612, height: 1008)
            }
        }
    }

    public struct Options: Equatable, Sendable {
        public var content: Content = .canvas
        public var branch: NodeID?
        public var paper: Paper = .a4
        public var landscape = true
        /// Fit the map on one page, or print at actual size.
        public var fitPage = false
        public var tile = true
        public var background = false
        public var notesAppendix = true
        public var header = true
        public var title = ""
        public var date = Date()
        public init() {}

        public var pageSize: CGSize {
            let s = paper.size
            return landscape ? CGSize(width: s.height, height: s.width) : s
        }
    }

    static let margin: CGFloat = 36
    static let headerHeight: CGFloat = 22

    static func printable(_ o: Options) -> CGRect {
        let p = o.pageSize
        let top = margin + (o.header ? headerHeight : 0)
        return CGRect(x: margin, y: margin, width: p.width - margin * 2, height: p.height - margin - top)
    }

    /// Pages across × down for the map at actual size.
    public static func grid(content: CGSize, _ o: Options) -> (cols: Int, rows: Int) {
        if o.fitPage || !o.tile { return (1, 1) }
        let r = printable(o)
        return (
            max(1, Int((content.width / r.width).rounded(.up))), max(1, Int((content.height / r.height).rounded(.up)))
        )
    }

    /// The print document as PDF: map pages (fit, single or tiled with cut marks), an
    /// outline for Outline content, and the notes appendix.
    public static func pdf(_ model: DocumentModel, canvas id: CanvasID, _ o: Options) -> (data: Data, pages: Int) {
        guard let canvas = model.canvases[id] else { return (Data(), 0) }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: o.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return (Data(), 0) }
        var pages = 0
        let title =
            o.title.isEmpty ? (canvas.title.isEmpty ? canvas.nodes[canvas.root]?.text ?? "" : canvas.title) : o.title
        let dateText = o.date.formatted(date: .abbreviated, time: .omitted)

        func begin(_ n: Int, of total: Int) {
            ctx.beginPDFPage(nil)
            pages += 1
            if o.header {
                text(
                    "\(title) · \(dateText)", at: CGPoint(x: margin, y: o.pageSize.height - margin - 12), size: 9,
                    color: .secondaryLabelColor)
                if total > 1 {
                    text(
                        "\(n) / \(total)",
                        at: CGPoint(x: o.pageSize.width - margin - 40, y: o.pageSize.height - margin - 12), size: 9,
                        color: .secondaryLabelColor)
                }
            }
        }
        func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, bold: Bool = false, width: CGFloat? = nil)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let attr = NSAttributedString(
                string: s,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                    .foregroundColor: color,
                ])
            if let width {
                attr.draw(with: CGRect(x: p.x, y: p.y, width: width, height: 1000), options: [.usesLineFragmentOrigin])
            } else {
                attr.draw(at: p)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if o.content == .outline {
            var lines: [(String, Int, String?)] = []
            canvas.walk { _, n, d in lines.append((n.text, d, n.note?.text)) }
            outlinePages(lines, title: title, begin: begin, text: text, o: o, ctx: ctx)
        } else {
            var io = ImageExporter.Options()
            io.padding = 12
            io.background = o.background ? .theme : .transparent
            if o.content == .branch, let b = o.branch {
                io.scope = .branch
                io.selection = [b]
            }
            let rect = ImageExporter.contentRect(model, canvas: id, io)
            let area = printable(o)
            // Rasterise at 3× of print size (300 dpi equivalent at actual size).
            let fit = min(area.width / rect.width, area.height / rect.height, 1)
            let printScale = o.fitPage || !o.tile ? fit : 1
            io.scale = Double(printScale * 3)
            guard let img = ImageExporter.image(model, canvas: id, io) else { return (Data(), 0) }
            let drawn = CGSize(width: rect.width * printScale, height: rect.height * printScale)
            let (cols, rows) = grid(content: drawn, o)
            let total = cols * rows
            for r in 0..<rows {
                for c in 0..<cols {
                    begin(r * cols + c + 1, of: total)
                    ctx.saveGState()
                    ctx.clip(to: area)
                    // Tile (c, r) shows the slice starting at (c·w, r·h) of the map, top first.
                    let x = area.minX - CGFloat(c) * area.width + (total == 1 ? (area.width - drawn.width) / 2 : 0)
                    let yTop =
                        area.maxY + CGFloat(r) * area.height - (total == 1 ? (area.height - drawn.height) / 2 : 0)
                    ctx.interpolationQuality = .high
                    ctx.draw(img, in: CGRect(x: x, y: yTop - drawn.height, width: drawn.width, height: drawn.height))
                    ctx.restoreGState()
                    if total > 1 { cutMarks(ctx, area) }
                    ctx.endPDFPage()
                }
            }
        }
        if o.notesAppendix {
            var notes: [(String, String)] = []
            let parents = canvas.parentMap()
            canvas.walk { id, n, _ in
                guard let t = n.note?.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let path = (canvas.path(to: id, parents: parents).compactMap { canvas.nodes[$0]?.text } + [n.text])
                    .joined(separator: " › ")
                notes.append((path, t))
            }
            if !notes.isEmpty { appendix(notes, begin: begin, text: text, o: o, ctx: ctx) }
        }
        ctx.closePDF()
        return (data as Data, pages)
    }

    static func cutMarks(_ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.gray.cgColor)
        ctx.setLineWidth(0.5)
        let l: CGFloat = 10
        for (x, y) in [(r.minX, r.minY), (r.maxX, r.minY), (r.minX, r.maxY), (r.maxX, r.maxY)] {
            let dx: CGFloat = x == r.minX ? -1 : 1
            let dy: CGFloat = y == r.minY ? -1 : 1
            ctx.move(to: CGPoint(x: x + dx * 3, y: y))
            ctx.addLine(to: CGPoint(x: x + dx * (3 + l), y: y))
            ctx.move(to: CGPoint(x: x, y: y + dy * 3))
            ctx.addLine(to: CGPoint(x: x, y: y + dy * (3 + l)))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func outlinePages(
        _ lines: [(String, Int, String?)], title: String, begin: (Int, Int) -> Void,
        text: (String, CGPoint, CGFloat, NSColor, Bool, CGFloat?) -> Void, o: Options, ctx: CGContext
    ) {
        let area = printable(o)
        var y = area.maxY
        var page = 1
        begin(page, 0)
        for (t, d, note) in lines {
            let size: CGFloat = d == 0 ? 18 : d == 1 ? 13 : 11
            let need = size + 8 + (note == nil ? 0 : 14)
            if y - need < area.minY {
                ctx.endPDFPage()
                page += 1
                begin(page, 0)
                y = area.maxY
            }
            y -= size + 6
            text(t, CGPoint(x: area.minX + CGFloat(d) * 16, y: y), size, .labelColor, d <= 1, nil)
            if let note, !note.isEmpty {
                y -= 13
                text(
                    note.replacingOccurrences(of: "\n", with: " "), CGPoint(x: area.minX + CGFloat(d) * 16 + 8, y: y),
                    9, .secondaryLabelColor, false, nil)
            }
        }
        ctx.endPDFPage()
    }

    static func appendix(
        _ notes: [(String, String)], begin: (Int, Int) -> Void,
        text: (String, CGPoint, CGFloat, NSColor, Bool, CGFloat?) -> Void, o: Options, ctx: CGContext
    ) {
        let area = printable(o)
        begin(0, 0)
        var y = area.maxY - 20
        text("Notes", CGPoint(x: area.minX, y: y), 16, .labelColor, true, nil)
        y -= 12
        for (path, note) in notes {
            let body = NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 10)])
            let h = body.boundingRect(
                with: CGSize(width: area.width, height: 10_000), options: [.usesLineFragmentOrigin]
            ).height
            if y - h - 30 < area.minY {
                ctx.endPDFPage()
                begin(0, 0)
                y = area.maxY
            }
            y -= 16
            text(path, CGPoint(x: area.minX, y: y), 10, .labelColor, true, nil)
            y -= h + 4
            text(note, CGPoint(x: area.minX, y: y), 10, .secondaryLabelColor, false, area.width)
            y -= 8
        }
        ctx.endPDFPage()
    }

    /// A single-page vector-framed PDF of the export (Export sheet › PDF).
    public static func singlePage(_ model: DocumentModel, canvas id: CanvasID, _ io: ImageExporter.Options) -> Data {
        let rect = ImageExporter.contentRect(model, canvas: id, io)
        var x = io
        x.scale = max(io.scale, 2)
        guard let img = ImageExporter.image(model, canvas: id, x) else { return Data() }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: rect.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.draw(img, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
