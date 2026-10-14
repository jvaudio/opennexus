import Foundation
import NexusCore
import NexusFormat

// MARK: Mermaid

public enum MermaidFormat {
    public enum Flavour: String, CaseIterable, Sendable {
        case mindmap, flowchart, sequence, `class`
        public var title: String { rawValue }
    }

    /// The flavour that suits the canvas type (artboard 30, "auto-chosen from type").
    public static func flavour(for c: Canvas) -> Flavour {
        switch c.type {
        case .sequence: .sequence
        case .flowchart, .dfd, .architecture, .swimlane, .threatModel: .flowchart
        default: .mindmap
        }
    }

    public static func export(_ c: Canvas, flavour: Flavour? = nil) -> String {
        switch flavour ?? self.flavour(for: c) {
        case .sequence: Mermaid.sequence(c)
        case .flowchart: Mermaid.flowchart(c)
        case .mindmap: mindmap(c)
        case .class: classDiagram(c)
        }
    }

    static func safe(_ s: String) -> Bool {
        !s.isEmpty && s.rangeOfCharacter(from: CharacterSet(charactersIn: "()[]{}\"`:;#<>")) == nil && !s.contains("\n")
    }

    static func mindmapText(_ id: NodeID, _ n: Node, root: Bool) -> String {
        let t = n.text.replacingOccurrences(of: "\n", with: " ")
        let q = "\"" + t.replacingOccurrences(of: "\"", with: "'") + "\""
        if root { return "\(id.rawValue)((\(safe(t) ? t : q)))" }
        return safe(t) ? t : "\(id.rawValue)[\(q)]"
    }

    public static func mindmap(_ c: Canvas, from top: NodeID? = nil) -> String {
        var out = "mindmap\n"
        c.walk(from: top ?? c.root) { id, n, d in
            out += String(repeating: "  ", count: d + 1) + mindmapText(id, n, root: d == 0) + "\n"
        }
        return out
    }

