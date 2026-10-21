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
        // Zones are subgraphs holding their members' branches, so relationships can end on them.
        for z in canvas.zones {
            lines.append("    subgraph \(ref(.zone(z.id))) [\(quote(z.title))]")
            for m in z.members { lines += canvas.subtree(m).map { "        \($0.rawValue)" } }
            lines.append("    end")
        }
        for r in canvas.relationships where canvas.has(r.from) && canvas.has(r.to) {
            let l = r.label.isEmpty ? "" : "|\(label(r.label))|"
            edges.append("    \(ref(r.from)) -.->\(l) \(ref(r.to))")
        }
        return (lines + edges).joined(separator: "\n") + "\n"
    }

    /// A topic's id, or `zone_<id>` for a zone's subgraph (zone ids could match topic ids).
    static func ref(_ end: RelationshipEnd) -> String { end.zone.map { "zone_\($0)" } ?? end.rawValue }
}
