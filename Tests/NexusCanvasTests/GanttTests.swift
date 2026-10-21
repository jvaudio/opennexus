import AppKit
import Foundation
import PDFKit
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusInterchange
@testable import NexusKeys

private func d(_ s: String) -> TaskDate { TaskDate(s)! }

/// Release 2.0 › Build (Design, Code, Docs) and Launch, with dependencies.
func ganttDocument() -> DocumentModel {
    var c = Canvas(id: "c1", title: "Release plan", rootText: "Release 2.0")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let build = try! e.addChild(of: e.canvas.root, text: "Build")
        let design = try! e.addChild(of: build, text: "Design")
        let code = try! e.addChild(of: build, text: "Code")
        let docs = try! e.addChild(of: build, text: "Docs")
        let launch = try! e.addChild(of: e.canvas.root, text: "Launch")
        _ = try! e.addChild(of: e.canvas.root, text: "Ideas")
        e.updateTask(design) {
            $0.start = d("2026-11-02")
            $0.due = d("2026-11-06")
            $0.owner = "Ana"
        }
        e.updateTask(code) {
            $0.start = d("2026-11-09")
            $0.due = d("2026-11-20")
            $0.progress = 40
        }
        e.updateTask(docs) { $0.done = false }
        e.updateTask(launch) { $0.due = d("2026-11-24") }
        try! e.addDependency(code, on: design)
        try! e.addDependency(launch, on: code, lag: 1)
    }
    return DocumentModel(canvases: [c])
}

@MainActor
@Suite(.serialized) struct GanttTests {
    func harness() -> CanvasHarness {
        let h = CanvasHarness(model: ganttDocument())
        h.controller.today = d("2026-11-04")
        h.controller.onViewMode = { [weak h] m in
            h?.host.showGantt(m == .gantt)
            if m == .gantt { h?.host.ganttView.focus() } else { h?.window.makeFirstResponder(h?.host.canvasView) }
        }
        return h
    }

    func id(_ h: CanvasHarness, _ t: String) -> NodeID { h.canvas.nodes.first { $0.value.text == t }!.key }

    // MARK: Layout

    @Test func rowsBarsAndArrows() {
        let doc = ganttDocument()
        let c = doc.canvases["c1"]!
        let L = GanttLayout(canvas: c, scale: .day, today: d("2026-11-04"))
        let names = L.rows.map { c.nodes[$0.id]!.text }
        #expect(names == ["Build", "Design", "Code", "Docs", "Launch"], "tasks and their parents, root as title")
        #expect(L.rows[0].kind == .summary && L.rows[3].kind == .undated && L.rows[4].kind == .milestone)
        #expect(L.origin.weekday == 1, "the timeline starts on a Monday")
        let code = L.rows[2]
        #expect(code.bar?.minX == L.x(for: d("2026-11-09")))
        #expect(code.bar?.width == 12 * L.dayWidth, "two working weeks span twelve calendar days")
        #expect(code.progress == 40 && code.cells[5] == "40%" && code.cells[4] == "10")
        #expect(L.rows[0].bar?.minX == L.x(for: d("2026-11-02")), "the summary spans its tasks")
        #expect(L.arrows.count == 2 && L.arrows.allSatisfy { !$0.violated })
        #expect(L.arrows[0].points.first?.x == L.rows[1].bar?.maxX, "finish to start leaves the bar's end")
        #expect(L.date(atX: L.x(for: d("2026-11-11")) + 3) == d("2026-11-11"))
        let collapsed = GanttLayout(canvas: c, collapsed: [L.rows[0].id], today: d("2026-11-04"))
        #expect(collapsed.rows.map { c.nodes[$0.id]!.text } == ["Build", "Launch"])
    }

    @Test func violationsAndLateTasksAreFlagged() {
        var c = ganttDocument().canvases["c1"]!
        let code = c.nodes.first { $0.value.text == "Code" }!.key
        c.nodes[code]?.todo?.start = d("2026-11-04")
        let L = GanttLayout(canvas: c, today: d("2026-11-30"))
        #expect(L.arrows.contains { $0.violated })
        #expect(L.rows.first { $0.id == code }?.late == true, "open and past its due date")
    }

