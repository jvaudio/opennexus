import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusInterchange

/// M12: an image's map lands in the open document as one undo step.
@MainActor
@Suite(.serialized) struct ImageToMapTests {
    static func imported() -> Imported {
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
