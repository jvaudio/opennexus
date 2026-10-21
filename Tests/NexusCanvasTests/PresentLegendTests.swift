import AVFoundation
import AppKit
import Foundation
import NexusCore
import NexusKeys
import Testing

@testable import NexusCanvas

private func d(_ s: String) -> TaskDate { TaskDate(s)! }

/// M21: the legend and task details in Present and its exports, and moving the legend
/// from the keyboard and VoiceOver.
@MainActor
@Suite(.serialized) struct PresentLegendTests {
    /// The Gantt fixture (Build › Design, Code, Docs; Launch; Ideas) with markers and a legend.
    static func document(legend: Legend? = Legend(markers: ["flag-red": "Blocked"])) -> DocumentModel {
        var doc = ganttDocument()
        var c = doc.canvases["c1"]!
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let design = e.canvas.nodes.first { $0.value.text == "Design" }!.key
            let launch = e.canvas.nodes.first { $0.value.text == "Launch" }!.key
            e.update(design) { $0.markers = ["flag-red"] }
            e.update(launch) {
                $0.markers = ["priority-1"]
                $0.labels = ["Q4"]
            }
            e.updateMeta { $0.legend = legend }
        }
        doc.canvases["c1"] = c
        return doc
    }

    func harness(_ doc: DocumentModel = document()) -> CanvasHarness {
        let h = CanvasHarness(model: doc)
        h.controller.today = d("2026-11-04")
        return h
    }

    func id(_ h: CanvasHarness, _ t: String) -> NodeID { h.canvas.nodes.first { $0.value.text == t }!.key }

    // MARK: 1 · The legend in Present

    @Test func slidesShowTheLegendInTheCornerPerTheSetting() throws {
        let h = harness()
        #expect(h.controller.scene.legend != nil)
        h.press("shift+cmd+p")
        // The canvas's own box steps aside; every slide gets the corner legend.
        #expect(h.controller.scene.legend == nil, "not drawn on the stage while presenting")
        for s in h.controller.slides {
            let l = try #require(h.controller.presentLegend(for: s), "\(s.title)")
            #expect(l.rows.map(\.text) == ["Priority 1", "Blocked", "Q4"])
        }
        // L turns it off (one undo step, saved in the deck settings) and back on.
        let depth = h.undo.stack.undoStack.count
        h.press("l")
        #expect(h.canvas.presentation.legend == false)
        #expect(h.controller.slides.allSatisfy { h.controller.presentLegend(for: $0) == nil })
        #expect(h.undo.stack.undoStack.count == depth + 1)
        #expect(h.canvas.presentation.json.objectValue?["legend"] == .bool(false))
        let back = try PresentationSettings(json: h.canvas.presentation.json, path: "p")
        #expect(back == h.canvas.presentation)
        h.press("l")
        #expect(h.canvas.presentation.legend && h.canvas.presentation.isDefault, "the default writes nothing")
        h.press("escape")
        #expect(h.controller.present == nil && h.controller.scene.legend != nil)
        // A canvas without a visible legend has nothing to show, and L says so.
        let none = harness(Self.document(legend: Legend(visible: false)))
        none.press("shift+cmd+p")
        #expect(none.controller.slides.allSatisfy { none.controller.presentLegend(for: $0) == nil })
        none.press("l")
        #expect(none.canvas.presentation.legend, "nothing to toggle")
        #expect(none.controller.toast?.text.contains("no legend") == true)
    }

    // MARK: 2 · Task details

    @Test func taskSlidesShowTheirTaskLine() throws {
        let h = harness()
        h.press("shift+cmd+p")
        let slides = h.controller.slides
        let launch = try #require(slides.first { $0.title == "Launch" })
        let due = TaskFormat.day(d("2026-11-24"), today: d("2026-11-04"))
        #expect(h.controller.slideTaskLine(launch) == "◆ \(due) · 0%")
        let ideas = try #require(slides.first { $0.title == "Ideas" })
        #expect(h.controller.slideTaskLine(ideas) == nil, "not a task")
        // The Build slide's topics carry their own lines on the stage, as on the canvas.
        let build = try #require(slides.firstIndex { $0.title == "Build" })
        h.controller.goToSlide(build)
        let pinned = try #require(h.controller.scene.nodes[id(h, "Design")]?.pinned)
        #expect(pinned.contains { $0.key == "◷" && $0.value.hasPrefix("Ana · ") })
        // Settings › Show task details on topics turns both off.
        h.controller.prefs.set("editing.taskDetails", false)
        h.controller.goToSlide(build)
        #expect(h.controller.slideTaskLine(launch) == nil)
        #expect(h.controller.scene.nodes[id(h, "Design")]?.pinned.isEmpty == true)
    }

    @Test func timelineSlidesFollowBranchesWithDatedTasks() throws {
        let h = harness()
        h.press("shift+cmd+p")
        let before = h.controller.slides.map(\.id)
        #expect(!before.contains { $0.hasPrefix("timeline:") }, "off by default")
        h.press("t")
        #expect(h.canvas.presentation.timeline)
        let ids = h.controller.slides.map(\.id)
        let build = id(h, "Build")
        let launch = id(h, "Launch")
        #expect(
            ids == [
                "title", "branch:\(build.rawValue)", "timeline:\(build.rawValue)", "branch:\(launch.rawValue)",
                "timeline:\(launch.rawValue)", "branch:\(id(h, "Ideas").rawValue)",
            ])
        #expect(h.controller.present?.index == 0, "the current slide stays put")
        let slide = try #require(h.controller.slides.first { $0.id == "timeline:\(build.rawValue)" })
        #expect(h.controller.slideTitle(slide) == "Build · Timeline")
        #expect(h.controller.presentLegend(for: slide) == nil, "no markers on a Timeline")
        #expect(h.controller.slideTaskLine(slide) == nil)
        let chart = try #require(h.controller.timelineChart(for: slide))
        #expect(chart.renderer.layout.rows.map(\.id) == [build, id(h, "Design"), id(h, "Code"), id(h, "Docs")])
        #expect(chart.size.width < chart.renderer.layout.size.width, "only the branch's dates")
        let days = [d("2026-11-02"), d("2026-11-06")].map { TaskFormat.day($0, today: d("2026-11-04")) }
        #expect(h.controller.timelineSpoken(slide).contains("Design, Ana · \(days[0]) → \(days[1])"))
        #expect(h.canvas.presentation.json.objectValue?["timeline"] == .bool(true))
        // T again removes them.
        h.press("t")
        #expect(h.controller.slides.map(\.id) == before)
    }

    // MARK: Exports

    /// Pixels that differ between two slides inside a region (in 1920 × 1080 slide points).
    static func differing(_ a: CGImage, _ b: CGImage, in r: CGRect) -> Int {
        func bytes(_ i: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: i.width * i.height * 4)
            let ctx = CGContext(
                data: &out, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            return out
        }
        let x = bytes(a)
        let y = bytes(b)
        var n = 0
        for row in Int(r.minY)..<Int(r.maxY) {
            for col in Int(r.minX)..<Int(r.maxX) {
                let k = (row * a.width + col) * 4
                if abs(Int(x[k]) - Int(y[k])) + abs(Int(x[k + 1]) - Int(y[k + 1])) + abs(Int(x[k + 2]) - Int(y[k + 2]))
                    > 24
                {
                    n += 1
                }
            }
        }
        return n
    }

    @Test func slideExportsCarryTheLegendAndTimelines() async throws {
        let prefs = Preferences.isolated()
        prefs.set("appearance.followSystem", false)
        let on = Self.document()
        var off = on
        off.canvases["c1"]!.presentation.legend = false
        let withLegend = SlideExporter.renderSlides(on, canvas: "c1", prefs: prefs, today: d("2026-11-04"))
        let without = SlideExporter.renderSlides(off, canvas: "c1", prefs: prefs, today: d("2026-11-04"))
        #expect(withLegend.count == 4 && without.count == 4)
        // The bottom-left corner (above the 64 pt margin) holds the legend on every slide.
        let corner = CGRect(x: 84, y: 1080 - 64 - 200, width: 300, height: 200)
        for i in withLegend.indices {
            #expect(Self.differing(withLegend[i], without[i], in: corner) > 2000, "slide \(i + 1)")
        }
        // The rest of the slide is the same.
        let top = CGRect(x: 1200, y: 0, width: 700, height: 200)
        #expect(Self.differing(withLegend[1], without[1], in: top) == 0)
        // PDF, PowerPoint and video are made from these images.
        let pdf = CGPDFDocument(CGDataProvider(data: SlideExporter.pdf(withLegend) as CFData)!)
        #expect(pdf?.numberOfPages == 4)
        let pptx = SlideExporter.pptx(withLegend, titles: Deck.slides(on.canvases["c1"]!).map(\.title))
        #expect(ViewsTests.zipEntries(pptx).filter { $0.hasPrefix("ppt/media/") }.count == 4)
        let mp4 = FileManager.default.temporaryDirectory.appendingPathComponent("m21-\(UUID().uuidString).mp4")
        try await SlideExporter.video(Array(withLegend.prefix(2)), to: mp4, hold: 0.5, fade: 0.2)
        #expect(try await AVURLAsset(url: mp4).load(.duration).seconds > 1)
        // Timeline slides export as charts.
        var timeline = on
        timeline.canvases["c1"]!.presentation.timeline = true
        let charts = SlideExporter.renderSlides(timeline, canvas: "c1", prefs: prefs, today: d("2026-11-04"))
        #expect(charts.count == 6)
        let middle = CGRect(x: 400, y: 400, width: 1100, height: 300)
        #expect(Self.differing(charts[2], charts[1], in: middle) > 5000, "the Gantt fills the stage")
    }

    // MARK: 3 · Moving the legend from the keyboard

    @Test func arrowsNudgeTheSelectedLegendOneUndoStepEachPress() throws {
        let h = harness(LegendTests.document(legend: Legend()))
        let start = try #require(h.controller.scene.legend?.rect.origin)
        let topic = h.controller.selection.primary
        // Select Legend is in the palette (and the View menu); it needs a legend.
        h.controller.openPalette()
        h.type("legend")
        #expect(h.controller.paletteRows.contains { $0.id == CommandID.selectLegend.rawValue })
        #expect(!h.controller.paletteRows.contains { $0.id == CommandID.legendLeft.rawValue }, "not selected yet")
        h.controller.closePalette()
        #expect(h.controller.perform(.selectLegend))
        #expect(h.controller.legendSelected && h.controller.activeScope == .legend)
        #expect(h.host.canvasView.legendLayer.selected, "drawn with the selection ring")
        let depth = h.undo.stack.undoStack.count
        h.press("left")
        h.press("left")
        h.press("shift+down")
        let moved = try #require(h.canvas.legend?.position)
        #expect(moved == CanvasPoint(x: start.x - 20, y: start.y + 50))
        #expect(h.undo.stack.undoStack.count == depth + 3, "one undo step per press")
        #expect(h.controller.selection.primary == topic, "arrows didn't move the topic selection")
        h.undo.undo(h.store)
        #expect(h.canvas.legend?.position == CanvasPoint(x: start.x - 20, y: start.y))
        // ↩ opens the editor; Esc hands the keys back to the topics.
        var asked: [CanvasRequest] = []
        h.controller.onRequest = { asked.append($0) }
        h.press("return")
        #expect(asked == [.legend])
        h.press("escape")
        #expect(!h.controller.legendSelected && h.controller.activeScope == .canvas)
        let before = h.canvas.legend?.position
        h.press("right")
        #expect(h.canvas.legend?.position == before && h.controller.selection.primary != topic)
        // Reset Position stays, and is a command too.
        #expect(h.controller.perform(.resetLegendPosition))
        #expect(h.canvas.legend?.position == nil && h.controller.scene.legend?.rect.origin == start)
        // Another selection, or a topic command, takes the keys back.
        h.controller.selectLegend()
        h.controller.select(topic)
        #expect(!h.controller.legendSelected)
        h.controller.selectLegend()
        h.press("tab")
        #expect(!h.controller.legendSelected && h.controller.mode == .edit, "Tab adds a topic as usual")
    }

    @Test func aClickSelectsTheLegend() throws {
        let h = harness(LegendTests.document(legend: Legend()))
        let v = h.host.canvasView
        let l = try #require(h.controller.scene.legend)
        let p = v.camera.toView(CGPoint(x: l.rect.minX + 20, y: l.rect.minY + 12))
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let depth = h.undo.stack.undoStack.count
        v.mouseDown(with: event(.leftMouseDown))
        v.mouseUp(with: event(.leftMouseUp))
        #expect(h.controller.legendSelected && h.undo.stack.undoStack.count == depth)
        h.press("up")
        #expect(h.canvas.legend?.position == CanvasPoint(x: l.rect.minX, y: l.rect.minY - 10))
    }

    @Test func legendKeysHaveTheirOwnScopeWithoutConflicts() {
        #expect(CommandRegistry.standard.conflicts(custom: [:]).isEmpty)
        for p in KeyProfile.all { #expect(CommandRegistry.standard.conflicts(profile: p).isEmpty, "\(p.name)") }
        let reg = CommandRegistry.standard
        for c in [CommandID.legendLeft, .legendRight, .legendUp, .legendDown] {
            #expect(reg[c]?.scope == .legend && reg[c]?.keys.count == 1)
        }
        #expect(reg[.legendLeftFar]?.keys == [KeyChord("shift+left")!])
        #expect(reg[.selectLegend]?.menu == .view && reg[.resetLegendPosition]?.menu == .view)
    }

    @Test func voiceOverMovesAndFocusesIt() throws {
        let h = harness(LegendTests.document(legend: Legend()))
        let item = try #require(h.host.canvasView.accessibilityTree.roots().last as? LegendItem)
        let start = try #require(h.controller.scene.legend?.rect.origin)
        let names = item.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(
            names == [
                "Edit Legend", "Hide Legend", "Move Legend Left", "Move Legend Right", "Move Legend Up",
                "Move Legend Down",
            ])
        let depth = h.undo.stack.undoStack.count
        let right = try #require(item.accessibilityCustomActions()?.first { $0.name == "Move Legend Right" })
        #expect(right.handler?() == true)
        #expect(h.canvas.legend?.position == CanvasPoint(x: start.x + 10, y: start.y))
        #expect(h.undo.stack.undoStack.count == depth + 1)
        #expect(item.accessibilityFrame().width > 0)
        #expect(item.accessibilityCustomActions()?.last?.name == "Reset Legend Position")
        // Focusing it selects it, so the arrow keys move it.
        item.setAccessibilityFocused(true)
        #expect(h.controller.legendSelected && item.isAccessibilityFocused())
        h.press("down")
        #expect(h.canvas.legend?.position == CanvasPoint(x: start.x + 10, y: start.y + 10))
    }

    /// Visual review: NEXUS_SNAPSHOT_DIR=… writes the exported slides with the corner legend
    /// and a Timeline slide.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil)) func snapshot() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        let prefs = Preferences.isolated()
        prefs.set("appearance.followSystem", false)
        var doc = Self.document()
        doc.canvases["c1"]!.presentation.timeline = true
        let images = SlideExporter.renderSlides(doc, canvas: "c1", prefs: prefs, today: d("2026-11-04"))
        for (i, img) in images.enumerated() {
            try ImageExporter.png(img).write(to: dir.appending(path: "m21-slide\(i + 1).png"))
        }
    }
}
