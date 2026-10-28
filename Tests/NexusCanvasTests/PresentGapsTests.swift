import AppKit
import Foundation
import NexusCore
import NexusKeys
import Testing

@testable import NexusCanvas

private func d(_ s: String) -> TaskDate { TaskDate(s)! }

/// M35 · Present, part 3: the legend over what a slide doesn't frame, Timeline charts
/// and the topics under them, the dots beside the legend, and the strip from the keyboard.
@MainActor
@Suite(.serialized) struct PresentGapsTests {
    static func prefs() -> Preferences {
        let p = Preferences.isolated()
        p.set("appearance.followSystem", false)
        return p
    }

    // MARK: 1 · What passes under the legend (D263)

    @Test func framingKeepsFramedLinesAndOutlinesClearOfTheLegend() {
        let stage = CGRect(x: 100, y: 100, width: 1600, height: 900)
        let legend = CGRect(x: 60, y: 850, width: 300, height: 160)
        // Topics clear of the legend, as M28 checked them…
        let topics = [
            CGRect(x: 0, y: 0, width: 100, height: 40), CGRect(x: 1500, y: 860, width: 100, height: 40),
            CGRect(x: 0, y: 700, width: 100, height: 40), CGRect(x: 400, y: 860, width: 100, height: 40),
        ]
        let content = topics.reduce(CGRect.null) { $0.union($1) }
        let plain = SlideFit.camera(content, in: stage)
        #expect(!topics.contains { plain.toView($0).intersects(legend.insetBy(dx: -6, dy: -6)) })
        #expect(SlideFit.camera(content, topics: topics, stage: stage, legend: legend) == plain)
        // …but the elbow between two of them runs under it.
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 50, y: 740))
        line.addLine(to: CGPoint(x: 50, y: 880))
        line.addLine(to: CGPoint(x: 400, y: 880))
        let moved = SlideFit.camera(content, topics: topics, lines: [line], stage: stage, legend: legend)
        #expect(moved != plain)
        var t = CGAffineTransform(a: moved.zoom, b: 0, c: 0, d: moved.zoom, tx: moved.offset.x, ty: moved.offset.y)
        let drawn = line.copy(using: &t)!.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        #expect(!drawn.intersects(CGPath(rect: legend, transform: nil)))
        #expect(stage.insetBy(dx: -1, dy: -1).contains(moved.toView(content)))
        // A zone or boundary outline framed with the topics counts as one of them.
        let zone = CGRect(x: -10, y: 690, width: 130, height: 210)
        let around = SlideFit.camera(content.union(zone), topics: topics + [zone], stage: stage, legend: legend)
        #expect(SlideFit.camera(content.union(zone), in: stage).toView(zone).intersects(legend))
        #expect(!around.toView(zone).intersects(legend))
    }

    /// The corner document, with a marker on Notes so its branch slide has a legend.
    static func notesDocument(context at: CanvasPoint? = nil) -> DocumentModel {
        var doc = PresentLegendTests.cornerDocument()
        var c = doc.canvases["c1"]!
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let notes = e.canvas.nodes.first { $0.value.text == "Notes" }!.key
            e.update(notes) { $0.markers = ["flag-red"] }
            if let at { _ = e.addFloating(at: at, text: "Context topic") }
        }
        doc.canvases["c1"] = c
        return doc
    }

    @Test func theLegendIsAnOpaqueCardOverContextTheSlideDoesntFrame() throws {
        // Where the exported Notes slide puts its legend, and the world point at the box's
        // right edge.
        var box = CGRect.null
        var spot = CanvasPoint(x: 0, y: 0)
        let before = SlideExporter.renderSlides(Self.notesDocument(), canvas: "c1", prefs: Self.prefs()) { v, s in
            guard s.title == "Notes", let b = v.presentLegendRect() else { return }
            box = b
            let w = v.camera.toWorld(CGPoint(x: b.maxX - 30, y: b.midY))
            spot = CanvasPoint(x: Double(w.x), y: Double(w.y))
        }
        #expect(!box.isNull)
        // A floating topic there is dimmed context on the Notes slide, half under the box.
        var under = false
        let after = SlideExporter.renderSlides(Self.notesDocument(context: spot), canvas: "c1", prefs: Self.prefs()) {
            v, s in
            guard s.title == "Notes",
                let id = v.controller.canvas.nodes.first(where: { $0.value.text == "Context topic" })?.key,
                let r = v.controller.scene.nodes[id]?.frame.rect
            else { return }
            #expect(!s.focus.contains(id), "not framed by the slide")
            #expect(v.presentLegendRect() == box, "the same framing and box")
            under = v.camera.toView(r).intersects(box) && v.camera.toView(r).maxX > box.maxX
        }
        #expect(under)
        #expect(before.count == 2 && after.count == 2)
        // Inside the card nothing of it shows; beside the card it is drawn.
        #expect(PresentLegendTests.differing(before[1], after[1], in: box.insetBy(dx: 12, dy: 12)) == 0)
        let beside = CGRect(x: box.maxX + 2, y: box.minY, width: 120, height: box.height)
        #expect(PresentLegendTests.differing(before[1], after[1], in: beside) > 50)
    }

    // MARK: 2 · Timeline slides (D264)

    /// A flowchart with three dated steps and Timeline slides on (M28's snapshot).
    static func flowDocument() -> DocumentModel {
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
        return DocumentModel(canvases: [flow])
    }

    @Test func timelineSlidesFrameTheirTopicsBelowTheChart() throws {
        let h = CanvasHarness(model: Self.flowDocument())
        h.controller.today = d("2026-11-04")
        let v = h.host.canvasView
        h.press("shift+cmd+p")
        let last = h.controller.slides.count - 1
        let slide = h.controller.slides[last]
        #expect(slide.timeline != nil)
        h.controller.goToSlide(last)
        for stageOnly in [false, true] {
            if h.controller.present?.stageOnly != stageOnly { h.press("f") }
            let chart = try #require(v.presentChartRect())
            let topics = slide.focus.compactMap { h.controller.scene.nodes[$0]?.frame.rect }
            let content = topics.reduce(CGRect.null) { $0.union($1) }
            let stage = v.stageRect(aspect: h.canvas.presentation.aspectRatio)
            // The whole-stage fit (M28) put the diagram's top under the chart…
            #expect(topics.contains { SlideFit.camera(content, in: stage).toView($0).intersects(chart) })
            // …now every topic is below it, inside the stage.
            for r in topics {
                let shown = v.camera.toView(r)
                #expect(shown.minY >= chart.maxY + SlideFit.chartGap - 0.5)
                #expect(stage.insetBy(dx: -1, dy: -1).contains(shown))
            }
            // The chart sits under the title and leaves room below it.
            let title = SlideTitleMetrics.screen(h.controller, slide, width: v.bounds.width)
            #expect(chart.minY >= title + 24)
            let bottom = v.bounds.height - (stageOnly ? 64 : 304)
            #expect(chart.maxY <= title + 30 + (bottom - title - 30) * TimelinePlacement.share + 0.5)
        }
        // A slide without a chart has no rectangle to avoid.
        h.controller.goToSlide(0)
        #expect(v.presentChartRect() == nil)
        // Exported slides do the same around the export's chart.
        var checked = 0
        let images = SlideExporter.renderSlides(
            Self.flowDocument(), canvas: "c1", prefs: Self.prefs(), today: d("2026-11-04")
        ) { view, s in
            guard s.timeline != nil else { return }
            let chart = try! #require(view.presentChartRect())
            let c = view.controller
            let place = TimelinePlacement.export(c, s, size: SlideExporter.size)
            #expect(chart == place.drawn(c.timelineChart(for: s)!))
            #expect(chart.minY >= SlideTitleMetrics.export(c, s, size: SlideExporter.size) + 40)
            for r in s.focus.compactMap({ c.scene.nodes[$0]?.frame.rect }) {
                #expect(view.camera.toView(r).minY >= chart.maxY + SlideFit.chartGap - 0.5)
            }
            checked += 1
        }
        #expect(checked == 1 && images.count == h.controller.slides.count)
        // Branch Timelines too (the Gantt fixture's Build and Launch).
        var gantt = PresentLegendTests.document()
        gantt.canvases["c1"]!.presentation.timeline = true
        var branches = 0
        _ = SlideExporter.renderSlides(gantt, canvas: "c1", prefs: Self.prefs(), today: d("2026-11-04")) { view, s in
            guard s.timeline != nil, let chart = view.presentChartRect() else { return }
            for r in s.focus.compactMap({ view.controller.scene.nodes[$0]?.frame.rect }) {
                #expect(view.camera.toView(r).minY >= chart.maxY + SlideFit.chartGap - 0.5)
            }
            branches += 1
        }
        #expect(branches == 2)
    }

    // MARK: 3 · The dots and the legend (D265)

    @Test func progressDotsTakeOnlyTheRoomRightOfTheLegend() {
        #expect(PresentProgress.width(PresentProgress.full, count: 60) == CGFloat(22 + 59 * 13))
        #expect(PresentProgress.style(count: 60, room: 900) == PresentProgress.full)
        #expect(PresentProgress.style(count: 60, room: 700) == PresentProgress.condensed)
        #expect(PresentProgress.style(count: 60, room: 400) == .counter)
        #expect(PresentProgress.counter(11, of: 60) == "Slide 12 of 60")
        // A 300 × 160 legend, every window from 800 pt to 2,400 pt, decks of 1 to 150.
        let legend = SceneLegend(rect: CGRect(x: 0, y: 0, width: 250, height: 133), rows: [], automatic: true)
        for width in stride(from: CGFloat(800), through: 2400, by: 50) {
            for count in [1, 8, 30, 60, 61, 90, 150] {
                let size = CGSize(width: width, height: 900)
                let place = PresentLegendPlacement.screen(stageOnly: true, viewWidth: width, slides: count)
                let box = place.rect(legend, in: size)
                let dots = PresentProgress.rect(count: count, viewSize: size, legend: box, bottom: place.bottom)
                #expect(dots.minX - box.maxX >= PresentProgress.gap - 0.5, "\(width) pt, \(count) slides")
                #expect(dots.maxX <= width - PresentProgress.trailing + 0.5)
            }
        }
        // The legend keeps its size until even the counter wouldn't fit, then narrows.
        let wide = PresentLegendPlacement.screen(stageOnly: true, viewWidth: 1200, slides: 60)
        #expect(wide.scale(legend) == 1.2)
        let narrow = PresentLegendPlacement.screen(stageOnly: true, viewWidth: 480, slides: 60)
        #expect(narrow.scale(legend) < 1.2)
        // Exports have no dots, and their legend keeps its 2×.
        #expect(PresentLegendPlacement.export(SlideExporter.size).maxWidth == .infinity)
    }

    /// A map with 64 main topics, all marked: a 65-slide deck with a legend on each.
    static func longDeck() -> DocumentModel {
        var c = Canvas(id: "c1", title: "Long", rootText: "Plan")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            for i in 1...64 {
                let n = try! e.addChild(of: e.canvas.root, text: "Topic \(i)")
                e.update(n) {
                    $0.markers = [i.isMultiple(of: 2) ? "flag-red" : "priority-1"]
                    $0.labels = ["A rather long label"]
                }
            }
            e.updateMeta { $0.legend = Legend(markers: ["flag-red": "Blocked by another team"]) }
        }
        return DocumentModel(canvases: [c])
    }

    @Test func dotsAndLegendNeverMeetInANarrowWindow() throws {
        for width in [1000.0, 1180, 1440] {
            let h = CanvasHarness(model: Self.longDeck(), width: width, height: 860)
            let v = h.host.canvasView
            h.press("shift+cmd+p")
            #expect(h.controller.slides.count == 65)
            for stageOnly in [false, true] {
                if h.controller.present?.stageOnly != stageOnly { h.press("f") }
                let box = try #require(v.presentLegendRect())
                let place = PresentLegendPlacement.screen(
                    stageOnly: stageOnly, viewWidth: v.bounds.width, slides: 65)
                let dots = PresentProgress.rect(count: 65, viewSize: v.bounds.size, legend: box, bottom: place.bottom)
                #expect(!dots.intersects(box) && dots.minX - box.maxX >= PresentProgress.gap - 0.5, "\(width)")
            }
            h.window.orderOut(nil)
        }
    }

    // MARK: 4 · The strip from the keyboard (D266)

    @Test func tabWalksTheStripsControlsAndReturnUsesThem() throws {
        let h = CanvasHarness(model: PresentLegendTests.document())
        h.controller.today = d("2026-11-04")
        h.press("shift+cmd+p")
        let ids = h.controller.stripControls.map(\.id)
        #expect(
            ids == [
                "transition.glide", "transition.zoom", "transition.cut", "legend", "timeline", "style", "depth",
                "overview", "aspect", "theme", "keys",
                "export.PDF", "export.PowerPoint", "export.Keynote", "export.Video",
            ])
        // VoiceOver labels name the control without the ✓; the state is a trait or value.
        let labels = h.controller.stripControls.map(\.label)
        #expect(labels.allSatisfy { !$0.isEmpty && !$0.contains("✓") })
        #expect(Set(labels).count == labels.count, "no two read the same")
        #expect(h.controller.stripControls.first { $0.id == "legend" }?.on == true)
        let aspect = h.controller.stripControls.first { $0.id == "aspect" }
        #expect(aspect?.label == "Aspect" && aspect?.value == "16:9")
        // ⇥ moves into the strip, one control at a time; → still changes slides.
        h.press("tab")
        #expect(h.controller.present?.stripFocus == "transition.glide")
        h.press("tab")
        #expect(h.controller.focusedStripControl?.id == "transition.zoom")
        h.press("right")
        #expect(h.controller.present?.index == 1 && h.controller.present?.stripFocus == "transition.zoom")
        // ↩ uses it (one undo step), as a click does.
        let depth = h.undo.stack.undoStack.count
        h.press("return")
        #expect(h.canvas.presentation.transition == "zoom" && h.undo.stack.undoStack.count == depth + 1)
        #expect(h.controller.present?.index == 1, "↩ didn't step the slide")
        // Space on the aspect pop-up steps to its next choice.
        while h.controller.present?.stripFocus != "aspect" { h.press("tab") }
        h.press("space")
        #expect(h.canvas.presentation.aspect == "16:10")
        // ⇧⇥ goes back (past M42's Style, Depth and Overviews); L and T keep working while a
        // control has focus.
        for _ in 0..<4 { h.press("shift+tab") }
        #expect(h.controller.present?.stripFocus == "timeline")
        h.press("l")
        #expect(h.canvas.presentation.legend == false)
        #expect(h.controller.stripControls.first { $0.id == "legend" }?.on == false)
        h.press("t")
        #expect(h.canvas.presentation.timeline)
        h.press("return")
        #expect(h.canvas.presentation.timeline == false, "the focused Timeline chip turned them off")
        // An export button asks for the export.
        var asked: [String] = []
        h.controller.onExportSlides = { asked.append($0) }
        while h.controller.present?.stripFocus != "export.Keynote" { h.press("tab") }
        h.press("return")
        #expect(asked == ["Keynote"])
        // Past the last control ⇥ hands the keys back to the slides; Esc does too, and
        // only a second Esc ends the presentation.
        h.press("tab")
        h.press("tab")
        #expect(h.controller.present?.stripFocus == nil)
        h.press("return")
        #expect(h.controller.present?.index == 2, "↩ steps slides again")
        h.press("shift+tab")
        #expect(h.controller.present?.stripFocus == "export.Video")
        h.press("escape")
        #expect(h.controller.present != nil && h.controller.present?.stripFocus == nil)
        // With the stage alone, ⇥ brings the strip back; F hides it and its focus.
        h.press("f")
        h.press("tab")
        #expect(h.controller.present?.stageOnly == false && h.controller.present?.stripFocus == "transition.glide")
        h.press("f")
        #expect(h.controller.present?.stageOnly == true && h.controller.present?.stripFocus == nil)
        h.press("escape")
        #expect(h.controller.present == nil)
    }

    @Test func diagramsListStepThroughFlowAndTheKeysListTab() {
        let h = CanvasHarness(model: DocumentModel(canvases: [TechSamples.flowchart()]))
        h.press("shift+cmd+p")
        let flow = h.controller.stripControls.first { $0.id == "flow" }
        #expect(flow?.label == "Step through flow")
        #expect(!h.controller.stripControls.contains { $0.id == "legend" || $0.id == "timeline" })
        let before = h.canvas.presentation.stepThroughFlow
        while h.controller.present?.stripFocus != "flow" { h.press("tab") }
        h.press("space")
        #expect(h.canvas.presentation.stepThroughFlow != before)
    }

    /// Visual review: NEXUS_SNAPSHOT_DIR=… writes a Timeline slide on screen and exported,
    /// a narrow window with a long deck, the strip with a focused chip, and the legend over
    /// context.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil)) func snapshot() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        let h = CanvasHarness(model: Self.flowDocument())
        h.controller.today = d("2026-11-04")
        h.press("shift+cmd+p")
        h.controller.goToSlide(h.controller.slides.count - 1)
        h.snapshot(to: dir.appending(path: "m35-timeline-strip.png"))
        h.press("f")
        h.snapshot(to: dir.appending(path: "m35-timeline-stage.png"))
        h.window.orderOut(nil)
        let gantt = SlideExporter.renderSlides(
            {
                var g = PresentLegendTests.document()
                g.canvases["c1"]!.presentation.timeline = true
                return g
            }(), canvas: "c1", prefs: Self.prefs(), today: d("2026-11-04"))
        try ImageExporter.png(gantt[2]).write(to: dir.appending(path: "m35-branch-timeline.png"))
        for width in [1000.0, 1180] {
            let n = CanvasHarness(model: Self.longDeck(), width: width, height: 860)
            n.press("shift+cmd+p")
            n.snapshot(to: dir.appending(path: "m35-dots-\(Int(width)).png"))
            n.press("tab")
            n.press("tab")
            n.press("tab")
            n.press("tab")
            n.snapshot(to: dir.appending(path: "m35-strip-focus-\(Int(width)).png"))
            n.window.orderOut(nil)
        }
        var spot = CanvasPoint(x: 0, y: 0)
        _ = SlideExporter.renderSlides(Self.notesDocument(), canvas: "c1", prefs: Self.prefs()) { v, s in
            guard s.title == "Notes", let b = v.presentLegendRect() else { return }
            let w = v.camera.toWorld(CGPoint(x: b.maxX - 30, y: b.midY))
            spot = CanvasPoint(x: Double(w.x), y: Double(w.y))
        }
        let notes = SlideExporter.renderSlides(Self.notesDocument(context: spot), canvas: "c1", prefs: Self.prefs())
        try ImageExporter.png(notes[1]).write(to: dir.appending(path: "m35-legend-card.png"))
    }
}