    /// Main topics become classes, everything under them their members; relationships
    /// become associations.
    public static func classDiagram(_ c: Canvas) -> String {
        var out = "classDiagram\n"
        let mains = c.nodes[c.root]?.children ?? []
        func name(_ id: NodeID) -> String { "C\(id.rawValue)" }
        for m in mains {
            guard let n = c.nodes[m] else { continue }
            out += "    class \(name(m))[\"\(Mermaid.label(n.text).replacingOccurrences(of: "\"", with: "'"))\"] {\n"
            for ch in n.children { c.walk(from: ch) { _, k, _ in out += "        +\(Mermaid.label(k.text))\n" } }
            out += "    }\n"
        }
        let owner: [NodeID: NodeID] = {
            var o: [NodeID: NodeID] = [:]
            for m in mains { for id in c.subtree(m) { o[id] = m } }
            return o
        }()
        for r in c.relationships {
            guard let a = owner[r.from], let b = owner[r.to], a != b else { continue }
            out += "    \(name(a)) --> \(name(b))" + (r.label.isEmpty ? "" : " : \(Mermaid.label(r.label))") + "\n"
        }
        return out
    }

    // MARK: Import

    public static func parse(_ text: String, title: String, report: inout ImportReport) throws -> ICanvas {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let body = lines.filter { !$0.trimmed.isEmpty && !$0.trimmed.hasPrefix("%%") }
        guard let head = body.first?.trimmed.lowercased() else { throw ImportError.empty(title) }
        report.sheets = 1
        if head == "mindmap" { return mindmapParse(Array(body.dropFirst()), title: title, report: &report) }
        if head.hasPrefix("flowchart") || head.hasPrefix("graph") {
            return flowParse(Array(body.dropFirst()), title: title, report: &report)
        }
        if head.hasPrefix("sequencediagram") {
            return sequenceParse(Array(body.dropFirst()), title: title, report: &report)
        }
        if head.hasPrefix("classdiagram") { return classParse(Array(body.dropFirst()), title: title, report: &report) }
        throw ImportError.invalid(title, "Mermaid \(head.split(separator: " ").first ?? "") diagrams aren’t supported")
    }

    /// `id((text))`, `id[text]`, `id(text)`, `id{{text}}`, `id))text((`, or plain text.
    static func shapeText(_ s: String) -> (ref: String?, text: String, shape: String?) {
        var t = s.trimmed
        if let i = t.range(of: ":::") { t = String(t[..<i.lowerBound]).trimmed }
        let pairs: [(String, String, String)] = [
            ("((", "))", "circle"), ("))", "((", "bang"), ("{{", "}}", "hexagon"), ("([", "])", "stadium"),
            ("[(", ")]", "cylinder"), ("[/", "/]", "parallelogram"), ("[\\", "\\]", "parallelogram"),
            ("[", "]", "rect"),
            ("(", ")", "rounded"), ("{", "}", "diamond"), (">", "]", "flag"),
        ]
        for (open, close, shape) in pairs {
            if let o = t.range(of: open), t.hasSuffix(close), o.lowerBound > t.startIndex || shape != "rect" {
                let ref = String(t[..<o.lowerBound]).trimmed
                var inner = String(t[o.upperBound..<t.index(t.endIndex, offsetBy: -close.count)]).trimmed
                if inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2 {
                    inner = String(inner.dropFirst().dropLast())
                }
                inner = inner.replacingOccurrences(of: "<br/>", with: " ").replacingOccurrences(
                    of: "#quot;", with: "\""
                )
                .replacingOccurrences(of: "#59;", with: ";").replacingOccurrences(of: "#124;", with: "|")
                return (ref.isEmpty ? nil : ref, inner, shape)
            }
        }
        return (nil, t, nil)
    }

    static func mindmapParse(_ lines: [String], title: String, report: inout ImportReport) -> ICanvas {
        var stack: [(Int, ITopic)] = []
        var tops: [ITopic] = []
        func pop(to level: Int) {
            while let last = stack.last, last.0 >= level {
                stack.removeLast()
                if stack.isEmpty { tops.append(last.1) } else { stack[stack.count - 1].1.children.append(last.1) }
            }
        }
        for l in lines {
            let t = l.trimmed
            if t.hasPrefix("::icon") {
                report.skip("Mermaid icon")
                continue
            }
            let indent = l.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let s = shapeText(t)
            pop(to: indent)
            stack.append((indent, ITopic(s.text, ref: s.ref)))
        }
        pop(to: Int.min)
        let root = tops.count == 1 ? tops[0] : ITopic(title, children: tops)
        var ic = ICanvas(title: root.text, root: root)
        ic.synthesizedRoot = tops.count != 1
        return ic
    }

    public struct Graph: Sendable {
        var order: [String] = []
        var text: [String: String] = [:]
        var shape: [String: String] = [:]
        var edges: [(String, String, String, Bool)] = []  // from, to, label, dotted
        var groups: [(String, [String])] = []

        mutating func node(_ ref: String, _ text: String? = nil, _ shape: String? = nil) {
            if text != nil || self.text[ref] == nil { self.text[ref] = text ?? self.text[ref] ?? ref }
            if let shape { self.shape[ref] = shape }
            if !order.contains(ref) { order.append(ref) }
        }
    }

    static func flowParse(_ lines: [String], title: String, report: inout ImportReport) -> ICanvas {
        var g = Graph()
        var groupStack: [(String, [String])] = []
        let arrow =
            /\s*(?:--\s*([^->|][^->]*?)\s*-->|-->\|([^|]*)\||==>\|([^|]*)\||-\.->\|([^|]*)\||-->|==>|-\.->|---|-\.-|===)\s*/
        for raw in lines.flatMap({ $0.split(separator: ";").map(String.init) }) {
            let l = raw.trimmed
            if l.isEmpty { continue }
            if l.hasPrefix("subgraph") {
                let rest = l.dropFirst(8).trimmed
                groupStack.append((shapeText(rest).text, []))
                continue
            }
            if l == "end" {
                if let gr = groupStack.popLast() { g.groups.append(gr) }
                continue
            }
            if l.hasPrefix("classDef") || l.hasPrefix("class ") || l.hasPrefix("style") || l.hasPrefix("linkStyle")
                || l.hasPrefix("click") || l.hasPrefix("direction")
            {
                report.skip("Mermaid styling and click handlers")
                continue
            }
            // Split a chain `A --> B -->|x| C` into nodes and edges.
            var parts: [String] = []
            var labels: [(String, Bool)] = []
            var rest = Substring(l)
            while let m = rest.firstMatch(of: arrow) {
                parts.append(String(rest[..<m.range.lowerBound]))
                let label = [m.1, m.2, m.3, m.4].compactMap { $0 }.first.map(String.init) ?? ""
                labels.append((label.trimmed, rest[m.range].contains(".")))
                rest = rest[m.range.upperBound...]
            }
            parts.append(String(rest))
            var prev: [String] = []
            for (i, p) in parts.enumerated() {
                var refs: [String] = []
                for piece in p.split(separator: "&") {
                    let s = shapeText(String(piece))
                    let ref = s.ref ?? s.text
                    guard !ref.isEmpty else { continue }
                    g.node(ref, s.ref == nil ? nil : s.text, s.shape)
                    refs.append(ref)
                    if !groupStack.isEmpty { groupStack[groupStack.count - 1].1.append(ref) }
                }
                if i > 0 {
                    for a in prev { for b in refs { g.edges.append((a, b, labels[i - 1].0, labels[i - 1].1)) } }
                }
                prev = refs
            }
        }
        return graphCanvas(g, title: title, type: .flowchart)
    }

    /// A graph as a canvas: tree edges come from a breadth-first walk from the sources,
    /// the rest become relationships. Several sources hang off a titled root.
    static func graphCanvas(_ g: Graph, title: String, type: DiagramType) -> ICanvas {
        var incoming: [String: Int] = [:]
        for e in g.edges where e.0 != e.1 { incoming[e.1, default: 0] += 1 }
        var sources = g.order.filter { incoming[$0] == nil }
        if sources.isEmpty, let first = g.order.first { sources = [first] }
        var parent: [String: (String, String)] = [:]
        var seen = Set(sources)
        var queue = sources
        var treeEdge = Set<Int>()
        while !queue.isEmpty {
            let a = queue.removeFirst()
            for (i, e) in g.edges.enumerated() where e.0 == a && !seen.contains(e.1) && !e.3 {
                seen.insert(e.1)
                parent[e.1] = (a, e.2)
                treeEdge.insert(i)
                queue.append(e.1)
            }
            // Unreached nodes join as extra sources.
            if queue.isEmpty, let next = g.order.first(where: { !seen.contains($0) }) {
                seen.insert(next)
                sources.append(next)
                queue.append(next)
            }
        }
        func topic(_ ref: String) -> ITopic {
            var t = ITopic(g.text[ref] ?? ref, ref: ref)
            switch g.shape[ref] {
            case "stadium", "circle": t.nodeType = .start
            case "diamond", "hexagon": t.nodeType = .decision
            case "parallelogram": t.nodeType = .io
            case "cylinder": t.nodeType = .store
            default: t.nodeType = type == .flowchart ? .process : nil
            }
            t.edgeLabel = parent[ref].flatMap { $0.1.isEmpty ? nil : $0.1 }
            t.children = g.order.filter { parent[$0]?.0 == ref }.map(topic)
            return t
        }
        var root: ITopic
        if sources.count == 1 {
            root = topic(sources[0])
        } else {
            root = ITopic(title, children: sources.map(topic))
        }
        let synthesized = sources.count != 1
        // A start step's last children are often end steps; mark stadium leaves as ends.
        func ends(_ t: inout ITopic) {
            for i in t.children.indices { ends(&t.children[i]) }
            if t.children.isEmpty, t.nodeType == .start, t.ref != sources.first { t.nodeType = .end }
        }
        ends(&root)
        var ic = ICanvas(title: title, root: root)
        ic.synthesizedRoot = synthesized
        ic.type = type
        ic.links = g.edges.enumerated().filter { !treeEdge.contains($0.offset) && $0.element.0 != $0.element.1 }.map {
            ICanvas.Link(from: $0.element.0, to: $0.element.1, label: $0.element.2)
        }
        ic.groups = g.groups.map { ICanvas.Group(refs: $0.1, title: $0.0) }
        return ic
    }

    static func sequenceParse(_ lines: [String], title: String, report: inout ImportReport) -> ICanvas {
        var order: [String] = []
        var names: [String: String] = [:]
        var actors = Set<String>()
        var messages: [ICanvas.Link] = []
        var heading = title
        func declare(_ a: String) { if !order.contains(a) { order.append(a) } }
        let msg = /^([^-<>+]+?)\s*(-->>|->>|-->|->|--x|-x|--\)|-\))\s*[+-]?([^:]+?)\s*:\s*(.*)$/
        for raw in lines {
            let l = raw.trimmed
            if l.hasPrefix("title") {
                heading = l.dropFirst(5).trimmed
                continue
            }
            if l.hasPrefix("participant ") || l.hasPrefix("actor ") {
                let isActor = l.hasPrefix("actor ")
                let rest = l.dropFirst(isActor ? 6 : 12).trimmed
                let parts = rest.components(separatedBy: " as ")
                let id = parts[0].trimmed
                declare(id)
                names[id] = parts.count > 1 ? parts[1].trimmed : id
                if isActor { actors.insert(id) }
                continue
            }
            if let m = l.wholeMatch(of: msg) {
                let a = String(m.1).trimmed
                let b = String(m.3).trimmed
                declare(a)
                declare(b)
                messages.append(
                    ICanvas.Link(from: a, to: b, label: String(m.4).trimmed, kind: m.2.hasPrefix("--") ? "return" : nil)
                )
                continue
            }
            for k in [
                "loop", "alt", "else", "opt", "par", "and", "critical", "break", "rect", "end", "Note", "note",
                "activate", "deactivate", "autonumber",
            ]
            where l.hasPrefix(k) {
                report.skip("Sequence blocks, notes and activations (\(k))")
                break
            }
        }
        var root = ITopic(heading)
        root.children = order.map {
            var t = ITopic(names[$0] ?? $0, ref: $0)
            t.nodeType = actors.contains($0) ? "actor" : .participant
            return t
        }
        var ic = ICanvas(title: heading, root: root)
        ic.type = .sequence
        ic.links = messages
        return ic
    }

    static func classParse(_ lines: [String], title: String, report: inout ImportReport) -> ICanvas {
        var order: [String] = []
        var label: [String: String] = [:]
        var members: [String: [String]] = [:]
        var links: [ICanvas.Link] = []
        var current: String?
        let rel =
            /^(\w+)\s*(?:"[^"]*"\s*)?(<\|--|--\|>|\*--|--\*|o--|--o|-->|<--|--|\.\.>|<\.\.|\.\.\|>|<\|\.\.|\.\.)\s*(?:"[^"]*"\s*)?(\w+)\s*(?::\s*(.*))?$/
        for raw in lines {
            let l = raw.trimmed
            if l == "}" {
                current = nil
                continue
            }
            if let c = current {
                members[c, default: []].append(l.trimmingCharacters(in: CharacterSet(charactersIn: "+-#~ ")))
                continue
            }
            if l.hasPrefix("class ") {
                var rest = l.dropFirst(6).trimmed
                let open = rest.hasSuffix("{")
                if open { rest = String(rest.dropLast()).trimmed }
                let s = shapeText(rest)
                let id = s.ref ?? s.text
                if !order.contains(id) { order.append(id) }
                label[id] = s.text
                if open { current = id }
                continue
            }
            if let m = l.wholeMatch(of: rel) {
                for id in [String(m.1), String(m.3)] where !order.contains(id) { order.append(id) }
                links.append(
                    ICanvas.Link(from: String(m.1), to: String(m.3), label: m.4.map { String($0).trimmed } ?? ""))
                continue
            }
            if let colon = l.firstIndex(of: ":"), !l[..<colon].trimmed.isEmpty,
                l[..<colon].trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            {
                let id = String(l[..<colon]).trimmed
                if !order.contains(id) { order.append(id) }
                members[id, default: []].append(
                    l[l.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "+-#~ ")))
                continue
            }
            report.skip("Class diagram statement")
        }
        var root = ITopic(title)
        root.children = order.map { id in
            var t = ITopic(label[id] ?? id, ref: id)
            t.children = (members[id] ?? []).map { ITopic($0) }
            return t
        }
        var ic = ICanvas(title: title, root: root)
        ic.links = links
        return ic
    }
}

