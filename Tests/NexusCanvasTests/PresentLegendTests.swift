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
        // The canvas's own box steps aside; each slide's corner legend lists that slide's
        // markers (M28: the Ideas slide has none, so it has no legend).
        #expect(h.controller.scene.legend == nil, "not drawn on the stage while presenting")
        let rows = h.controller.slides.map { h.controller.presentLegend(for: $0)?.rows.map(\.text) }
        #expect(rows == [["Priority 1", "Blocked", "Q4"], ["Blocked"], ["Priority 1", "Q4"], nil])
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
        // The bottom-left corner (above the 64 pt margin) holds the legend on every slide
        // with markers; the Ideas slide has none, so its corner is the stage (M28).
        let corner = CGRect(x: 84, y: 1080 - 64 - 200, width: 300, height: 200)
        for i in 0..<3 {
            #expect(Self.differing(withLegend[i], without[i], in: corner) > 2000, "slide \(i + 1)")
        }
        #expect(Self.differing(withLegend[3], without[3], in: corner) == 0, "Ideas: no legend")
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

    // MARK: M28 · Legend fit

    /// A marked topic in each far corner of the map, so the title slide fills the stage and
    /// puts "Bottom left" in the legend's corner. "Notes" has no markers.
    static func cornerDocument() -> DocumentModel {
        var c = Canvas(id: "c1", title: "Corners", rootText: "Plan")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            _ = try! e.addChild(of: e.canvas.root, text: "Notes")
            let low = e.addFloating(at: CanvasPoint(x: -900, y: 500), text: "Bottom left")
            let high = e.addFloating(at: CanvasPoint(x: 900, y: -500), text: "Top right")
            e.update(low) { $0.markers = ["flag-red"] }
            e.update(high) { $0.markers = ["priority-1"] }
            e.updateMeta { $0.legend = Legend() }
        }
        return DocumentModel(canvases: [c])
    }

    @Test func slideFitMovesOnlyWhenTheLegendCoversATopic() {
        let stage = CGRect(x: 100, y: 100, width: 1600, height: 900)
        let legend = CGRect(x: 60, y: 850, width: 300, height: 160)
        let away = [
            CGRect(x: 0, y: 0, width: 100, height: 40), CGRect(x: 1500, y: 0, width: 100, height: 40),
            CGRect(x: 800, y: 860, width: 100, height: 40),
        ]
        let content = away.reduce(CGRect.null) { $0.union($1) }
        let plain = SlideFit.camera(content, in: stage)
        #expect(plain.zoom == 1 && plain.offset == CGPoint(x: 100, y: 100))
        // Nothing under the legend: the whole-stage fit, as before.
        #expect(SlideFit.camera(content, topics: away, stage: stage, legend: legend) == plain)
        #expect(SlideFit.camera(content, topics: away, stage: stage, legend: nil) == plain)
        // A topic in the corner: the larger of the fits above and beside the legend.
        let corner = away + [CGRect(x: 0, y: 860, width: 100, height: 40)]
        #expect(corner.contains { plain.toView($0).intersects(legend) })
        let c = SlideFit.camera(content, topics: corner, stage: stage, legend: legend)
        #expect(
            !corner.contains { c.toView($0).intersects(legend.insetBy(dx: -SlideFit.gap / 2, dy: -SlideFit.gap / 2)) })
        #expect(abs(c.zoom - (1700 - 372) / 1600) < 0.001, "beside the legend is roomier than above it")
        #expect(stage.contains(c.toView(content)))
    }

    @Test func slidesFrameTheirTopicsClearOfTheLegend() throws {
        let h = harness(Self.cornerDocument())
        let v = h.host.canvasView
        h.press("shift+cmd+p")
        h.press("f")  // Stage only: the stage reaches down into the legend's corner.
        let slide = h.controller.slides[0]
        let legend = try #require(v.presentLegendRect())
        let topics = slide.focus.compactMap { h.controller.scene.nodes[$0]?.frame.rect }
        let content = topics.reduce(CGRect.null) { $0.union($1) }
        let stage = v.stageRect(aspect: h.canvas.presentation.aspectRatio)
        // Fitting the whole stage would put "Bottom left" under the legend…
        let plain = SlideFit.camera(content, in: stage)
        #expect(topics.contains { plain.toView($0).intersects(legend) })
        // …so the slide fits around it, inside the stage.
        for r in topics {
            #expect(!v.camera.toView(r).intersects(legend))
            #expect(stage.insetBy(dx: -1, dy: -1).contains(v.camera.toView(r)))
        }
        #expect(v.camera.zoom <= plain.zoom)
        // The legend sits on the progress dots' line, left of them.
        let dots = 22 + CGFloat(h.controller.slides.count - 1) * 13
        #expect(abs(legend.maxY - (v.bounds.height - 28)) < 0.01 && legend.maxX < v.bounds.width - 56 - dots)
        // With the strip, the legend sits just above it.
        h.press("f")
        let above = try #require(v.presentLegendRect())
        #expect(abs(above.maxY - (v.bounds.height - 28 - SlideStripView.height)) < 0.01)
        #expect(!topics.contains { v.camera.toView($0).intersects(above) })
        // The Notes slide has no markers, so no legend and nothing to avoid.
        h.controller.goToSlide(1)
        #expect(v.presentLegendRect() == nil)
        // Exported slides frame around the legend's place on a 1920 × 1080 slide.
        let prefs = Preferences.isolated()
        prefs.set("appearance.followSystem", false)
        var checked = 0
        let images = SlideExporter.renderSlides(Self.cornerDocument(), canvas: "c1", prefs: prefs) { view, s in
            guard let box = view.presentLegendRect(), let l = view.controller.presentLegend(for: s) else { return }
            #expect(box == PresentLegendPlacement.export(SlideExporter.size).rect(l, in: SlideExporter.size))
            let rects = s.focus.compactMap { view.controller.scene.nodes[$0]?.frame.rect }
            let full = SlideFit.camera(
                rects.reduce(CGRect.null) { $0.union($1) }, in: view.stageRect(aspect: 16.0 / 9))
            #expect(rects.contains { full.toView($0).intersects(box) }, "the plain fit would cover a topic")
            #expect(!rects.contains { view.camera.toView($0).intersects(box) })
            checked += 1
        }
        #expect(images.count == 2 && checked == 1)
    }

    @Test func eachSlidesLegendListsItsOwnMarkers() throws {
        let h = harness()
        h.press("shift+cmd+p")
        func slide(_ t: String) -> Slide? { h.controller.slides.first { $0.title == t } }
        let launch = try #require(slide("Launch"))
        // VoiceOver reads what the slide shows.
        let spoken = try #require(h.controller.presentLegend(for: launch)?.spoken)
        #expect(spoken.contains("Priority 1") && spoken.contains("Q4") && !spoken.contains("Blocked"))
        // A merged slide lists both slides' markers, in the legend's order.
        let build = try #require(h.controller.slides.firstIndex { $0.title == "Build" })
        h.controller.goToSlide(build)
        h.press("m")
        let merged = try #require(slide("Build · Launch"))
        #expect(h.controller.presentLegend(for: merged)?.rows.map(\.text) == ["Priority 1", "Blocked", "Q4"])
        h.undo.undo(h.store)
        #expect(slide("Build") != nil)
        // A topic hidden from slides, or under a fold, takes its markers with it.
        let design = id(h, "Design")
        h.controller.perform("Hide") { $0.update(design) { $0.presentHidden = true } }
        #expect(h.controller.presentLegend(for: try #require(slide("Build"))) == nil)
        #expect(h.controller.presentLegend(for: h.controller.slides[0])?.rows.map(\.text) == ["Priority 1", "Q4"])
        h.controller.perform("Show") { $0.update(design) { $0.presentHidden = false } }
        let buildID = id(h, "Build")
        h.controller.perform("Fold") { try $0.toggleFold(buildID) }
        #expect(h.controller.presentLegend(for: try #require(slide("Build"))) == nil)
        // A canvas legend that lists nothing yet stays off the slides.
        var doc = LegendTests.document(legend: Legend())
        doc.canvases["c1"]!.nodes = doc.canvases["c1"]!.nodes.mapValues { n in
            var n = n
            n.markers = []
            n.labels = []
            return n
        }
        let blank = harness(doc)
        blank.press("shift+cmd+p")
        #expect(blank.controller.slides.allSatisfy { blank.controller.presentLegend(for: $0) == nil })
    }

    @Test func diagramDecksCloseWithATimelineSlide() throws {
        var flow = TechSamples.flowchart()
        var u = UndoStack()
        flow.edit("Tasks", undo: &u) { e in
            let email = e.canvas.nodes.first { $0.value.text == "Enter email" }!.key
            let send = e.canvas.nodes.first { $0.value.text == "Email the link" }!.key
            e.updateTask(email) {
                $0.start = d("2026-11-02")
                $0.due = d("2026-11-03")
                $0.owner = "Ana"
            }
            e.updateTask(send) { $0.due = d("2026-11-06") }
        }
        let h = harness(DocumentModel(canvases: [flow]))
        h.press("shift+cmd+p")
        let before = h.controller.slides.map(\.id)
        #expect(before.first == "title" && before.dropFirst().allSatisfy { $0.hasPrefix("flow:") })
        h.press("t")
        let root = h.canvas.root
        #expect(h.controller.slides.map(\.id) == before + ["timeline:\(root.rawValue)"])
        let slide = try #require(h.controller.slides.last)
        #expect(h.controller.slideTitle(slide) == "Forgot password · Timeline")
        #expect(slide.kicker.hasSuffix("STEP \(before.count) OF \(before.count)"))
        let chart = try #require(h.controller.timelineChart(for: slide))
        let rows = chart.renderer.layout.rows.map(\.id)
        #expect(rows.contains(id(h, "Enter email")) && rows.contains(id(h, "Email the link")))
        let spoken = h.controller.timelineSpoken(slide)
        #expect(spoken.hasPrefix("Timeline for Forgot password: Enter email, ⚠︎ Ana · "))
        #expect(spoken.contains("Email the link, ◆ "))
        #expect(h.controller.presentLegend(for: slide) == nil && h.controller.slideTaskLine(slide) == nil)
        // Sequences close the same way, and exports draw it as a chart.
        var seq = TechSamples.sequence()
        seq.edit("Task", undo: &u) { e in
            let auth = e.canvas.nodes.first { $0.value.text == "Auth service" }!.key
            e.updateTask(auth) {
                $0.start = d("2026-11-02")
                $0.due = d("2026-11-04")
            }
            e.updateMeta { $0.presentation.timeline = true }
        }
        #expect(Deck.slides(seq).last?.id == "timeline:\(seq.root.rawValue)")
        let prefs = Preferences.isolated()
        prefs.set("appearance.followSystem", false)
        let images = SlideExporter.renderSlides(
            DocumentModel(canvases: [seq]), canvas: "c1", prefs: prefs, today: d("2026-11-04"))
        #expect(images.count == Deck.slides(seq).count)
        let middle = CGRect(x: 400, y: 400, width: 1100, height: 300)
        #expect(Self.differing(images[images.count - 1], images[images.count - 2], in: middle) > 5000)
        // Without dated tasks, nothing changes.
        var plain = TechSamples.flowchart()
        plain.presentation.timeline = true
        #expect(!Deck.slides(plain).contains { $0.timeline != nil })
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
        // M28: a slide framed around the legend, and a flowchart's closing Timeline.
        for (i, img) in SlideExporter.renderSlides(Self.cornerDocument(), canvas: "c1", prefs: prefs).enumerated() {
            try ImageExporter.png(img).write(to: dir.appending(path: "m28-corner\(i + 1).png"))
        }
        var flow = TechSamples.flowchart()
        var u = UndoStack()
        flow.edit("Tasks", undo: &u) { e in
            for (k, t) in ["Enter email", "Create reset token", "Email the link"].enumerated() {
                let n = e.canvas.nodes.first { $0.value.text == t }!.key
                e.updateTask(n) {
                    $0.start = d("2026-11-02").adding(days: k * 2)
                    $0.due = d("2026-11-03").adding(days: k * 2)
                }
            }
            e.updateMeta { $0.presentation.timeline = true }
        }
        let deck = SlideExporter.renderSlides(
            DocumentModel(canvases: [flow]), canvas: "c1", prefs: prefs, today: d("2026-11-04"))
        if let last = deck.last { try ImageExporter.png(last).write(to: dir.appending(path: "m28-flow-timeline.png")) }
        // The screen with the stage alone, framed around the legend.
        let h = harness(Self.cornerDocument())
        h.press("shift+cmd+p")
        h.press("f")
        h.snapshot(to: dir.appending(path: "m28-screen-stage.png"))
        h.press("f")
        h.snapshot(to: dir.appending(path: "m28-screen-strip.png"))
        h.window.orderOut(nil)
    }
}
