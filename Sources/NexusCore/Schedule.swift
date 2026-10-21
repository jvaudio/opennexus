import Foundation

/// When a task runs, in calendar days (M11).
public struct TaskSpan: Hashable, Sendable {
    public var start: TaskDate
    /// Last day, inclusive (the same day for a milestone).
    public var finish: TaskDate
    /// A task with a due date and no start.
    public var milestone: Bool
    /// Working days from start through finish (0 for a milestone).
    public var workingDays: Int
}

extension Canvas {
    public var workCalendar: WorkCalendar { schedule.calendar }

    /// Effective progress in percent: 100 when done, else the stored percentage, else the
    /// topic's progress marker, else 0 (D143).
    public func progress(of id: NodeID) -> Int {
        guard let n = nodes[id] else { return 0 }
        if n.todo?.done == true { return 100 }
        if let p = n.todo?.progress { return max(0, min(100, p)) }
        for m in n.markers where m.hasPrefix("progress-") {
            if let p = Int(m.dropFirst("progress-".count)) { return max(0, min(100, p)) }
        }
        return 0
    }

    /// The task's span, or nil when it has no dates.
    public func span(of id: NodeID, calendar cal: WorkCalendar? = nil) -> TaskSpan? {
        guard let t = nodes[id]?.todo else { return nil }
        let cal = cal ?? workCalendar
        switch (t.start, t.due) {
        case (let s?, let d?):
            let f = max(s, d)
            return TaskSpan(start: s, finish: f, milestone: false, workingDays: max(1, cal.workingDays(from: s, through: f)))
        case (let s?, nil):
            return TaskSpan(start: s, finish: s, milestone: false, workingDays: 1)
        case (nil, let d?):
            return TaskSpan(start: d, finish: d, milestone: true, workingDays: 0)
        default:
            return nil
        }
    }

    /// Topics this task waits for, transitively (stops at cycles).
    func predecessors(of id: NodeID) -> Set<NodeID> {
        var seen = Set<NodeID>()
        var stack = nodes[id]?.todo?.after.map(\.task) ?? []
        while let cur = stack.popLast() {
            guard seen.insert(cur).inserted else { continue }
            stack.append(contentsOf: nodes[cur]?.todo?.after.map(\.task) ?? [])
        }
        return seen
    }
}

/// The derived plan of one canvas: rows in outline order, spans, dependency edges, and
/// what breaks the rules. Pure, so the Gantt, exports and tests share it.
public struct TaskSchedule: Sendable {
    public struct Edge: Hashable, Sendable {
        public var from: NodeID
        public var to: NodeID
        public var type: DependencyType
        public var lag: Int
    }

    public struct Row: Hashable, Sendable {
        public var id: NodeID
        /// 0 for main topics.
        public var depth: Int
        /// A topic without a to-do that has tasks below it.
        public var isSummary: Bool
        /// Rows below this one (for collapsing).
        public var hasChildren: Bool
    }

    public let calendar: WorkCalendar
    public private(set) var rows: [Row] = []
    public private(set) var spans: [NodeID: TaskSpan] = [:]
    /// Summary rows' spans, from the earliest start to the latest finish below them.
    public private(set) var summarySpans: [NodeID: TaskSpan] = [:]
    public private(set) var edges: [Edge] = []
    /// Edges whose successor starts or finishes before the dependency allows.
    public private(set) var violations: Set<Edge> = []
    /// Tasks on a dependency cycle.
    public private(set) var cycle: Set<NodeID> = []

    public init(_ canvas: Canvas) {
        calendar = canvas.workCalendar
        let cal = calendar
        for (id, n) in canvas.nodes where n.todo != nil {
            if let s = canvas.span(of: id, calendar: cal) { spans[id] = s }
        }
        // Rows: tasks and the topics above them, in outline order (the root is the title).
        var hasTask = Set<NodeID>()
        for top in canvas.tops {
            var order: [(NodeID, Int)] = []
            canvas.walk(from: top) { id, _, d in order.append((id, d)) }
            // Reversed pre-order visits children before their parent.
            for (id, _) in order.reversed() {
                guard let n = canvas.nodes[id] else { continue }
                if n.todo != nil || n.children.contains(where: hasTask.contains) { hasTask.insert(id) }
            }
        }
        let rootIsTask = canvas.nodes[canvas.root]?.todo != nil
        for top in canvas.tops {
            canvas.walk(from: top) { id, n, d in
                guard hasTask.contains(id) else { return }
                if id == canvas.root && !rootIsTask { return }
                let depth = top == canvas.root ? (rootIsTask ? d : d - 1) : d
                let kids = n.children.contains { hasTask.contains($0) }
                rows.append(Row(id: id, depth: max(0, depth), isSummary: n.todo == nil, hasChildren: kids))
            }
        }
        for r in rows.reversed() where r.isSummary {
            var lo: TaskDate?
            var hi: TaskDate?
            for c in canvas.nodes[r.id]?.children ?? [] {
                guard let s = spans[c] ?? summarySpans[c] else { continue }
                lo = min(lo ?? s.start, s.start)
                hi = max(hi ?? s.finish, s.finish)
            }
            if let lo, let hi {
                summarySpans[r.id] = TaskSpan(
                    start: lo, finish: hi, milestone: false, workingDays: cal.workingDays(from: lo, through: hi))
            }
        }
        // Dependencies and the rules they set.
        for (id, n) in canvas.nodes {
            for d in n.todo?.after ?? [] where canvas.nodes[d.task] != nil && d.task != id {
                edges.append(Edge(from: d.task, to: id, type: d.type, lag: d.lag))
            }
        }
        edges.sort { ($0.to.rawValue, $0.from.rawValue) < ($1.to.rawValue, $1.from.rawValue) }
        for e in edges where !TaskSchedule.satisfied(e, spans: spans, calendar: cal) { violations.insert(e) }
        cycle = TaskSchedule.cycleMembers(edges)
    }