    @Test func thousandTasksLayOutQuickly() {
        var c = Canvas(id: "c1", title: "Big", rootText: "Big")
        var u = UndoStack()
        c.edit("Big", undo: &u) { e in
            var prev: NodeID?
            for i in 0..<1000 {
                let id = try! e.addChild(of: e.canvas.root, text: "Task \(i)")
                e.updateTask(id) {
                    $0.start = d("2026-01-05").adding(days: i % 300)
                    $0.due = d("2026-01-09").adding(days: i % 300)
                    if let prev, i % 3 == 0 { $0.after = [TaskDependency(task: prev, type: .startToStart)] }
                }
                prev = id
            }
        }
        _ = GanttLayout(canvas: c, today: d("2026-03-01"))
        let t0 = Date()
        let L = GanttLayout(canvas: c, today: d("2026-03-01"))
        let ms = Date().timeIntervalSince(t0) * 1000
        #expect(L.rows.count == 1000)
        #expect(ms < 50, "1,000-task Gantt layout took \(ms) ms")
    }

    // MARK: Keyboard

    @Test func commandFourShowsTheGanttWithItsOwnKeys() throws {
        let h = harness()
        let design = id(h, "Design")
        let code = id(h, "Code")
        h.controller.select(design)
        h.press("cmd+4")
        #expect(h.controller.viewMode == .gantt)
        #expect(!h.host.ganttView.isHidden)
        #expect(h.controller.activeScope == .gantt)
        h.press("down")
        #expect(h.controller.selection.primary == code, "↓ moves to the next row, not spatially")
        h.press("up")
        #expect(h.controller.selection.primary == design)
        let before = h.undo.stack.undoStack.count
        h.press("opt+right")
        #expect(h.canvas.nodes[design]?.todo?.start == d("2026-11-03"))
        #expect(h.canvas.nodes[code]?.todo?.start == d("2026-11-10"), "the dependant follows")
        #expect(h.undo.stack.undoStack.count == before + 1, "one undo step")
        h.undo.undo(h.store)
        #expect(h.canvas.nodes[code]?.todo?.start == d("2026-11-09"))
        h.press("opt+shift+right")
        #expect(h.canvas.nodes[design]?.todo?.due == d("2026-11-09"), "lengthened over the weekend")
        h.press("opt+cmd+left")
        #expect(h.canvas.nodes[design]?.todo?.start == d("2026-10-26"), "a week earlier")
        h.press("5")
        #expect(h.canvas.nodes[design]?.todo?.progress == 50)
        h.press("space")
        #expect(h.canvas.nodes[design]?.todo?.done == true)
        h.press("ctrl+2")
        #expect(h.canvas.nodes[design]?.priority == 2, "topic keys pass through")
        h.press("tab")
        #expect(h.canvas.nodes[design]?.children.isEmpty == true, "Tab doesn't add topics in the Gantt")
        h.press("esc")
        #expect(h.controller.viewMode == .canvas)
        #expect(h.controller.selection.primary == design, "the selection survives the switch")
    }

    @Test func linkUnlinkScheduleAndScale() throws {
        let h = harness()
        let docs = id(h, "Docs")
        let launch = id(h, "Launch")
        h.controller.viewMode = .gantt
        h.controller.select(docs)
        h.press("cmd+d")
        #expect(h.canvas.nodes[docs]?.todo?.start == d("2026-11-04"), "undated tasks start today")
        h.controller.setSelection(Selection(primary: docs, nodes: [docs, launch]))
        h.press("cmd+l")
        #expect(h.canvas.nodes[launch]?.todo?.after.contains { $0.task == docs } == true)
        h.press("shift+cmd+l")
        #expect(h.canvas.nodes[launch]?.todo?.after.isEmpty == true)
        var scrolled: TaskDate?
        h.controller.onGanttScroll = { scrolled = $0 }
        h.press("t")
        #expect(scrolled == d("2026-11-04"))
        #expect(h.controller.ganttScale == .day)
        h.press("cmd+-")
        #expect(h.controller.ganttScale == .week, "⌘- zooms the timeline out")
        h.press("cmd+=")
        #expect(h.controller.ganttScale == .day)
        h.controller.select(id(h, "Build"))
        h.press("left")
        #expect(h.controller.ganttCollapsed == [id(h, "Build")])
        h.press("right")
        #expect(h.controller.ganttCollapsed.isEmpty)
    }

