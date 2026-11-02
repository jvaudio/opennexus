import Foundation

/// Requests per minute per address, in fixed one-minute windows.
public actor RateLimiter {
    let perMinute: Int
    var windows: [String: (start: Date, count: Int)] = [:]

    public init(perMinute: Int) { self.perMinute = perMinute }

    /// Nil when allowed; otherwise the seconds until the address may try again.
    public func check(_ address: String, now: Date = Date()) -> Int? {
        if windows.count > 10_000 { windows = windows.filter { now.timeIntervalSince($0.value.start) < 60 } }
        var w = windows[address] ?? (now, 0)
        if now.timeIntervalSince(w.start) >= 60 { w = (now, 0) }
        guard w.count < perMinute else { return max(1, Int((60 - now.timeIntervalSince(w.start)).rounded(.up))) }
        w.count += 1
        windows[address] = w
        return nil
    }
}

/// Deletes expired shares, at most every ten minutes (reads also refuse them on their own).
public actor Sweeper {
    let storage: any ShareStorage
    var last = Date.distantPast
    public init(storage: any ShareStorage) { self.storage = storage }

    public func sweepIfDue(now: Date) {
        guard now.timeIntervalSince(last) >= 600 else { return }
        last = now
        let storage = storage
        Task { await Self.sweep(storage, now: now) }
    }

    @discardableResult
    public static func sweep(_ storage: any ShareStorage, now: Date) async -> Int {
        var removed = 0
        for id in (try? await storage.ids()) ?? [] {
            if let m = try? await storage.meta(id), m.isExpired(now) {
                try? await storage.delete(id)
                removed += 1
            }
        }
        return removed
    }
}
