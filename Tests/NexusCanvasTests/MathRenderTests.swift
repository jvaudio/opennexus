import CoreGraphics
import Foundation
import NexusCore
import NexusTheme
import Testing

@testable import NexusCanvas
@testable import NexusScene

/// Formulas on the canvas and in exports (M48).
@MainActor
@Suite struct MathRenderTests {
    static let scratch = ProcessInfo.processInfo.environment["NEXUS_MATH_SCRATCH"].map { URL(fileURLWithPath: $0) }

    func mathDocument() -> DocumentModel {
        var d = launchPlanDocument()
        var c = d.canvases["c1"]!
        var undo = UndoStack()
        let root = c.root
        c.edit("Math", undo: &undo) { e in
            let q = try! e.addChild(of: root, text: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")
            e.update(q) { $0.textFormat = "math" }
            _ = try! e.addChild(of: root, text: "Energy $E = mc^2$ costs \\$5")
            _ = try! e.addChild(of: root, text: "Water: $$\\ce{2H2 + O2 -> 2H2O}$$ forms")
            _ = try! e.addChild(of: root, text: "Bad $\\frac{a$ here")
            _ = try! e.addChild(of: root, text: "Prices $5 and $10 stay")
        }
        d.canvases["c1"] = c
        return d
    }

    /// Operators on a PDF page that draw: fills, strokes and images.
    final class PDFOps {
        var fills = 0
        var strokes = 0
        var images = 0
    }

    static func ops(_ data: Data, page: Int = 1) throws -> PDFOps {
        let doc = try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
        let p = try #require(doc.page(at: page))
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "f") { _, i in
            Unmanaged<PDFOps>.fromOpaque(i!).takeUnretainedValue().fills += 1
        }
        CGPDFOperatorTableSetCallback(table, "f*") { _, i in
            Unmanaged<PDFOps>.fromOpaque(i!).takeUnretainedValue().fills += 1
        }
        CGPDFOperatorTableSetCallback(table, "S") { _, i in
            Unmanaged<PDFOps>.fromOpaque(i!).takeUnretainedValue().strokes += 1
        }
        CGPDFOperatorTableSetCallback(table, "Do") { _, i in
            Unmanaged<PDFOps>.fromOpaque(i!).takeUnretainedValue().images += 1
        }
        let ops = PDFOps()
        let stream = CGPDFContentStreamCreateWithPage(p)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(ops).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return ops
    }

    /// A3: a PDF's picture leaves formulas out and draws them over it as paths.
    @Test func pdfDrawsFormulasAsPaths() throws {
        let d = mathDocument()
        let page = try Self.ops(PrintLayout.singlePage(d, canvas: "c1", ImageExporter.Options()))
        #expect(page.images == 1)
        #expect(page.fills > 20)
        let plain = try Self.ops(PrintLayout.singlePage(launchPlanDocument(), canvas: "c1", ImageExporter.Options()))
        #expect(plain.images == 1)
        #expect(plain.fills == 0)
        let printed = PrintLayout.pdf(d, canvas: "c1", PrintLayout.Options())
        #expect(try Self.ops(printed.data).fills == page.fills)
        // The picture without its formulas differs from the one with them.
        var o = ImageExporter.Options()
        o.formulas = false
        let without = try #require(ImageExporter.image(d, canvas: "c1", o))
        let with = try #require(ImageExporter.image(d, canvas: "c1", ImageExporter.Options()))
        #expect(ImageExporter.png(without) != ImageExporter.png(with))
        if let dir = Self.scratch {
            try PrintLayout.singlePage(d, canvas: "c1", ImageExporter.Options()).write(
                to: dir.appendingPathComponent("math-map.pdf"))
            try ImageExporter.png(without).write(to: dir.appendingPathComponent("math-map-without.png"))
        }
    }

    /// Writes the map as PNG and SVG for a look by eye, when NEXUS_MATH_SCRATCH names a folder.
    @Test func scratchRender() throws {
        guard let dir = Self.scratch else { return }
        let d = mathDocument()
        var o = ImageExporter.Options()
        o.scale = 2
        let img = try #require(ImageExporter.image(d, canvas: "c1", o))
        try ImageExporter.png(img).write(to: dir.appendingPathComponent("math-map.png"))
        try SVGExporter.export(d, canvas: "c1", o).write(
            to: dir.appendingPathComponent("math-map.svg"), atomically: true, encoding: .utf8)
    }
}
