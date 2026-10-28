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
    /// The canvas's legend in a corner of every slide, when the canvas shows one (M21).
    public var legend: Bool = true
    /// A Timeline slide (a compact Gantt) after each branch that has dated tasks (M21).
    public var timeline: Bool = false
    /// calm (Glide and dimming, as before M42), dynamic (the default: fly-to, builds,
    /// spotlight) or showtime (as dynamic, quicker, with the focus enlarged) (M42).
    public var style: String = "dynamic"
    /// main: a slide per main topic; all: a slide per topic with children, walked in
    /// outline order (M42). Flow and message decks ignore it.
    public var depth: String = "main"
    /// An overview of the whole map between branches (M42).
    public var overview: Bool = false
    public var extra: [String: JSONValue] = [:]

    public init() {}

    public var isDefault: Bool { self == PresentationSettings() }

    public static let styles = ["calm", "dynamic", "showtime"]

    /// How the camera moves between slides (M42): an explicit Cut always cuts; Calm keeps
    /// the deck's Glide, and Zoom and the other styles fly (van Wijk and Nuij's path).
    public var cameraMove: String {
        if transition == "cut" { return "cut" }
        return style == "calm" && transition == "glide" ? "glide" : "fly"
    }

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
        legend = try r.bool("legend", default: true)
        timeline = try r.bool("timeline", default: false)
        style = try r.optionalString("style") ?? "dynamic"
        depth = try r.optionalString("depth") ?? "main"
        overview = try r.bool("overview", default: false)
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
        w.set("legend", legend, omitting: true)
        w.set("timeline", timeline, omitting: false)
        if style != "dynamic" { w.set("style", style) }
        if depth != "main" { w.set("depth", depth) }
        w.set("overview", overview, omitting: false)
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
    /// A Timeline slide: the branch under this topic drawn as a compact Gantt (M21), or
    /// the whole diagram when it is the central topic (M28).
    public var timeline: NodeID?
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
            for (i, r) in Mermaid.messages(c).enumerated() {
                guard let (from, to) = r.topics, visible(from) && visible(to) else { continue }
                out.append(
                    Slide(
                        id: "msg:\(r.id)", kicker: kicker, title: r.label.isEmpty ? "Message \(i + 1)" : r.label,
                        focus: all, highlight: [from, to], flow: r.id, note: c.nodes[to]?.note?.text))
            }
            return out + diagramTimeline(c, kicker: kicker, title: rootText, focus: all)
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
            return out + diagramTimeline(c, kicker: kicker, title: rootText, focus: all)
        }
        // Hierarchies: one slide per main topic, framed on its branch; with Depth › Every
        // branch, then one per topic under it that has children, framed with its parent (M42).
        let mains = (c.nodes[c.root]?.children ?? []).filter(visible)
        for (k, m) in mains.enumerated() {
            let branch = c.subtree(m, includeFolded: false).filter(visible)
            out.append(
                Slide(
                    id: "branch:\(m.rawValue)", kicker: kicker, title: c.nodes[m]?.text ?? "", focus: [c.root] + branch,
                    highlight: [m], flow: nil, note: c.nodes[m]?.note?.text))
            if s.depth == "all" {
                let parents = c.parentMap()
                for id in branch.dropFirst() {
                    guard let n = c.nodes[id], !n.folded, n.children.contains(where: visible), let p = parents[id]
                    else { continue }
                    out.append(
                        Slide(
                            id: "branch:\(id.rawValue)", kicker: kicker, title: n.text,
                            focus: [p] + c.subtree(id, includeFolded: false).filter(visible), highlight: [id],
                            flow: nil,
                            note: n.note?.text))
                }
            }
            if s.timeline, branch.contains(where: { c.nodes[$0]?.todo?.isScheduled == true }) {
                var t = Slide(
                    id: "timeline:\(m.rawValue)", kicker: kicker, title: c.nodes[m]?.text ?? "",
                    focus: [c.root] + branch, highlight: [m], flow: nil, note: nil)
                t.timeline = m
                out.append(t)
            }
            if s.overview, k < mains.count - 1 {
                out.append(
                    Slide(
                        id: "overview:\(m.rawValue)", kicker: kicker, title: rootText, focus: all, highlight: [],
                        flow: nil, note: nil))
            }
        }
        return out
    }

    /// What a slide builds in on arrival (Dynamic, Showtime; M42): a branch slide's topics
    /// under its focus topic, in outline order. Title, overview, flow and message slides
    /// build nothing (a flow slide draws its flow on instead).
    public static func builds(_ slide: Slide, in c: Canvas) -> [NodeID] {
        guard slide.flow == nil, slide.id.hasPrefix("branch:"), let h = slide.highlight.last else { return [] }
        let focus = Set(slide.focus)
        return c.subtree(h, includeFolded: false).dropFirst().filter(focus.contains)
    }

    /// Present from Selected Topic (⌥⌘P): the playing slide about `id` (its own, or its
    /// nearest ancestor's), else the first flow or message slide that involves it, else 0.
    public static func index(for id: NodeID, in slides: [Slide], canvas c: Canvas) -> Int {
        let parents = c.parentMap()
        var cur: NodeID? = id
        while let x = cur {
            if let i = slides.firstIndex(where: { !$0.skipped && $0.id == "branch:\(x.rawValue)" }) { return i }
            cur = parents[x]
        }
        return slides.firstIndex { !$0.skipped && $0.flow != nil && $0.highlight.contains(id) } ?? 0
    }

    /// Flow and message decks have no branches, so with Timeline slides on they close
    /// with one for the whole diagram (M28, D235): every dated task, filed under the
    /// central topic as `timeline:<root>`.
    static func diagramTimeline(_ c: Canvas, kicker: String, title: String, focus: [NodeID]) -> [Slide] {
        guard c.presentation.timeline, focus.contains(where: { c.nodes[$0]?.todo?.isScheduled == true }) else {
            return []
        }
        var t = Slide(
            id: "timeline:\(c.root.rawValue)", kicker: kicker, title: title, focus: focus, highlight: [], flow: nil,
            note: nil)
        t.timeline = c.root
        return [t]
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