// MARK: PlantUML

public enum PlantUMLFormat {
    /// Mind-map types as `@startmindmap`, sequences as sequence diagrams, flows as activity
    /// diagrams, and technical graphs as component diagrams.
    public static func export(_ c: Canvas) -> String {
        switch MermaidFormat.flavour(for: c) {
        case .sequence: return sequence(c)
        case .flowchart: return graph(c)
        default: return mindmap(c)
        }
    }

    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }

    public static func mindmap(_ c: Canvas) -> String {
        var out = "@startmindmap\n"
        let left = Set(c.nodes[c.root]?.children.enumerated().filter { $0.offset % 2 == 1 }.map(\.element) ?? [])
        let balanced = c.layout.structure == .mindmapBalanced
        var side: [NodeID: Bool] = [:]
        c.walk { id, n, d in
            if d == 1 { side[id] = balanced && left.contains(id) }
            for ch in n.children { side[ch] = side[ch] ?? side[id] ?? false }
            let mark = side[id] == true ? "-" : "*"
            out += String(repeating: mark, count: d + 1) + " " + clean(n.text) + "\n"
        }
        out += "@endmindmap\n"
        return out
    }

    static func sequence(_ c: Canvas) -> String {
        var out = "@startuml\n"
        if let t = c.nodes[c.root]?.text, !t.isEmpty { out += "title \(clean(t))\n" }
        let ps = Mermaid.participants(c)
        for (i, p) in ps.enumerated() {
            let n = c.nodes[p]!
            out += "\(n.nodeType == "actor" ? "actor" : "participant") \"\(clean(n.text))\" as P\(i + 1)\n"
        }
        let alias = Dictionary(uniqueKeysWithValues: ps.enumerated().map { ($1, "P\($0 + 1)") })
        for m in Mermaid.messages(c) {
            out += "\(alias[m.from]!) \(m.kind == "return" ? "-->" : "->") \(alias[m.to]!) : \(clean(m.label))\n"
        }
        out += "@enduml\n"
        return out
    }

    static func graph(_ c: Canvas) -> String {
        var out = "@startuml\n"
        let parents = c.parentMap()
        let ids = c.tops.flatMap { c.subtree($0) }
        for id in ids {
            guard let n = c.nodes[id] else { continue }
            let t = DiagramCatalog.effectiveType(id, in: c, parents: parents)
            let kind: String =
                switch t {
                case .store?, "db"?: "database"
                case .entity?, "actor"?: "actor"
                case .decision?: "agent"
                default: c.type == .architecture ? "component" : "rectangle"
                }
            out += "\(kind) \"\(clean(n.text))\" as \(id.rawValue)\n"
        }
        for id in ids {
            guard let p = parents[id], let n = c.nodes[id] else { continue }
            out +=
                "\(p.rawValue) --> \(id.rawValue)" + (n.edgeLabel.map { $0.isEmpty ? "" : " : \(clean($0))" } ?? "")
                + "\n"
        }
        for r in c.relationships where c.nodes[r.from] != nil && c.nodes[r.to] != nil {
            out += "\(r.from.rawValue) ..> \(r.to.rawValue)" + (r.label.isEmpty ? "" : " : \(clean(r.label))") + "\n"
        }
        out += "@enduml\n"
        return out
    }

    /// The `@startmindmap` / `@startwbs` subset (`*`/`+`/`-` depth markers, `:multiline;`)
    /// and simple sequence diagrams.
    public static func parse(_ text: String, title: String, report: inout ImportReport) throws -> ICanvas {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        report.sheets = 1
        let start = lines.first { $0.trimmed.hasPrefix("@start") }?.trimmed ?? ""
        if start.hasPrefix("@startmindmap") || start.hasPrefix("@startwbs") {
            var stack: [(Int, ITopic)] = []
            var tops: [ITopic] = []
            func pop(to level: Int) {
                while let last = stack.last, last.0 >= level {
                    stack.removeLast()
                    if stack.isEmpty { tops.append(last.1) } else { stack[stack.count - 1].1.children.append(last.1) }
                }
            }
            var multiline: (Int, [String])?
            for raw in lines {
                let l = raw.trimmed
                if var m = multiline {
                    if l.hasSuffix(";") {
                        m.1.append(String(l.dropLast()))
                        pop(to: m.0)
                        var t = ITopic(m.1.first ?? "")
                        let rest = m.1.dropFirst().joined(separator: "\n").trimmed
                        if !rest.isEmpty { t.note = rest }
                        stack.append((m.0, t))
                        multiline = nil
                    } else {
                        m.1.append(l)
                        multiline = m
                    }
                    continue
                }
                guard let ch = l.first, "*+-#".contains(ch) else {
                    if !l.isEmpty && !l.hasPrefix("@") && !l.hasPrefix("'") { report.skip("PlantUML styling") }
                    continue
                }
                let level = l.prefix { $0 == ch }.count
                var body = l.dropFirst(level)
                if body.hasPrefix("_") { body = body.dropFirst() }
                if let b = body.firstIndex(of: "]"), body.trimmed.hasPrefix("[") {
                    body = body[body.index(after: b)...]
                }
                let t = body.trimmed
                if t.hasPrefix(":") {
                    let inner = String(t.dropFirst())
                    if inner.hasSuffix(";") {
                        pop(to: level)
                        stack.append((level, ITopic(String(inner.dropLast()))))
                    } else {
                        multiline = (level, [inner])
                    }
                    continue
                }
                pop(to: level)
                stack.append((level, ITopic(t)))
            }
            pop(to: Int.min)
            let root = tops.count == 1 ? tops[0] : ITopic(title, children: tops)
            var ic = ICanvas(title: root.text, root: root)
            ic.synthesizedRoot = tops.count != 1
            return ic
        }
        if start.hasPrefix("@startuml"), lines.contains(where: { $0.contains("->") }) {
            let mermaid =
                ["sequenceDiagram"]
                + lines.compactMap { l -> String? in
                    let t = l.trimmed
                    if t.hasPrefix("@") || t.hasPrefix("'") || t.isEmpty { return nil }
                    if t.hasPrefix("title") { return t }
                    // PlantUML is `participant "Display" as Alias`; Mermaid is `participant Alias as Display`.
                    if let m = t.wholeMatch(of: /(participant|actor)\s+"?([^"]+?)"?\s+as\s+(\S+)/) {
                        return "\(m.1) \(m.3) as \(m.2)"
                    }
                    if t.hasPrefix("participant ") || t.hasPrefix("actor ") {
                        return t.replacingOccurrences(of: "\"", with: "")
                    }
                    return t.replacingOccurrences(of: " -> ", with: "->>").replacingOccurrences(
                        of: " --> ", with: "-->>"
                    )
                    .replacingOccurrences(of: " : ", with: ": ")
                }
            var r = report
            let ic = try MermaidFormat.parse(mermaid.joined(separator: "\n"), title: title, report: &r)
            report = r
            return ic
        }
        throw ImportError.invalid(title, "only PlantUML mind maps, WBS and sequence diagrams are supported")
    }
}
