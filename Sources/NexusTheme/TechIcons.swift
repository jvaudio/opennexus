import CoreGraphics
import Foundation

/// The 32 technical icons (artboard 13): vendor-neutral, a 24-pt grid like SF Symbols,
/// drawn with a 1.6 pt round stroke and inheriting the node-type colour. The paths are the
/// artboard's own (`Handoff/design/source/Icons.dc.html`); a zero-length `h.01` draws a dot
/// with the round cap.
public enum TechIcons {
    public static let paths: [String: String] = [
        "client": "M3 5h18v14H3z M3 9h18 M6 7h.01 M9 7h.01",
        "mobile": "M8 3h8v18H8z M11 18h2",
        "actor": "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M4 21c1-4 4-6 8-6s7 2 8 6",
        "service": "M4 6h16v12H4z M8 10h8 M8 14h5",
        "gateway": "M2 12h5 M17 12h5 M7 6h10v12H7z M11 9l2 3-2 3",
        "lb": "M10 3h4v4h-4z M12 7v4 M5 11h14 M5 11v3 M12 11v3 M19 11v3 M3 14h4v5H3z M10 14h4v5h-4z M17 14h4v5h-4z",
        "fn": "M6 20l6-16h2 M9.5 12.5L14 20h4",
        "container": "M3 8l9-5 9 5v8l-9 5-9-5z M3 8l9 5 9-5 M12 13v8",
        "cluster": "M12 3l8 4.5v9L12 21l-8-4.5v-9z M12 8v8 M8.5 10l7 4 M15.5 10l-7 4",
        "host": "M4 4h16v7H4z M4 13h16v7H4z M7 7.5h.01 M7 16.5h.01 M11 7.5h6 M11 16.5h6",
        "db":
            "M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3z M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6 M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3",
        "cache":
            "M4 7c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3z M4 7v10c0 1.7 3.6 3 8 3s8-1.3 8-3V7 M13 11l-3 4h4l-3 4",
        "queue": "M3 8h18v8H3z M7 8v8 M11 8v8 M15 8v8",
        "stream": "M3 7h12 M3 12h18 M3 17h14 M17 5l2 2-2 2 M19 15l2 2-2 2",
        "storage": "M4 6h16l-2 14H6z M4 6c0-1 3.6-2 8-2s8 1 8 2",
        "doc": "M6 3h8l4 4v14H6z M14 3v4h4 M9 12h6 M9 16h6",
        "cloud": "M7 18a4 4 0 0 1-.5-8A5.5 5.5 0 0 1 17 8.5a4 4 0 0 1 .5 9.5z",
        "region":
            "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M3 12h18 M12 3c2.5 2.5 3.5 5.5 3.5 9s-1 6.5-3.5 9 M12 3c-2.5 2.5-3.5 5.5-3.5 9s1 6.5 3.5 9",
        "saas": "M7 16a4 4 0 0 1-.5-8A5.5 5.5 0 0 1 17 6.5a4 4 0 0 1 .5 9.5 M12 11v9 M9 17l3 3 3-3",
        "router": "M3 14h18v6H3z M7 17h.01 M11 17h.01 M8 14L6 9 M16 14l2-5 M9 6a5 5 0 0 1 6 0",
        "switch": "M3 8h18v8H3z M7 12h.01 M10 12h.01 M13 12h.01 M16 12h3",
        "firewall": "M3 5h18v14H3z M3 10h18 M3 15h18 M9 5v5 M15 10v5 M9 15v4",
        "auth": "M6 11h12v10H6z M8 11V8a4 4 0 0 1 8 0v3 M12 15v2",
        "secret": "M8 15a4 4 0 1 1 2.8-6.8 M10.8 8.2L20 17.4V20h-2.6 M17 15l-1.5 1.5",
        "threat": "M12 3L2 20h20z M12 9v5 M12 17h.01",
        "mitigation": "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z M8.5 12l2.5 2.5 4.5-5",
        "asset": "M6 4h12l3 5-9 11L3 9z M3 9h18 M9 4l3 16 M15 4l-3 16",
        "monitor": "M3 12h4l3-7 4 14 3-7h4",
        "process": "M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16z M8 12h8",
        "entity": "M4 7h13v13H4z M17 7l3-3v13l-3 3 M4 7l3-3h13",
        "store": "M3 7h18 M3 17h18 M7 7v10",
        "decision": "M12 3l9 9-9 9-9-9z M10 10a2 2 0 1 1 2.5 2c-.5.2-.5.6-.5 1 M12 15.5h.01",
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
