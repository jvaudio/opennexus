import Foundation

/// Where formulas sit in topic text and notes (M48): `$…$` inline and `$$…$$` display, by
/// Pandoc's rules so prices don't turn into maths: an opening `$` has a non-space after
/// it, a closing `$` a non-space before it and no digit after it. `\$` is a dollar sign.
public enum MathMarkup {
    public struct Formula: Hashable, Sendable {
        /// The formula with its dollar signs, in UTF-16 units.
        public var range: NSRange
        /// The TeX between them.
        public var source: String
        public var display: Bool
    }

    public struct Scan: Sendable {
        public var formulas: [Formula] = []
        /// Each `\` of a `\$` outside formulas (UTF-16 offsets): shown as `$` alone.
        public var escapes: [Int] = []
    }

    /// Whether the text could hold a formula at all (the fast path for everything else).
    public static func mayContain(_ text: String) -> Bool { text.utf8.contains(UInt8(ascii: "$")) }

    public static func scan(_ text: String) -> Scan {
        var out = Scan()
        guard mayContain(text) else { return out }
        let u = Array(text.utf16)
        let dollar: UInt16 = 36
        let backslash: UInt16 = 92
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == backslash, i + 1 < u.count {
                if u[i + 1] == dollar { out.escapes.append(i) }
                i += 2
                continue
            }
            guard c == dollar else {
                i += 1
                continue
            }
            if i + 1 < u.count, u[i + 1] == dollar {
                // Display: up to the next unescaped `$$`.
                var j = i + 2
                var end: Int?
                while j + 1 < u.count {
                    if u[j] == backslash {
                        j += 2
                        continue
                    }
                    if u[j] == dollar, u[j + 1] == dollar {
                        end = j
                        break
                    }
                    j += 1
                }
                if let end, end > i + 2 {
                    let source = String(utf16CodeUnits: Array(u[(i + 2)..<end]), count: end - i - 2)
                    if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.formulas.append(
                            Formula(
                                range: NSRange(location: i, length: end + 2 - i),
                                source: source.trimmingCharacters(in: .whitespacesAndNewlines), display: true))
                        i = end + 2
                        continue
                    }
                }
                i += 2
                continue
            }
            // Inline: the opening dollar must touch its formula.
            guard i + 1 < u.count, !isSpace(u[i + 1]) else {
                i += 1
                continue
            }
            var j = i + 1
            var end: Int?
            while j < u.count {
                if u[j] == backslash {
                    j += 2
                    continue
                }
                if u[j] == dollar {
                    if !isSpace(u[j - 1]), !(j + 1 < u.count && isDigit(u[j + 1])) { end = j }
                    break
                }
                j += 1
            }
            if let end {
                out.formulas.append(
                    Formula(
                        range: NSRange(location: i, length: end + 1 - i),
                        source: String(utf16CodeUnits: Array(u[(i + 1)..<end]), count: end - i - 1),
                        display: false))
                i = end + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// The TeX of a text that is one display formula and nothing else (`$$…$$`), as a
    /// `/math` topic travels through Markdown and Xmind.
    public static func wholeDisplay(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = scan(t).formulas
        guard f.count == 1, f[0].display, f[0].range == NSRange(location: 0, length: (t as NSString).length)
        else { return nil }
        return f[0].source
    }

    /// The text as read aloud or exported as plain text: formulas keep their TeX, without
    /// dollar signs, and `\$` is `$`.
    public static func plain(_ text: String) -> String {
        let s = scan(text)
        guard !s.formulas.isEmpty || !s.escapes.isEmpty else { return text }
        let out = NSMutableString(string: text)
        let edits =
            s.formulas.map { ($0.range, $0.source) } + s.escapes.map { (NSRange(location: $0, length: 2), "$") }
        for (r, t) in edits.sorted(by: { $0.0.location > $1.0.location }) { out.replaceCharacters(in: r, with: t) }
        return out as String
    }
}
