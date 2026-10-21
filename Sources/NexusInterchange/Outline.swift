import Foundation
import NexusCore
import NexusFormat

// MARK: Markdown

public enum MarkdownFormat {
    public struct Options: Sendable, Equatable {
        /// Headings for the top levels (then nested bullets), or bullets throughout.
        public var headings = true
        /// Heading levels before switching to bullets (root is `#`).
        public var headingDepth = 2
        public var notes = true
        /// Topic comments as a "Comments" appendix after the outline (M14, D162).
        public var comments = true
        public var mermaidBlock = false
        public init() {}
    }

    static func line(_ n: Node) -> String {
        var t = n.text.replacingOccurrences(of: "\n", with: " ")
        if let link = n.link, !link.hasPrefix("#") { t = "[\(t)](\(link))" }
        if !n.labels.isEmpty { t += " " + n.labels.map { "`\($0)`" }.joined(separator: " ") }
        if let p = n.priority { t += " (P\(p))" }
        return t
    }

    /// One canvas as Markdown. Branch scope starts at `from`.
    public static func export(_ c: Canvas, from top: NodeID? = nil, options o: Options = Options()) -> String {
        var out = ""
        let start = top ?? c.root
        c.walk(from: start) { _, n, d in
            if o.headings && d < o.headingDepth {
                if !out.isEmpty { out += "\n" }
                let box = n.todo.map { $0.done ? "[x] " : "[ ] " } ?? ""
                out += String(repeating: "#", count: d + 1) + " " + box + line(n) + "\n"
                if o.notes, let note = n.note?.text, !note.trimmed.isEmpty { out += "\n" + note.trimmed + "\n" }
            } else {
                let level = o.headings ? d - o.headingDepth : d
                if o.headings && level == 0 && !out.hasSuffix("\n\n") && !out.isEmpty && !lastWasBullet(out) {
                    out += "\n"
                }
                let indent = String(repeating: "  ", count: max(level, 0))
                let box = n.todo.map { $0.done ? "[x] " : "[ ] " } ?? ""
                out += "\(indent)- \(box)\(line(n))\n"
                if o.notes, let note = n.note?.text, !note.trimmed.isEmpty {
                    for l in note.trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
                        out += "\(indent)  \(l)\n"
                    }
                }
            }
        }
        if top == nil && !c.floating.isEmpty {
            out += "\n"
            for f in c.floating {
                c.walk(from: f) { _, n, d in out += String(repeating: "  ", count: d) + "- " + line(n) + "\n" }
            }
        }
        if o.comments {
            let ids = top.map { c.subtree($0) } ?? c.tops.flatMap { c.subtree($0) }
            let appendix = commentsAppendix(c, topics: ids)
            if !appendix.isEmpty { out += "\n## Comments\n\n" + appendix }
        }
        if o.mermaidBlock {
            out += "\n```mermaid\n" + MermaidFormat.export(c) + "```\n"
        }
        return out
    }

    /// "- **Pricing** · Ana · 2026-10-20: Drop the annual tier?", one line per comment, in
    /// outline order. A comment's later lines are indented under it.
    static func commentsAppendix(_ c: Canvas, topics: [NodeID]) -> String {
        var out = ""
        for id in topics {
            guard let n = c.nodes[id] else { continue }
            for cm in n.comments {
                let who = [cm.author, String(cm.date.prefix(10))].filter { !$0.isEmpty }.joined(separator: " · ")
                let lines = cm.text.trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                let head = "**\(n.text.replacingOccurrences(of: "\n", with: " "))**" + (who.isEmpty ? "" : " · \(who)")
                out += "- \(head): \(lines.first ?? "")\n"
                for l in lines.dropFirst() { out += "  \(l)\n" }
            }
        }
        return out
    }

    static func lastWasBullet(_ s: String) -> Bool {
        s.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") } ?? false
    }

    /// Every canvas, separated by rules.
    public static func export(_ doc: DocumentModel, options: Options = Options()) -> String {
        doc.orderedCanvases.map { export($0, options: options) }.joined(separator: "\n---\n\n")
    }

    /// Markdown into a topic tree: headings nest, bullets nest by indentation, paragraphs
    /// become the note of the topic above, `- [ ]` becomes a to-do.
    public static func parse(_ text: String, title: String, report: inout ImportReport) -> ICanvas {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // YAML front matter.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(0...end)
        }
        struct Entry {
            var level: Int
            var topic: ITopic
        }
        var stack: [Entry] = []
        var tops: [ITopic] = []
        var inFence = false
        var fenceLang = ""
        var fence: [String] = []
        var noteLines: [String] = []

        func flushNote() {
            let note = noteLines.joined(separator: "\n").trimmed
            noteLines = []
            guard !note.isEmpty, !stack.isEmpty else { return }
            let existing = stack[stack.count - 1].topic.note
            stack[stack.count - 1].topic.note = existing.map { $0 + "\n\n" + note } ?? note
        }
        func pop(to level: Int) {
            while let last = stack.last, last.level >= level {
                stack.removeLast()
                if stack.isEmpty {
                    tops.append(last.topic)
                } else {
                    stack[stack.count - 1].topic.children.append(last.topic)
                }
            }
        }
        func push(_ t: ITopic, level: Int) {
            flushNote()
            pop(to: level)
            stack.append(Entry(level: level, topic: t))
        }

        for raw in lines {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    inFence = false
                    if fenceLang == "mermaid" {
                        report.skip("Mermaid block (paste it on its own to rebuild the diagram)")
                    } else {
                        noteLines.append("```\(fenceLang)\n" + fence.joined(separator: "\n") + "\n```")
                    }
                    fence = []
                } else {
                    inFence = true
                    fenceLang = raw.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmed
                }
                continue
            }
            if inFence {
                fence.append(raw)
                continue
            }
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "---" || t == "***" {
                if let last = noteLines.last, !last.isEmpty { noteLines.append("") }
                continue
            }
            if let h = heading(t) {
                var body = Substring(h.1)
                var todo: Bool?
                if body.hasPrefix("[ ] ") {
                    todo = false
                    body = body.dropFirst(4)
                } else if body.lowercased().hasPrefix("[x] ") {
                    todo = true
                    body = body.dropFirst(4)
                }
                var tp = topic(String(body))
                tp.todo = todo
                push(tp, level: h.0)
                continue
            }
            if let b = bullet(raw) {
                var tp = topic(b.text)
                tp.todo = b.todo
                push(tp, level: 100 + b.indent)
                continue
            }
            if t.hasPrefix("![") {
                report.skip("Image reference (import images with drag and drop)")
                continue
            }
            if t.hasPrefix("|") {
                noteLines.append(t)
                continue
            }
            noteLines.append(t.hasPrefix(">") ? String(t.dropFirst()).trimmed : t)
        }
        flushNote()
        pop(to: Int.min)
        // One top-level topic becomes the root; several hang off a root named after the file.
        var root: ITopic
        if tops.count == 1 {
            root = tops[0]
        } else {
            root = ITopic(title)
            root.children = tops
        }
        var ic = ICanvas(title: root.text, root: root)
        ic.synthesizedRoot = tops.count != 1
        return ic
    }

    static func heading(_ t: String) -> (Int, String)? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        var s = t.dropFirst(hashes).trimmed
        while s.hasSuffix("#") { s = String(s.dropLast()).trimmed }
        return (hashes, s)
    }

    static func bullet(_ raw: String) -> (indent: Int, text: String, todo: Bool?)? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = raw.trimmingCharacters(in: .whitespaces)
        var body: Substring
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            body = t.dropFirst(2)
        } else if let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), dot > t.startIndex,
            t[..<dot].allSatisfy(\.isNumber), t[t.index(after: dot)...].first == " "
        {
            body = t[t.index(dot, offsetBy: 2)...]
        } else {
            return nil
        }
        var todo: Bool?
        if body.hasPrefix("[ ] ") {
            todo = false
            body = body.dropFirst(4)
        } else if body.lowercased().hasPrefix("[x] ") {
            todo = true
            body = body.dropFirst(4)
        }
        return (indent, String(body), todo)
    }

    /// Inline Markdown: `[text](url)` becomes a link, `**bold**` and backticks are dropped,
    /// trailing `` `label` `` runs become labels, `(P1)` a priority marker.
    static func topic(_ s: String) -> ITopic {
        var text = s.trimmed
        var t = ITopic("")
        if let m = text.firstMatch(of: /\(P([1-9])\)$/) {
            t.markers.append("priority-\(m.1)")
            text = String(text[..<m.range.lowerBound]).trimmed
        }
        while let m = text.firstMatch(of: /\s`([^`]+)`$/) {
            t.labels.insert(String(m.1), at: 0)
            text = String(text[..<m.range.lowerBound]).trimmed
        }
        if let m = text.wholeMatch(of: /\[(.+)\]\((\S+)\)/) {
            text = String(m.1)
            t.link = String(m.2)
        } else if let m = text.firstMatch(of: /\[([^\]]+)\]\((\S+)\)/) {
            text = text.replacingCharacters(in: m.range, with: String(m.1))
            t.link = t.link ?? String(m.2)
        }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        t.text = text
        return t
    }
}

// MARK: Indented text

public enum IndentedText {
    /// Each line a topic; indentation (tabs, or the smallest step of spaces) nests.
    public static func parse(_ text: String, title: String) -> ICanvas {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let widths = lines.map { l in l.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }
        let step = widths.filter { $0 > 0 }.min() ?? 1
        var stack: [(Int, ITopic)] = []
        var tops: [ITopic] = []
        func pop(to level: Int) {
            while let last = stack.last, last.0 >= level {
                stack.removeLast()
                if stack.isEmpty { tops.append(last.1) } else { stack[stack.count - 1].1.children.append(last.1) }
            }
        }
        for (l, w) in zip(lines, widths) {
            var t = l.trimmingCharacters(in: .whitespaces)
            for p in ["- ", "* ", "+ ", "• ", "– "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
            let level = w / step
            pop(to: level)
            stack.append((level, MarkdownFormat.topic(t)))
        }
        pop(to: Int.min)
        var root: ITopic
        if tops.count == 1 {
            root = tops[0]
        } else {
            root = ITopic(title)
            root.children = tops
        }
        var ic = ICanvas(title: root.text, root: root)
        ic.synthesizedRoot = tops.count != 1
        return ic
    }

    /// True when a pasted string looks like an outline rather than one topic.
    public static func looksLikeOutline(_ s: String) -> Bool {
        let lines = s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.count > 1
    }

    public static func export(_ c: Canvas, from top: NodeID? = nil) -> String {
        var out = ""
        c.walk(from: top ?? c.root) { _, n, d in
            out += String(repeating: "\t", count: d) + n.text.replacingOccurrences(of: "\n", with: " ") + "\n"
        }
        return out
    }
}

// MARK: OPML

public enum OPMLFormat {
    public static func export(_ c: Canvas, from top: NodeID? = nil) -> String {
        var out = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head>
                <title>\(XML.escape(c.title.isEmpty ? (c.nodes[c.root]?.text ?? "") : c.title, attribute: false))</title>
              </head>
              <body>

            """
        func emit(_ id: NodeID, _ d: Int) {
            guard let n = c.nodes[id] else { return }
            let pad = String(repeating: "  ", count: d + 2)
            var attrs = "text=\"\(XML.escape(n.text))\""
            if let note = n.note?.text, !note.isEmpty { attrs += " _note=\"\(XML.escape(note))\"" }
            if let link = n.link, !link.hasPrefix("#") { attrs += " url=\"\(XML.escape(link))\"" }
            if let t = n.todo { attrs += " _status=\"\(t.done ? "checked" : "unchecked")\"" }
            if n.children.isEmpty {
                out += "\(pad)<outline \(attrs)/>\n"
            } else {
                out += "\(pad)<outline \(attrs)>\n"
                for ch in n.children { emit(ch, d + 1) }
                out += "\(pad)</outline>\n"
            }
        }
        emit(top ?? c.root, 0)
        out += "  </body>\n</opml>\n"
        return out
    }

    public static func parse(_ data: Data, name: String, report: inout ImportReport) throws -> ICanvas {
        let root = try XML.parse(data, name: name)
        guard root.localName == "opml", let body = root.kid("body") else {
            throw ImportError.invalid(name, "no OPML body")
        }
        func topic(_ e: XMLElement) -> ITopic {
            var t = ITopic(e.attr("text") ?? e.attr("title") ?? "")
            t.note = e.attr("_note")
            t.link = e.attr("url") ?? e.attr("htmlUrl") ?? e.attr("xmlUrl")
            if let s = e.attr("_status") { t.todo = s == "checked" }
            t.children = e.kids("outline").map(topic)
            return t
        }
        let tops = body.kids("outline").map(topic)
        let title = root.kid("head")?.kid("title")?.stringValue?.trimmed ?? ""
        var r: ITopic
        if tops.count == 1 {
            r = tops[0]
        } else {
            r = ITopic(title.isEmpty ? name : title)
            r.children = tops
        }
        report.sheets = 1
        return ICanvas(title: title.isEmpty ? r.text : title, root: r)
    }
}
