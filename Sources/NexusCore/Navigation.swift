import Foundation

// MARK: Filters (artboard 27)

/// A filter over topics: AND of clauses such as `type: Threat`, `risk: High`,
/// `status ≠ Mitigated`, `label: Q4`, or plain text.
public struct NodeFilter: Hashable, Sendable, JSONRepresentable {
    public struct Clause: Hashable, Sendable {
        public enum Op: String, Sendable { case equals = ":", notEquals = "≠", contains = "~" }
        public var field: String
        public var op: Op
        public var value: String

        public init(field: String, op: Op, value: String) {
            self.field = field
            self.op = op
            self.value = value
        }

        /// Chip text, as typed.
        public var text: String {
            field == "text" && op == .contains
                ? value
                : "\(field) \(op == .equals ? ":" : op.rawValue) \(value)"
                    .replacingOccurrences(of: " : ", with: ": ")
        }
    }

    public var name: String
    public var clauses: [Clause]
    /// Hide non-matching topics instead of dimming them.
    public var hide: Bool
    public var extra: [String: JSONValue] = [:]

    public init(name: String = "", clauses: [Clause] = [], hide: Bool = false) {
        self.name = name
        self.clauses = clauses
        self.hide = hide
    }

    public static let fields = [
        "type", "risk", "status", "marker", "label", "text", "todo", "note", "ai", "owner", "due", "task",
        "comment",
    ]

    /// Parses one chip: `field: value`, `field = value`, `field != value`, `field ≠ value`,
    /// or plain text (matches topic text).
    public static func parse(_ s: String) -> Clause? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        for (token, op) in [("≠", Clause.Op.notEquals), ("!=", .notEquals), (":", .equals), ("=", .equals)] {
            if let r = t.range(of: token) {
                let field = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                let value = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if fields.contains(field), !value.isEmpty { return Clause(field: field, op: op, value: value) }
            }
        }
        return Clause(field: "text", op: .contains, value: t)
    }

    func value(_ c: Clause, of id: NodeID, in canvas: Canvas, parents: [NodeID: NodeID]) -> [String] {
        guard let n = canvas.nodes[id] else { return [] }
        switch c.field {
        case "type":
            let t = DiagramCatalog.effectiveType(id, in: canvas, parents: parents)
            let name = t.flatMap { DiagramCatalog.info($0, in: canvas.type)?.name } ?? ""
            return [t?.rawValue ?? "topic", name]
        case "risk": return [Stride.field(n, Stride.riskKey) ?? ""]
        case "status": return [Stride.field(n, Stride.statusKey) ?? (n.todo.map { $0.done ? "Done" : "Open" } ?? "")]
        case "marker": return n.markers
        case "label": return n.labels
        case "todo": return [n.todo.map { $0.done ? "done" : "open" } ?? "none"]
        case "note": return [n.note?.text ?? ""]
        case "ai": return [n.ai ? "yes" : "no"]
        // M11: `owner: Ana`, `due: overdue` (or `week`, `none`, a date), `task: yes`.
        case "owner": return [n.todo?.owner ?? ""]
        case "task": return [n.todo?.isScheduled == true ? "yes" : "no"]
        // M14: `comment: yes`, `comment: Ana` (an author), `comment: budget` (words in the text).
        case "comment": return [n.comments.isEmpty ? "no" : "yes"] + n.comments.flatMap { [$0.author, $0.text] }
        case "due":
            guard let s = canvas.span(of: id) else { return n.todo == nil ? [] : ["none"] }
            let today = TaskDate.today()
            var out = [s.finish.description]
            if n.todo?.done != true && s.finish < today { out.append("overdue") }
            if s.finish >= today && s.finish.day - today.day < 7 { out.append("week") }
            return out
        default: return [n.text]
        }
    }

    public func matches(_ id: NodeID, in canvas: Canvas, parents: [NodeID: NodeID]? = nil) -> Bool {
        let p = parents ?? canvas.parentMap()
        return clauses.allSatisfy { c in
            let vals = value(c, of: id, in: canvas, parents: p).map { $0.lowercased() }
            let v = c.value.lowercased()
            let hit =
                switch c.op {
                case .contains: vals.contains { $0.contains(v) }
                // Markers match by family (`priority` matches priority-1); "Medium" matches "Med".
                default:
                    vals.contains {
                        $0 == v || (c.field == "marker" && $0.hasPrefix(v))
                            || (c.field == "risk" && !$0.isEmpty && v.hasPrefix($0))
                            || (c.field == "comment" && v.count > 2 && $0.contains(v))
                    }
                }
            return c.op == .notEquals ? !hit : hit
        }
    }

    /// Matching topics, in tree order.
    public func matching(in canvas: Canvas) -> [NodeID] {
        let p = canvas.parentMap()
        return canvas.tops.flatMap { canvas.subtree($0) }.filter { matches($0, in: canvas, parents: p) }
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        name = try r.optionalString("name") ?? ""
        hide = try r.bool("hide", default: false)
        clauses = try r.strings("clauses").compactMap(Self.parse)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("name", name)
        w.set("clauses", clauses.map(\.text), omitEmpty: false)
        w.set("hide", hide, omitting: false)
        return w.value
    }
}

// MARK: Find & replace (artboard 47)

public struct SearchOptions: Hashable, Sendable {
    public var matchCase = false
    public var wholeWords = false
    public var regex = false
    public var allCanvases = false
    public var notes = false
    public var labels = false
    public init() {}
}

