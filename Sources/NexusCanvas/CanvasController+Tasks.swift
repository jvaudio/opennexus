import AppKit
import NexusCore
import NexusInterchange
import NexusKeys

/// The Gantt's timeline scale (⌘= and ⌘- step through it).
public enum GanttScale: String, CaseIterable, Sendable {
    case day, week, month

    /// Width of one calendar day, in points.
    public var dayWidth: CGFloat {
        switch self {
        case .day: 30
        case .week: 12
        case .month: 4
        }
    }

    public var title: String {
        switch self {
        case .day: Loc.t("Days")
        case .week: Loc.t("Weeks")
        case .month: Loc.t("Months")
        }
    }
}

/// Task dates and the task line as people read them (M11).
public enum TaskFormat {
    static let utc = TimeZone(identifier: "UTC")!

    /// "2 Nov", or "2 Nov 2027" outside `today`'s year, in the user's locale.
    public static func day(_ d: TaskDate, today: TaskDate? = nil) -> String {
        var f = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if let today, today.components.year != d.components.year { f = f.year() }
        f.timeZone = utc
        return d.date(in: utc).formatted(f)
    }

    /// "Ana · 2 Nov → 6 Nov · 40%", nil for a plain to-do (D147). Overdue tasks start with ⚠︎.
    public static func line(_ c: Canvas, _ id: NodeID, today: TaskDate) -> String? {
        guard let n = c.nodes[id], let t = n.todo,
            t.isScheduled || t.owner != nil || t.progress != nil || !t.after.isEmpty
        else { return nil }
        var parts: [String] = []
        if let o = t.owner { parts.append(o) }
        switch (t.start, t.due) {
        case (let s?, let d?): parts.append("\(day(s, today: today)) → \(day(max(s, d), today: today))")
        case (let s?, nil): parts.append(Loc.f("From %@", day(s, today: today)))
        case (nil, let d?): parts.append("◆ " + day(d, today: today))
        default: break
        }
        parts.append("\(c.progress(of: id))%")
        let late = !t.done && (c.span(of: id)?.finish).map { $0 < today } == true
        return (late ? "⚠︎ " : "") + parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for a task: "Ana, 2 Nov to 6 Nov, 5 working days, 40 percent, after Design".
    public static func spoken(_ c: Canvas, _ id: NodeID, today: TaskDate) -> String? {
        guard let n = c.nodes[id], let t = n.todo else { return nil }
        var parts: [String] = []
        if let o = t.owner { parts.append(o) }
        if let s = c.span(of: id) {
            if s.milestone {
                parts.append(Loc.f("Milestone on %@", day(s.finish, today: today)))
            } else if s.start == s.finish {
                parts.append(Loc.f("On %@", day(s.start, today: today)))
                parts.append(Loc.n("%lld working day", "%lld working days", s.workingDays))
            } else {
                parts.append(Loc.f("%@ to %@", day(s.start, today: today), day(s.finish, today: today)))
                parts.append(Loc.n("%lld working day", "%lld working days", s.workingDays))
            }
            if !t.done && s.finish < today { parts.append(Loc.t("Overdue")) }
        }
        if t.isScheduled || t.progress != nil { parts.append(Loc.f("%lld percent", c.progress(of: id))) }
        let after = t.after.compactMap { c.nodes[$0.task]?.text }
        if !after.isEmpty { parts.append(Loc.f("After %@", after.joined(separator: ", "))) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Typed dates in the Task editor: `today`, `tomorrow`, `+3` (working days), `-2`, `2w`
/// (weeks), weekday names, `2/11` (in the locale's day-month order), `2 Nov`, `2026-11-02`.
public enum TaskDateParser {
    public static func parse(
        _ text: String, today: TaskDate, calendar: WorkCalendar = WorkCalendar(), locale: Locale = .current
    ) -> TaskDate? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if let d = TaskDate(s) { return d }
        switch s {
        case "today", Loc.t("today").lowercased(): return today
        case "tomorrow", Loc.t("tomorrow").lowercased(): return today.adding(days: 1)
        case "yesterday", Loc.t("yesterday").lowercased(): return today.adding(days: -1)
        default: break
        }
        if let sign = s.first, sign == "+" || sign == "-" {
            let body = s.dropFirst()
            if body.hasSuffix("w"), let n = Int(body.dropLast()), n <= 520 {
                return today.adding(days: (sign == "+" ? 1 : -1) * n * 7)
            }
            if let n = Int(body.hasSuffix("d") ? body.dropLast() : body), n <= 3650 {
                return calendar.shift(today, by: sign == "+" ? n : -n)
            }
        }
        // Weekday names: the next one on or after today.
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        let english = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let local = cal.shortWeekdaySymbols.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        for (i, names) in zip(0..<7, zip(english, local)) where s.count >= 2 {
            if names.0.hasPrefix(String(s.prefix(3))) || names.1.hasPrefix(s) || s.hasPrefix(names.1) {
                let iso = i == 0 ? 7 : i
                return today.adding(days: (iso - today.weekday + 7) % 7)
            }
        }
        let year = today.components.year
        // "2/11", "2.11.27", "11-2": numbers in the locale's order.
        let nums = s.split(whereSeparator: { "/.-".contains($0) }).map(String.init)
        if (2...3).contains(nums.count), nums.allSatisfy({ Int($0) != nil }) {
            let template = DateFormatter.dateFormat(fromTemplate: "dM", options: 0, locale: locale) ?? "d/M"
            let dayFirst =
                (template.firstIndex(of: "d") ?? template.startIndex)
                < (template.firstIndex(of: "M") ?? template.endIndex)
            let a = Int(nums[0])!
            let b = Int(nums[1])!
            var y = nums.count == 3 ? Int(nums[2])! : year
            if y < 100 { y += 2000 }
            return TaskDate(year: y, month: dayFirst ? b : a, day: dayFirst ? a : b)
        }
        // "2 nov", "nov 2", "2 nov 2027".
        let words = s.split(separator: " ").map(String.init)
        if (2...3).contains(words.count) {
            let months = cal.shortMonthSymbols.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let englishMonths = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            var day: Int?
            var month: Int?
            var y = year
            for w in words {
                if let n = Int(w) {
                    if n > 31 { y = n } else { day = n }
                } else if let m = months.firstIndex(where: { w.hasPrefix($0) || $0.hasPrefix(w) })
                    ?? englishMonths.firstIndex(where: { w.hasPrefix($0) })
                {
                    month = m + 1
                }
            }
            if let day, let month { return TaskDate(year: y, month: month, day: day) }
        }
        return nil
    }
}

/// The Task editor's fields, as typed (applied together as one undo step).
public struct TaskEditorState: Equatable, Sendable {
    public var node: NodeID
    public var start: String
    public var due: String
    /// Working days; typing here moves the due date.
    public var duration: String
    public var durationEdited = false
    public var owner: String
    public var progress: Int
    /// 0 is none.
    public var priority: Int
    public var done: Bool
    public var after: [TaskDependency]
    /// The dependency picker's query.
    public var query = ""
    public var error: String?
}

@MainActor
extension CanvasController {
    static let ganttPassThrough: Set<CommandID> = Set<CommandID>([
        .toggleTodo, .delete, .palette, .taskDetails, .inspector, .note, .label, .copy, .cut,
    ]).union((1...9).map { CommandID.priority($0) })

    public var todayDate: TaskDate { today ?? TaskDate.today() }

    /// The Gantt's plan for the current canvas.
    public var taskSchedule: TaskSchedule { TaskSchedule(canvas) }

    var taskHandlers: [CommandID: (CanvasController) -> Void] {
        var h: [CommandID: (CanvasController) -> Void] = [
            .taskDetails: { $0.openTaskEditor() },
            .ganttEditTask: { $0.openTaskEditor() },
            .ganttPrevious: { $0.stepGantt(-1, extend: false) },
            .ganttNext: { $0.stepGantt(1, extend: false) },
            .ganttExtendUp: { $0.stepGantt(-1, extend: true) },
            .ganttExtendDown: { $0.stepGantt(1, extend: true) },
            .ganttCollapse: { $0.ganttCollapseOrParent() },
            .ganttExpand: { $0.ganttExpandOrChild() },
            .ganttEarlier: { $0.moveSelectedTasks(by: -1) },
            .ganttLater: { $0.moveSelectedTasks(by: 1) },
            .ganttWeekEarlier: { $0.moveSelectedTasks(by: -$0.canvas.workCalendar.weekLength) },
            .ganttWeekLater: { $0.moveSelectedTasks(by: $0.canvas.workCalendar.weekLength) },
            .ganttShorten: { $0.resizeSelectedTasks(by: -1) },
            .ganttLengthen: { $0.resizeSelectedTasks(by: 1) },
            .ganttToggleDone: { $0.toggleSelectedTasksDone() },
            .ganttLink: { $0.linkSelectedTasks() },
            .ganttUnlink: { $0.unlinkSelectedTasks() },
            .ganttScheduleToday: { $0.scheduleSelectedFromToday() },
            .ganttToday: { c in c.onGanttScroll?(c.todayDate) },
            .ganttExit: { $0.viewMode = .canvas },
            .exportGantt: { $0.openExport(.ganttPNG) },
        ]
        for n in 0...9 { h[.ganttProgress(n)] = { $0.setSelectedProgress(n * 10) } }
        return h
    }

    // MARK: Task editor

    public func openTaskEditor(_ id: NodeID? = nil) {
        if mode == .edit { commitEdit() }
        let id = id ?? selection.primary
        guard let n = canvas.nodes[id] else { return }
        let t = n.todo ?? Todo(done: false)
        let span = canvas.span(of: id)
        taskEditor = TaskEditorState(
            node: id, start: t.start?.description ?? "", due: t.due?.description ?? "",
            duration: span.map { $0.milestone ? "0" : "\($0.workingDays)" } ?? "", owner: t.owner ?? "",
            progress: canvas.progress(of: id), priority: n.priority ?? 0, done: t.done, after: t.after)
    }

    public func setTaskEditor(_ s: TaskEditorState) { taskEditor = s }

    public func closeTaskEditor() {
        taskEditor = nil
        onRestoreFocus?()
    }

    /// Applies every field as one undo step. Returns false (and says why) when a date
    /// can't be read or a dependency would loop.
    @discardableResult
    public func applyTaskEditor() -> Bool {
        guard var s = taskEditor else { return false }
        let cal = canvas.workCalendar
        let today = todayDate
        func date(_ text: String) -> (ok: Bool, value: TaskDate?) {
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return (true, nil) }
            let d = TaskDateParser.parse(text, today: today, calendar: cal)
            return (d != nil, d)
        }
        let start = date(s.start)
        var due = date(s.due)
        guard start.ok else {
            s.error = Loc.f("Can’t read the start date “%@”", s.start)
            taskEditor = s
            return false
        }
        guard due.ok else {
            s.error = Loc.f("Can’t read the due date “%@”", s.due)
            taskEditor = s
            return false
        }
        if s.durationEdited, let st = start.value, let days = Int(s.duration.trimmingCharacters(in: .whitespaces)) {
            due = (true, days <= 0 ? nil : cal.finish(start: st, days: days))
        }
        if let a = start.value, let b = due.value, b < a {
            s.error = Loc.t("The due date is before the start")
            taskEditor = s
            return false
        }
        let id = s.node
        let edited = s
        let ok = perform(Loc.t("Edit Task")) { e -> Bool in
            let old = e[id]?.todo?.after ?? []
            e.updateTask(id) {
                $0.start = start.value
                $0.due = due.value
                $0.owner = edited.owner.trimmingCharacters(in: .whitespaces).isEmpty ? nil : edited.owner
                $0.done = edited.done || edited.progress >= 100
                $0.progress = edited.progress == 0 ? nil : min(100, edited.progress)
                $0.after = []
            }
            e.update(id) { $0.priority = edited.priority == 0 ? nil : edited.priority }
            for d in edited.after {
                do {
                    try e.addDependency(id, on: d.task, type: d.type, lag: d.lag)
                } catch {
                    // Put back what was there and refuse.
                    e.updateTask(id) { $0.after = old }
                    throw error
                }
            }
            e.pushDependants(of: [id])
            return true
        }
        guard ok == true else {
            s.error = Loc.t("That dependency would make a loop")
            taskEditor = s
            return false
        }
        taskEditor = nil
        onRestoreFocus?()
        return true
    }

    /// Owners already used on this canvas, for the Owner field.
    public var ownerSuggestions: [String] {
        Array(Set(canvas.nodes.values.compactMap { $0.todo?.owner })).sorted()
    }

    /// Topics the edited task could depend on, matching `query` (no loops, not itself).
    public func dependencyCandidates(_ query: String, limit: Int = 6) -> [NodeID] {
        guard let s = taskEditor else { return [] }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let blocked = Set(s.after.map(\.task)).union([s.node])
        let c = canvas
        var out: [NodeID] = []
        for top in c.tops {
            c.walk(from: top) { id, n, _ in
                guard out.count < limit, !blocked.contains(id), id != c.root || n.todo != nil,
                    !c.predecessors(of: id).contains(s.node),
                    q.isEmpty ? n.todo != nil : n.text.lowercased().contains(q)
                else { return }
                out.append(id)
            }
        }
        return out
    }

    // MARK: Gantt commands

    var visibleGanttRows: [TaskSchedule.Row] { taskSchedule.visibleRows(collapsed: ganttCollapsed) }

    func stepGantt(_ delta: Int, extend: Bool) {
        let rows = visibleGanttRows
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == selection.primary }
        let j = i.map { max(0, min(rows.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : rows.count - 1)
        select(rows[j].id, extend: extend)
    }

    func ganttCollapseOrParent() {
        let id = selection.primary
        let rows = taskSchedule.rows
        guard let r = rows.first(where: { $0.id == id }) else { return }
        if r.hasChildren && !ganttCollapsed.contains(id) {
            ganttCollapsed.insert(id)
            refreshView()
        } else if let p = canvas.parent(of: id), rows.contains(where: { $0.id == p }) {
            select(p)
        }
    }

    func ganttExpandOrChild() {
        let id = selection.primary
        guard let r = taskSchedule.rows.first(where: { $0.id == id }), r.hasChildren else { return }
        if ganttCollapsed.contains(id) {
            ganttCollapsed.remove(id)
            refreshView()
        } else if let first = visibleGanttRows.drop(while: { $0.id != id }).dropFirst().first {
            select(first.id)
        }
    }

    public func toggleGanttRow(_ id: NodeID) {
        if ganttCollapsed.contains(id) { ganttCollapsed.remove(id) } else { ganttCollapsed.insert(id) }
        refreshView()
    }

    /// Selected topics that are tasks (summary rows are left alone).
    var selectedTasks: [NodeID] {
        let order = taskSchedule.rows.map(\.id)
        let picked = Set(selection.nodes).union([selection.primary])
        return order.filter { picked.contains($0) && canvas.nodes[$0]?.todo != nil }
    }

    func moveSelectedTasks(by n: Int) {
        let ids = selectedTasks.filter { canvas.span(of: $0) != nil }
        guard !ids.isEmpty else { return showToast(TaskRefusal.noDates.description) }
        perform(n < 0 ? Loc.t("Move Earlier") : Loc.t("Move Later")) { e in
            for id in ids { try e.moveTask(id, byWorkingDays: n) }
        }
    }

    func resizeSelectedTasks(by n: Int) {
        let ids = selectedTasks.filter { canvas.span(of: $0) != nil }
        guard !ids.isEmpty else { return showToast(TaskRefusal.noDates.description) }
        perform(n < 0 ? Loc.t("Shorten Task") : Loc.t("Lengthen Task")) { e in
            for id in ids { try e.resizeTask(id, byWorkingDays: n) }
        }
    }

    func toggleSelectedTasksDone() {
        let ids = selectedTasks
        guard !ids.isEmpty else { return }
        let done = !ids.allSatisfy { canvas.nodes[$0]?.todo?.done == true }
        perform(Loc.t("To-Do")) { e in for id in ids { e.updateTask(id) { $0.done = done } } }
    }

    func setSelectedProgress(_ p: Int) {
        let ids = selectedTasks
        guard !ids.isEmpty else { return }
        perform(Loc.t("Set Progress")) { e in
            for id in ids {
                e.updateTask(id) {
                    $0.progress = p == 0 ? nil : p
                    $0.done = false
                }
            }
        }
    }

    func linkSelectedTasks() {
        let ids = selectedTasks
        guard ids.count >= 2 else { return showToast(Loc.t("Select two or more tasks to link")) }
        perform(Loc.t("Link Tasks")) { e in
            for (a, b) in zip(ids, ids.dropFirst()) { try e.addDependency(b, on: a) }
        }
    }

    func unlinkSelectedTasks() {
        let ids = selectedTasks
        perform(Loc.t("Remove Dependencies")) { e in for id in ids { e.updateTask(id) { $0.after = [] } } }
    }

    func scheduleSelectedFromToday() {
        let ids = selectedTasks.filter { canvas.span(of: $0) == nil }
        guard !ids.isEmpty else { return showToast(Loc.t("The selected tasks already have dates")) }
        let day = canvas.workCalendar.snapForward(todayDate)
        perform(Loc.t("Schedule from Today")) { e in
            for id in ids { e.reschedule(id, start: day, due: day) }
        }
    }

    func stepGanttScale(_ delta: Int) {
        let all = GanttScale.allCases
        let i = all.firstIndex(of: ganttScale) ?? 0
        ganttScale = all[max(0, min(all.count - 1, i + delta))]
        refreshView()
    }

    public func setGanttScale(_ s: GanttScale) {
        ganttScale = s
        refreshView()
    }

    /// One drag in the Gantt: new dates for a task, dependants pushed, one undo step.
    public func dragTask(_ id: NodeID, start: TaskDate?, due: TaskDate?, name: String) {
        perform(name) { e in e.reschedule(id, start: start, due: due) }
    }

    public func setProgress(_ id: NodeID, _ p: Int) {
        perform(Loc.t("Set Progress")) { e in e.updateTask(id) { $0.progress = max(0, min(100, p)) } }
    }

    /// Drag from one bar to another: `successor` waits for `predecessor` (finish to start).
    public func linkTasks(_ predecessor: NodeID, _ successor: NodeID) {
        perform(Loc.t("Link Tasks")) { e in try e.addDependency(successor, on: predecessor) }
    }
}
