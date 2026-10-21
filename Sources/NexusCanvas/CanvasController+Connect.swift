import Foundation
import NexusCore
import NexusKeys

/// One possible Connect target: a topic or a zone.
public struct ConnectCandidate: Equatable, Sendable {
    public var end: RelationshipEnd
    public var hint: String
    /// Distance rank: 0 is the nearest topic or zone.
    public var rank: Int

    /// The topic, when the candidate is one.
    public var node: NodeID? { end.topic }
}

/// Connect mode (F2): hint chips nearest-first, type hint letters or text to filter,
/// arrows move the highlight, ↩ draws the edge, Esc changes nothing. Zones are targets
/// too, and a selected zone is the source (D171).
public struct ConnectState: Equatable, Sendable {
    public var source: RelationshipEnd
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

    mutating func refilter(texts: [RelationshipEnd: String]) {
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
        matches = candidates.filter { (texts[$0.end] ?? "").lowercased().contains(needle) }
        matchedHints = false
    }
}

@MainActor
extension CanvasController {
    /// ⇧⌘L: enter Connect mode from the selected zone, or else the primary selection.
    /// Topics and zones are candidates, nearest centre first.
    public func startConnect() {
        if mode == .edit { commitEdit() }
        let source: RelationshipEnd =
            if case .zone(let z)? = selectedElement { .zone(z) } else { .topic(selection.primary) }
        guard let sr = scene.rect(of: source) else { return }
        let s = CGPoint(x: sr.midX, y: sr.midY)
        let topics: [RelationshipEnd] = scene.order.map { .topic($0) }
        let zones: [RelationshipEnd] = scene.zones.map { .zone($0.zone.id) }
        let others = (topics + zones).filter { $0 != source }
        let scene = scene
        func distance(_ e: RelationshipEnd) -> CGFloat {
            guard let r = scene.rect(of: e) else { return .infinity }
            return hypot(r.midX - s.x, r.midY - s.y)
        }
        let measured: [(end: RelationshipEnd, d: CGFloat)] = others.map { ($0, distance($0)) }
        func before(_ a: RelationshipEnd, _ b: RelationshipEnd) -> Bool {
            if let x = a.topic, let y = b.topic { return x < y }
            return a.topic != nil || (b.topic == nil && a.rawValue < b.rawValue)
        }
        let ranked = measured.sorted { a, b in a.d == b.d ? before(a.end, b.end) : a.d < b.d }.map(\.end)
        let hints = ConnectState.hints(count: ranked.count)
        var state = ConnectState(
            source: source,
            candidates: ranked.enumerated().map { ConnectCandidate(end: $1, hint: hints[$0], rank: $0) })
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

    /// What Connect mode shows and filters on: topic text, and a zone's title.
    var connectTexts: [RelationshipEnd: String] {
        var out = Dictionary(uniqueKeysWithValues: canvas.nodes.map { (RelationshipEnd.topic($0.key), $0.value.text) })
        for z in canvas.zones { out[.zone(z.id)] = Loc.f("Zone: %@", z.title) }
        return out
    }

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
            c.refilter(texts: connectTexts)
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
            c.refilter(texts: connectTexts)
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
        let target = c.target?.end
        let newText = c.query.trimmingCharacters(in: .whitespaces)
        guard target != nil || c.offersCreate else {
            cancelConnect()
            return
        }
        connect = nil
        mode = .select
        let root = canvas.root
        let primary = source.topic ?? selection.primary
        let result = perform(
            Loc.t("Relationship"), selectionAfter: { (r: (RelationshipEnd, String)) in Selection(r.0.topic ?? primary) }
        ) { e in
            let to = try target ?? .topic(e.addChild(of: root, text: newText))
            return (to, e.connect(source, to: to))
        }
        guard let (_, rid) = result else { return }
        selection = Selection(primary)
        selectedElement = .relationship(rid)
        var session = EditSession(node: primary, text: "", selectAll: false)
        session.element = .relationship(rid)
        edit = session
        mode = .edit
        onEditChange?(edit)
        onSceneChange?(true)
    }
}
