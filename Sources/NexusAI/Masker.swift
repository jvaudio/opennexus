import Foundation
import NaturalLanguage
import NexusCore

/// Data masking (artboard 52): finds emails, keys, names and phone numbers in topics and
/// notes. You review each hit; the masked copy is a new canvas (the original stays).
public enum Masker {
    public enum Kind: String, Sendable, CaseIterable {
        case emails, keys, names, phones
        public var title: String {
            switch self {
            case .emails: "Emails"
            case .keys: "Keys"
            case .names: "Names"
            case .phones: "Phones"
            }
        }
    }

    public struct Hit: Hashable, Sendable, Identifiable {
        public var kind: Kind
        public var node: NodeID
        /// text or note
        public var field: String
        public var range: NSRange
        public var text: String
        public var id: String { "\(node.rawValue)/\(field)/\(range.location)" }
    }

    static let patterns: [(Kind, String)] = [
        (.emails, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        (
            .keys,
            #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{8,}\b|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bxox[abpr]-[A-Za-z0-9-]{10,}\b|\b[A-Za-z0-9_\-]{32,}\b"#
        ),
        (.phones, #"(?<![\w@])\+?\d[\d ().-]{7,}\d(?!\w)"#),
    ]

    public static func scan(_ c: Canvas) -> [Hit] {
        var out: [Hit] = []
        for id in c.tops.flatMap({ c.subtree($0) }) {
            guard let n = c.nodes[id] else { continue }
            out += scan(n.text, node: id, field: "text")
            if let note = n.note?.text { out += scan(note, node: id, field: "note") }
        }
        return out
    }

    static func scan(_ s: String, node: NodeID, field: String) -> [Hit] {
        var hits: [Hit] = []
        let ns = s as NSString
        var taken: [NSRange] = []
        for (kind, p) in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                taken.append(m.range)
                hits.append(
                    Hit(kind: kind, node: node, field: field, range: m.range, text: ns.substring(with: m.range)))
            }
        }
        // Person names from NaturalLanguage's named-entity tagger.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = s
        tagger.enumerateTags(
            in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, r in
            if tag == .personalName {
                let range = NSRange(r, in: s)
                if !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                    hits.append(Hit(kind: .names, node: node, field: field, range: range, text: String(s[r])))
                }
            }
            return true
        }
        return hits
    }

    public static func counts(_ hits: [Hit]) -> [(Kind, Int)] {
        Kind.allCases.map { k in (k, hits.filter { $0.kind == k }.count) }
    }

    /// A masked copy: each accepted hit becomes a bar of █ the same length (at most 12).
    public static func maskedCopy(_ c: Canvas, hits: [Hit], id: CanvasID) -> Canvas {
        var copy = c
        copy.id = id
        copy.title = (c.title.isEmpty ? (c.nodes[c.root]?.text ?? "Map") : c.title) + " (masked)"
        let byField = Dictionary(grouping: hits) { "\($0.node.rawValue)/\($0.field)" }
        for (_, hs) in byField {
            guard let h0 = hs.first, var n = copy.nodes[h0.node] else { continue }
            var s = (h0.field == "note" ? n.note?.text ?? "" : n.text) as NSString
            for h in hs.sorted(by: { $0.range.location > $1.range.location })
            where h.range.location + h.range.length <= s.length {
                s =
                    s.replacingCharacters(
                        in: h.range, with: String(repeating: "█", count: min(max(h.range.length, 4), 12)))
                    as NSString
            }
            if h0.field == "note" { n.note?.text = s as String } else { n.text = s as String }
            n.marks = []
            copy.nodes[h0.node] = n
        }
        return copy
    }
}
