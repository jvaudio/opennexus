import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusInterchange

/// M12: an image's map lands in the open document as one undo step.
@MainActor
@Suite(.serialized) struct ImageToMapTests {
    nonisolated static func imported() -> Imported {
        let image = RecognisedImage(
            width: 600, height: 300,
            boxes: [
                TextBox("Project Plan", x: 40, y: 20, width: 300, height: 32),
                TextBox("Goals", x: 40, y: 80, width: 70, height: 16),
                TextBox("• Ship v1", x: 64, y: 104, width: 120, height: 16),
                TextBox("Risks", x: 40, y: 136, width: 60, height: 16),
            ])
        return ImageOutline.build(image, title: "plan").imported(source: "plan.png")
    }

    func harness(_ model: DocumentModel) -> CanvasHarness {
        let h = CanvasHarness(model: model)
        h.controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("nexus-test-\(UUID().uuidString)"))
        return h
    }

    @Test func fillsAnUntouchedCanvasInPlace() {
        let h = harness(.blank())
        let style = h.canvas.style
        h.controller.addImageCanvas(Self.imported())
        #expect(h.store.model.canvasOrder.count == 1)
        #expect(h.canvas.nodes[h.canvas.root]?.text == "Project Plan" && h.canvas.nodes.count == 4)
        #expect(h.canvas.style == style, "the canvas keeps the look chosen for it")
        #expect(h.controller.importReport?.format == "Image")
        #expect(h.undo.stack.undoStack.count == 1)
        h.undo.undo(h.store)
        #expect(h.canvas.nodes.count == 1)
    }

    /// M19: a PDF's pages land together, the first filling an untouched canvas, as one undo.
    @Test func everyPageLandsAsOneUndo() {
        let h = harness(.blank())
        let pages = ["Kickoff", "Timeline"].enumerated().map { i, title in
            RecognisedImage(
                width: 600, height: 800,
                boxes: [
                    TextBox(title, x: 40, y: 60, width: 200, height: 40),
                    TextBox("• One", x: 60, y: 140, width: 80, height: 16),
                ], page: i + 1, pages: 2)
        }
        h.controller.addImageCanvas(ImageOutline.build(pages: pages, title: "deck").imported(source: "deck.pdf"))
        #expect(h.store.model.canvasOrder.count == 2)
        #expect(h.store.model.orderedCanvases.map(\.title) == ["Kickoff", "Timeline"])
        #expect(h.controller.canvasID == h.store.model.canvasOrder[0])
        #expect(h.undo.stack.undoStack.count == 1)
        h.undo.undo(h.store)
        #expect(h.store.model.canvasOrder.count == 1 && h.canvas.nodes.count == 1)
    }

    @Test func addsACanvasNextToAMap() {
        let h = harness(launchPlanDocument())
        let first = h.controller.canvasID
        h.controller.addImageCanvas(Self.imported())
        #expect(h.store.model.canvasOrder.count == 2 && h.controller.canvasID != first)
        #expect(h.canvas.nodes[h.canvas.root]?.text == "Project Plan")
        #expect(h.undo.stack.undoStack.count == 1)
        h.undo.undo(h.store)
        #expect(h.store.model.canvasOrder == [first])
    }

    /// M19: the merge sheet reads a picture off the main thread. Its row shows progress at
    /// once, Merge waits for it, and removing the row stops the reading.
    @Test func mergeSheetReadsPicturesInTheBackground() async throws {
        let h = harness(launchPlanDocument())
        var o = ImageExporter.Options()
        o.scale = 2
        let png = ImageExporter.png(try #require(ImageExporter.image(launchPlanDocument(), canvas: "c1", o)))
        let dir = FileManager.default.temporaryDirectory.appending(path: "merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "plan.png")
        try png.write(to: url)

        h.controller.openMerge()
        let removed = h.controller.addMergeSource(url)
        h.controller.removeMergeSource("plan.png")
        await removed?.value
        #expect(h.controller.mergeState?.sources.isEmpty == true, "a removed picture doesn't come back")

        let task = try #require(h.controller.addMergeSource(url))
        let row = try #require(h.controller.mergeState?.sources.first)
        #expect(row.progress == 0 && row.kind == "IM" && h.controller.mergeState?.reading == true)
        h.controller.applyMerge()
        #expect(h.controller.mergeState != nil, "Merge waits for the reading")
        await task.value
        let read = try #require(h.controller.mergeState?.sources.first)
        #expect(read.progress == nil && read.canvases.count == 1 && read.canvases[0].nodes.count == 16)
        h.controller.applyMerge()
        #expect(h.store.model.canvasOrder.count == 3, "the picture's canvas and the map of content")
    }

    /// Waits (up to two seconds) for the main actor to catch up with the reading.
    func settle(_ ready: () -> Bool) async {
        for _ in 0..<200 where !ready() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// M29: File › Import… of a long PDF shows the page being read, and Cancel stops the
    /// reading with nothing opened.
    @Test func fileImportShowsPagesAndCancels() async throws {
        let progress = ImageImportProgress(name: "report.pdf") { _, _, _, report in
            report(0, 4)
            report(1, 4)
            while true { try await Task.sleep(for: .seconds(30)) }
        }
        var windows = 0
        progress.onManyPages = { windows += 1 }
        var outcomes: [String] = []
        #expect(progress.detail == "Reading the text in the image…" && progress.fraction == 0)
        let task = progress.start(Data(), refine: false) { outcome in
            switch outcome {
            case .imported: outcomes.append("imported")
            case .failed: outcomes.append("failed")
            case .cancelled: outcomes.append("cancelled")
            }
        }
        await settle { progress.done == 1 }
        #expect(progress.total == 4 && progress.done == 1 && progress.fraction == 0.25)
        #expect(progress.detail == "Reading page 2 of 4…", "the page being read, as in the merge sheet")
        #expect(windows == 1, "the window is asked for once, when the pages are known")
        progress.cancel()
        await task.value
        #expect(outcomes == ["cancelled"] && progress.cancelled && progress.finished)
        progress.cancel()
        #expect(outcomes == ["cancelled"], "the outcome comes once")
    }

    /// M29: a single picture asks for no window, and a failure is reported, not cancelled.
    @Test func fileImportOfOnePictureNeedsNoWindow() async throws {
        let one = ImageImportProgress(name: "plan.png") { _, _, _, report in
            report(0, 1)
            report(1, 1)
            return Self.imported()
        }
        var windows = 0
        one.onManyPages = { windows += 1 }
        var canvases = 0
        await one.start(Data(), refine: false) { outcome in
            if case .imported(let im) = outcome { canvases = im.canvases.count }
        }.value
        #expect(canvases == 1 && windows == 0 && !one.cancelled)

        let broken = ImageImportProgress(name: "broken.pdf") { _, name, _, _ in
            throw ImportError.invalid(name, "no pages")
        }
        var failed = false
        await broken.start(Data(), refine: false) { outcome in
            if case .failed = outcome { failed = true }
        }.value
        #expect(failed)
    }

    /// M29: the real path, Vision on a three-page PDF: the page count arrives before the
    /// first page, the window is asked for, and every page becomes a canvas.
    @Test func fileImportReadsEveryPageWithProgress() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 500, height: 300)
        let pdf = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        for title in ["Kickoff", "Timeline", "Budget"] {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 40)])
                .draw(at: CGPoint(x: 30, y: 200))
            NSAttributedString(string: "First point", attributes: [.font: NSFont.systemFont(ofSize: 22)])
                .draw(at: CGPoint(x: 70, y: 130))
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let progress = ImageImportProgress(name: "deck.pdf")
        var totals: [Int] = []
        progress.onManyPages = { totals.append(progress.total) }
        var titles: [String] = []
        await progress.start(data as Data, refine: false) { outcome in
            if case .imported(let im) = outcome { titles = im.canvases.map(\.title) }
        }.value
        await settle { progress.done == 3 }
        #expect(totals == [3], "the window is asked for before the first page is read")
        #expect(progress.done == 3 && progress.total == 3 && progress.fraction == 1)
        #expect(titles == ["Kickoff", "Timeline", "Budget"])

        // Cancelled as soon as its window would show, Vision stops between pages.
        final class Pages: @unchecked Sendable {
            let lock = NSLock()
            var read: [Int] = []
        }
        let pages = Pages()
        let stopped = ImageImportProgress(name: "deck.pdf") { data, name, refine, report in
            // Announce the pages, then wait for the cancel to arrive before reading any, so
            // the check doesn't depend on how fast this Mac reads a page.
            report(0, 3)
            for _ in 0..<500 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return try await ImageToMap.importImage(data, name: name, refine: refine) { done, total in
                pages.lock.withLock { pages.read.append(done) }
                report(done, total)
            }
        }
        stopped.onManyPages = { stopped.cancel() }
        var cancelled = false
        await stopped.start(data as Data, refine: false) { outcome in
            if case .cancelled = outcome { cancelled = true }
        }.value
        #expect(cancelled)
        #expect(stopped.cancelled)
        #expect(pages.lock.withLock { pages.read.last ?? 0 } < 3, "the reader stops between pages: \(pages.read)")
    }

    @Test func readsPicturesFromThePasteboard() throws {
        let h = harness(.blank())
        #expect(ImageToMap.image(on: h.controller.pasteboard) == nil)
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pb = h.controller.pasteboard
        pb.clearContents()
        pb.setData(rep.representation(using: .tiff, properties: [:]), forType: .tiff)
        let found = try #require(ImageToMap.image(on: pb))
        #expect(found.name.hasSuffix(".png") && NSBitmapImageRep(data: found.data)?.pixelsWide == 4)
        #expect(ImageToMap.isImage(name: "Screenshot 2026-10-20.HEIC") && ImageToMap.isImage(name: "poster.pdf"))
        #expect(!ImageToMap.isImage(name: "notes.md"))
    }
}

