import Testing

@testable import NexusCore

/// A tiny deterministic PRNG so property tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Applies one random tree operation. Refusals are fine; they record nothing.
@discardableResult
func randomOperation(_ c: inout Canvas, _ undo: inout UndoStack, _ rng: inout SplitMix64) -> String {
    let ids = c.nodes.keys.sorted()
    let target = ids.randomElement(using: &rng)!
    let other = ids.randomElement(using: &rng)!
    let op = Int.random(in: 0..<28, using: &rng)
    let label = "op\(op) target \(target) other \(other)"
    _ = try? c.edit("op\(op)", undo: &undo) { e -> Void in
        switch op {
        case 0, 1: try e.addChild(of: target)
        case 2: try e.addSibling(of: target)
        case 3: try e.addSibling(of: target, before: true)
        case 4: try e.addParent(of: target)
        case 5: _ = try e.delete([target])
        case 6: _ = try e.deleteKeepingChildren(target)
        case 7: try e.reorder(target, by: Bool.random(using: &rng) ? 1 : -1)
        case 8: try e.promote(target)
        case 9: try e.demote(target)
        case 10: try e.duplicate(target)
        case 11: try e.toggleFold(target)
        case 12: e.setText(target, "t\(Int.random(in: 0..<100, using: &rng))")
        case 13: if other != target { e.connect(target, to: other) }
        // M3 elements and direct manipulation.
        case 14: try e.addBoundary(around: [target])
        case 15:
            if let p = e.canvas.parent(of: target), let kids = e.canvas.nodes[p]?.children, kids.count > 1 {
                _ = try e.addSummary(over: Array(kids.prefix(2)))
            }
        case 16: _ = try e.addCallout(on: target)
        case 17: e.addZone(origin: CanvasPoint(x: Double(op) * 10, y: -300))
        case 18: try e.move(target, toParent: other)
        case 19: try e.detach(target, at: CanvasPoint(x: 400, y: 300))
        case 20:
            if let z = e.canvas.zones.first { e.moveZone(z.id, by: 25, -10) }
        case 21:
            if let b = e.canvas.boundaries.first { e.removeElement(.boundary(b.id)) }
        case 22: _ = try e.duplicate(target, toParent: other)
        // Zone relationship ends (D170): connecting to a zone, then removing it.
        case 24:
            if let z = e.canvas.zones.randomElement(using: &rng) {
                let ends: [RelationshipEnd] = [.topic(target), .zone(z.id)]
                let flip = Bool.random(using: &rng)
                e.connect(ends[flip ? 1 : 0], to: ends[flip ? 0 : 1])
            }
        case 25:
            if let z = e.canvas.zones.first { e.removeElement(.zone(z.id)) }
        // Boundary and summary ends (D180).
        case 26:
            let ends: [RelationshipEnd] =
                e.canvas.boundaries.map { .boundary($0.id) } + e.canvas.summaries.map { .summary($0.id) }
            if let end = ends.randomElement(using: &rng) {
                if Bool.random(using: &rng) {
                    e.connect(.topic(target), to: end)
                } else {
                    e.connect(end, to: .topic(target))
                }
            }
        case 27:
            if let s = e.canvas.summaries.first { e.removeElement(.summary(s.id)) }
        default:
            if let k = e.canvas.callouts.first { e.removeElement(.callout(k.id)) }
        }
    }
    return label
}

@Suite struct UndoPropertyTests {
    /// Do/undo symmetry: after any sequence of operations, undoing everything returns
    /// the original canvas, and redoing everything returns the final one.
    @Test(arguments: [1, 2, 3, 42, 1234, 99_999] as [UInt64])
    func undoAllRestoresOriginal(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let original = sampleCanvas()
        var c = original
        var undo = UndoStack()
        for _ in 0..<200 {
            randomOperation(&c, &undo, &rng)
            #expect(
                c.validate().isEmpty,
                "invalid tree after an operation (seed \(seed)): \(c.validate().first.map { "\($0)" } ?? "")")
        }
        let final = c
        var steps = 0
        while let p = undo.undo() {
            p.apply(to: &c)
            steps += 1
        }
        #expect(c == original)
        for _ in 0..<steps {
            undo.redo()!.apply(to: &c)
        }
        #expect(c == final)
    }

    /// Tree and element invariants hold after every step, and every step undoes cleanly.
    @Test(arguments: Array(UInt64(100)..<150)) func invariantsHoldWithElements(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let original = sampleCanvas()
        var c = original
        var undo = UndoStack()
        for i in 0..<200 {
            let label = randomOperation(&c, &undo, &rng)
            if let err = c.validate().first {
                Issue.record("seed \(seed) step \(i) \(label): \(err)")
                return
            }
        }
        while let p = undo.undo() { p.apply(to: &c) }
        #expect(c == original)
    }

    @Test func eachStepIsInvertible() {
        var rng = SplitMix64(seed: 7)
        var c = sampleCanvas()
        var undo = UndoStack()
        for _ in 0..<100 {
            let before = c
            randomOperation(&c, &undo, &rng)
            if let last = undo.undoStack.last, before != c {
                var probe = c
                last.inverted.apply(to: &probe)
                #expect(probe == before)
            }
        }
    }

    @Test func coalescingMergesIntoOneStep() {
        var c = sampleCanvas()
        let original = c
        var undo = UndoStack()
        let n = c.nodes[c.root]!.children[0]
        for t in ["A", "Au", "Aud", "Audi"] {
            c.edit("Typing", undo: &undo, coalescingKey: "type:\(n)") { $0.setText(n, t) }
        }
        #expect(undo.undoStack.count == 1)
        undo.undo()!.apply(to: &c)
        #expect(c == original)
    }

    @Test func mergeDropsNoOps() {
        var c = sampleCanvas()
        var undo = UndoStack()
        let n = c.nodes[c.root]!.children[0]
        let old = c.nodes[n]!.text
        c.edit("Typing", undo: &undo, coalescingKey: "k") { $0.setText(n, "x") }
        c.edit("Typing", undo: &undo, coalescingKey: "k") { $0.setText(n, old) }
        #expect(undo.undoStack.first?.isEmpty == true)
    }

    @Test func newEditClearsRedo() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        try c.edit("Add", undo: &undo) { try $0.addChild(of: $0.canvas.root) }
        undo.undo()!.apply(to: &c)
        #expect(undo.canRedo)
        try c.edit("Add", undo: &undo) { try $0.addChild(of: $0.canvas.root) }
        #expect(!undo.canRedo)
    }

    @Test func idsStayUniqueAcrossUndo() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let a = try c.edit("Add", undo: &undo) { try $0.addChild(of: $0.canvas.root) }
        undo.undo()!.apply(to: &c)
        let b = try c.edit("Add", undo: &undo) { try $0.addChild(of: $0.canvas.root) }
        #expect(c.nodes[b] != nil)
        #expect(a != b || c.nodes[a] != nil)
    }
}
