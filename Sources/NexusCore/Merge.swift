import Foundation

/// Three-way merge of a document changed on disk (an agent, the CLI, Git) with the copy
/// open in the app. `base` is what the app last read or saved.
///
/// Each canvas, topic and canvas setting is taken from whichever side changed it. When
/// both sides changed the same one differently, the app's version wins and the merge
/// reports it. A canvas whose merge wouldn't be a valid tree keeps the app's version.
public struct DocumentMerge: Sendable {
    public var model: DocumentModel
    /// "Pricing", "canvas settings on Launch plan", … kept from the app.
    public var conflicts: [String]

    public init(base: DocumentModel, current: DocumentModel, disk: DocumentModel) {
        var out = current
        var conflicts: [String] = []
        for id in Set(base.canvases.keys).union(current.canvases.keys).union(disk.canvases.keys) {
            let b = base.canvases[id]
            let c = current.canvases[id]
            let d = disk.canvases[id]
            if c == b {
                out.canvases[id] = d
            } else if d == b || c == d {
                continue
            } else if let b, let c, let d {
                let (merged, clashes) = Self.mergeCanvas(base: b, current: c, disk: d)
                if merged.validate().isEmpty {
                    out.canvases[id] = merged
                    conflicts += clashes
                } else {
                    conflicts.append("canvas “\(c.title.isEmpty ? id.rawValue : c.title)”")
                }
            } else {
                // Added on both sides, or deleted on one and edited on the other: keep the app's.
                conflicts.append("canvas “\((c ?? d)?.title ?? id.rawValue)”")
            }
        }
        // Tab order: the app's if it was reordered here, else the disk's; then any newcomers.
        var order = current.canvasOrder == base.canvasOrder ? disk.canvasOrder : current.canvasOrder
        order = order.filter { out.canvases[$0] != nil }
        for id in disk.canvasOrder + current.canvasOrder where out.canvases[id] != nil && !order.contains(id) {
            order.append(id)
        }
        out.canvasOrder = order
        if current.theme == base.theme { out.theme = disk.theme }
        for (k, v) in disk.assets where out.assets[k] == nil { out.assets[k] = v }
        model = out
        self.conflicts = conflicts
    }

    static func meta(_ c: Canvas) -> Canvas {
        var m = c
        m.nodes = [:]
        return m
    }

    static func mergeCanvas(base b: Canvas, current c: Canvas, disk d: Canvas) -> (Canvas, [String]) {
        var out = c
        var clashes: [String] = []
        for id in Set(b.nodes.keys).union(c.nodes.keys).union(d.nodes.keys) {
            let bn = b.nodes[id]
            let cn = c.nodes[id]
            let dn = d.nodes[id]
            if cn == bn {
                out.nodes[id] = dn
            } else if dn != bn, dn != cn {
                clashes.append("“\((cn ?? dn)?.text ?? id.rawValue)”")
            }
        }
        let bm = meta(b)
        let cm = meta(c)
        let dm = meta(d)
        if cm == bm {
            let nodes = out.nodes
            out = dm
            out.nodes = nodes
        } else if dm != bm, dm != cm {
            // Settings changed on both sides: relationships the disk added still come in.
            for r in d.relationships
            where !c.relationships.contains(where: { $0.id == r.id })
                && !b.relationships.contains(where: { $0.id == r.id })
            {
                out.relationships.append(r)
            }
            clashes.append("canvas settings on “\(c.title.isEmpty ? c.id.rawValue : c.title)”")
        }
        // Relationships whose ends were removed by the other side go too.
        out.relationships.removeAll { out.nodes[$0.from] == nil || out.nodes[$0.to] == nil }
        out.floating.removeAll { out.nodes[$0] == nil }
        return (out, clashes)
    }
}
