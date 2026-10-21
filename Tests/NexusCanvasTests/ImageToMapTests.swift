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

    func roundTrip(_ doc: DocumentModel, _ structure: LayoutStructure) throws {
        var m = doc
        m.canvases["c1"]!.layout.structure = structure
        var o = ImageExporter.Options()
        o.scale = 2
        let png = ImageExporter.png(try #require(ImageExporter.image(m, canvas: "c1", o)))
        let im = try Interchange.importFile(name: "launch.png", data: png)
        let c = im.canvases[0]
        #expect(outline(c, c.root) == outline(m.canvases["c1"]!, m.canvases["c1"]!.root), "\(structure.rawValue)")
        #expect(im.report.format == "Image")
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