    /// The date an edge requires, and whether it constrains the successor's start or finish.
    public static func requirement(_ e: Edge, pred: TaskSpan, calendar cal: WorkCalendar) -> (
        onStart: Bool, date: TaskDate
    ) {
        switch e.type {
        case .finishToStart: (true, cal.shift(pred.finish, by: 1 + e.lag))
        case .startToStart: (true, cal.shift(pred.start, by: e.lag))
        case .finishToFinish: (false, cal.shift(pred.finish, by: e.lag))
        case .startToFinish: (false, cal.shift(pred.start, by: e.lag))
        }
    }

    static func satisfied(_ e: Edge, spans: [NodeID: TaskSpan], calendar cal: WorkCalendar) -> Bool {
        guard let p = spans[e.from], let s = spans[e.to] else { return true }
        let r = requirement(e, pred: p, calendar: cal)
        return r.onStart ? s.start >= r.date : s.finish >= r.date
    }

    /// Kahn's algorithm: whatever is left over sits on a cycle.
    static func cycleMembers(_ edges: [Edge]) -> Set<NodeID> {
        var indegree: [NodeID: Int] = [:]
        var out: [NodeID: [NodeID]] = [:]
        for e in edges {
            indegree[e.to, default: 0] += 1
            indegree[e.from, default: 0] += 0
            out[e.from, default: []].append(e.to)
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key)
        while let n = queue.popLast() {
            for m in out[n] ?? [] {
                indegree[m]! -= 1
                if indegree[m] == 0 { queue.append(m) }
            }
            indegree[n] = nil
        }
        // Leftovers include tasks downstream of a loop; keep those that reach themselves.
        let rest = Set(indegree.keys)
        return rest.filter { start in
            var seen = Set<NodeID>()
            var stack = (out[start] ?? []).filter(rest.contains)
            while let cur = stack.popLast() {
                if cur == start { return true }
                guard seen.insert(cur).inserted else { continue }
                stack.append(contentsOf: (out[cur] ?? []).filter(rest.contains))
            }
            return false
        }
    }

    /// Visible rows when some are collapsed (view state, D146).
    public func visibleRows(collapsed: Set<NodeID>) -> [Row] {
        guard !collapsed.isEmpty else { return rows }
        var out: [Row] = []
        var hideBelow: Int?
        for r in rows {
            if let h = hideBelow {
                if r.depth > h { continue }
                hideBelow = nil
            }
            out.append(r)
            if collapsed.contains(r.id) && r.hasChildren { hideBelow = r.depth }
        }
        return out
    }

    /// The span shown for a row (its own, or the summary of the tasks below it).
    public func displaySpan(_ id: NodeID) -> TaskSpan? { spans[id] ?? summarySpans[id] }

    /// Earliest start and latest finish over every row.
    public var range: (start: TaskDate, finish: TaskDate)? {
        let all = Array(spans.values) + Array(summarySpans.values)
        guard let lo = all.map(\.start).min(), let hi = all.map(\.finish).max() else { return nil }
        return (lo, hi)
    }
}

// MARK: Editing tasks

public enum TaskRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case dependsOnItself
    case wouldCycle
    case noDates

    public var description: String {
        switch self {
        case .dependsOnItself: CoreText.t("A task can’t depend on itself")
        case .wouldCycle: CoreText.t("That dependency would make a loop")
        case .noDates: CoreText.t("The task has no dates yet")
        }
    }
}

extension CanvasEditor {
    /// Edits a topic's task fields, making it a to-do first if needed.
    public mutating func updateTask(_ id: NodeID, _ body: (inout Todo) -> Void) {
        update(id) {
            var t = $0.todo ?? Todo(done: false)
            body(&t)
            if let p = t.progress {
                t.progress = max(0, min(100, p))
                if p >= 100 { t.done = true }
            }
            if let o = t.owner, o.trimmingCharacters(in: .whitespaces).isEmpty { t.owner = nil }
            $0.todo = t
        }
    }

