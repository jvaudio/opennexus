import Foundation
import Testing

@testable import NexusCore

private func d(_ s: String) -> TaskDate { TaskDate(s)! }

/// Launch plan with three dated tasks under Timeline: Design (Mon 2 Nov, 5 days),
/// Build (after Design), Ship (milestone after Build).
func taskCanvas() -> (Canvas, design: NodeID, build: NodeID, ship: NodeID) {
    var c = sampleCanvas()
    var u = UndoStack()
    let timeline = c.nodes.first { $0.value.text == "Timeline" }!.key
    let ids = c.edit("Tasks", undo: &u) { e -> (NodeID, NodeID, NodeID) in
        let a = try! e.addChild(of: timeline, text: "Design")
        let b = try! e.addChild(of: timeline, text: "Build")
        let s = try! e.addChild(of: timeline, text: "Ship")
        e.updateTask(a) {
            $0.start = d("2026-11-02")
            $0.due = d("2026-11-06")
            $0.owner = "Ana"
        }
        e.updateTask(b) {
            $0.start = d("2026-11-09")
            $0.due = d("2026-11-13")
        }
        e.updateTask(s) { $0.due = d("2026-11-16") }
        try! e.addDependency(b, on: a)
        try! e.addDependency(s, on: b)
        return (a, b, s)
    }
    return (c, ids.0, ids.1, ids.2)
}

@Suite struct TaskModelTests {
    @Test func everyFieldRoundTrips() throws {
        var t = Todo(done: false)
        t.start = d("2026-11-02")
        t.due = d("2026-11-06")
        t.owner = "Ana"
        t.progress = 40
        t.after = [TaskDependency(task: "n7"), TaskDependency(task: "n9", type: .startToStart, lag: 2)]
        let back = try Todo(json: t.json, path: "todo")
        #expect(back == t)
        #expect(t.json.objectValue?["start"] == "2026-11-02")
        #expect(t.after[0].json == ["task": "n7"], "the default kind and lag are omitted")
    }

    @Test func plainToDoIsUnchanged() throws {
        let t = Todo(done: true)
        #expect(t.json == ["done": true])
        var zero = Todo(done: false)
        zero.progress = 0
        #expect(zero.json == ["done": false], "progress 0 is the default")
    }

    @Test func unknownKeysInsideTaskAndDependencyRoundTrip() throws {
        let json: JSONValue = [
            "done": false, "due": "2026-12-01", "effort": "3h",
            "after": [["task": "n2", "type": "FF", "note": "waits for sign-off"]],
        ]
        let t = try Todo(json: json, path: "todo")
        #expect(t.extra["effort"] == "3h")
        #expect(t.after[0].extra["note"] == "waits for sign-off")
        #expect(t.json == json)
    }

    @Test func badValuesAreRejected() {
        #expect(throws: ModelDecodingError.self) { try Todo(json: ["done": false, "start": "2/11/26"], path: "t") }
        #expect(throws: ModelDecodingError.self) { try Todo(json: ["done": false, "progress": 140], path: "t") }
        #expect(throws: ModelDecodingError.self) {
            try Todo(json: ["done": false, "after": [["task": "n2", "type": "XX"]]], path: "t")
        }
        #expect(TaskDate("2026-02-30") == nil)
    }

    @Test func toggleKeepsTaskFields() throws {
        var (c, design, _, _) = taskCanvas()
        var u = UndoStack()
        c.edit("Toggle", undo: &u) { $0.toggleMarker(design, priority: 0) }
        #expect(c.nodes[design]?.todo?.done == true)
        #expect(c.nodes[design]?.todo?.owner == "Ana", "Control-0 used to rebuild the to-do")
        #expect(c.nodes[design]?.todo?.start == d("2026-11-02"))
    }

    @Test func effectiveProgress() {
        var c = sampleCanvas()
        let id = c.nodes.first { $0.value.text == "Pro" }!.key
        #expect(c.progress(of: id) == 0)
        c.nodes[id]?.markers = ["progress-75"]
        #expect(c.progress(of: id) == 75, "falls back to the progress marker")
        c.nodes[id]?.todo = Todo(done: false)
        c.nodes[id]?.todo?.progress = 30
        #expect(c.progress(of: id) == 30)
        c.nodes[id]?.todo?.done = true
        #expect(c.progress(of: id) == 100)
    }

    @Test func progressOfHundredChecksTheToDo() {
        var (c, design, _, _) = taskCanvas()
        var u = UndoStack()
        c.edit("Progress", undo: &u) { $0.updateTask(design) { $0.progress = 100 } }
        #expect(c.nodes[design]?.todo?.done == true)
        c.edit("Owner", undo: &u) { $0.updateTask(design) { $0.owner = "  " } }
        #expect(c.nodes[design]?.todo?.owner == nil, "a blank owner is cleared")
    }

    @Test func scheduleIsOmittedWhenDefault() throws {
        var c = Canvas(id: "c1", title: "t")
        #expect(c.json.objectValue?["schedule"] == nil)
        c.schedule.holidays = [d("2026-12-25")]
        c.schedule.workdays = [1, 2, 3, 4]
        let back = try Canvas(json: c.json, path: "c1")
        #expect(back.schedule == c.schedule)
        #expect(back == c)
    }
}

