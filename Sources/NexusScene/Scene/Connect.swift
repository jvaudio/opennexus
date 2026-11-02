import Foundation
import NexusCore

/// One possible Connect target: a topic, zone, boundary or summary.
public struct ConnectCandidate: Equatable, Sendable {
    public var end: RelationshipEnd
    public var hint: String
    /// Distance rank: 0 is the nearest target.
    public var rank: Int

    public init(end: RelationshipEnd, hint: String, rank: Int) {
        self.end = end
        self.hint = hint
        self.rank = rank
    }

    /// The topic, when the candidate is one.
    public var node: NodeID? { end.topic }
}

/// Connect mode (F2): hint chips nearest-first, type hint letters or text to filter,
/// arrows move the highlight, ↩ draws the edge, Esc changes nothing. Zones, boundaries
/// and summary brackets are targets too, and a selected one is the source (D171, D184).
public struct ConnectState: Equatable, Sendable {
    public var source: RelationshipEnd
    public var query: String = ""
    public var highlighted: Int = 0
    public var candidates: [ConnectCandidate]
    /// The candidates the query leaves, in rank order.
    public var matches: [ConnectCandidate] = []
    /// True when the query matched hints (false: it filters by topic text).
    public var matchedHints = true

    public init(source: RelationshipEnd, candidates: [ConnectCandidate]) {
        self.source = source
        self.candidates = candidates
    }

    public var target: ConnectCandidate? {
        matches.indices.contains(highlighted) ? matches[highlighted] : nil
    }

    /// "Create new node" is offered when typed text matches nothing.
    public var offersCreate: Bool { matches.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

extension ConnectState {
    package static let alphabet = Array("ASDFGHJKLQWERTYUIOPZXCVBNM").map(String.init)

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

    package mutating func refilter(texts: [RelationshipEnd: String]) {
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
