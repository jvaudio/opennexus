import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusScene
@testable import NexusTheme

/// Writes what every drawing path produces (offscreen canvases, image exports, SVG,
/// viewer bundles, slides, Gantt charts) for the built-in starters, the guides' maps, the
/// format fixtures and the style goldens' maps, as raw pixels and text. Run on two
/// commits and compare the folders (`scripts/compare-renders.py`) to prove a refactor
/// changed nothing (M47a). Only runs when `OPENNEXUS_RENDER_DUMP` names a folder.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENNEXUS_RENDER_DUMP"] != nil))
struct RenderDump {
    nonisolated static let out = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["OPENNEXUS_RENDER_DUMP"] ?? "/")

    static func write(_ name: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? data.write(to: out.appendingPathComponent(name))
    }

    /// The image's pixels as 8-bit sRGB RGBA, with its size in the first 8 bytes.
    static func pixels(_ img: CGImage) -> Data {
        let w = img.width
        let h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var d = Data()
        withUnsafeBytes(of: UInt32(w).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(h).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: bytes)
        return d
    }

    /// Each page of a PDF at 1×.
    static func pdf(_ name: String, _ data: Data) {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else { return }
        for i in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let ctx = CGContext(
                data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: box.size))
            ctx.drawPDFPage(page)
            if let img = ctx.makeImage() { write("\(name)-p\(i).rgba", pixels(img)) }
        }
    }

    static var documents: [(String, DocumentModel)] {
        var docs: [(String, DocumentModel)] = []
        for s in StarterLibrary.all { docs.append(("starter-\(s.id)", s.document())) }
        for r in Role.allCases { docs.append(("tour-\(r.rawValue)", StarterLibrary.tourDocument(r))) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NexusFormatTests/Fixtures")
        for name in ["FutureKeys", "LaunchPlan", "Review", "TaskPlan"] {
            let url = fixtures.appendingPathComponent("\(name).nexus")
            if let w = try? FileWrapper(url: url), let m = try? NexusPackage.read(from: w) {
                docs.append(("fixture-\(name)", m))
            }
        }
        return docs
    }

    @Test func dump() throws {
        let today = TaskDate("2026-10-29")
        for (name, doc) in Self.documents {
            for (i, id) in doc.canvasOrder.enumerated() {
                guard let c = doc.canvases[id] else { continue }
                let tag = "\(name)-c\(i)"
                var o = ImageExporter.Options()
                o.scale = 1
                if let img = ImageExporter.image(doc, canvas: c.id, o) {
                    Self.write("\(tag)-image.rgba", Self.pixels(img))
                }
                Self.write("\(tag).svg", Data(SVGExporter.export(doc, canvas: c.id, o).utf8))
                let slides = SlideExporter.renderSlides(
                    doc, canvas: c.id, size: CGSize(width: 960, height: 540), prefs: .isolated(), today: today)
                for (k, s) in slides.enumerated() { Self.write("\(tag)-slide\(k).rgba", Self.pixels(s)) }
                if let g = HeadlessExport.data(doc, canvas: c.id, format: .ganttPNG),
                    let src = CGImageSourceCreateWithData(g as CFData, nil),
                    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
                {
                    Self.write("\(tag)-gantt.rgba", Self.pixels(img))
                }
                for (k, f) in [ExportFormat.pdf, .ganttPDF].enumerated() {
                    if let d = HeadlessExport.data(doc, canvas: c.id, format: f) { Self.pdf("\(tag)-pdf\(k)", d) }
                }
                if i == 0 {
                    for content in [PrintLayout.Content.canvas, .outline] {
                        var po = PrintLayout.Options()
                        po.content = content
                        po.date = Date(timeIntervalSince1970: 1_793_000_000)
                        po.title = "Print"
                        Self.pdf("\(tag)-print-\(content.rawValue)", PrintLayout.pdf(doc, canvas: c.id, po).data)
                    }
                }
            }
            if let html = HeadlessExport.data(doc, format: .html) { Self.write("\(name).html", html) }
        }
        for (theme, style) in StyleGoldenTests.cases {
            let h = CanvasHarness(model: nodeStyleSampleDocument(theme: theme, style: style), width: 560, height: 340)
            h.host.canvasView.fitToWindow()
            h.controller.select(h.canvas.nodes[h.canvas.root]!.children[1])
            let rep = try #require(h.renderOffscreen(scale: 2))
            Self.write("ns-\(theme)-\(style).rgba", Self.pixels(try #require(rep.cgImage)))
        }
    }
}
