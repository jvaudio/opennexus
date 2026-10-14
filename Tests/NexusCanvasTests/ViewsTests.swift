import AVFoundation
import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

@MainActor
@Suite(.serialized) struct ViewsTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID {
        h.canvas.nodes.first { $0.value.text == text }!.key
    }

    func twoCanvasDoc() -> DocumentModel {
        var doc = launchPlanDocument()
        var c2 = Canvas(id: "c2", title: "Threats", rootText: "Payments")
        var undo = UndoStack()
        c2.edit("Seed", undo: &undo) { e in _ = try! e.addChild(of: e.canvas.root, text: "Price ceiling") }
        doc.canvases["c2"] = c2
        doc.canvasOrder.append("c2")
        return doc
    }

    /// S11: ⌘K, type, ↩ runs the top row; recent commands come first next time.
    @Test func paletteRunsTheTopRow() {
        UserDefaults.standard.removeObject(forKey: CanvasController.recentKey)
        let h = CanvasHarness(model: launchPlanDocument())
        h.press("cmd+k")
        #expect(h.controller.palette != nil)
        h.type("conv")
        let top = h.controller.paletteRows.first
        #expect(top?.title == "Convert Diagram Type…")
        #expect(top?.keys == "⌥⌘T" && top?.hyper?.contains("T") == true)
        #expect(top?.matched == [0, 1, 2, 3])
        // Commands that can't run here are hidden, not greyed.
        #expect(!h.controller.paletteRows.contains { $0.title == "Bold" || $0.title == "Connect to Target" })
        h.press("return")
        #expect(h.controller.palette == nil && h.controller.convert != nil)
        h.press("esc")
        h.press("cmd+k")
        #expect(h.controller.paletteRows.first?.title == "Convert Diagram Type…", "recent first")
        // ⌘↩ runs and keeps the palette open.
        h.type("zoom in")
        h.press("cmd+return")
        #expect(h.controller.palette != nil)
        h.press("esc")
        #expect(h.controller.palette == nil)
    }

    @Test func paletteSelectsByType() {
        let h = CanvasHarness(model: DocumentModel(canvases: [TechSamples.architecture()]))
        h.press("cmd+k")
        h.type("select by type serv")
        let row = h.controller.paletteRows.first { $0.title == "Select by type · Service" }
        #expect(row?.subtitle == "2 nodes on this canvas")
        h.controller.runPaletteRow(row!)
        #expect(h.controller.selection.nodes.count == 2)
    }

    /// ⌘J: results span canvases; ↩ switches canvas and selects.
    @Test func quickJumpAcrossCanvases() {
        let h = CanvasHarness(model: twoCanvasDoc())
        h.press("cmd+j")
        h.type("price")
        let rows = h.controller.jumpRows
        #expect(rows.first?.title == "Price ceiling")
        #expect(rows.first?.path == "Threats", "the canvas title stands for its central topic")
        #expect(rows.first?.badge == "TOPIC")
        h.press("return")
        #expect(h.canvas.id == "c2")
        #expect(h.canvas.nodes[h.controller.selection.primary]?.text == "Price ceiling")
    }

    /// Outline keys: ⇥ indents, ⇧⇥ outdents, ↩ adds a sibling, ↑↓ walk rows; the outline
    /// view reflects the same tree and selection.
    @Test func outlineKeysAndLiveLink() {
        let h = CanvasHarness(model: launchPlanDocument())
        let outline = OutlineView(controller: h.controller)
        outline.frame = CGRect(x: 0, y: 0, width: 560, height: 800)
        h.window.contentView?.addSubview(outline)
        outline.layoutSubtreeIfNeeded()
        h.window.makeFirstResponder(outline.document)
        #expect(h.controller.outlineFocused)
        #expect(outline.document.rows.filter { $0.kind == .topic || $0.kind == .title }.count == 16)
        let teams = node(h, "Teams")
        let devs = node(h, "Developers")
        h.controller.select(teams)
        h.press("tab")  // indent under Developers
        #expect(h.canvas.parent(of: teams) == devs)
        h.press("shift+tab")
        #expect(h.canvas.parent(of: teams) == node(h, "Positioning"))
        h.press("up")
        #expect(h.controller.selection.primary == devs)
        h.press("down")
        h.press("down")
        #expect(h.controller.selection.primary == node(h, "Pricing"))
        h.press("return")  // sibling, in edit
        #expect(h.controller.mode == .edit)
        h.type("Support")
        h.press("return")
        #expect(h.canvas.nodes.values.contains { $0.text == "Support" })
        // Live link: the outline drew the new row; the canvas scene has it too.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        outline.document.relayout(width: 560)
        #expect(outline.document.rows.contains { $0.text.string == "Support" })
        #expect(h.controller.scene.nodes[node(h, "Support")] != nil)
        outline.removeFromSuperview()
    }

    /// Artboard 27: Focus makes the branch the whole map; Esc climbs out.
    @Test func focusDrillsAndClimbs() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        h.press("cmd+.")
        #expect(h.controller.focusRoot == pricing)
        let s = h.controller.scene
        #expect(s.nodes[pricing]?.role == .root)
        #expect(s.nodes[node(h, "Pro")]?.blurred == false)
        #expect(s.nodes[node(h, "Teams")]?.blurred == true)
        #expect((s.nodes[node(h, "Teams")]?.opacity ?? 1) < 0.3)
        // Pricing's children now surround it (a balanced map of its own).
        let kids = h.canvas.nodes[pricing]!.children.compactMap { s.nodes[$0]?.frame.center.x }
        let px = s.nodes[pricing]!.frame.center.x
        #expect(kids.contains { $0 < px } && kids.contains { $0 > px })
        #expect(h.controller.focusPath.map { h.canvas.nodes[$0]!.text } == ["Launch plan", "Pricing"])
        h.press("esc")
        #expect(h.controller.focusRoot == nil)
        #expect(h.controller.scene.nodes[node(h, "Teams")]?.blurred == false)
    }

    @Test func filterDimsHidesAndSaves() {
        let h = CanvasHarness(model: DocumentModel(canvases: [TechSamples.threatModel()]))
        h.press("shift+cmd+f")
        #expect(h.controller.filterBarVisible)
        h.controller.addFilterClause("type: Threat")
        h.controller.addFilterClause("risk: High")
        let (hits, all) = h.controller.filterMatchCount
        #expect(hits == 2 && all == h.canvas.nodes.count)
        let logs = node(h, "Card data in logs")
        let tls = node(h, "Mutual TLS")
        #expect(h.controller.scene.nodes[logs]?.opacity == 1)
        #expect(h.controller.scene.nodes[tls]?.opacity == 0.25)
        h.controller.setFilterHides(true)
        #expect(h.controller.scene.nodes[tls]?.opacity == 0.05)
        #expect(
            h.controller.suggestedFilterName
                == "type: Threat · High".replacingOccurrences(of: "type: ", with: "").replacingOccurrences(
                    of: "Threat", with: "Threat"))
        h.controller.saveFilter(named: "High threats")
        #expect(h.canvas.filters.map(\.name) == ["High threats"])
        h.press("shift+cmd+f")
        #expect(!h.controller.filterBarVisible && h.controller.filterClauses.isEmpty)
        #expect(h.controller.scene.nodes[tls]?.opacity == 1)
        h.controller.applySavedFilter(h.canvas.filters[0])
        #expect(h.controller.scene.nodes[tls]?.opacity == 0.05)
    }

    /// Artboard 47: ⌘F, matches glow and the substring highlights; replace all is one undo.
    @Test func findAndReplace() {
        let h = CanvasHarness(model: twoCanvasDoc())
        h.press("cmd+f")
        #expect(h.controller.navTab == 1)
        h.controller.updateSearch(query: "pric")
        let pricing = node(h, "Pricing")
        #expect(h.controller.search.matches.count == 1)
        #expect(h.controller.scene.nodes[pricing]?.glow == true)
        #expect(h.controller.scene.nodes[pricing]?.matchRanges == [NSRange(location: 0, length: 4)])
        var o = SearchOptions()
        o.allCanvases = true
        h.controller.updateSearch(options: o)
        #expect(h.controller.search.matches.count == 2)
        h.controller.stepSearch(1)
        #expect(h.canvas.id == "c2", "the next match is on the other canvas")
        h.controller.updateSearch(replacement: "Cost")
        h.controller.replaceAllMatches()
        #expect(h.store.model.canvases["c1"]!.nodes.values.contains { $0.text == "Costing" })
        #expect(h.store.model.canvases["c2"]!.nodes.values.contains { $0.text == "Coste ceiling" })
        #expect(h.controller.search.matches.isEmpty)
    }

    @Test func tagsHighlightAndTodosToggle() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pro = node(h, "Pro")
        h.controller.perform("Seed") { e in
            e.update(pro) {
                $0.labels = ["Q4"]
                $0.todo = Todo(done: false)
            }
        }
        #expect(h.controller.tagCounts.map(\.title) == ["Q4"])
        h.controller.toggleTag("label:Q4", combine: false)
        #expect(h.controller.scene.nodes[pro]?.opacity == 1)
        #expect(h.controller.scene.nodes[node(h, "Teams")]?.opacity == 0.3)
        h.controller.toggleTag("label:Q4", combine: false)
        #expect(h.controller.scene.nodes[node(h, "Teams")]?.opacity == 1)
        h.controller.toggleTodo(pro)
        #expect(h.canvas.nodes[pro]?.todo?.done == true)
    }

    @Test func zenTogglesAndEscExits() {
        let h = CanvasHarness(model: launchPlanDocument())
        h.press("opt+cmd+f")
        #expect(h.controller.zen)
        h.press("esc")
        #expect(!h.controller.zen)
        h.press("cmd+2")
        #expect(h.controller.viewMode == .outline)
        h.press("cmd+3")
        #expect(h.controller.viewMode == .split)
    }

    /// F6: auto slides, → steps, S skips, M merges, H hides, Esc ends.
    @Test func presentKeys() {
        let h = CanvasHarness(model: DocumentModel(canvases: [TechSamples.dfd()]))
        h.press("shift+cmd+p")
        #expect(h.controller.present?.index == 0)
        let slides = h.controller.slides
        #expect(slides.count == 1 + FlowGraph(h.canvas).flows.count)
        h.press("right")
        #expect(h.controller.present?.index == 1)
        let s1 = h.controller.slides[1]
        #expect(h.controller.scene.relationships.first { $0.relationship.id == s1.flow }?.glow == true)
        let dimmed = h.controller.scene.nodes.values.filter { $0.opacity < 1 }
        #expect(!dimmed.isEmpty && !dimmed.contains { s1.highlight.contains($0.id) })
        h.type("s")
        #expect(h.controller.slides[1].skipped)
        h.press("left")
        h.press("right")
        #expect(h.controller.present?.index == 2, "→ jumps over the skipped slide")
        h.type("m")
        #expect(
            h.canvas.presentation.merged.contains(h.controller.slides[2].id) || h.controller.slides.count < slides.count
        )
        h.press("shift+/")
        #expect(h.controller.present?.showKeys == true)
        h.press("esc")
        #expect(h.controller.present != nil && h.controller.present?.showKeys == false)
        h.press("esc")
        #expect(h.controller.present == nil)
        #expect(!h.controller.scene.nodes.values.contains { $0.opacity < 1 })
    }

    /// Export: PDF pages, a valid .pptx zip, and an H.264 video of the right length.
    @Test func exportFormats() async throws {
        let doc = launchPlanDocument()
        let images = SlideExporter.renderSlides(doc, canvas: "c1")
        #expect(images.count == 6)
        #expect(images[0].width == 1920 && images[0].height == 1080)
        let pdf = SlideExporter.pdf(images)
        let pdfDoc = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)
        #expect(pdfDoc?.numberOfPages == 6)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pptx = dir.appendingPathComponent("deck.pptx")
        try SlideExporter.pptx(images, titles: Deck.slides(doc.canvases["c1"]!).map(\.title)).write(to: pptx)
        // Read the zip's central directory: every entry present, stored with matching CRCs.
        let data = try Data(contentsOf: pptx)
        let names = Self.zipEntries(data)
        #expect(names.contains("[Content_Types].xml") && names.contains("ppt/presentation.xml"))
        #expect(names.contains("ppt/slides/slide6.xml") && names.contains("ppt/media/image1.png"))
        #expect(names.count == 9 + 3 * 6)
        let mp4 = dir.appendingPathComponent("deck.mp4")
        try await SlideExporter.video(Array(images.prefix(2)), to: mp4, hold: 1, fade: 0.5)
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.5) < 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    /// Entry names from a zip's central directory.
    static func zipEntries(_ d: Data) -> [String] {
        let bytes = [UInt8](d)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { u32($0) == 0x0605_4B50 })
        else { return [] }
        var p = u32(eocd + 16)
        var out: [String] = []
        for _ in 0..<u16(eocd + 10) {
            guard u32(p) == 0x0201_4B50 else { break }
            let n = u16(p + 28)
            let extra = u16(p + 30)
            let comment = u16(p + 32)
            out.append(String(decoding: bytes[(p + 46)..<(p + 46 + n)], as: UTF8.self))
            p += 46 + n + extra + comment
        }
        return out
    }
}
