import Foundation
import NexusCore

/// Formulas in Markdown and Xmind (M48). Inline `$…$` and display `$$…$$` are text both
/// ways; a `/math` topic travels as `$$…$$`, and a topic that is one `$$…$$` comes back
/// as `/math`.
enum MathInterchange {
    /// The topic's text as written out.
    static func text(_ n: Node) -> String {
        n.textFormat == "math" ? "$$" + n.text.trimmingCharacters(in: .whitespacesAndNewlines) + "$$" : n.text
    }

    /// A topic read in: one display formula and nothing else becomes `/math`.
    static func read(_ t: inout ITopic) {
        guard t.textFormat == nil, let source = MathMarkup.wholeDisplay(t.text) else { return }
        t.text = source
        t.textFormat = "math"
    }

    /// `body` applied to the text between formulas, which stay as they are.
    static func outsideFormulas(_ s: String, _ body: (String) -> String) -> String {
        let formulas = MathMarkup.scan(s).formulas
        guard !formulas.isEmpty else { return body(s) }
        let ns = s as NSString
        var out = ""
        var at = 0
        for f in formulas {
            out += body(ns.substring(with: NSRange(location: at, length: f.range.location - at)))
            out += ns.substring(with: f.range)
            at = f.range.location + f.range.length
        }
        return out + body(ns.substring(from: at))
    }
}
