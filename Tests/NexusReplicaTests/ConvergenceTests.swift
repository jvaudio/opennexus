import Foundation
import NexusCore
import NexusFormat
import Testing

@testable import NexusReplica

/// A1, A2, A6, A8: replicas that get the same ops end with the same document, whatever
/// order the ops came in, however often, and however late.
@Suite struct ConvergenceTests {
    /// A session: the host's replica and joiners, and the ops each hasn't received yet.
    struct Session {
        var replicas: [Replica]
        /// (to, ops): undelivered batches.
        var pending: [(Int, [Op])] = []
        var log: [[Op]] = []

        init(_ n: Int, doc: DocumentModel = sampleDocument(), times: [FakeTime]? = nil) {
            let times = times ?? (0..<n).map { _ in FakeTime() }
            let (host, seed) = Replica.seed(doc, id: "host01", clock: HybridClock(replica: "host01", now: times[0].now))
            replicas = [host]
            for i in 1..<n {
                let id = "peer\(i)a"
                var r = Replica(id: id, clock: HybridClock(replica: id, now: times[i].now))
                _ = r.receive(seed)
                replicas.append(r)
            }
            log = [seed]
        }

        mutating func broadcast(from i: Int, _ ops: [Op]) {
            guard !ops.isEmpty else { return }
            log.append(ops)
            for j in replicas.indices where j != i { pending.append((j, ops)) }
        }

        /// Delivers one random batch; sometimes keeps it to deliver again (a duplicate).
        mutating func deliverOne(_ rng: inout SplitMix64) {
            guard !pending.isEmpty else { return }
            let k = Int.random(in: 0..<pending.count, using: &rng)
            let (to, ops) = pending[k]
            // Out of order inside a batch too.
            _ = replicas[to].receive(ops.shuffled(using: &rng))
            if Int.random(in: 0..<5, using: &rng) != 0 { pending.remove(at: k) }
        }

        mutating func deliverAll(_ rng: inout SplitMix64) {
            while !pending.isEmpty { deliverOne(&rng) }
        }
    }

    /// A1: 3–5 replicas, every kind of edit plus undo and redo, random, duplicated and
    /// out-of-order delivery; every replica ends with the same canonical JSON and a valid
    /// tree, the same as a replica built from scratch.
    @Test(arguments: Array(UInt64(1)...200)) func replicasConverge(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let n = 3 + Int(seed % 3)
        let times = (0..<n).map { i in FakeTime(1_800_000_000_000 + Int64(i * 37)) }
        var s = Session(n, times: times)
        for _ in 0..<60 {
            let i = Int.random(in: 0..<n, using: &rng)
            for t in times { t.ms += Int64.random(in: 0..<3, using: &rng) }
            let roll = Int.random(in: 0..<10, using: &rng)
            let ops: [Op]
            if roll == 0, let step = s.replicas[i].undo() {
                ops = step.ops
            } else if roll == 1, let step = s.replicas[i].redo() {
                ops = step.ops
            } else {
                ops = randomEdit(&s.replicas[i], &rng)
            }
            s.broadcast(from: i, ops)
            for _ in 0..<Int.random(in: 0..<4, using: &rng) { s.deliverOne(&rng) }
        }
        s.deliverAll(&rng)
        let first = canonical(s.replicas[0].doc)
        for (i, r) in s.replicas.enumerated() {
            #expect(canonical(r.doc) == first, "seed \(seed): replica \(i) differs")
            for c in r.doc.canvases.values {
                #expect(c.validate().isEmpty, "seed \(seed): replica \(i) canvas \(c.id): \(c.validate())")
            }
        }
        #expect(canonical(s.replicas[1].rebuilt()) == first, "seed \(seed): a fresh build differs")
    }

