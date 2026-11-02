import Foundation
import NexusCore
import NexusFormat
import Testing

@testable import NexusReplica

@Suite struct PositionTests {
    func stamp(_ n: Int, _ r: String = "abcde1") -> Stamp { Stamp(time: 1_800_000_000_000, count: n, replica: r) }

    @Test func keysSitStrictlyBetweenTheirNeighbours() {
        var rng = SplitMix64(seed: 1)
        var keys: [String] = [Position.between(nil, nil, stamp: stamp(0))]
        for i in 1..<2_000 {
            let at = Int.random(in: 0...keys.count, using: &rng)
            let a = at > 0 ? keys[at - 1] : nil
            let b = at < keys.count ? keys[at] : nil
            let k = Position.between(a, b, stamp: stamp(i, i % 2 == 0 ? "abcde1" : "zzzzz9"))
            if let a { #expect(a < k) }
            if let b { #expect(k < b) }
            keys.insert(k, at: at)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        // Appending and prepending keep keys short (16 characters are the stamp).
        var last: String?
        var first: String?
        for i in 0..<1_000 {
            let k = Position.between(last, nil, stamp: stamp(i))
            if let last { #expect(last < k) }
            last = k
            let f = Position.between(nil, first, stamp: stamp(i))
            if let first { #expect(f < first) }
            first = f
        }
        #expect(last!.count < 16 + 60 && first!.count < 16 + 60)
    }

    @Test func twoPeopleInsertingAtTheSamePlaceGetDifferentKeys() {
        let a = Position.between(nil, nil, stamp: stamp(0))
        let b = Position.between(a, nil, stamp: stamp(1))
        let x = Position.between(a, b, stamp: stamp(5, "aaaaa1"))
        let y = Position.between(a, b, stamp: stamp(5, "bbbbb1"))
        #expect(x != y && a < x && x < b && a < y && y < b)
        let z = Position.between(min(x, y), max(x, y), stamp: stamp(6))
        #expect(min(x, y) < z && z < max(x, y))
    }

    @Test func stampsRoundTripAndSortLikeTheirCodes() {
        let s = [stamp(3), stamp(70_000, "k3x9qa"), Stamp(time: 1_900_000_000_000, count: 0, replica: "aaaaa1")]
        for x in s { #expect(Stamp(code: x.code) == x) }
        #expect(s.sorted() == s.sorted { $0.code < $1.code })
        #expect(Stamp(code: "short") == nil)
    }

    @Test func clockNeverRunsBackwards() {
        let t = FakeTime()
        var c = HybridClock(replica: "aaaaa1", now: t.now)
        let a = c.tick()
        let b = c.tick()
        #expect(a < b)
        c.observe(Stamp(time: t.ms + 5_000, count: 7, replica: "zzzzz9"))
        let d = c.tick()
        #expect(d.time == t.ms + 5_000 && d.count == 8)
        #expect(ReplicaID.isValid(ReplicaID.make()))
    }
}

@Suite struct ReplicaTests {
    func seeded(_ doc: DocumentModel = sampleDocument(), id: String = "host01") -> (Replica, [Op]) {
        Replica.seed(doc, id: id)
    }

    @Test func aSeedMaterialisesTheDocumentExactly() {
        let doc = sampleDocument()
        let (r, ops) = seeded(doc)
        #expect(canonical(r.doc) == canonical(doc))
        var joiner = Replica(id: "join01")
        _ = joiner.receive(ops)
        #expect(canonical(joiner.doc) == canonical(doc))
        #expect(canonical(r.rebuilt()) == canonical(doc))
    }

    @Test func opsRoundTripThroughJSON() {
        let (_, ops) = seeded()
        let text = CanonicalJSON.compact(Op.encode(ops))
        let back = Op.decode(try! CanonicalJSON.parse(Data(text.utf8)))
        #expect(back == ops)
    }

    /// Every local edit, recorded, materialises to exactly the edited document, and a
    /// replica built from scratch agrees.
    @Test(arguments: Array(UInt64(1)...20)) func localEditsMaterialiseExactly(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var (r, _) = seeded()
        for step in 0..<150 {
            let before = r.doc
            randomEdit(&r, &rng)
            let rebuilt = r.rebuilt()
            if canonical(rebuilt) != canonical(r.doc) {
                Issue.record("seed \(seed) step \(step): the state doesn't materialise to the edit")
                _ = before
                return
            }
            for c in r.doc.canvases.values where !c.validate().isEmpty {
                Issue.record("seed \(seed) step \(step): \(c.validate())")
                return
            }
        }
    }
}
