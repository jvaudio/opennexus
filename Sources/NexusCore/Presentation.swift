import Foundation

/// Present mode settings stored with the canvas (artboard 32).
public struct PresentationSettings: Hashable, Sendable, JSONRepresentable {
    /// Slide ids in a custom order (drag to reorder); others keep their generated place.
    public var order: [String] = []
    public var skipped: [String] = []
    /// Slides merged with the one after them.
    public var merged: [String] = []
    /// glide, zoom or cut
    public var transition: String = "glide"
    /// 16:9, 4:3, 16:10 or 1:1
    public var aspect: String = "16:9"
    /// canvas, dark or light
    public var theme: String = "canvas"
    /// Flowcharts, DFDs and sequences step one flow at a time.
    public var stepThroughFlow: Bool = true
    public var extra: [String: JSONValue] = [:]

    public init() {}

    public var isDefault: Bool { self == PresentationSettings() }

    public var aspectRatio: Double {
        switch aspect {
        case "4:3": 4.0 / 3
        case "16:10": 1.6
        case "1:1": 1
        default: 16.0 / 9
        }
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        order = try r.strings("order")
        skipped = try r.strings("skipped")
        merged = try r.strings("merged")
        transition = try r.optionalString("transition") ?? "glide"
        aspect = try r.optionalString("aspect") ?? "16:9"
        theme = try r.optionalString("theme") ?? "canvas"
        stepThroughFlow = try r.bool("stepThroughFlow", default: true)
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("order", order, omitEmpty: true)
        w.set("skipped", skipped, omitEmpty: true)
        w.set("merged", merged, omitEmpty: true)
        if transition != "glide" { w.set("transition", transition) }
        if aspect != "16:9" { w.set("aspect", aspect) }
        if theme != "canvas" { w.set("theme", theme) }
        w.set("stepThroughFlow", stepThroughFlow, omitting: true)
        return w.value
    }
}

/// One slide: what to frame, what to emphasise, and what the presenter says.
public struct Slide: Hashable, Sendable, Identifiable {
    public var id: String
    public var kicker: String
    public var title: String
    /// Topics the camera frames; the rest dims.
    public var focus: [NodeID]
    /// Topics drawn with the step glow.
    public var highlight: [NodeID]
    /// A flow (tree edge `t:<child>` or relationship id) drawn as the moving step.
    public var flow: String?
    public var note: String?
    public var skipped: Bool = false
}

public enum Deck {
    /// The generated slides for a canvas, after the user's order, merges and skips.
    public static func slides(_ canvas: Canvas) -> [Slide] {
        let s = canvas.presentation
        var raw = generated(canvas)
        // Merge a slide into the next one.
        var i = 0
        while i < raw.count - 1 {
            if s.merged.contains(raw[i].id) {
                let a = raw[i]
                let b = raw[i + 1]
                raw[i + 1] = Slide(
                    id: b.id, kicker: a.kicker, title: "\(a.title) · \(b.title)", focus: unique(a.focus + b.focus),
                    highlight: unique(a.highlight + b.highlight), flow: b.flow ?? a.flow,
                    note: [a.note, b.note].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty)
                raw.remove(at: i)
            } else {
                i += 1
            }
        }
        // Custom order first (for ids that still exist), then the rest in place.
        if !s.order.isEmpty {
            let byID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ordered = s.order.compactMap { byID[$0] }
            let rest = raw.filter { !s.order.contains($0.id) }
            raw = ordered + rest
        }
        for k in raw.indices { raw[k].skipped = s.skipped.contains(raw[k].id) }
        // Step numbering in the kicker, over slides that play.
        let playing = raw.filter { !$0.skipped && $0.id != "title" }
        for k in raw.indices where raw[k].id != "title" {
            if let n = playing.firstIndex(where: { $0.id == raw[k].id }) {
                raw[k].kicker += " · STEP \(n + 1) OF \(playing.count)"
            }
        }
        return raw
    }