    @Test func ganttScopeHasNoConflicts() {
        #expect(CommandRegistry.standard.conflicts(custom: [:]).isEmpty)
        for p in KeyProfile.all { #expect(CommandRegistry.standard.conflicts(profile: p).isEmpty, "\(p.name)") }
        #expect(CommandRegistry.standard[.showGantt]?.keys == [KeyChord("cmd+4")!])
    }

    // MARK: Task editor

    @Test func taskEditorAppliesEveryFieldAsOneUndo() throws {
        let h = harness()
        let docs = id(h, "Docs")
        let code = id(h, "Code")
        h.controller.select(docs)
        h.press("ctrl+cmd+t")
        var s = try #require(h.controller.taskEditor)
        #expect(s.node == docs)
        s.start = "2026-11-23"
        s.duration = "3"
        s.durationEdited = true
        s.owner = "Kim"
        s.progress = 20
        s.priority = 3
        s.after = [TaskDependency(task: code, type: .startToStart, lag: 2)]
        h.controller.setTaskEditor(s)
        let before = h.undo.stack.undoStack.count
        #expect(h.controller.applyTaskEditor())
        let t = try #require(h.canvas.nodes[docs]?.todo)
        #expect(t.start == d("2026-11-23") && t.due == d("2026-11-25"), "three working days")
        #expect(t.owner == "Kim" && t.progress == 20 && h.canvas.nodes[docs]?.priority == 3)
        #expect(t.after == [TaskDependency(task: code, type: .startToStart, lag: 2)])
        #expect(h.undo.stack.undoStack.count == before + 1)
        #expect(h.controller.taskEditor == nil)
    }

    @Test func taskEditorRefusesBadInput() throws {
        let h = harness()
        let design = id(h, "Design")
        let launch = id(h, "Launch")
        h.controller.openTaskEditor(design)
        var s = try #require(h.controller.taskEditor)
        s.start = "someday"
        h.controller.setTaskEditor(s)
        #expect(!h.controller.applyTaskEditor())
        #expect(h.controller.taskEditor?.error?.contains("someday") == true)
        s.start = "2026-11-10"
        s.due = "2026-11-02"
        h.controller.setTaskEditor(s)
        #expect(!h.controller.applyTaskEditor(), "due before start")
        s.due = "2026-11-12"
        s.after = [TaskDependency(task: launch)]
        h.controller.setTaskEditor(s)
        #expect(!h.controller.applyTaskEditor(), "Launch already waits for Design")
        #expect(h.canvas.nodes[design]?.todo?.start == d("2026-11-02"), "nothing changed")
        #expect(!h.controller.dependencyCandidates("").contains(launch), "loops aren't offered")
    }

    @Test func typedDates() {
        let today = d("2026-11-04")  // a Wednesday
        let en = Locale(identifier: "en_GB")
        func p(_ s: String) -> TaskDate? { TaskDateParser.parse(s, today: today, locale: en) }
        #expect(p("today") == today)
        #expect(p("tomorrow") == d("2026-11-05"))
        #expect(p("+3") == d("2026-11-09"), "three working days")
        #expect(p("-1") == d("2026-11-03"))
        #expect(p("+2w") == d("2026-11-18"))
        #expect(p("fri") == d("2026-11-06"))
        #expect(p("wed") == today)
        #expect(p("2/12") == d("2026-12-02"), "day first in en_GB")
        #expect(TaskDateParser.parse("12/2", today: today, locale: Locale(identifier: "en_US")) == d("2026-12-02"))
        #expect(p("2 Dec") == d("2026-12-02"))
        #expect(p("dec 2 2027") == d("2027-12-02"))
        #expect(p("2026-11-30") == d("2026-11-30"))
        #expect(p("soon") == nil && p("31/2") == nil)
    }

    // MARK: Canvas, VoiceOver, filters

    @Test func taskLineShowsOnTopics() throws {
        let h = harness()
        let design = id(h, "Design")
        let pinned = try #require(h.controller.scene.nodes[design]?.pinned)
        #expect(pinned.contains { $0.key == "◷" && $0.value.hasPrefix("Ana · ") && $0.value.hasSuffix("· 0%") })
        #expect(h.controller.scene.nodes[id(h, "Docs")]?.pinned.isEmpty == true, "a plain to-do has no line")
        h.controller.prefs.set("editing.taskDetails", false)
        h.controller.refreshView()
        #expect(h.controller.scene.nodes[design]?.pinned.isEmpty == true)
        h.controller.today = d("2026-12-01")
        h.controller.prefs.set("editing.taskDetails", true)
        h.controller.refreshView()
        #expect(h.controller.scene.nodes[design]?.pinned.first?.value.hasPrefix("⚠︎") == true, "overdue")
    }

    @Test func spokenAndAccessibilityRows() throws {
        let h = harness()
        let c = h.canvas
        let spoken = try #require(TaskFormat.spoken(c, id(h, "Design"), today: d("2026-11-04")))
        #expect(spoken.contains("Ana") && spoken.contains("5 working days") && spoken.contains("0 percent"))
        #expect(TaskFormat.spoken(c, id(h, "Code"), today: d("2026-11-04"))?.contains("After Design") == true)
        h.controller.viewMode = .gantt
        h.host.ganttView.surface.reload()
        let rows = h.host.ganttView.surface.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { $0.accessibilityRole() == .row && $0.accessibilityLabel()?.isEmpty == false })
        #expect(rows[1].accessibilityLabel()?.contains("working days") == true)
        #expect(rows[0].accessibilityLabel()?.contains("Summary") == true)
        #expect(rows[2].accessibilityCustomActions()?.count == 3)
    }

