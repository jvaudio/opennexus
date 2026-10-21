import Foundation
import NexusCore

/// Task fields as text, shared by the Markdown and OPML formats (M22, D205–D206).
public enum TaskMarkup {
    // MARK: Dependencies

    /// "n1,n7(SS+2),n9(-1)": each predecessor's id, then its kind and lag when they aren't
    /// finish-to-start with no lag. `prefix` goes before each id (Markdown writes "^").
    public static func dependencies(_ after: [TaskDependency], prefix: String = "") -> String {
        after.map { d in
            var s = prefix + d.task.rawValue
            if d.type != .finishToStart || d.lag != 0 {
                let type = d.type == .finishToStart ? "" : d.type.rawValue
                let lag = d.lag == 0 ? "" : d.lag > 0 ? "+\(d.lag)" : "\(d.lag)"
                s += "(\(type)\(lag))"
            }
            return s
        }
        .joined(separator: ",")
    }

    /// The inverse of `dependencies`; nil when any item doesn't parse.
    public static func dependencies(_ s: String, prefix: String = "") -> [ITask.Dependency]? {
        var out: [ITask.Dependency] = []
        for item in s.split(separator: ",", omittingEmptySubsequences: false) {
            let x = item.trimmed
            guard x.hasPrefix(prefix),
                let m = x.dropFirst(prefix.count).wholeMatch(
                    of: /([A-Za-z0-9_-]+)(?:\((FS|SS|FF|SF)?([+-]\d{1,4})?\))?/)
            else { return nil }
            let type = m.2.flatMap { DependencyType(rawValue: String($0)) } ?? .finishToStart
            let lag = m.3.flatMap { Int($0) }.map { max(-3650, min(3650, $0)) } ?? 0
            out.append(ITask.Dependency(ref: String(m.1), type: type, lag: lag))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Markdown

    /// What a Markdown line's trailing tokens say (D205).
    struct Suffix: Equatable {
        var owner: String?
        var start: TaskDate?
        var due: TaskDate?
        var progress: Int?
        var after: [ITask.Dependency] = []
        /// The topic's own id (`^n3`), which dependencies and comments name.
        var anchor: String?

        var hasTask: Bool { owner != nil || start != nil || due != nil || progress != nil || !after.isEmpty }
    }

    /// Ids Markdown can write as `^id` anchors.
    static func anchorable(_ id: NodeID) -> Bool { id.rawValue.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil }

    enum Token: CaseIterable {
        case anchor, after, progress, dates, owner
    }

    /// "@Ana 2026-11-02→2026-11-06 40% after:^n1,^n7(SS+2) ^n3": the tokens a to-do line
    /// ends with, each written only when set. `anchor` is the topic's own id.
    static func suffix(_ todo: Todo?, anchor: String?) -> String {
        var parts: [String] = []
        if let t = todo {
            if let o = t.owner, !o.isEmpty {
                parts.append(o.contains { $0.isWhitespace || "@[]".contains($0) } ? "@[\(o)]" : "@\(o)")
            }
            if t.start != nil || t.due != nil {
                parts.append("\(t.start?.description ?? "")→\(t.due?.description ?? "")")
            }
            if let p = t.progress, p != 0 { parts.append("\(p)%") }
            if !t.after.isEmpty { parts.append("after:" + dependencies(t.after, prefix: "^")) }
        }
        if let anchor { parts.append("^" + anchor) }
        return parts.map { " " + $0 }.joined()
    }

    /// Matches one token at the end of `s` (after a space), returning where it starts.
    static func match(_ kind: Token, in s: String, into x: inout Suffix) -> String.Index? {
        switch kind {
        case .anchor:
            guard let m = s.firstMatch(of: /\s\^([A-Za-z0-9_-]+)$/) else { return nil }
            x.anchor = String(m.1)
            return m.range.lowerBound
        case .after:
            guard let m = s.firstMatch(of: /\safter:(\S+)$/), let deps = dependencies(String(m.1), prefix: "^")
            else { return nil }
            x.after = deps
            return m.range.lowerBound
        case .progress:
            guard let m = s.firstMatch(of: /\s(\d{1,3})%$/), let p = Int(m.1), p <= 100 else { return nil }
            x.progress = p
            return m.range.lowerBound
        case .dates:
            guard let m = s.firstMatch(of: /\s(\d{4}-\d{2}-\d{2})?(?:→|->)(\d{4}-\d{2}-\d{2})?$/),
                m.1 != nil || m.2 != nil
            else { return nil }
            let start = m.1.flatMap { TaskDate(String($0)) }
            let due = m.2.flatMap { TaskDate(String($0)) }
            guard (m.1 == nil) == (start == nil), (m.2 == nil) == (due == nil) else { return nil }
            x.start = start
            x.due = due
            return m.range.lowerBound
        case .owner:
            if let m = s.firstMatch(of: /\s@\[([^\]]+)\]$/) {
                x.owner = String(m.1).trimmed
                return m.range.lowerBound
            }
            guard let m = s.firstMatch(of: /\s@([^\s@\[\]]+)$/) else { return nil }
            x.owner = String(m.1)
            return m.range.lowerBound
        }
    }

    /// Splits a line's text from its trailing tokens. `tasks` false reads only the anchor
    /// (lines without a check box). A `\` before the text's last word, which the exporter
    /// adds when that word would read as a token, is removed.
    static func parse(_ line: String, tasks: Bool) -> (text: String, suffix: Suffix) {
        var s = line.trimmed
        var x = Suffix()
        var seen = Set<Token>()
        let kinds: [Token] = tasks ? Token.allCases : [.anchor]
        outer: while true {
            for k in kinds where !seen.contains(k) {
                if let at = match(k, in: s, into: &x) {
                    s = String(s[..<at]).trimmed
                    seen.insert(k)
                    continue outer
                }
            }
            break
        }
        // Undo the exporter's escape.
        if let r = s.range(of: #"(^|\s)\\\S"#, options: [.regularExpression, .backwards]) {
            let slash = s[r].hasPrefix("\\") ? r.lowerBound : s.index(after: r.lowerBound)
            var plain = s
            plain.remove(at: slash)
            if needsEscape(plain, tasks: tasks) { s = plain }
        }
        return (s, x)
    }

    /// Where the token that `text` ends with starts, if it ends with one.
    static func tokenStart(_ text: String, tasks: Bool) -> String.Index? {
        var scratch = Suffix()
        let probe = " " + text
        for k in tasks ? Token.allCases : [.anchor] {
            guard let at = match(k, in: probe, into: &scratch) else { continue }
            // Skip the space the match starts with; `probe` is one character longer.
            let offset = probe.distance(from: probe.startIndex, to: at)
            return text.index(text.startIndex, offsetBy: offset)
        }
        return nil
    }

    static func needsEscape(_ text: String, tasks: Bool) -> Bool { tokenStart(text, tasks: tasks) != nil }

    /// `text` with a `\` before the token it ends with, if any, so it reads as text.
    static func escaped(_ text: String, tasks: Bool) -> String {
        guard let at = tokenStart(text, tasks: tasks) else { return text }
        var t = text
        t.insert("\\", at: at)
        return t
    }
}

extension ITopic {
    /// Changes the topic with this ref, here or below; false when there's none.
    mutating func update(ref: String, _ body: (inout ITopic) -> Void) -> Bool {
        if self.ref == ref {
            body(&self)
            return true
        }
        for i in children.indices where children[i].update(ref: ref, body) { return true }
        return false
    }
}

extension ICanvas {
    /// Changes the topic with this ref anywhere on the canvas; false when there's none.
    mutating func updateTopic(ref: String, _ body: (inout ITopic) -> Void) -> Bool {
        if root.update(ref: ref, body) { return true }
        for i in floating.indices where floating[i].update(ref: ref, body) { return true }
        return false
    }
}
