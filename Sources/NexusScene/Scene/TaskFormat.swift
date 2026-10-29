import Foundation
import NexusCore

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
    package static let utc = TimeZone(identifier: "UTC")!

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
