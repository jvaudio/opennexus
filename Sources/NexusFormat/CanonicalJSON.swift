import Foundation
import NexusCore

/// Writes JSON in the one canonical form OpenNexus uses on disk, so the same model
/// always produces the same bytes and files diff cleanly in Git:
///
/// - object keys sorted by Unicode code point
/// - two-space indent, `"key": value`, one value per line
/// - empty containers as `{}` and `[]`
/// - integers without a decimal point; other numbers in shortest round-trip form
/// - only `"`, `\` and control characters escaped (UTF-8 kept as is)
/// - LF line endings and a trailing newline
public enum CanonicalJSON {
    public static func data(_ value: JSONValue) -> Data {
        Data(string(value).utf8)
    }

    public static func string(_ value: JSONValue) -> String {
        var out = ""
        out.reserveCapacity(4096)
        write(value, indent: 0, into: &out)
        out.append("\n")
        return out
    }

    /// The same form on one line with no spaces: what viewer copies and interactive
    /// exports carry (M43).
    public static func compact(_ value: JSONValue) -> String {
        var out = ""
        out.reserveCapacity(1 << 16)
        writeCompact(value, into: &out)
        return out
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func write(_ value: JSONValue, indent: Int, into out: inout String) {
        switch value {
        case .null: out.append("null")
        case .bool(let b): out.append(b ? "true" : "false")
        case .number(let n): out.append(number(n))
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            if a.isEmpty {
                out.append("[]")
                return
            }
            out.append("[\n")
            for (i, v) in a.enumerated() {
                pad(indent + 1, &out)
                write(v, indent: indent + 1, into: &out)
                out.append(i == a.count - 1 ? "\n" : ",\n")
            }
            pad(indent, &out)
            out.append("]")
        case .object(let o):
            if o.isEmpty {
                out.append("{}")
                return
            }
            out.append("{\n")
            let keys = o.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            for (i, k) in keys.enumerated() {
                pad(indent + 1, &out)
                writeString(k, into: &out)
                out.append(": ")
                write(o[k]!, indent: indent + 1, into: &out)
                out.append(i == keys.count - 1 ? "\n" : ",\n")
            }
            pad(indent, &out)
            out.append("}")
        }
    }

    private static func writeCompact(_ value: JSONValue, into out: inout String) {
        switch value {
        case .array(let a):
            out.append("[")
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(",") }
                writeCompact(v, into: &out)
            }
            out.append("]")
        case .object(let o):
            out.append("{")
            let keys = o.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            for (i, k) in keys.enumerated() {
                if i > 0 { out.append(",") }
                writeString(k, into: &out)
                out.append(":")
                writeCompact(o[k]!, into: &out)
            }
            out.append("}")
        default: write(value, indent: 0, into: &out)
        }
    }

    private static func pad(_ level: Int, _ out: inout String) {
        out.append(String(repeating: "  ", count: level))
    }

    static func number(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
            return String(Int64(n))
        }
        return "\(n)"
    }

    private static func writeString(_ s: String, into out: inout String) {
        out.append("\"")
        // Copy the runs between escapes whole, not scalar by scalar (SVGs run to megabytes).
        let u = s.utf8
        var run = u.startIndex
        var i = run
        while i != u.endIndex {
            let b = u[i]
            guard b < 0x20 || b == 0x22 || b == 0x5C else {
                i = u.index(after: i)
                continue
            }
            out.append(contentsOf: Substring(s.unicodeScalars[run..<i]))
            switch b {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            default: out.append(String(format: "\\u%04x", b))
            }
            i = u.index(after: i)
            run = i
        }
        out.append(contentsOf: Substring(s.unicodeScalars[run..<u.endIndex]))
        out.append("\"")
    }
}
