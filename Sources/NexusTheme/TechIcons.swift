import CoreGraphics
import Foundation

/// The 32 technical icons (artboard 13): vendor-neutral, a 24-pt grid like SF Symbols,
/// drawn with a 1.6 pt round stroke and inheriting the node-type colour.
public enum TechIcons {
    public static let paths: [String: String] = [
        "client": "M3 5h18v11H3z M8 20h8 M12 16v4",
        "mobile": "M7 2.5h10v19H7z M11 18.5h2",
        "actor": "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M4.5 21c1-4 4-6 7.5-6s6.5 2 7.5 6",
        "service": "M4 5h16v14H4z M8 10h8 M8 14h5",
        "gateway": "M3 12h4 M17 12h4 M7 7h10v10H7z M10.5 9.5L13 12l-2.5 2.5",
        "lb": "M12 3.5v5 M9 3.5h6 M12 8.5L5 17 M12 8.5V17 M12 8.5L19 17 M3.5 17h3 M10.5 17h3 M17.5 17h3",
        "fn": "M7 4h3l7 16 M13.5 11.5L9 20",
        "container": "M12 3l8 4.5v9L12 21l-8-4.5v-9z M4 7.5l8 4.5 8-4.5 M12 12v9",
        "cluster":
            "M7 3l4 2.3v4.4L7 12 3 9.7V5.3z M17 3l4 2.3v4.4L17 12l-4-2.3V5.3z M12 12l4 2.3v4.4L12 21l-4-2.3v-4.4z",
        "host": "M4 4h16v6H4z M4 14h16v6H4z M7.5 7h1 M7.5 17h1",
        "db":
            "M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3z M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6 M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3",
        "cache":
            "M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3z M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6 M13 10.5l-3 4h4l-3 4",
        "queue": "M3 8h18v8H3z M7.5 8v8 M12 8v8 M16.5 8v8",
        "stream": "M3 7h12 M3 12h18 M3 17h14",
        "storage": "M4 5h16l-2 15H6z M4 5c0 1.1 3.6 2 8 2s8-.9 8-2",
        "doc": "M6 3h8l4 4v14H6z M14 3v4h4 M9 12h6 M9 16h6",
        "cloud": "M7 18h10a4 4 0 0 0 .5-8A6 6 0 0 0 6 9.5 4.3 4.3 0 0 0 7 18z",
        "region": "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M3 12h18",
        "saas": "M7 17h10a4 4 0 0 0 .5-8A6 6 0 0 0 6 8.5 4.3 4.3 0 0 0 7 17z M12 11v8 M9.5 16.5L12 19l2.5-2.5",
        "router": "M4 14h16v6H4z M8 14V9 M16 14V9 M6 9h4 M14 9h4 M7.5 17h1",
        "switch": "M4 8h13 M14 5l3 3-3 3 M20 16H7 M10 13l-3 3 3 3",
        "firewall": "M3 5h18v14H3z M3 10h18 M3 15h18 M9 5v5 M15 10v5 M9 15v4",
        "auth": "M6 11h12v10H6z M8.5 11V7.5a3.5 3.5 0 0 1 7 0V11 M12 15v2",
        "secret": "M8 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z M11.5 12H21 M17.5 12v3 M20.5 12v2",
        "threat": "M12 3.5l9.5 17h-19z M12 10v5 M12 17.5v.5",
        "mitigation": "M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6z M8.5 12l2.5 2.5 4.5-5",
        "asset": "M6.5 4h11l4 5L12 21 2.5 9z M2.5 9h19 M12 21L8.5 9l2-5 M12 21l3.5-12-2-5",
        "monitor": "M3 5h18v12H3z M6 11.5h3l2-3 2 5 2-2h3 M9 21h6",
        "process": "M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16z",
        "entity": "M5 5h14v14H5z",
        "store": "M4 6h16 M4 18h16 M4 6v12",
        "decision": "M12 3l9 9-9 9-9-9z",
    ]

    private nonisolated(unsafe) static var cache: [String: CGPath] = [:]
    private static let lock = NSLock()

    /// The icon in 24 × 24 coordinates.
    public static func path(_ id: String) -> CGPath? {
        lock.lock()
        defer { lock.unlock() }
        if let p = cache[id] { return p }
        guard let d = paths[id], let p = SVGPath.parse(d) else { return nil }
        cache[id] = p
        return p
    }

    /// The icon fitted into `rect` (square, centred).
    public static func path(_ id: String, in rect: CGRect) -> CGPath? {
        guard let p = path(id) else { return nil }
        let s = min(rect.width, rect.height) / 24
        var t = CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12 * s).scaledBy(x: s, y: s)
        return p.copy(using: &t)
    }
}