public struct SearchMatch: Hashable, Sendable, Identifiable {
    public enum Field: String, Sendable { case text, note, label, comment }
    public var canvas: CanvasID
    public var node: NodeID
    public var field: Field
    /// Label index for `.label`, comment index for `.comment`.
    public var index: Int = 0
    /// UTF-16 range inside the field.
    public var range: NSRange
    public var id: String { "\(canvas.rawValue)/\(node.rawValue)/\(field.rawValue)/\(index)/\(range.location)" }
}

public enum TextSearch {
    /// nil when the pattern is invalid (regex) or empty.
    public static func expression(_ query: String, _ o: SearchOptions) -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = o.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if o.wholeWords { pattern = "\\b(?:\(pattern))\\b" }
        return try? NSRegularExpression(pattern: pattern, options: o.matchCase ? [] : [.caseInsensitive])
    }

    public static func find(_ query: String, _ o: SearchOptions, in doc: DocumentModel, current: CanvasID)
        -> [SearchMatch]
    {
        guard let re = expression(query, o) else { return [] }
        let ids = o.allCanvases ? doc.canvasOrder : [current]
        var out: [SearchMatch] = []
        for cid in ids {
            guard let c = doc.canvases[cid] else { continue }
            for id in c.tops.flatMap({ c.subtree($0) }) {
                guard let n = c.nodes[id] else { continue }
                func scan(_ s: String, _ f: SearchMatch.Field, _ i: Int = 0) {
                    for m in re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
                    where m.range.length > 0 {
                        out.append(SearchMatch(canvas: cid, node: id, field: f, index: i, range: m.range))
                    }
                }
                scan(n.text, .text)
                if o.notes, let note = n.note?.text { scan(note, .note) }
                // "+ Notes" covers comments too (M14).
                if o.notes { for (i, cm) in n.comments.enumerated() { scan(cm.text, .comment, i) } }
                if o.labels { for (i, l) in n.labels.enumerated() { scan(l, .label, i) } }
            }
        }
        return out
    }

    /// The replacement for one match (regex templates like `$1` work in regex mode).
    static func replaced(
        _ s: String, _ m: SearchMatch, _ re: NSRegularExpression, with template: String, _ o: SearchOptions
    )
        -> String
    {
        let ns = s as NSString
        guard m.range.location + m.range.length <= ns.length else { return s }
        let piece = ns.substring(with: m.range)
        let replacement =
            o.regex
            ? re.stringByReplacingMatches(
                in: piece, range: NSRange(location: 0, length: (piece as NSString).length), withTemplate: template)
            : template
        return ns.replacingCharacters(in: m.range, with: replacement)
    }

    /// Replaces matches on one canvas as one edit. Matches must belong to that canvas.
    public static func replace(
        _ matches: [SearchMatch], query: String, with template: String, _ o: SearchOptions, in e: inout CanvasEditor
    ) -> Int {
        guard let re = expression(query, o) else { return 0 }
        // Replace back to front so earlier ranges stay valid.
        var count = 0
        for m in matches.sorted(by: {
            ($0.node, $0.field.rawValue, $0.index, $0.range.location) > (
                $1.node, $1.field.rawValue, $1.index, $1.range.location
            )
        })
        where m.canvas == e.canvas.id {
            guard let n = e[m.node] else { continue }
            switch m.field {
            case .text:
                let t = replaced(n.text, m, re, with: template, o)
                if t != n.text {
                    e.setText(m.node, t)
                    count += 1
                }
            case .note:
                guard let note = n.note else { continue }
                let t = replaced(note.text, m, re, with: template, o)
                e.update(m.node) { $0.note?.text = t }
                count += 1
            case .comment:
                guard m.index < n.comments.count else { continue }
                let t = replaced(n.comments[m.index].text, m, re, with: template, o)
                e.update(m.node) { $0.comments[m.index].text = t }
                count += 1
            case .label:
                guard m.index < n.labels.count else { continue }
                let t = replaced(n.labels[m.index], m, re, with: template, o)
                e.update(m.node) { $0.labels[m.index] = t }
                count += 1
            }
        }
        return count
    }
}

// MARK: Counts (artboard 47)

public struct CanvasCounts: Equatable, Sendable {
    public var topics = 0
    public var words = 0
    public var characters = 0
    public var notes = 0
    /// Topics with comments, and the comments on them (M14).
    public var commented = 0
    public var comments = 0
    public var aiCreated = 0

    public init(_ canvas: Canvas, nodes: [NodeID]? = nil) {
        let ids = nodes ?? canvas.tops.flatMap { canvas.subtree($0) }
        for id in ids {
            guard let n = canvas.nodes[id] else { continue }
            topics += 1
            words += n.text.split { $0.isWhitespace || $0.isNewline }.count
            characters += n.text.count
            if n.note != nil { notes += 1 }
            if !n.comments.isEmpty {
                commented += 1
                comments += n.comments.count
            }
            if n.ai { aiCreated += 1 }
        }
    }
}

// MARK: Breadcrumbs

extension Canvas {
    /// "Pricing" → "Launch plan › Pricing" path of ancestors (root first), excluding `id`.
    public func path(to id: NodeID, parents: [NodeID: NodeID]? = nil) -> [NodeID] {
        let p = parents ?? parentMap()
        var out: [NodeID] = []
        var cur = p[id]
        while let c = cur {
            out.insert(c, at: 0)
            cur = p[c]
        }
        return out
    }
}