    @Test func filterByOwnerAndDue() {
        let c = ganttDocument().canvases["c1"]!
        let byOwner = NodeFilter(clauses: [NodeFilter.parse("owner: ana")!])
        #expect(byOwner.matching(in: c).map { c.nodes[$0]!.text } == ["Design"])
        let dated = NodeFilter(clauses: [NodeFilter.parse("task: yes")!])
        #expect(dated.matching(in: c).count == 3)
    }

    // MARK: Export

    @Test func ganttExportsAsImagesAndPDF() throws {
        let h = harness()
        h.controller.openExport(.ganttPNG)
        var s = try #require(h.controller.exportState)
        #expect(s.format.group == .tasks)
        s.gantt.scale = 2
        let size = GanttExporter.pixelSize(h.controller, h.canvas, s.gantt)
        let png = try #require(h.controller.exportData(s))
        let img = try #require(NSBitmapImageRep(data: png))
        #expect(CGFloat(img.pixelsWide) == size.width && CGFloat(img.pixelsHigh) == size.height)
        #expect(size.width > 1200 && size.height > 200)
        s.format = .ganttJPEG
        #expect(h.controller.exportData(s).map { NSBitmapImageRep(data: $0) != nil } == true)
        #expect(h.controller.exportPreview(s) != nil)
        s.format = .ganttPDF
        let pdfData = try #require(h.controller.exportData(s))
        let pdf = try #require(PDFDocument(data: pdfData))
        #expect(pdf.pageCount == 1)
        let text = pdf.string ?? ""
        #expect(text.contains("Design") && text.contains("Launch"), "vector text stays selectable")
        s.gantt.paper = "a4"
        let tiledData = try #require(h.controller.exportData(s))
        let tiled = try #require(PDFDocument(data: tiledData))
        #expect(tiled.pageCount > 1, "tiled over A4 pages")
        #expect(tiled.page(at: tiled.pageCount - 1)?.string?.contains("Design") == true, "the table repeats")
        s.format = .ics
        #expect(h.controller.exportText(s)?.hasPrefix("BEGIN:VCALENDAR") == true)
        s.format = .tasksCSV
        let csv = try #require(h.controller.exportText(s))
        #expect(csv.contains("Design") && !csv.contains("Ideas"))
    }

    @Test func selectedBranchesOnly() {
        let h = harness()
        h.controller.select(id(h, "Code"))
        var o = GanttExporter.Options()
        o.selectionOnly = true
        let r = GanttExporter.renderer(h.controller, h.canvas, o)
        #expect(r.layout.rows.map { h.canvas.nodes[$0.id]!.text } == ["Build", "Code"])
    }
}
