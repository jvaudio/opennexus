import Foundation

/// Mermaid text for "Copy as Mermaid" (artboard 23). M7 adds the full exporter set; the
/// same generators back it.
public enum Mermaid {
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "#quot;").replacingOccurrences(of: "\n", with: "<br/>") + "\""
    }

    public static func label(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ";", with: "#59;")
            .replacingOccurrences(of: "|", with: "#124;")
    }

    /// The sequence's participants, in order.
    public static func participants(_ canvas: Canvas) -> [NodeID] {
        canvas.nodes[canvas.root]?.children ?? []
    }

    /// Messages: relationships between participants, in time order.
    public static func messages(_ canvas: Canvas) -> [Relationship] {
        let ps = Set(participants(canvas))
        return canvas.relationships.filter { $0.connects(within: ps) }
    }

    public static func sequence(_ canvas: Canvas) -> String {
        let ps = participants(canvas)
        let alias = Dictionary(uniqueKeysWithValues: ps.enumerated().map { ($1, "P\($0 + 1)") })
        var lines = ["sequenceDiagram"]
        if let title = canvas.nodes[canvas.root]?.text, !title.isEmpty { lines.append("    title \(label(title))") }
        for p in ps {
            let n = canvas.nodes[p]!
            let kind = n.nodeType == "actor" ? "actor" : "participant"
            lines.append("    \(kind) \(alias[p]!) as \(label(n.text))")
        }
        for m in messages(canvas) {
            let arrow = m.kind == "return" ? "-->>" : "->>"
            lines.append("    \(alias[m.from.topic!]!)\(arrow)\(alias[m.to.topic!]!): \(label(m.label))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func flowchart(_ canvas: Canvas) -> String {
        let parents = canvas.parentMap()
        var lines = ["flowchart TD"]
        var edges: [String] = []
        let ids = canvas.tops.flatMap { canvas.subtree($0) }
        for id in ids {
            guard let n = canvas.nodes[id] else { continue }
            let t = DiagramCatalog.effectiveType(id, in: canvas, parents: parents)
            let q = quote(n.text)
            let shape: String =
                switch t {
                case .start?, .end?: "([\(q)])"
                case .decision?: "{\(q)}"
                case .io?: "[/\(q)/]"
                case .document?: "[\(q)]"
                default: "[\(q)]"
                }
            lines.append("    \(id.rawValue)\(shape)")
            if let p = parents[id] {
                let l = n.edgeLabel.map { $0.isEmpty ? "" : "|\(label($0))|" } ?? ""
                edges.append("    \(p.rawValue) -->\(l) \(id.rawValue)")
            }
        }
        // Zones, and boundaries that relationships end on, are subgraphs holding their
        // branches (nested when one holds another), so relationships can end on them.
        func group(_ g: EndGroup, _ depth: Int) {
            let pad = String(repeating: "    ", count: depth)
            lines.append("\(pad)subgraph \(g.ref) [\(quote(g.title))]")
            lines += g.nodes.map { "\(pad)    \($0.rawValue)" }
            for inner in g.groups { group(inner, depth + 1) }
            lines.append("\(pad)end")
        }
        for g in canvas.endGroups() { group(g, 1) }
        for r in canvas.relationships where canvas.has(r.from) && canvas.has(r.to) {
            let l = r.label.isEmpty ? "" : "|\(label(r.label))|"
            edges.append("    \(canvas.textRef(r.from)) -.->\(l) \(canvas.textRef(r.to))")
        }
        return (lines + edges).joined(separator: "\n") + "\n"
    }
}

/// A zone, or a boundary a relationship ends on, as a group in a text format (Mermaid
/// subgraph, PlantUML rectangle). `nodes` are the topics it holds directly; groups it
/// wholly contains are nested in `groups` (D172, D182).
public struct EndGroup: Equatable, Sendable {
    public var ref: String
    public var title: String
    public var nodes: [NodeID]
    public var groups: [EndGroup] = []
}

extension Canvas {
    /// How text formats name a relationship end: a topic's id, `zone_<id>` or
    /// `boundary_<id>` for a group (ids could clash with topic ids), and a summary's own
    /// topic for a summary (its bracket has no counterpart there).
    public func textRef(_ end: RelationshipEnd) -> String {
        switch end {
        case .topic(let id): id.rawValue
        case .zone(let id): "zone_\(id)"
        case .boundary(let id): "boundary_\(id)"
        case .summary(let id): summaries.first { $0.id == id }?.topic.rawValue ?? id
        }
    }

    /// Zones and the boundaries relationships end on, nested by containment. A topic sits
    /// in the innermost group that holds it (when two groups only overlap, the smaller one
    /// keeps the shared topics). Zones come first, then boundaries, each in canvas order.
    public func endGroups() -> [EndGroup] {
        struct Item {
            var group: EndGroup
            var all: [NodeID]
        }
        let ended = Set(relationships.flatMap { [$0.from.boundary, $0.to.boundary] }.compactMap(\.self))
        var items: [Item] = zones.map {
            Item(
                group: EndGroup(ref: textRef(.zone($0.id)), title: $0.title, nodes: []),
                all: $0.members.flatMap { subtree($0) })
        }
        for b in boundaries where ended.contains(b.id) {
            items.append(
                Item(
                    group: EndGroup(
                        ref: textRef(.boundary(b.id)), title: b.title.isEmpty ? "Boundary" : b.title, nodes: []),
                    all: b.nodes.flatMap { subtree($0) }))
        }
        let sets = items.map { Set($0.all) }
        // Smaller groups are inner; of two equal ones, the later is inside the earlier.
        func inner(_ a: Int, than b: Int) -> Bool {
            sets[a].count < sets[b].count || (sets[a].count == sets[b].count && a > b)
        }
        // Parent: the innermost other group that holds all of this one.
        var parent = [Int?](repeating: nil, count: items.count)
        for i in items.indices {
            for j in items.indices where j != i && sets[i].isSubset(of: sets[j]) && inner(i, than: j) {
                if parent[i].map({ inner(j, than: $0) }) ?? true { parent[i] = j }
            }
        }
        // Each topic belongs to the innermost group that holds it.
        var owner: [NodeID: Int] = [:]
        for i in items.indices {
            for n in items[i].all where owner[n].map({ inner(i, than: $0) }) ?? true { owner[n] = i }
        }
        for i in items.indices {
            var seen = Set<NodeID>()
            items[i].group.nodes = items[i].all.filter { owner[$0] == i && seen.insert($0).inserted }
        }
        func build(_ i: Int) -> EndGroup {
            var g = items[i].group
            g.groups = items.indices.filter { parent[$0] == i }.map(build)
            return g
        }
        return items.indices.filter { parent[$0] == nil }.map(build)
    }
}