    static func unique(_ ids: [NodeID]) -> [NodeID] {
        var seen = Set<NodeID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Slides before user edits: a title slide, then branches or flow steps.
    public static func generated(_ c: Canvas) -> [Slide] {
        let hidden = Set(c.nodes.filter { $0.value.presentHidden }.keys)
        let visible: (NodeID) -> Bool = { !hidden.contains($0) }
        let rootText = c.nodes[c.root]?.text ?? c.title
        let kicker = "\(rootText.uppercased()) · \(c.type.displayName.uppercased())"
        let all = c.tops.flatMap { c.subtree($0, includeFolded: false) }.filter(visible)
        var out = [
            Slide(
                id: "title", kicker: kicker, title: rootText, focus: all, highlight: [], flow: nil,
                note: c.nodes[c.root]?.note?.text)
        ]
        let s = c.presentation
        if c.type == .sequence {
            for (i, r) in Mermaid.messages(c).enumerated() where visible(r.from) && visible(r.to) {
                out.append(
                    Slide(
                        id: "msg:\(r.id)", kicker: kicker, title: r.label.isEmpty ? "Message \(i + 1)" : r.label,
                        focus: all, highlight: [r.from, r.to], flow: r.id, note: c.nodes[r.to]?.note?.text))
            }
            return out
        }
        if DiagramCatalog.isTechnical(c.type) && s.stepThroughFlow {
            // One slide per flow, breadth-first from the diagram's sources.
            let g = FlowGraph(c)
            var order: [FlowGraph.Flow] = []
            var queue = c.tops
            var seen = Set<NodeID>()
            var used = Set<String>()
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard seen.insert(id).inserted else { continue }
                for f in g.flows where f.from == id && !used.contains(f.id) {
                    used.insert(f.id)
                    order.append(f)
                    queue.append(f.to)
                }
                queue.append(contentsOf: c.nodes[id]?.children ?? [])
            }
            order += g.flows.filter { !used.contains($0.id) }
            for f in order where visible(f.from) && visible(f.to) {
                let from = c.nodes[f.from]?.text ?? ""
                let to = c.nodes[f.to]?.text ?? ""
                let title =
                    f.label.isEmpty
                    ? "\(from) → \(to)" : "\(f.label.prefix(1).uppercased())\(f.label.dropFirst()) → \(to)"
                out.append(
                    Slide(
                        id: "flow:\(f.id)", kicker: kicker, title: title, focus: all, highlight: [f.from, f.to],
                        flow: f.id, note: c.nodes[f.to]?.note?.text))
            }
            return out
        }
        // Hierarchies: one slide per main topic, framed on its branch.
        for m in (c.nodes[c.root]?.children ?? []) where visible(m) {
            let branch = c.subtree(m, includeFolded: false).filter(visible)
            out.append(
                Slide(
                    id: "branch:\(m.rawValue)", kicker: kicker, title: c.nodes[m]?.text ?? "", focus: [c.root] + branch,
                    highlight: [m], flow: nil, note: c.nodes[m]?.note?.text))
        }
        return out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension CanvasEditor {
    /// S (skip), M (merge with next) and H (hide topic) toggles, as edits.
    public mutating func toggleSkip(_ slide: String) {
        updateMeta { c in
            if let i = c.presentation.skipped.firstIndex(of: slide) {
                c.presentation.skipped.remove(at: i)
            } else {
                c.presentation.skipped.append(slide)
            }
        }
    }

    public mutating func toggleMerge(_ slide: String) {
        updateMeta { c in
            if let i = c.presentation.merged.firstIndex(of: slide) {
                c.presentation.merged.remove(at: i)
            } else {
                c.presentation.merged.append(slide)
            }
        }
    }

    public mutating func moveSlide(_ slide: String, to index: Int, in ids: [String]) {
        var order = ids.filter { $0 != slide }
        order.insert(slide, at: min(max(index, 0), order.count))
        updateMeta { $0.presentation.order = order }
    }
}