    /// A2: "A under B" and "B under A" at the same time end in one acyclic tree.
    @Test func concurrentCyclesResolveTheSameEverywhere() throws {
        var s = Session(3)
        let c = s.replicas[0].doc.canvases["c1"]!
        let a = c.nodes.first { $0.value.text == "Pricing" }!.key
        let b = c.nodes.first { $0.value.text == "Channels" }!.key
        func move(_ i: Int, _ x: NodeID, under y: NodeID) throws -> [Op] {
            var e = CanvasEditor(s.replicas[i].doc.canvases["c1"]!)
            try e.move(x, toParent: y)
            return s.replicas[i].record(e.patch(actionName: "Move"))
        }
        let ab = try move(1, a, under: b)
        let ba = try move(2, b, under: a)
        _ = s.replicas[0].receive(ba + ab)
        _ = s.replicas[1].receive(ba)
        _ = s.replicas[2].receive(ab)
        let first = canonical(s.replicas[0].doc)
        for r in s.replicas {
            #expect(canonical(r.doc) == first)
            #expect(r.doc.canvases["c1"]!.validate().isEmpty)
        }
        // The later move lost: it would have made a cycle.
        let tree = s.replicas[0].doc.canvases["c1"]!
        let parents = tree.parentMap()
        #expect((parents[a] == b) != (parents[b] == a))
    }

    /// A6: a late joiner's document (a snapshot from one replica, then everything sent since
    /// and some from before) equals the live one byte for byte.
    @Test(arguments: Array(UInt64(1)...25)) func lateJoinerMatches(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var s = Session(3)
        for _ in 0..<40 {
            let i = Int.random(in: 0..<3, using: &rng)
            s.broadcast(from: i, randomEdit(&s.replicas[i], &rng))
            s.deliverOne(&rng)
        }
        // Replica 1's snapshot, taken while ops are still in flight.
        let snapshot = s.replicas[1].snapshot()
        let tail = s.log.count
        for _ in 0..<40 {
            let i = Int.random(in: 0..<3, using: &rng)
            s.broadcast(from: i, randomEdit(&s.replicas[i], &rng))
            s.deliverOne(&rng)
        }
        s.deliverAll(&rng)
        var late = Replica(id: "late01")
        _ = late.receive(snapshot)
        // The relay's tail since the snapshot, plus a few older batches resent.
        for ops in s.log[tail...] { _ = late.receive(ops) }
        for ops in s.log.prefix(tail).suffix(5) { _ = late.receive(ops) }
        // Ops the snapshot's replica hadn't seen yet came before the cut; the relay's
        // ordering covers them, so give the joiner the whole log once more, out of order.
        for ops in s.log.shuffled(using: &rng) { _ = late.receive(ops) }
        #expect(canonical(late.doc) == canonical(s.replicas[0].doc))
    }

    /// A8: a replica offline for a while (and saved and reloaded in between) catches up.
    @Test func offlineEditsConvergeAfterReconnecting() throws {
        var rng = SplitMix64(seed: 9)
        var s = Session(2)
        var offline: [Op] = []
        for _ in 0..<30 {
            s.broadcast(from: 0, randomEdit(&s.replicas[0], &rng))
            offline += randomEdit(&s.replicas[1], &rng)
        }
        // Replica 1 saved and reopened while offline.
        let saved = try s.replicas[1].encoded()
        var reopened = try Replica(decoding: saved)
        #expect(canonical(reopened.doc) == canonical(s.replicas[1].doc))
        offline += randomEdit(&reopened, &rng)
        s.replicas[1] = reopened
        // Back online: send what waited, receive what was missed.
        _ = s.replicas[0].receive(offline)
        for (to, ops) in s.pending where to == 1 { _ = s.replicas[1].receive(ops) }
        #expect(canonical(s.replicas[0].doc) == canonical(s.replicas[1].doc))
    }
}

/// A3: undo is selective in a session.
@Suite struct SelectiveUndoTests {
    func node(_ r: Replica, _ text: String) -> NodeID {
        r.doc.canvases["c1"]!.nodes.first { $0.value.text == text }!.key
    }

