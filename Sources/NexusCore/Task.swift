import Foundation

/// A calendar date with no time or time zone (`yyyy-MM-dd`), stored as days since
/// 1970-01-01 so arithmetic and weekdays need no `Calendar` (D142).
public struct TaskDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Days since 1970-01-01.
    public var day: Int

    public init(day: Int) { self.day = day }

    public init?(year: Int, month: Int, day d: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), d >= 1, d <= TaskDate.days(in: month, year: year)
        else { return nil }
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        day = era * 146_097 + doe - 719_468
    }

    /// `2026-11-02`; nil for anything else.
    public init?(_ s: String) {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    init(json s: String, path: String) throws {
        guard let d = TaskDate(s) else { throw ModelDecodingError(path: path, "expected a date like 2026-11-02") }
        self = d
    }

    /// The local calendar day of `date` in `zone` (used for Xmind's epoch times and "today").
    public init(_ date: Date, in zone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self = TaskDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1) ?? TaskDate(day: 0)
    }

    public static func today(in zone: TimeZone = .current) -> TaskDate { TaskDate(Date(), in: zone) }

    public var components: (year: Int, month: Int, day: Int) {
        // Howard Hinnant's civil_from_days.
        let z = day + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// ISO weekday: 1 is Monday, 7 is Sunday.
    public var weekday: Int { ((day % 7 + 7) % 7 + 3) % 7 + 1 }

    /// Midnight at the start of this day in `zone`.
    public func date(in zone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = components
        return cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days n: Int) -> TaskDate { TaskDate(day: day + n) }

    public var description: String {
        let c = components
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    public static func < (a: TaskDate, b: TaskDate) -> Bool { a.day < b.day }

    static func days(in month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

/// How a successor waits for its predecessor.
public enum DependencyType: String, Sendable, CaseIterable {
    /// Finish to start: the successor starts after the predecessor finishes.
    case finishToStart = "FS"
    case startToStart = "SS"
    case finishToFinish = "FF"
    case startToFinish = "SF"
}

/// One dependency, stored on the successor's to-do (`todo.after`).
public struct TaskDependency: Hashable, Sendable, JSONRepresentable {
    /// The predecessor topic (same canvas).
    public var task: NodeID
    public var type: DependencyType = .finishToStart
    /// Working days of delay (negative overlaps).
    public var lag: Int = 0
    public var extra: [String: JSONValue] = [:]

    public init(task: NodeID, type: DependencyType = .finishToStart, lag: Int = 0) {
        self.task = task
        self.type = type
        self.lag = lag
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        task = NodeID(try r.string("task"))
        let t = try r.optionalString("type") ?? "FS"
        guard let type = DependencyType(rawValue: t) else {
            throw ModelDecodingError(path: "\(path).type", "expected FS, SS, FF or SF")
        }
        self.type = type
        lag = try r.optionalInt("lag", in: -3650...3650) ?? 0
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("task", task.rawValue)
        if type != .finishToStart { w.set("type", type.rawValue) }
        if lag != 0 { w.set("lag", .number(Double(lag))) }
        return w.value
    }
}

/// A canvas's work calendar (`canvas.schedule`), written only when not the default (D145).
public struct WorkSchedule: Hashable, Sendable, JSONRepresentable {
    /// ISO weekdays that are working days (1 is Monday).
    public var workdays: [Int] = [1, 2, 3, 4, 5]
    public var holidays: [TaskDate] = []
    /// Skip non-working days when counting durations and drawing bars (Xmind's toggle).
    public var skipNonWorking = true
    public var extra: [String: JSONValue] = [:]

    public init() {}

    public var isDefault: Bool { self == WorkSchedule() }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        let days = try r.array("workdays")
        if r.raw("workdays") != nil {
            workdays = try days.enumerated().map { i, v in
                guard case .number(let n) = v, n == n.rounded(), n >= 1, n <= 7 else {
                    throw ModelDecodingError(path: "\(path).workdays[\(i)]", "expected a weekday 1–7")
                }
                return Int(n)
            }
        }
        holidays = try r.strings("holidays").enumerated().map {
            try TaskDate(json: $1, path: "\(path).holidays[\($0)]")
        }
        skipNonWorking = try r.bool("skipNonWorking", default: true)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("workdays", .array(workdays.map { .number(Double($0)) }))
        w.set("holidays", holidays.map(\.description), omitEmpty: true)
        w.set("skipNonWorking", skipNonWorking, omitting: true)
        return w.value
    }

    /// Working-day arithmetic for this schedule.
    public var calendar: WorkCalendar { WorkCalendar(self) }
}

/// Working-day arithmetic. With skipping off (or no working weekdays), every day works.
public struct WorkCalendar: Sendable {
    let workdays: Set<Int>
    let holidays: Set<TaskDate>
    let skip: Bool

    public init(_ s: WorkSchedule = WorkSchedule()) {
        workdays = Set(s.workdays)
        holidays = Set(s.holidays)
        skip = s.skipNonWorking && !workdays.isEmpty
    }

    public func isWorking(_ d: TaskDate) -> Bool {
        !skip || (workdays.contains(d.weekday) && !holidays.contains(d))
    }

    /// `d` itself when it works, else the next working day.
    public func snapForward(_ d: TaskDate) -> TaskDate {
        var x = d
        for _ in 0..<4000 where !isWorking(x) { x = x.adding(days: 1) }
        return x
    }

    /// `d` itself when it works, else the previous working day.
    public func snapBack(_ d: TaskDate) -> TaskDate {
        var x = d
        for _ in 0..<4000 where !isWorking(x) { x = x.adding(days: -1) }
        return x
    }

    /// Moves `n` working days from `d` (backwards when negative), landing on a working day.
    public func shift(_ d: TaskDate, by n: Int) -> TaskDate {
        var x = n >= 0 ? snapForward(d) : snapBack(d)
        var left = abs(n)
        let step = n >= 0 ? 1 : -1
        var guardSteps = 0
        while left > 0, guardSteps < 400_000 {
            x = x.adding(days: step)
            guardSteps += 1
            if isWorking(x) { left -= 1 }
        }
        return x
    }

    /// Working days from `a` through `b`, inclusive (0 when `b` is before `a`).
    public func workingDays(from a: TaskDate, through b: TaskDate) -> Int {
        guard b >= a else { return 0 }
        guard skip else { return b.day - a.day + 1 }
        let span = b.day - a.day + 1
        var n = (span / 7) * workdays.count
        var x = a.adding(days: (span / 7) * 7)
        while x <= b {
            if workdays.contains(x.weekday) { n += 1 }
            x = x.adding(days: 1)
        }
        for h in holidays where h >= a && h <= b && workdays.contains(h.weekday) { n -= 1 }
        return max(0, n)
    }

    /// The last day of a task that starts on `start` and lasts `days` working days.
    public func finish(start: TaskDate, days: Int) -> TaskDate {
        shift(snapForward(start), by: max(1, days) - 1)
    }
}
