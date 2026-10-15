import Foundation
import NexusCore
import NexusKeys

/// One possible Connect target.
public struct ConnectCandidate: Equatable, Sendable {
    public var node: NodeID
    public var hint: String
    /// Distance rank: 0 is the nearest topic.
    public var rank: Int
}

/// Connect mode (F2): hint chips nearest-first, type hint letters or text to filter,
/// arrows move the highlight, ↩ draws the edge, Esc changes nothing.
public struct ConnectState: Equatable, Sendable {
    public var source: NodeID
    public var query: String = ""
    public var highlighted: Int = 0
    public var candidates: [ConnectCandidate]
    /// The candidates the query leaves, in rank order.
    public var matches: [ConnectCandidate] = []
    /// True when the query matched hints (false: it filters by topic text).
    public var matchedHints = true

    public var target: ConnectCandidate? {
        matches.indices.contains(highlighted) ? matches[highlighted] : nil
    }

    /// "Create new node" is offered when typed text matches nothing.
    public var offersCreate: Bool { matches.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

extension ConnectState {
    static let alphabet = Array("ASDFGHJKLQWERTYUIOPZXCVBNM").map(String.init)

    /// Prefix-free hints, shortest for the nearest: single letters while they last,
    /// then the last letters become prefixes for two-letter hints.
    public static func hints(count n: Int) -> [String] {
        let a = alphabet
        guard n > a.count else { return Array(a.prefix(n)) }
        var prefixes = 1
        while (a.count - prefixes) + prefixes * a.count < n { prefixes += 1 }
        let singles = Array(a.prefix(a.count - prefixes))
        let heads = Array(a.suffix(prefixes))
        var out = singles
        for h in heads {
            for t in a {
                out.append(h + t)
                if out.count == n { return out }
            }
        }
        return out
    }

    mutating func refilter(texts: [NodeID: String]) {
        let q = query.uppercased()
        highlighted = 0
        guard !q.isEmpty else {
            matches = candidates
            matchedHints = true
            return
        }
        let exact = candidates.filter { $0.hint == q }
        let prefixed = candidates.filter { $0.hint != q && $0.hint.hasPrefix(q) }
        if !exact.isEmpty || !prefixed.isEmpty {
            matches = exact + prefixed
            matchedHints = true
            return
        }
        let needle = query.lowercased()
        matches = candidates.filter { (texts[$0.node] ?? "").lowercased().contains(needle) }
        matchedHints = false
    }
}

@MainActor
extension CanvasController {
    /// ⇧⌘L: enter Connect mode from the primary selection.
    public func startConnect() {
        if mode == .edit { commitEdit() }
        let source = selection.primary
        guard let s = scene.nodes[source]?.frame.center else { return }
        let others = scene.order.filter { $0 != source }
        let ranked = others.sorted {
            let a = scene.nodes[$0]!.frame.center
            let b = scene.nodes[$1]!.frame.center
            let da = hypot(a.x - s.x, a.y - s.y)
            let db = hypot(b.x - s.x, b.y - s.y)
            return da == db ? $0 < $1 : da < db
        }
        let hints = ConnectState.hints(count: ranked.count)
        var state = ConnectState(
            source: source,
            candidates: ranked.enumerated().map { ConnectCandidate(node: $1, hint: hints[$0], rank: $0) })
        state.matches = state.candidates
        connect = state
        selectedElement = nil
        mode = .connect
        onSceneChange?(false)
    }

    public func cancelConnect() {
        connect = nil
        mode = .select
        onSceneChange?(false)
    }

    var nodeTexts: [NodeID: String] { canvas.nodes.mapValues(\.text) }

    /// Connect-mode keys. Returns true when handled.
    func handleConnectKey(_ chord: KeyChord, characters: String?) -> Bool {
        guard var c = connect else { return false }
        if chord.modifiers.contains(.command) || chord.modifiers.contains(.control) { return false }
        switch chord.key {
        case .escape:
            cancelConnect()
        case .return:
            finishConnect()
        case .delete:
            guard !c.query.isEmpty else { return true }
            c.query.removeLast()
            c.refilter(texts: nodeTexts)
            connect = c
        case .down, .right:
            if !c.matches.isEmpty { c.highlighted = (c.highlighted + 1) % c.matches.count }
            connect = c
        case .up, .left:
            if !c.matches.isEmpty { c.highlighted = (c.highlighted + c.matches.count - 1) % c.matches.count }
            connect = c
        default:
            guard let ch = characters, !ch.isEmpty,
                ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return true }
            c.query += ch
            c.refilter(texts: nodeTexts)
            connect = c
        }
        onSceneChange?(false)
        return true
    }

    /// ↩: draws the edge (creating the target if the text matched nothing) and opens
    /// its label in Edit mode. One undo step.
    public func finishConnect() {
        guard let c = connect else { return }
        let source = c.source
        let target = c.target?.node
        let newText = c.query.trimmingCharacters(in: .whitespaces)
        guard target != nil || c.offersCreate else {
            cancelConnect()
            return
        }
        connect = nil
        mode = .select
        let root = canvas.root
        let result = perform(Loc.t("Relationship"), selectionAfter: { (r: (NodeID, String)) in Selection(r.0) }) { e in
            let to = try target ?? e.addChild(of: root, text: newText)
            let rid = e.connect(source, to: to)
            return (to, rid)
        }
        guard let (_, rid) = result else { return }
        selection = Selection(source)
        selectedElement = .relationship(rid)
        var session = EditSession(node: source, text: "", selectAll: false)
        session.element = .relationship(rid)
        edit = session
        mode = .edit
        onEditChange?(edit)
        onSceneChange?(true)
    }
}