    func edit(_ r: inout Replica, _ body: (inout CanvasEditor) throws -> Void) rethrows -> [Op] {
        var e = CanvasEditor(r.doc.canvases["c1"]!)
        try body(&e)
        return r.record(e.patch(actionName: "Edit"))
    }

    @Test func undoNeverRevertsSomeoneElsesLaterChange() throws {
        var s = ConvergenceTests.Session(2)
        let pricing = node(s.replicas[0], "Pricing")
        let channels = node(s.replicas[0], "Channels")
        // Replica 0 renames two topics in one step; replica 1 then renames one of them again.
        let mine = edit(&s.replicas[0]) { e in
            e.setText(pricing, "Prices")
            e.setText(channels, "Go-to-market")
        }
        _ = s.replicas[1].receive(mine)
        let theirs = edit(&s.replicas[1]) { $0.setText(pricing, "Pricing model") }
        _ = s.replicas[0].receive(theirs)
        // Undo on replica 0 puts back only what still holds its value.
        let stepResult = s.replicas[0].undo()
        let step = try #require(stepResult)
        _ = s.replicas[1].receive(step.ops)
        for r in s.replicas {
            #expect(r.doc.canvases["c1"]!.nodes[pricing]?.text == "Pricing model")
            #expect(r.doc.canvases["c1"]!.nodes[channels]?.text == "Channels")
        }
        // Redo brings back only its own change, still without touching theirs.
        let redoResult = s.replicas[0].redo()
        let redo = try #require(redoResult)
        _ = s.replicas[1].receive(redo.ops)
        #expect(s.replicas[1].doc.canvases["c1"]!.nodes[channels]?.text == "Go-to-market")
        #expect(s.replicas[1].doc.canvases["c1"]!.nodes[pricing]?.text == "Pricing model")
        // A delete undone while someone added under it brings both back.
        let gone = try edit(&s.replicas[0]) { _ = try $0.delete([pricing]) }
        let addUnder = try edit(&s.replicas[1]) { _ = try $0.addChild(of: pricing, text: "Enterprise") }
        _ = s.replicas[1].receive(gone)
        _ = s.replicas[0].receive(addUnder)
        #expect(canonical(s.replicas[0].doc) == canonical(s.replicas[1].doc))
        #expect(s.replicas[0].doc.canvases["c1"]!.nodes[pricing] == nil)
        let backResult = s.replicas[0].undo()
        let back = try #require(backResult)
        _ = s.replicas[1].receive(back.ops)
        for r in s.replicas {
            let c = r.doc.canvases["c1"]!
            #expect(
                c.nodes[pricing] != nil && c.nodes[pricing]!.children.contains { c.nodes[$0]?.text == "Enterprise" })
            #expect(c.validate().isEmpty)
        }
    }

    /// The undo property test, inside a session: after any run of edits, undoing them all
    /// gives back the original document and redoing them all the final one, on both replicas.
    @Test(arguments: [1, 2, 3, 42, 1234, 99_999] as [UInt64]) func undoAllRestoresOriginal(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        var s = ConvergenceTests.Session(2)
        let original = canonical(s.replicas[0].doc, assets: false)
        for _ in 0..<200 {
            let ops = randomEdit(&s.replicas[0], &rng)
            _ = s.replicas[1].receive(ops)
        }
        let steps = s.replicas[0].undoStack.count
        let final = canonical(s.replicas[0].doc)
        for _ in 0..<steps {
            let stepResult = s.replicas[0].undo()
            let step = try #require(stepResult)
            _ = s.replicas[1].receive(step.ops)
        }
        #expect(!s.replicas[0].canUndo)
        #expect(canonical(s.replicas[0].doc, assets: false) == original)
        #expect(canonical(s.replicas[1].doc, assets: false) == original)
        for _ in 0..<steps {
            let stepResult = s.replicas[0].redo()
            let step = try #require(stepResult)
            _ = s.replicas[1].receive(step.ops)
        }
        #expect(canonical(s.replicas[0].doc) == final)
        #expect(canonical(s.replicas[1].doc) == final)
    }
}