@Suite struct WorkCalendarTests {
    @Test func datesAndWeekdays() {
        #expect(d("1970-01-01").day == 0)
        #expect(d("1970-01-01").weekday == 4, "a Thursday")
        #expect(d("2026-11-02").weekday == 1, "a Monday")
        #expect(d("2024-02-29").description == "2024-02-29")
        #expect(d("1969-12-31").day == -1)
        for day in stride(from: -719_000, through: 2_900_000, by: 997) {
            #expect(TaskDate(TaskDate(day: day).description)?.day == day)
        }
        let utc = TimeZone(identifier: "UTC")!
        #expect(TaskDate(d("2026-11-02").date(in: utc), in: utc) == d("2026-11-02"))
    }

    @Test func weekendsAreSkipped() {
        let cal = WorkCalendar()
        #expect(!cal.isWorking(d("2026-11-07")))
        #expect(cal.shift(d("2026-11-06"), by: 1) == d("2026-11-09"), "Friday plus one working day is Monday")
        #expect(cal.shift(d("2026-11-09"), by: -1) == d("2026-11-06"))
        #expect(cal.workingDays(from: d("2026-11-02"), through: d("2026-11-13")) == 10)
        #expect(cal.finish(start: d("2026-11-05"), days: 3) == d("2026-11-09"))
        #expect(cal.snapForward(d("2026-11-07")) == d("2026-11-09"))
    }

    @Test func holidaysAndCustomWeeks() {
        var s = WorkSchedule()
        s.holidays = [d("2026-12-24")]
        s.workdays = [1, 2, 3, 4]
        let cal = s.calendar
        #expect(!cal.isWorking(d("2026-12-24")))
        #expect(!cal.isWorking(d("2026-12-04")), "Fridays are off")
        #expect(cal.workingDays(from: d("2026-12-21"), through: d("2026-12-27")) == 3)
    }

    @Test func skippingOffCountsEveryDay() {
        var s = WorkSchedule()
        s.skipNonWorking = false
        let cal = s.calendar
        #expect(cal.isWorking(d("2026-11-07")))
        #expect(cal.workingDays(from: d("2026-11-02"), through: d("2026-11-08")) == 7)
        var none = WorkSchedule()
        none.workdays = []
        #expect(none.calendar.isWorking(d("2026-11-07")), "no working weekdays can't hang the calendar")
    }
}

@Suite struct ScheduleTests {
    @Test func spansAndRows() {
        let (c, design, build, ship) = taskCanvas()
        let s = TaskSchedule(c)
        #expect(
            s.spans[design]
                == TaskSpan(start: d("2026-11-02"), finish: d("2026-11-06"), milestone: false, workingDays: 5))
        #expect(s.spans[ship]?.milestone == true)
        let timeline = c.parent(of: design)!
        #expect(s.rows.map(\.id) == [timeline, design, build, ship])
        #expect(s.rows[0].isSummary && s.rows[0].depth == 0 && s.rows[1].depth == 1)
        #expect(s.summarySpans[timeline]?.start == d("2026-11-02"))
        #expect(s.summarySpans[timeline]?.finish == d("2026-11-16"))
        #expect(s.violations.isEmpty && s.cycle.isEmpty)
        #expect(s.visibleRows(collapsed: [timeline]).map(\.id) == [timeline])
    }

    @Test func dependencyKindsAndLags() {
        let cal = WorkCalendar()
        let p = TaskSpan(start: d("2026-11-02"), finish: d("2026-11-06"), milestone: false, workingDays: 5)
        func req(_ t: DependencyType, _ lag: Int) -> (Bool, TaskDate) {
            let r = TaskSchedule.requirement(.init(from: "a", to: "b", type: t, lag: lag), pred: p, calendar: cal)
            return (r.onStart, r.date)
        }
        #expect(req(.finishToStart, 0) == (true, d("2026-11-09")))
        #expect(req(.finishToStart, 2) == (true, d("2026-11-11")))
        #expect(req(.startToStart, 1) == (true, d("2026-11-03")))
        #expect(req(.finishToFinish, 0) == (false, d("2026-11-06")))
        #expect(req(.startToFinish, 0) == (false, d("2026-11-02")))
    }

    @Test func movingATaskPushesDependantsTransitively() throws {
        var (c, design, build, ship) = taskCanvas()
        var u = UndoStack()
        try c.edit("Move", undo: &u) { try $0.moveTask(design, byWorkingDays: 3) }
        #expect(c.nodes[design]?.todo?.start == d("2026-11-05"))
        #expect(c.nodes[design]?.todo?.due == d("2026-11-11"), "keeps five working days over the weekend")
        #expect(c.nodes[build]?.todo?.start == d("2026-11-12"))
        #expect(c.nodes[build]?.todo?.due == d("2026-11-18"))
        #expect(c.nodes[ship]?.todo?.due == d("2026-11-19"))
        #expect(TaskSchedule(c).violations.isEmpty)
        #expect(u.undoStack.count == 1, "one undo step")
        u.undo()!.apply(to: &c)
        #expect(c.nodes[build]?.todo?.start == d("2026-11-09"))
    }

    @Test func dependantsAreNeverPulledBack() throws {
        var (c, design, build, _) = taskCanvas()
        var u = UndoStack()
        try c.edit("Move", undo: &u) { try $0.moveTask(design, byWorkingDays: -2) }
        #expect(c.nodes[build]?.todo?.start == d("2026-11-09"))
        try c.edit("Resize", undo: &u) { try $0.resizeTask(design, byWorkingDays: -10) }
        #expect(c.nodes[design]?.todo?.due == c.nodes[design]?.todo?.start, "never ends before it starts")
    }

    @Test func violationsAndCyclesAreReported() {
        var (c, design, build, _) = taskCanvas()
        c.nodes[build]?.todo?.start = d("2026-11-04")
        #expect(TaskSchedule(c).violations.map(\.to) == [build])
        c.nodes[design]?.todo?.after = [TaskDependency(task: build)]
        let s = TaskSchedule(c)
        #expect(s.cycle == [design, build])
    }
}

