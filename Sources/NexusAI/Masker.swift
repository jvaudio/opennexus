import Foundation
import NaturalLanguage
import NexusCore

/// Data masking (artboard 52): finds emails, keys, names and phone numbers in topics and
/// notes. You review each hit; the masked copy is a new canvas (the original stays).
public enum Masker {
    public enum Kind: String, Sendable, CaseIterable {
        case emails, keys, names, phones, custom
        public var title: String {
            switch self {
            case .emails: "Emails"
            case .keys: "Keys"
            case .names: "Names"
            case .phones: "Phones"
            case .custom: "Custom"
            }
        }
    }

    /// Settings › Privacy & Data › Data masking.
    public struct Options: Sendable, Equatable {
        public var kinds: Set<Kind> = [.emails, .keys, .names, .phones, .custom]
        /// Extra regular expressions (ticket or account ids).
        public var custom: [String] = []
        /// "••••", "████" or "[redacted]".
        public var glyph = "█"
        public init() {}

        public func mask(_ length: Int) -> String {
            switch glyph {
            case "[redacted]": "[redacted]"
            case "••••": String(repeating: "•", count: min(max(length, 4), 12))
            default: String(repeating: "█", count: min(max(length, 4), 12))
            }
        }
    }

    public struct Hit: Hashable, Sendable, Identifiable {
        public var kind: Kind
        public var node: NodeID
        /// text, note, comment.N or author.N
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

    public static func scan(_ c: Canvas, options: Options = Options()) -> [Hit] {
        var out: [Hit] = []
        for id in c.tops.flatMap({ c.subtree($0) }) {
            guard let n = c.nodes[id] else { continue }
            out += scan(n.text, node: id, field: "text", options: options)
            if let note = n.note?.text { out += scan(note, node: id, field: "note", options: options) }
            // Comments (M14): the text, and the author as a name when names are masked.
            for (i, cm) in n.comments.enumerated() {
                out += scan(cm.text, node: id, field: "comment.\(i)", options: options)
                if options.kinds.contains(.names), !cm.author.isEmpty {
                    let r = NSRange(location: 0, length: (cm.author as NSString).length)
                    out.append(Hit(kind: .names, node: id, field: "author.\(i)", range: r, text: cm.author))
                }
            }
        }
        return out
    }

    /// The text with every hit masked (the Settings preview, quick masking).
    public static func mask(_ s: String, options: Options = Options()) -> String {
        var ns = s as NSString
        for h in scan(s, node: "n", field: "text", options: options).sorted(by: {
            $0.range.location > $1.range.location
        }) {
            ns = ns.replacingCharacters(in: h.range, with: options.mask(h.range.length)) as NSString
        }
        return ns as String
    }

    static func scan(_ s: String, node: NodeID, field: String, options: Options = Options()) -> [Hit] {
        var hits: [Hit] = []
        let ns = s as NSString
        var taken: [NSRange] = []
        let all =
            patterns.filter { options.kinds.contains($0.0) }
            + (options.kinds.contains(.custom) ? options.custom.filter { !$0.isEmpty }.map { (Kind.custom, $0) } : [])
        for (kind, p) in all {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                taken.append(m.range)
                hits.append(
                    Hit(kind: kind, node: node, field: field, range: m.range, text: ns.substring(with: m.range)))
            }
        }
        // Person names from NaturalLanguage's named-entity tagger.
        guard options.kinds.contains(.names) else { return hits }
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

    /// The text a hit's field names on a topic.
    public static func text(of field: String, in n: Node) -> String {
        let parts = field.split(separator: ".")
        let i = parts.count == 2 ? Int(parts[1]).flatMap { n.comments.indices.contains($0) ? $0 : nil } : nil
        switch (parts.first, i) {
        case ("comment"?, let i?): return n.comments[i].text
        case ("author"?, let i?): return n.comments[i].author
        case ("note"?, _): return n.note?.text ?? ""
        default: return n.text
        }
    }

    public static func counts(_ hits: [Hit]) -> [(Kind, Int)] {
        Kind.allCases.map { k in (k, hits.filter { $0.kind == k }.count) }
    }

    /// A masked copy: each accepted hit becomes a bar of █ the same length (at most 12).
    public static func maskedCopy(_ c: Canvas, hits: [Hit], id: CanvasID, options: Options = Options()) -> Canvas {
        var copy = c
        copy.id = id
        copy.title = (c.title.isEmpty ? (c.nodes[c.root]?.text ?? "Map") : c.title) + " (masked)"
        let byField = Dictionary(grouping: hits) { "\($0.node.rawValue)/\($0.field)" }
        for (_, hs) in byField {
            guard let h0 = hs.first, var n = copy.nodes[h0.node] else { continue }
            let parts = h0.field.split(separator: ".")
            let index = parts.count == 2 ? Int(parts[1]).flatMap { n.comments.indices.contains($0) ? $0 : nil } : nil
            var s: NSString
            switch (parts.first, index) {
            case ("comment"?, let i?): s = n.comments[i].text as NSString
            case ("author"?, let i?): s = n.comments[i].author as NSString
            case ("note"?, _): s = (n.note?.text ?? "") as NSString
            default: s = n.text as NSString
            }
            for h in hs.sorted(by: { $0.range.location > $1.range.location })
            where h.range.location + h.range.length <= s.length {
                s = s.replacingCharacters(in: h.range, with: options.mask(h.range.length)) as NSString
            }
            switch (parts.first, index) {
            case ("comment"?, let i?): n.comments[i].text = s as String
            case ("author"?, let i?): n.comments[i].author = s as String
            case ("note"?, _): n.note?.text = s as String
            default: n.text = s as String
            }
            n.marks = []
            copy.nodes[h0.node] = n
        }
        return copy
    }
}
