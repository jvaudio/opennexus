import Foundation
import NexusCore
import NexusScene
import NexusTheme

/// What VoiceOver says for a topic, shaped by Settings › Accessibility › VoiceOver.
@MainActor
public enum Spoken {
    public static func describe(
        _ id: NodeID, in c: NexusCore.Canvas, prefs: Preferences, branchColor: String? = nil,
        depth knownDepth: Int? = nil,
        maxDepth knownMax: Int? = nil, today: TaskDate = .today(), hints: Bool = true
    ) -> String {
        guard let n = c.nodes[id] else { return "" }
        let depth: Int
        let maxDepth: Int
        if let knownDepth, let knownMax {
            (depth, maxDepth) = (knownDepth, knownMax)
        } else {
            // One walk from the root gives every depth.
            let d = depths(c)
            depth = d.depths[id] ?? c.depth(of: id)
            maxDepth = d.max
        }
        var parts: [String] = [n.text.isEmpty ? Loc.t("Topic") : title(n, prefs: prefs)]
        if let error = mathError(n, prefs: prefs) { parts.append(Loc.f("Formula error: %@", error)) }
        let role =
            id == c.root
            ? Loc.t("Central topic")
            : c.floating.contains(id) ? Loc.t("Floating topic") : depth == 1 ? Loc.t("Main topic") : Loc.t("Subtopic")
        if prefs.bool("accessibility.announceLevel") {
            parts.append(Loc.f("%@, level %lld of %lld", role, depth + 1, maxDepth + 1))
            parts.append(
                n.folded
                    ? Loc.n("%lld child, collapsed", "%lld children, collapsed", n.children.count)
                    : Loc.n("%lld child", "%lld children", n.children.count))
        } else {
            parts.append(role)
        }
        if let t = n.nodeType, let info = DiagramCatalog.info(t, in: c.type) { parts.append(Loc.t(info.name)) }
        if let b = branchColor { parts.append(Loc.f("Branch colour %@", b)) }
        if let todo = n.todo { parts.append(todo.done ? Loc.t("Done") : Loc.t("To do")) }
        if let task = TaskFormat.spoken(c, id, today: today) { parts.append(task) }
        if n.note != nil { parts.append(Loc.t("Has note")) }
        if !n.comments.isEmpty { parts.append(Loc.n("%lld comment", "%lld comments", n.comments.count)) }
        if prefs.string("accessibility.readEdges") == "source" {
            for r in c.relationships where r.touches(id) {
                let other = r.from == .topic(id) ? r.to : r.from
                let name = c.spokenName(other)
                parts.append(
                    r.label.isEmpty
                        ? Loc.f("Connected to %@", name) : Loc.f("Connected to %@ by ‘%@’", name, r.label))
            }
        }
        if hints && prefs.bool("accessibility.speakHints") { parts.append(Loc.t("Tab adds a child")) }
        return parts.joined(separator: ". ") + "."
    }

    /// The title as read: formulas as their TeX source (decision #14, D421), a `/math`
    /// topic as "Equation, …", `\$` as a dollar sign (M48).
    public static func title(_ n: NexusCore.Node, prefs: Preferences) -> String {
        if n.textFormat == "math" {
            return Loc.f("Equation, %@", n.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard n.textFormat == nil, prefs.bool("editing.typesetMath") else { return n.text }
        return MathMarkup.plain(n.text)
    }

    /// MathJax's message for the topic's first formula that failed, once it's known.
    static func mathError(_ n: NexusCore.Node, prefs: Preferences) -> String? {
        let keys: [MathEngine.Key] =
            n.textFormat == "math"
            ? [MathEngine.Key(n.text.trimmingCharacters(in: .whitespacesAndNewlines), display: true)]
            : n.textFormat == nil && prefs.bool("editing.typesetMath") ? MathMarkup.keys(n.text) : []
        for k in keys {
            if case .error(let message)? = MathEngine.shared.cached(k) { return message }
        }
        return nil
    }

    /// Depth of every topic in the tree under the root (floating tops start their own).
    public static func depths(_ c: NexusCore.Canvas) -> (depths: [NodeID: Int], max: Int) {
        var depths: [NodeID: Int] = [:]
        for top in c.tops { c.walk(from: top) { id, _, d in depths[id] = d } }
        return (depths, depths.values.max() ?? 0)
    }

    /// A plain colour word for a branch colour ("teal", "orange"…), for VoiceOver.
    public static func colorName(_ c: RGBA) -> String {
        let mx = max(c.r, c.g, c.b)
        let mn = min(c.r, c.g, c.b)
        let delta = mx - mn
        if delta < 0.08 { return mx > 0.85 ? "white" : mx < 0.2 ? "black" : "grey" }
        var h: Double
        if mx == c.r {
            h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6)
        } else if mx == c.g {
            h = (c.b - c.r) / delta + 2
        } else {
            h = (c.r - c.g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        switch h {
        case ..<15, 345...: return "red"
        case ..<40: return "orange"
        case ..<65: return "yellow"
        case ..<150: return "green"
        case ..<195: return "teal"
        case ..<235: return "blue"
        case ..<260: return "indigo"
        case ..<290: return "purple"
        default: return "pink"
        }
    }

    static func sample(_ prefs: Preferences) -> String {
        var c = NexusCore.Canvas(id: "c1", title: "", rootText: "Launch plan")
        var undo = UndoStack()
        c.edit("Sample", undo: &undo) { e in
            let p = try! e.addChild(of: e.canvas.root, text: "Pricing")
            for t in ["Free", "Pro", "Team"] {
                let k = try! e.addChild(of: p, text: t)
                _ = try? e.addChild(of: k, text: "Seats")
            }
            e.update(p) {
                $0.folded = true
                $0.note = Note(text: "x")
            }
            let t = try! e.addChild(of: e.canvas.root, text: "Timeline")
            _ = e.connect(p, to: t, label: "drives")
        }
        let id = c.nodes.first { $0.value.text == "Pricing" }!.key
        return describe(id, in: c, prefs: prefs, branchColor: "teal").replacingOccurrences(
            of: "level 2 of 4", with: "level 2 of 4")
    }
}