@Suite struct DependencyTests {
    @Test func refusesSelfAndCycles() {
        var (c, design, _, ship) = taskCanvas()
        var u = UndoStack()
        #expect(throws: TaskRefusal.wouldCycle) {
            try c.edit("Link", undo: &u) { try $0.addDependency(design, on: ship) }
        }
        #expect(throws: TaskRefusal.dependsOnItself) {
            try c.edit("Link", undo: &u) { try $0.addDependency(design, on: design) }
        }
    }

    @Test func addingUpdatesAnExistingDependency() throws {
        var (c, design, build, _) = taskCanvas()
        var u = UndoStack()
        try c.edit("Link", undo: &u) { try $0.addDependency(build, on: design, type: .startToStart, lag: 1) }
        #expect(c.nodes[build]?.todo?.after == [TaskDependency(task: design, type: .startToStart, lag: 1)])
        c.edit("Unlink", undo: &u) { $0.removeDependency(build, on: design) }
        #expect(c.nodes[build]?.todo?.after.isEmpty == true)
    }

    @Test func deleteDropsDependenciesOnTheTopic() throws {
        var (c, design, build, _) = taskCanvas()
        var u = UndoStack()
        try c.edit("Delete", undo: &u) { _ = try $0.delete([design]) }
        #expect(c.nodes[build]?.todo?.after.isEmpty == true)
        u.undo()!.apply(to: &c)
        #expect(c.nodes[build]?.todo?.after.map(\.task) == [design])
        try c.edit("Delete", undo: &u) { _ = try $0.deleteKeepingChildren(build) }
        let ship = c.nodes.first { $0.value.text == "Ship" }!.key
        #expect(c.nodes[ship]?.todo?.after.isEmpty == true)
        #expect(c.validate().isEmpty)
    }

    @Test func graftRemapsInsideAndKeepsSameCanvasLinks() throws {
        var (c, design, build, _) = taskCanvas()
        var u = UndoStack()
        let timeline = c.parent(of: design)!
        // The whole Timeline branch: inner dependencies follow the copies.
        let f = c.fragment([timeline])
        let risks = c.nodes.first { $0.value.text == "Risks" }!.key
        let tops = try c.edit("Paste", undo: &u) { try $0.paste(f, under: risks) }
        let copy = c.nodes[tops[0]]!.children
        #expect(c.nodes[copy[3]]?.todo?.after.map(\.task) == [copy[2]])
        // Only Build: its dependency on Design (outside) survives in the same canvas…
        let one = c.fragment([build])
        let pasted = try c.edit("Paste", undo: &u) { try $0.paste(one, under: risks) }
        #expect(c.nodes[pasted[0]]?.todo?.after.map(\.task) == [design])
        // …but not in another canvas.
        var other = Canvas(id: "c9", title: "Other")
        let elsewhere = try other.edit("Paste", undo: &u) { try $0.paste(one, under: $0.canvas.root) }
        #expect(other.nodes[elsewhere[0]]?.todo?.after.isEmpty == true)
    }

    @Test func repairDropsBrokenDependencies() {
        var (c, design, build, _) = taskCanvas()
        c.nodes[build]?.todo?.after += [
            TaskDependency(task: "n999"), TaskDependency(task: build), TaskDependency(task: design),
        ]
        #expect(!c.validate().isEmpty)
        let fixes = c.repair()
        #expect(fixes == ["3 task dependencies on missing or repeated topics"])
        #expect(c.nodes[build]?.todo?.after.map(\.task) == [design])
        #expect(c.validate().isEmpty)
    }
}