/// Round trip: a map OpenNexus draws, read back from its PNG with real Vision.
@MainActor
@Suite struct ImageRoundTripTests {
    func outline(_ c: Canvas, _ id: NodeID, _ depth: Int = 0) -> String {
        String(repeating: "  ", count: depth) + (c.nodes[id]?.text ?? "") + "\n"
            + (c.nodes[id]?.children ?? []).map { outline(c, $0, depth + 1) }.joined()
    }

    @Test(arguments: [
        LayoutStructure.mindmapBalanced, .mindmapRight, .mindmapLeft, .logicRight, .logicLeft, .orgDown, .treeIndented,
        .treeDown, .timelineHorizontal, .braceRight,
    ])
    func exportedMapReadsBack(_ structure: LayoutStructure) throws {
        for doc in [launchPlanDocument(), offsiteDocument()] { try roundTrip(doc, structure) }
    }

    /// M19: a fishbone (Ishikawa) diagram reads back as one, head on either side: the
    /// categories at the ends of the bones, nearest the head first, with their causes.
    @Test(arguments: [LayoutStructure.fishboneLeft, .fishboneRight])
    func exportedFishboneReadsBack(_ structure: LayoutStructure) throws {
        let template = try #require(TemplateLibrary.all.first { $0.id == "fishbone" }).document()
        for doc in [launchPlanDocument(), template] {
            var m = doc
            m.canvases["c1"]!.type = .fishbone
            let c = try roundTrip(m, structure)
            #expect(c.type == .fishbone && c.layout.structure == structure, "\(structure.rawValue)")
        }
    }

