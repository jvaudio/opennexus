import AppKit
import PDFKit
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusScene

/// Defects found while moving drawing off AppKit (M47a), each kept fixed.
@MainActor
struct RenderDefectTests {
    /// Page `i` of a PDF at 1× on white: sRGB RGBA, top row first.
    static func page(_ data: Data, _ i: Int = 0) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let doc = try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
        let page = try #require(doc.page(at: i + 1))
        let box = page.getBoxRect(.mediaBox)
        let w = Int(box.width)
        let h = Int(box.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(
            CGContext(
                data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: box.size))
        ctx.drawPDFPage(page)
        return (bytes, w, h)
    }

    /// The darkest grey level inside `rect` (PDF points, y up) of a rendered page.
    static func darkest(_ p: (bytes: [UInt8], width: Int, height: Int), in rect: CGRect) -> Int {
        var least = 255
        for y in max(0, p.height - Int(rect.maxY.rounded(.up)))..<min(p.height, p.height - Int(rect.minY)) {
            for x in max(0, Int(rect.minX))..<min(p.width, Int(rect.maxX.rounded(.up))) {
                let i = (y * p.width + x) * 4
                least = min(least, (Int(p.bytes[i]) + Int(p.bytes[i + 1]) + Int(p.bytes[i + 2])) / 3)
            }
        }
        return least
    }

    /// `body` with the app in the given appearance, as the Mac's reaches drawing.
    static func appearance<T>(_ name: NSAppearance.Name, _ body: () -> T) -> T {
        let app = NSApplication.shared
        let was = app.appearance
        let look = NSAppearance(named: name)!
        app.appearance = look
        defer { app.appearance = was }
        var result: T?
        look.performAsCurrentDrawingAppearance { result = body() }
        return result!
    }

    static func fixture(_ name: String) throws -> DocumentModel {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NexusFormatTests/Fixtures/\(name).nexus")
        return try NexusPackage.read(from: FileWrapper(url: url))
    }

    /// Printing used the label colours, which are white in Dark Mode: on paper the text
    /// vanished. The appendix drew each note hanging from 1000 pt up, off the page.
    @Test func printTextIsDarkAndOnThePageInDarkMode() throws {
        var m = launchPlanDocument()
        let id = try #require(m.canvases["c1"]!.nodes.first { $0.value.text == "Pricing" }?.key)
        m.canvases["c1"]!.nodes[id]!.note = Note(text: "Keep the free tier generous.")
        var o = PrintLayout.Options()
        o.fitPage = true
        let map = Self.appearance(.darkAqua) { PrintLayout.pdf(m, canvas: "c1", o) }
        let pdf = try #require(PDFDocument(data: map.data))
        #expect(pdf.pageCount == 2)
        let appendix = try #require(pdf.page(at: 1))
        let note = try #require(pdf.findString("Keep the free tier generous.", withOptions: []).first)
        let rect = note.bounds(for: appendix)
        #expect(!rect.isEmpty && appendix.bounds(for: .mediaBox).contains(rect), "\(rect)")
        #expect(Self.darkest(try Self.page(map.data, 1), in: rect) < 140)

        o.content = .outline
        let outline = Self.appearance(.darkAqua) { PrintLayout.pdf(m, canvas: "c1", o) }
        let text = try #require(PDFDocument(data: outline.data))
        let title = try #require(text.findString("Competitor response", withOptions: []).first)
        let titleRect = title.bounds(for: try #require(text.page(at: 0)))
        #expect(Self.darkest(try Self.page(outline.data), in: titleRect) < 100)
    }

    /// The CLI's and Quick Look's exports built the map before choosing the named theme,
    /// so once the process had an `NSApp` they took the Mac's appearance.
    @Test func headlessExportsIgnoreTheAppAppearance() throws {
        let m = try Self.fixture("TaskPlan")
        for format in [ExportFormat.ganttPDF, .pdf] {
            let light = try #require(Self.appearance(.aqua) { HeadlessExport.data(m, format: format) })
            let dark = try #require(Self.appearance(.darkAqua) { HeadlessExport.data(m, format: format) })
            #expect(try Self.page(light).bytes == Self.page(dark).bytes, "\(format)")
        }
    }

    /// Exports drew through a window, so text rasterised at the display's scale (blurry
    /// at 2× on a 1× display). They now rasterise at the export's own scale.
    @Test func exportTextRasterisesAtTheExportScale() throws {
        var o = ImageExporter.Options()
        o.scale = 2
        let controller = ImageExporter.controller(launchPlanDocument(), canvas: "c1", o)
        let r = ImageExporter.renderer(controller, size: CGSize(width: 800, height: 600))
        #expect(r.backingScale == 1)
        r.place(Camera(offset: .zero, zoom: 2))
        #expect(!r.nodeLayers.isEmpty)
        for l in r.nodeLayers.values {
            #expect(l.textScale == 2)
            #expect(l.text.contentsScale == 2 && l.caption.contentsScale == 2)
        }
    }

    /// A topic's text layers kept CALayer's default scale of 1 until the zoom changed
    /// (blurry on Retina at zoom ≤ 1), and its caption never followed the zoom.
    @Test func topicTextStartsAndStaysAtTheTextScale() {
        let l = NodeLayer(id: "n1")
        #expect([l.text, l.lead, l.badgeText, l.decor, l.caption].allSatisfy { $0.contentsScale == l.textScale })
        l.textScale = 3
        #expect([l.text, l.lead, l.badgeText, l.decor, l.caption].allSatisfy { $0.contentsScale == 3 })
    }

    /// The hand-drawn border's wobble was seeded from `hashValue`, which changes every
    /// launch: the same map drew a different border each time.
    @Test func sketchWobbleIsTheSameEveryLaunch() {
        #expect(NodeLayer.wobbleSeed("n1") == 6210)
        #expect(NodeLayer.wobbleSeed("n1") != NodeLayer.wobbleSeed("n2"))
    }
}
