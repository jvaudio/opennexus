import AppKit
import Foundation
import PDFKit
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusKeys

/// M7: copy and paste, paste as branch, merge, canvas tab operations, exports, Map Shot
/// and print, on the real controller.
@MainActor
@Suite(.serialized) struct FileFlowTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    func harness() -> CanvasHarness {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("nexus-test-\(UUID().uuidString)"))
        return h
    }

    @Test func copyPasteTopicsAndOutlines() throws {
        let h = harness()
        let pricing = node(h, "Pricing")
        let risks = node(h, "Risks")
        h.controller.select(pricing)
        h.press("cmd+c")
        #expect(h.controller.pasteboard.string(forType: .string)?.hasPrefix("Pricing\n\tFree tier") == true)
        h.controller.select(risks)
        let depth = h.undo.stack.undoStack.count
        h.press("cmd+v")
        #expect(h.undo.stack.undoStack.count == depth + 1)
        let pasted = h.canvas.nodes[risks]!.children.last!
        #expect(h.canvas.nodes[pasted]!.text == "Pricing" && h.canvas.nodes[pasted]!.children.count == 3)
        #expect(h.controller.selection.primary == pasted)

        // Markdown from another app becomes a branch, as one undo.
        let pb = h.controller.pasteboard
        pb.clearContents()
        pb.setString("# Trip\n## Packing\n- Passport\n- Charger\n## Route", forType: .string)
        h.controller.select(risks)
        h.press("cmd+v")
        let trip = h.canvas.nodes[risks]!.children.last!
        #expect(h.canvas.nodes[trip]!.text == "Trip")
        #expect(h.canvas.nodes[trip]!.children.map { h.text($0) } == ["Packing", "Route"])
        h.undo.undo(h.store)
        #expect(!h.canvas.nodes.values.contains { $0.text == "Trip" })

        // Indented text with several tops pastes each as a sibling branch.
        pb.clearContents()
        pb.setString("Alpha\n\tA1\nBeta", forType: .string)
        h.controller.select(risks)
        h.controller.paste()
        #expect(h.canvas.nodes[risks]!.children.suffix(2).map { h.text($0) } == ["Alpha", "Beta"])

        // One line is one topic.
        pb.clearContents()
        pb.setString("Just a note", forType: .string)
        h.controller.select(risks)
        h.controller.paste()
        #expect(h.text(h.canvas.nodes[risks]!.children.last!) == "Just a note")

        // Cut removes and remembers.
        let channels = node(h, "Channels")
        h.controller.select(channels)
        h.press("cmd+x")
        #expect(h.canvas.nodes[channels] == nil)
        h.controller.select(h.canvas.root)
        h.press("cmd+v")
        #expect(h.canvas.nodes.values.contains { $0.text == "Channels" })
    }

    @Test func mergeAsCanvasesAndIntoThisCanvas() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appending(path: "Notes.md")
        try "# Notes\n## Inbox\n- Call Sam\n## Ideas".write(to: md, atomically: true, encoding: .utf8)
        let nx = dir.appending(path: "Q3 roadmap.nexus")
        var other = DocumentModel(canvases: [
            Canvas(id: "c1", title: "Q3 roadmap", rootText: "Q3 roadmap"),
            Canvas(id: "c2", title: "Hiring", rootText: "Hiring"),
        ])
        other.canvasOrder = ["c1", "c2"]
        try NexusPackage.write(other, to: nx)

        let h = harness()
        h.controller.openMerge()
        h.controller.addMergeSource(md)
        h.controller.addMergeSource(nx)
        let m = try #require(h.controller.mergeState)
        #expect(m.sources.map(\.kind) == ["MD", "NX"])
        #expect(m.sources[1].detail == "1 topics · 2 canvases" || m.sources[1].detail.hasSuffix("2 canvases"))
        h.controller.applyMerge()
        #expect(h.store.model.canvasOrder.count == 5, "launch plan + notes + 2 roadmap canvases + map of content")
        #expect(h.undo.stack.undoStack.count == 1)
        let moc = h.canvas
        #expect(moc.title == "Map of Content" && moc.nodes[moc.root]!.children.count == 3)
        let link = try #require(moc.nodes[moc.nodes[moc.root]!.children[0]]!.link)
        #expect(TopicLink.parse(link)?.canvas != "c1", "links point at the merged canvases")
        h.undo.undo(h.store)
        #expect(h.store.model.canvasOrder == ["c1"] && h.controller.canvasID == "c1")

        // Into this canvas: central topics become branches, one undo.
        h.controller.openMerge()
        h.controller.mergeState?.intoThisCanvas = true
        h.controller.addMergeSource(md)
        let before = h.canvas.nodes[h.canvas.root]!.children.count
        h.controller.applyMerge()
        #expect(h.canvas.nodes[h.canvas.root]!.children.count == before + 1)
        #expect(h.store.model.canvasOrder == ["c1"])
    }

    @Test func canvasTabOperationsAreUndoable() throws {
        let h = harness()
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        h.press("opt+cmd+n")
        #expect(h.store.model.canvasOrder.count == 2)
        #expect(h.canvas.nodes[h.canvas.root]!.text == "Pricing" && h.canvas.nodes[h.canvas.root]!.children.count == 3)
        let fromTopic = h.controller.canvasID
        h.controller.duplicateCanvas()
        #expect(h.store.model.canvasOrder.count == 3 && h.canvas.title == "Pricing copy")
        h.controller.deleteCanvas()
        #expect(h.store.model.canvasOrder.count == 2)
        h.undo.undo(h.store)
        #expect(h.store.model.canvasOrder.count == 3)
        h.controller.switchCanvas(to: fromTopic)
        h.controller.copyCanvas()
        h.controller.pasteCanvas()
        #expect(h.store.model.canvasOrder.count == 4)
        h.controller.renameCanvas("Pricing detail")
        #expect(h.canvas.title == "Pricing detail")
        while h.undo.undo(h.store) {}
        #expect(h.store.model.canvasOrder == ["c1"])
        h.controller.deleteCanvas()
        #expect(h.store.model.canvasOrder == ["c1"], "the last canvas stays")
    }

    @Test func imageExportsScaleScopeAndBackground() throws {
        let h = harness()
        let m = h.store.model
        var o = ImageExporter.Options()
        o.scale = 1
        let one = try #require(ImageExporter.image(m, canvas: "c1", o))
        o.scale = 2
        let two = try #require(ImageExporter.image(m, canvas: "c1", o))
        #expect(abs(two.width - one.width * 2) <= 2 && abs(two.height - one.height * 2) <= 2)
        o.padding = 100
        o.scale = 1
        let padded = try #require(ImageExporter.image(m, canvas: "c1", o))
        #expect(abs(padded.width - (one.width + 104)) <= 2, "padding is per side (48 → 100)")
        // Transparent corners vs theme background.
        o.background = .transparent
        let clear = try #require(ImageExporter.image(m, canvas: "c1", o))
        let rep = NSBitmapImageRep(cgImage: clear)
        #expect(rep.colorAt(x: 2, y: 2)!.alphaComponent < 0.01)
        o.background = .theme
        let filled = NSBitmapImageRep(cgImage: try #require(ImageExporter.image(m, canvas: "c1", o)))
        #expect(filled.colorAt(x: 2, y: 2)!.alphaComponent > 0.99)
        // Branch scope is smaller than the canvas.
        o.scope = .branch
        o.selection = [node(h, "Pricing")]
        let branch = try #require(ImageExporter.image(m, canvas: "c1", o))
        #expect(branch.width < padded.width && branch.height < padded.height)
        // JPEG and PNG encode.
        #expect(ImageExporter.png(one).starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(ImageExporter.jpeg(one, quality: 0.8).starts(with: [0xFF, 0xD8]))
        // Split by branch: one named file per main topic.
        let files = ImageExporter.splitByBranch(m, canvas: "c1", ImageExporter.Options())
        #expect(
            files.map(\.name) == [
                "01-positioning.png", "02-pricing.png", "03-channels.png", "04-timeline.png", "05-risks.png",
            ])
    }

    @Test func svgIsWellFormedWithMetadataAndOutlines() throws {
        let h = harness()
        var model = h.store.model
        let api = model.canvases["c1"]!.nodes.first { $0.value.text == "Pricing" }!.key
        model.canvases["c1"]!.nodes[api]!.metadata = [MetadataField(key: "owner", value: "Team Atlas")]
        model.canvases["c1"]!.nodes[api]!.nodeType = "service"
        var o = SVGExporter.Options()
        let svg = SVGExporter.export(model, canvas: "c1", ImageExporter.Options(), o)
        let doc = try XMLDocument(data: Data(svg.utf8))
        #expect(doc.rootElement()?.name == "svg")
        #expect(svg.contains("data-nexus-type=\"service\"") && svg.contains("data-owner=\"Team Atlas\""))
        #expect(svg.contains(">Pricing</text>") && svg.contains("<path d=\"M"))
        o.outlineText = true
        o.metadata = false
        let outlined = SVGExporter.export(model, canvas: "c1", ImageExporter.Options(), o)
        #expect(try XMLDocument(data: Data(outlined.utf8)).rootElement() != nil)
        #expect(!outlined.contains("<text") && !outlined.contains("data-nexus"))
        // macOS renders it.
        #expect(NSImage(data: Data(svg.utf8)) != nil)
    }

    @Test func printTilesAndAppendix() throws {
        let h = harness()
        var o = PrintLayout.Options()
        o.fitPage = true
        h.controller.select(node(h, "Pricing"))
        h.store.commitDocument("Note", focus: "c1") { d in
            let id = d.canvases["c1"]!.nodes.first { $0.value.text == "Pricing" }!.key
            d.canvases["c1"]!.nodes[id]!.note = Note(text: "Keep the free tier generous.")
        }
        let fit = h.controller.printPDF(o)
        #expect(fit.pages == 2, "one map page and the notes appendix")
        #expect(PDFDocument(data: fit.data)?.pageCount == 2)
        o.notesAppendix = false
        o.fitPage = false
        o.tile = true
        o.paper = .a4
        o.landscape = false
        // A wide map at actual size spans pages across.
        var wide = launchPlanDocument()
        var undo = UndoStack()
        wide.canvases["c1"]!.edit("Wide", undo: &undo) { e in
            for i in 0..<12 {
                let t = try! e.addChild(of: e.canvas.root, text: "Branch with a long title number \(i)")
                for j in 0..<6 { _ = try! e.addChild(of: t, text: "A rather long subtopic \(j)") }
            }
        }
        let tiled = PrintLayout.pdf(wide, canvas: "c1", o)
        #expect(tiled.pages > 1)
        #expect(PDFDocument(data: tiled.data)?.pageCount == tiled.pages)
        o.content = .outline
        let outline = h.controller.printPDF(o)
        let text = PDFDocument(data: outline.data)?.string ?? ""
        #expect(text.contains("Launch plan") && text.contains("Competitor response"))
    }

    @Test func mapShotKeysAndOutput() throws {
        let h = harness()
        h.press("ctrl+cmd+m")
        let s = try #require(h.controller.mapShot)
        #expect(abs(s.rect.width / s.rect.height - 1.6) < 0.02, "16:10 by default")
        h.press("right")
        #expect(h.controller.mapShot!.rect.minX == s.rect.minX + 10)
        h.press("shift+down")
        #expect(h.controller.mapShot!.rect.minY == s.rect.minY + 50)
        h.press("1")
        let sq = h.controller.mapShot!
        #expect(sq.aspect == .square && sq.rect.width == sq.rect.height)
        h.press("opt+right")
        #expect(
            h.controller.mapShot!.rect.width == sq.rect.width + 20
                && h.controller.mapShot!.rect.height == sq.rect.height + 20)
        let img = try #require(h.controller.mapShotImage(h.controller.mapShot!))
        #expect(img.width == Int((h.controller.mapShot!.rect.width + 24) * 2), "12 pt padding each side at 2×")
        var saved: String?
        h.controller.onSaveMapShot = { _, name in saved = name }
        h.press("return")
        #expect(h.controller.mapShot == nil && saved?.hasPrefix("Map Shot ") == true)
        #expect(h.controller.pasteboard.data(forType: .png) != nil)
        h.press("ctrl+cmd+m")
        h.press("esc")
        #expect(h.controller.mapShot == nil)
    }

    @Test func exportSheetRemembersPerFormatAndProducesFiles() throws {
        let h = harness()
        UserDefaults.standard.removeObject(forKey: "export.lastSettings.png")
        UserDefaults.standard.removeObject(forKey: "export.lastSettings.markdown")
        h.press("shift+cmd+e")
        var s = try #require(h.controller.exportState)
        #expect(s.format == .png || ExportFormat.allCases.contains(s.format))
        s.format = .png
        h.controller.setExport(s)
        s = h.controller.exportState!
        s.image.scale = 3
        s.image.background = .white
        h.controller.setExport(s)
        h.controller.setExport(
            {
                var x = h.controller.exportState!; x.format = .markdown; return x
            }())
        #expect(h.controller.exportState!.format == .markdown)
        h.controller.closeExport()
        h.controller.openExport(.png)
        #expect(h.controller.exportState!.image.scale == 3 && h.controller.exportState!.image.background == .white)
        h.controller.closeExport()
        for f in ExportFormat.allCases where f != .powerpoint && f != .keynote {
            var st = ExportState.remembered(f)
            st.image.scale = 1
            let data = try #require(h.controller.exportData(st), "\(f)")
            #expect(!data.isEmpty, "\(f)")
            for mark in ["watermark", "Made with", "Created with OpenNexus", "Trial"] {
                #expect(data.range(of: Data(mark.utf8)) == nil, "\(f) has no watermark")
            }
        }
        var saved: (Data, String)?
        h.controller.onSaveFile = { saved = ($0, $1) }
        h.controller.runExport(ExportState.remembered(.opml))
        #expect(saved?.1 == "Launch plan.opml")
    }

    // MARK: M13: zones export and print on their own; Excel

    /// A zone far from the main tree holding a floating topic with a child, plus an
    /// empty zone.
    func zoneHarness() throws -> (CanvasHarness, zone: String, empty: String) {
        let h = harness()
        let ids = try #require(
            h.controller.perform("Zones") { e -> (String, String) in
                let top = e.addFloating(at: CanvasPoint(x: 2000, y: 1400), text: "Parking lot")
                let later = try e.addChild(of: top, text: "Later idea")
                e.update(later) { $0.note = Note(text: "Revisit after GA.") }
                let z = e.addZone(
                    title: "Ideas", origin: CanvasPoint(x: 1960, y: 1340), width: 320, height: 200, members: [top])
                let empty = e.addZone(title: "Empty", origin: CanvasPoint(x: -2000, y: -1400), width: 200, height: 150)
                return (z, empty)
            })
        h.store.commitDocument("Note", focus: "c1") { d in
            let id = d.canvases["c1"]!.nodes.first { $0.value.text == "Pricing" }!.key
            d.canvases["c1"]!.nodes[id]!.note = Note(text: "Keep the free tier generous.")
        }
        return (h, ids.0, ids.1)
    }

    @Test func zoneExportCropsToTheZone() throws {
        let (h, zone, empty) = try zoneHarness()
        let m = h.store.model
        var o = ImageExporter.Options()
        o.scale = 1
        let whole = try #require(ImageExporter.image(m, canvas: "c1", o))
        o.scope = .zone
        o.zone = zone
        let rect = try #require(h.controller.scene.zones.first { $0.zone.id == zone }?.rect)
        #expect(ImageExporter.contentRect(m, canvas: "c1", o) == rect.insetBy(dx: -48, dy: -48).integral)
        let img = try #require(ImageExporter.image(m, canvas: "c1", o))
        #expect(abs(CGFloat(img.width) - (rect.width + 96)) <= 2 && img.width < whole.width)
        // The zone's topics are drawn; the main tree isn't.
        let svg = SVGExporter.export(m, canvas: "c1", o, SVGExporter.Options())
        #expect(svg.contains("Parking lot") && svg.contains("Later idea") && svg.contains("Ideas"))
        #expect(!svg.contains("Pricing") && !svg.contains("Positioning"))
        #expect(try XMLDocument(data: Data(svg.utf8)).rootElement() != nil)
        // An empty zone still exports its frame.
        o.zone = empty
        let emptyRect = try #require(h.controller.scene.zones.first { $0.zone.id == empty }?.rect)
        let frame = try #require(ImageExporter.image(m, canvas: "c1", o))
        #expect(abs(CGFloat(frame.width) - (emptyRect.width + 96)) <= 2)
        // PDF goes through the same scope.
        let pdf = try #require(PDFDocument(data: PrintLayout.singlePage(m, canvas: "c1", ImageExporter.Options())))
        o.zone = zone
        let zonePDF = try #require(PDFDocument(data: PrintLayout.singlePage(m, canvas: "c1", o)))
        #expect(
            zonePDF.page(at: 0)!.bounds(for: .mediaBox).width < pdf.page(at: 0)!.bounds(for: .mediaBox).width)
    }

    @Test func zoneCommandsMenuAndPanelEntryPoints() throws {
        let (h, zone, _) = try zoneHarness()
        // No zone in play: the commands are hidden from ⌘K.
        h.controller.select(node(h, "Pricing"))
        #expect(!h.controller.canPerform(.exportZone) && !h.controller.canPerform(.printZone))
        h.press("cmd+k")
        h.type("zone")
        #expect(!h.controller.paletteRows.contains { $0.id == CommandID.exportZone.rawValue })
        h.controller.closePalette()
        // A topic inside the zone is enough.
        h.controller.select(node(h, "Later idea"))
        #expect(h.controller.targetZone == zone)
        h.press("cmd+k")
        h.type("zone")
        let rows = h.controller.paletteRows.map(\.id)
        #expect(rows.contains(CommandID.exportZone.rawValue) && rows.contains(CommandID.printZone.rawValue))
        h.controller.closePalette()

        // Right-clicking the zone's title bar: its context menu.
        let rect = try #require(h.controller.scene.zones.first { $0.zone.id == zone }?.rect)
        let v = h.host.canvasView
        let at = v.convert(v.camera.toView(CGPoint(x: rect.minX + 60, y: rect.minY + 12)), to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: at, modifierFlags: [], timestamp: 0,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(v.menu(for: event))
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Export Zone…") && titles.contains("Print Zone…"))
        #expect(h.controller.selectedElement == .zone(zone))
        let export = try #require(menu.items.first { $0.title == "Export Zone…" })
        #expect(v.validateMenuItem(export))

        // Export Zone…: the sheet opens on a visual format, scoped to the zone.
        v.performRegistryCommand(export)
        let s = try #require(h.controller.exportState)
        #expect(s.format.isVisual && s.image.scope == .zone && s.image.zone == zone)
        // Switching format keeps the zone; the scope isn't remembered for next time.
        var svg = s
        svg.format = .svg
        h.controller.setExport(svg)
        #expect(h.controller.exportState?.image.scope == .zone)
        var png = h.controller.exportState!
        png.format = .png
        h.controller.setExport(png)
        var saved: (Data, String)?
        h.controller.onSaveFile = { saved = ($0, $1) }
        h.controller.runExport(h.controller.exportState!)
        #expect(saved?.1 == "Launch plan – Ideas.png")
        #expect(saved.map { NSImage(data: $0.0) != nil } == true)
        #expect(ExportState.remembered(.png, prefs: h.controller.prefs).image.scope != .zone)

        // Print Zone…: the zone alone, its own notes in the appendix.
        h.controller.selectElement(.zone(zone))
        #expect(h.controller.perform(.printZone))
        let p = try #require(h.controller.printState)
        #expect(p.content == .zone && p.zone == zone)
        var po = p
        po.notesAppendix = true
        po.fitPage = true
        let out = h.controller.printPDF(po)
        #expect(out.pages == 2, "the zone's page and its notes")
        let text = PDFDocument(data: out.data)?.string ?? ""
        #expect(text.contains("Launch plan – Ideas") && text.contains("Parking lot › Later idea"))
        #expect(!text.contains("Pricing"), "only the zone's notes")
        h.controller.closePrint()

        // The Format panel's zone section has both buttons.
        h.controller.exportZone(zone)
        #expect(h.controller.exportState?.image.zone == zone)
        h.controller.closeExport()
        h.controller.printZone(zone)
        #expect(h.controller.printState?.zone == zone)
    }

    @Test func excelExportFromTheSheet() throws {
        let h = harness()
        var s = ExportState.remembered(.excel)
        s.format = .excel
        let data = try #require(h.controller.exportData(s))
        let files = try Zip.read(data)
        #expect(files["xl/workbook.xml"] != nil && files["xl/worksheets/sheet1.xml"] != nil)
        #expect(h.controller.exportText(s)?.hasPrefix("Level\tPath\tTopic") == true)
        var saved: (Data, String)?
        h.controller.onSaveFile = { saved = ($0, $1) }
        h.controller.runExport(s)
        #expect(saved?.1 == "Launch plan.xlsx")
    }
}