    @discardableResult func roundTrip(_ doc: DocumentModel, _ structure: LayoutStructure) throws -> Canvas {
        var m = doc
        m.canvases["c1"]!.layout.structure = structure
        var o = ImageExporter.Options()
        o.scale = 2
        let png = ImageExporter.png(try #require(ImageExporter.image(m, canvas: "c1", o)))
        let im = try Interchange.importFile(name: "launch.png", data: png)
        let c = im.canvases[0]
        #expect(outline(c, c.root) == outline(m.canvases["c1"]!, m.canvases["c1"]!.root), "\(structure.rawValue)")
        #expect(im.report.format == "Image")
        return c
    }
}

/// A deeper map with long topics that wrap, for the round trip.
func offsiteDocument() -> DocumentModel {
    var c = Canvas(id: "c1", title: "Q4 offsite", rootText: "Q4 offsite")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let tree: [(String, [(String, [String])])] = [
            ("Venue", [("Book a room near the office for forty people", ["Check catering"]), ("Projector", [])]),
            ("Agenda", [("Morning", ["Strategy review", "Roadmap"]), ("Afternoon", ["Workshops"])]),
            ("Travel", [("Trains", []), ("Hotel for the team", ["Two nights"])]),
        ]
        for (m, subs) in tree {
            let id = try! e.addChild(of: e.canvas.root, text: m)
            for (s, leaves) in subs {
                let sid = try! e.addChild(of: id, text: s)
                for l in leaves { try! e.addChild(of: sid, text: l) }
            }
        }
    }
    return DocumentModel(canvases: [c])
}