    /// `successor` waits for `predecessor`. An existing dependency between them is updated.
    public mutating func addDependency(
        _ successor: NodeID, on predecessor: NodeID, type: DependencyType = .finishToStart, lag: Int = 0
    ) throws {
        guard self[successor] != nil, self[predecessor] != nil else { throw TreeOperationRefusal.missingNode }
        guard successor != predecessor else { throw TaskRefusal.dependsOnItself }
        guard !canvas.predecessors(of: predecessor).contains(successor) else { throw TaskRefusal.wouldCycle }
        if self[predecessor]?.todo == nil { update(predecessor) { $0.todo = Todo(done: false) } }
        updateTask(successor) { t in
            let d = TaskDependency(task: predecessor, type: type, lag: lag)
            if let i = t.after.firstIndex(where: { $0.task == predecessor }) {
                t.after[i].type = type
                t.after[i].lag = lag
            } else {
                t.after.append(d)
            }
        }
        pushDependants(of: [predecessor])
    }

    public mutating func removeDependency(_ successor: NodeID, on predecessor: NodeID) {
        guard self[successor]?.todo?.after.contains(where: { $0.task == predecessor }) == true else { return }
        update(successor) { $0.todo?.after.removeAll { $0.task == predecessor } }
    }

    /// Sets a task's dates, then moves later any task that now starts too early.
    public mutating func reschedule(_ id: NodeID, start: TaskDate?, due: TaskDate?) {
        updateTask(id) {
            $0.start = start
            $0.due = due
        }
        pushDependants(of: [id])
    }

    /// Moves a task by working days, keeping its length.
    public mutating func moveTask(_ id: NodeID, byWorkingDays n: Int) throws {
        guard let s = canvas.span(of: id), let t = self[id]?.todo else { throw TaskRefusal.noDates }
        let cal = canvas.workCalendar
        if s.milestone {
            reschedule(id, start: nil, due: cal.shift(s.finish, by: n))
            return
        }
        let start = cal.shift(s.start, by: n)
        let due = t.due == nil ? nil : cal.finish(start: start, days: s.workingDays)
        reschedule(id, start: start, due: due)
    }

    /// Lengthens (or shortens) a task by working days; it never ends before it starts.
    public mutating func resizeTask(_ id: NodeID, byWorkingDays n: Int) throws {
        guard let s = canvas.span(of: id) else { throw TaskRefusal.noDates }
        let cal = canvas.workCalendar
        let start = s.start
        let due = max(start, cal.shift(s.finish, by: n))
        reschedule(id, start: start, due: due)
    }

    /// Pushes dependants forward just enough to satisfy their dependencies, transitively.
    /// Tasks are never pulled earlier (D145).
    public mutating func pushDependants(of ids: [NodeID]) {
        var dependants: [NodeID: [NodeID]] = [:]
        for (id, n) in canvas.nodes {
            for d in n.todo?.after ?? [] { dependants[d.task, default: []].append(id) }
        }
        guard !dependants.isEmpty else { return }
        let cal = canvas.workCalendar
        var queue = ids
        var steps = 0
        while !queue.isEmpty, steps < 10_000 {
            steps += 1
            let cur = queue.removeFirst()
            for succ in (dependants[cur] ?? []).sorted() {
                guard var s = canvas.span(of: succ, calendar: cal), let todo = self[succ]?.todo else { continue }
                var moved = false
                for d in todo.after {
                    guard let p = canvas.span(of: d.task, calendar: cal) else { continue }
                    let e = TaskSchedule.Edge(from: d.task, to: succ, type: d.type, lag: d.lag)
                    let r = TaskSchedule.requirement(e, pred: p, calendar: cal)
                    if r.onStart, s.start < r.date {
                        let start = cal.snapForward(r.date)
                        s = shifted(s, start: start, cal)
                        moved = true
                    } else if !r.onStart, s.finish < r.date {
                        let finish = cal.snapForward(r.date)
                        let start = s.milestone ? finish : cal.shift(finish, by: -(max(1, s.workingDays) - 1))
                        s = shifted(s, start: max(s.start, start), cal)
                        if s.finish < finish { s.finish = finish }
                        moved = true
                    }
                }
                guard moved else { continue }
                update(succ) {
                    if s.milestone {
                        $0.todo?.due = s.finish
                    } else {
                        $0.todo?.start = s.start
                        if $0.todo?.due != nil { $0.todo?.due = s.finish }
                    }
                }
                queue.append(succ)
            }
        }
    }

    private func shifted(_ s: TaskSpan, start: TaskDate, _ cal: WorkCalendar) -> TaskSpan {
        var x = s
        x.start = start
        x.finish = s.milestone ? start : cal.finish(start: start, days: s.workingDays)
        return x
    }

    /// Drops dependencies on topics that were deleted.
    mutating func dropDependencies(on removed: Set<NodeID>) {
        let hit = canvas.nodes.filter { _, n in n.todo?.after.contains { removed.contains($0.task) } == true }.keys
        for id in hit.sorted() { update(id) { $0.todo?.after.removeAll { removed.contains($0.task) } } }
    }
}
