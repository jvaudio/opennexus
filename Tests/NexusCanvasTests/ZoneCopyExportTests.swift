import AppKit
import Foundation
import PDFKit
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusKeys

/// M20: export every zone at once (D195) and copy, cut, paste and duplicate zones (D196),
/// on the real controller.
@MainActor
@Suite(.serialized) struct ZoneCopyExportTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    /// The launch plan with a zone "Ideas" around "Parking lot" › "Later idea", connected
    /// to "Pricing" both ways (one end on the zone itself).
    func harness(pasteboard: NSPasteboard? = nil) throws -> (CanvasHarness, zone: String) {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.pasteboard = pasteboard ?? NSPasteboard(name: NSPasteboard.Name("nexus-test-\(UUID().uuidString)"))
        let pricing = node(h, "Pricing")
        let zone = try #require(
            h.controller.perform("Zone") { e -> String in
                let top = e.addFloating(at: CanvasPoint(x: 2000, y: 1400), text: "Parking lot")
                let later = try e.addChild(of: top, text: "Later idea")
                let z = e.addZone(
                    title: "Ideas", origin: CanvasPoint(x: 1960, y: 1340), width: 320, height: 200, members: [top])
                _ = e.connect(.topic(later), to: .topic(top), label: "inside")
                _ = e.connect(.topic(pricing), to: .zone(z), label: "pricing to zone")
                _ = e.connect(.topic(top), to: .topic(pricing), label: "lot to pricing")
                return z
            })
        return (h, zone)
    }

    func labels(_ c: Canvas, touching zone: Zone) -> [String] {
        let inside = Set(zone.members.flatMap { c.subtree($0) })
        return c.relationships.filter { r in
            [r.from, r.to].contains { $0 == .zone(zone.id) || $0.topic.map(inside.contains) == true }
        }.map(\.label).sorted()
    }

    // MARK: Copy, cut, paste, duplicate (D196)

    @Test func copyAndPasteAZoneInTheSameCanvas() throws {
        let (h, zone) = try harness()
        let original = try #require(h.canvas.zones.first { $0.id == zone })
        h.controller.selectElement(.zone(zone))
        h.press("cmd+c")
        let pb = h.controller.pasteboard
        #expect(pb.data(forType: .nexusFragment) != nil && pb.string(forType: .nexusFragmentSource) != nil)
        #expect(pb.string(forType: .string) == "Parking lot\n\tLater idea\n")
        let depth = h.undo.stack.undoStack.count
        let rels = h.canvas.relationships.count
        h.press("cmd+v")
        #expect(h.undo.stack.undoStack.count == depth + 1, "one undo step")
        #expect(h.canvas.zones.count == 2)
        let pasted = try #require(h.canvas.zones.last)
        #expect(pasted.id != zone && pasted.title == "Ideas" && h.controller.selectedElement == .zone(pasted.id))
        // The zone lands at the paste point, its member where it sits in the zone.
        let p = try #require(h.controller.floatingPlacement?())
        #expect(pasted.origin == CanvasPoint(x: Double(p.x), y: Double(p.y)))
        let top = try #require(pasted.members.first)
        #expect(h.canvas.nodes[top]?.text == "Parking lot" && h.canvas.floating.contains(top))
        #expect(h.canvas.nodes[top]?.position == CanvasPoint(x: pasted.origin.x + 40, y: pasted.origin.y + 60))
        #expect(h.controller.scene.zones.contains { $0.zone.id == pasted.id })
        // Back in its own canvas, relationships to the rest of the map are kept.
        #expect(h.canvas.relationships.count == rels + 3)
        #expect(labels(h.canvas, touching: pasted) == ["inside", "lot to pricing", "pricing to zone"])
        #expect(h.canvas.relationships.last { $0.label == "pricing to zone" }?.to == .zone(pasted.id))
        #expect(labels(h.canvas, touching: original) == ["inside", "lot to pricing", "pricing to zone"])
        #expect(h.canvas.validate().isEmpty)
        h.undo.undo(h.store)
        #expect(h.canvas.zones.map(\.id) == [zone] && h.canvas.relationships.count == rels)
        #expect(h.controller.selectedElement == nil, "the pasted zone is gone")
    }

    @Test func pasteIntoAnotherCanvasDropsOutsideEnds() throws {
        let (h, zone) = try harness()
        h.controller.selectElement(.zone(zone))
        h.controller.copySelection()
        // A second canvas in the same document, with the same topic ids as the first.
        var copy = launchPlanDocument().canvases["c1"]!
        copy.title = "Copy"
        h.store.commitDocument("Add", focus: "c1") { d in _ = d.add([copy]) }
        let second = try #require(h.store.model.canvasOrder.last)
        h.controller.switchCanvas(to: second)
        #expect(h.canvas.nodes[node(h, "Pricing")] != nil)
        h.controller.paste()
        let pasted = try #require(h.canvas.zones.first)
        #expect(pasted.title == "Ideas" && pasted.members.count == 1)
        #expect(labels(h.canvas, touching: pasted) == ["inside"], "ends outside the copy don't travel")
        #expect(h.canvas.relationships.map(\.label) == ["inside"])
        #expect(h.canvas.validate().isEmpty)
    }

    @Test func pasteIntoAnotherDocumentDropsOutsideEnds() throws {
        let (h, zone) = try harness()
        h.controller.selectElement(.zone(zone))
        h.controller.copySelection()
        // Same canvas id and topic ids, but another open document.
        let other = CanvasHarness(model: launchPlanDocument())
        other.controller.pasteboard = h.controller.pasteboard
        #expect(other.controller.canvasID == h.controller.canvasID)
        other.controller.paste()
        let pasted = try #require(other.canvas.zones.first)
        #expect(pasted.title == "Ideas")
        #expect(other.canvas.relationships.map(\.label) == ["inside"])
        #expect(other.canvas.validate().isEmpty)
        other.undo.undo(other.store)
        #expect(other.canvas.zones.isEmpty && !other.canvas.nodes.values.contains { $0.text == "Parking lot" })
    }

    @Test func cutIsCopyThenDeleteInOneStep() throws {
        let (h, zone) = try harness()
        let before = h.canvas
        h.controller.selectElement(.zone(zone))
        let cut = NSMenuItem(title: "Cut", action: #selector(CanvasView.cut(_:)), keyEquivalent: "")
        #expect(h.host.canvasView.validateMenuItem(cut), "a selected zone can be cut")
        let depth = h.undo.stack.undoStack.count
        h.press("cmd+x")
        #expect(h.undo.stack.undoStack.count == depth + 1)
        #expect(h.canvas.zones.isEmpty && h.controller.selectedElement == nil)
        #expect(!h.canvas.nodes.values.contains { $0.text == "Parking lot" || $0.text == "Later idea" })
        #expect(h.canvas.relationships.isEmpty && h.canvas.validate().isEmpty)
        #expect(h.controller.pasteboard.data(forType: .nexusFragment) != nil)
        h.undo.undo(h.store)
        #expect(h.canvas == before && h.canvas.zones == before.zones && h.canvas.relationships == before.relationships)
        h.undo.redo(h.store)
        #expect(h.canvas.zones.isEmpty)
        // Pasting the cut zone back keeps its relationship to Pricing (same canvas).
        h.controller.paste()
        let pasted = try #require(h.canvas.zones.first)
        #expect(labels(h.canvas, touching: pasted) == ["inside", "lot to pricing", "pricing to zone"])
    }

    @Test func duplicateZone() throws {
        let (h, zone) = try harness()
        let original = try #require(h.canvas.zones.first { $0.id == zone })
        // Hidden from ⌘K until a zone is in play.
        h.controller.select(node(h, "Pricing"))
        #expect(!h.controller.canPerform(.duplicateZone))
        // ⌘D on a selected zone duplicates it beside the original.
        h.controller.selectElement(.zone(zone))
        h.press("cmd+d")
        let copy = try #require(h.canvas.zones.last)
        #expect(h.canvas.zones.count == 2 && copy.id != zone && h.controller.selectedElement == .zone(copy.id))
        #expect(copy.origin == CanvasPoint(x: original.origin.x + original.width + 40, y: original.origin.y))
        #expect(labels(h.canvas, touching: copy) == ["inside", "lot to pricing", "pricing to zone"])
        // The command works from a topic inside the zone too.
        h.controller.select(node(h, "Later idea"))
        #expect(h.controller.canPerform(.duplicateZone))
        #expect(h.controller.perform(.duplicateZone))
        #expect(h.canvas.zones.count == 3)
        #expect(h.canvas.validate().isEmpty)
        h.undo.undo(h.store)
        h.undo.undo(h.store)
        #expect(h.canvas.zones.map(\.id) == [zone])
    }

    // MARK: Export each zone (D195)

    /// Five zones, two with the same title and two whose titles need cleaning.
    func manyZones() throws -> CanvasHarness {
        let (h, _) = try harness()
        h.controller.perform("Zones") { e in
            _ = e.addZone(title: "Empty", origin: CanvasPoint(x: -2000, y: -1400), width: 200, height: 150)
            _ = e.addZone(title: "ideas", origin: CanvasPoint(x: -2000, y: 1400), width: 240, height: 160)
            _ = e.addZone(title: "Q3/Q4: plan", origin: CanvasPoint(x: 2000, y: -1400))
            _ = e.addZone(title: "  ", origin: CanvasPoint(x: 3000, y: -1400))
        }
        return h
    }

    @Test func fileNamesAreSafeAndUnique() {
        #expect(
            ImageExporter.fileNames(
                ["Ideas", "ideas", "Ideas", "a/b:c", "", "..hidden", "Tab\there"], fallback: "Zone")
                == ["Ideas", "ideas 2", "Ideas 3", "a-b-c", "Zone", "hidden", "Tab-here"])
        #expect(ImageExporter.fileNames([String(repeating: "x", count: 300)], fallback: "Zone")[0].count == 100)
    }

    @Test func eachZoneAsItsOwnFile() throws {
        let h = try manyZones()
        #expect(h.controller.canPerform(.exportZones))
        h.press("cmd+k")
        h.type("each zone")
        #expect(h.controller.paletteRows.contains { $0.id == CommandID.exportZones.rawValue })
        h.controller.closePalette()
        #expect(h.controller.perform(.exportZones))
        var s = try #require(h.controller.exportState)
        #expect(s.image.scope == .zone && s.zones == .each)
        let names = ["Ideas", "Empty", "ideas 2", "Q3-Q4- plan", "Zone"]
        for format in [ExportFormat.png, .jpeg, .svg, .pdf] {
            s.format = format
            h.controller.setExport(s)
            s = try #require(h.controller.exportState)
            #expect(s.zones == .each && s.image.scope == .zone, "switching format keeps each-zone")
            #expect(h.controller.exportSizeLine(s) == "5 files")
            var saved: [(String, Data)] = []
            h.controller.onSaveFolder = { saved = $0 }
            h.controller.runExport(s)
            #expect(saved.map(\.0) == names.map { $0 + "." + format.fileExt })
            for (_, data) in saved {
                switch format {
                case .svg: #expect(String(decoding: data, as: UTF8.self).contains("<svg"))
                case .pdf: #expect(PDFDocument(data: data)?.pageCount == 1)
                default: #expect(NSImage(data: data) != nil)
                }
            }
            h.controller.openExport(format)
            h.controller.exportEachZone()
            s = try #require(h.controller.exportState)
        }
        // Each file is cropped to its own zone.
        var saved: [(String, Data)] = []
        h.controller.onSaveFolder = { saved = $0 }
        s.format = .png
        h.controller.setExport(s)
        h.controller.runExport(h.controller.exportState!)
        var o = ImageExporter.Options()
        o.scale = s.image.scale
        o.scope = .zone
        for (z, file) in zip(h.canvas.zones, saved) {
            o.zone = z.id
            let size = ImageExporter.pixelSize(h.store.model, canvas: "c1", o)
            let rep = try #require(NSBitmapImageRep(data: file.1))
            #expect(CGFloat(rep.pixelsWide) == size.width && CGFloat(rep.pixelsHigh) == size.height)
        }
        // A canvas without zones hides the command.
        let plain = CanvasHarness(model: launchPlanDocument())
        #expect(!plain.controller.canPerform(.exportZones))
    }

    @Test func onePDFWithAPagePerZone() throws {
        let h = try manyZones()
        h.controller.exportEachZone()
        var s = try #require(h.controller.exportState)
        s.format = .pdf
        h.controller.setExport(s)
        s = try #require(h.controller.exportState)
        s.zones = .pages
        h.controller.setExport(s)
        s = try #require(h.controller.exportState)
        #expect(h.controller.exportSizeLine(s) == "5 pages")
        var saved: (Data, String)?
        h.controller.onSaveFile = { saved = ($0, $1) }
        h.controller.runExport(s)
        let file = try #require(saved)
        #expect(file.1 == "Launch plan – Zones.pdf")
        let pdf = try #require(PDFDocument(data: file.0))
        #expect(pdf.pageCount == 5)
        // Each page is its zone's size.
        var o = s.image
        for (i, z) in h.canvas.zones.enumerated() {
            o.zone = z.id
            let r = ImageExporter.contentRect(h.store.model, canvas: "c1", o)
            let box = try #require(pdf.page(at: i)?.bounds(for: .mediaBox))
            #expect(abs(box.width - r.width) < 1 && abs(box.height - r.height) < 1)
        }
        // A page per zone is PDF only: another format writes a file per zone instead.
        s.format = .png
        h.controller.setExport(s)
        #expect(h.controller.exportState?.zones == .each)
        // One zone still exports alone.
        s = h.controller.exportState!
        s.zones = .one
        s.format = .pdf
        h.controller.setExport(s)
        h.controller.runExport(h.controller.exportState!)
        #expect(PDFDocument(data: saved!.0)?.pageCount == 1 && saved?.1 == "Launch plan – Ideas.pdf")
    }
}
