import Foundation
import NexusCore
import NexusFormat

@testable import NexusReplica

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

/// A fake wall clock that moves only when told (each replica its own, so clocks disagree).
final class FakeTime: @unchecked Sendable {
    var ms: Int64
    init(_ ms: Int64 = 1_800_000_000_000) { self.ms = ms }
    var now: @Sendable () -> Int64 { { self.ms } }
}

/// A launch plan with a second canvas, a relationship, a boundary, a summary, a callout, a
/// floating topic in a zone, a comment and a task: something of every kind.
func sampleDocument() -> DocumentModel {
    var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        var ids: [String: NodeID] = [:]
        for (m, subs) in [
            ("Positioning", ["Developers", "Teams"]), ("Pricing", ["Free tier", "Pro", "Annual"]),
            ("Channels", ["Product Hunt", "Newsletter"]), ("Timeline", ["Beta", "GA"]),
        ] {
            let id = try! e.addChild(of: e.canvas.root, text: m)
            ids[m] = id
            for s in subs { ids[s] = try! e.addChild(of: id, text: s) }
        }
        e.connect(ids["Pricing"]!, to: ids["Channels"]!, label: "drives")
        _ = try! e.addBoundary(around: [ids["Timeline"]!], title: "Dates")
        _ = try! e.addSummary(over: [ids["Free tier"]!, ids["Pro"]!])
        _ = try! e.addCallout(on: ids["GA"]!)
        let f = e.makeNodeID()
        e.insert(Node(text: "Parking lot", kind: .floating), as: f)
        e.update(f) { $0.position = CanvasPoint(x: 600, y: -200) }
        e.updateMeta { $0.floating.append(f) }
        e.addZone(title: "Later", origin: CanvasPoint(x: 560, y: -260), members: [f])
        e.update(ids["Pro"]!) {
            $0.comments = [TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "Price?")]
            $0.todo = Todo(done: false)
        }
        e.update(ids["GA"]!) { $0.todo = Todo(done: false) }
        e.update(ids["Beta"]!) { $0.note = Note(text: "Invite list") }
    }
    let r = Canvas(id: "c2", title: "Risks", rootText: "Risks")
    var doc = DocumentModel(canvases: [c, r])
    doc.theme = .object(["customThemes": .object(["t1": .object(["name": .string("Mine")])])])
    doc.assets = ["a1.png": Data([1, 2, 3])]
    return doc
}

/// The shared part of a document as canonical bytes, for "byte-identical" checks.
/// `assets: false` for undo checks: undo keeps assets an edit added, as the app does.
func canonical(_ doc: DocumentModel, assets: Bool = true) -> String {
    var out = "order: \(doc.canvasOrder.map(\.rawValue))\n"
    for id in doc.canvasOrder {
        if let c = doc.canvases[id] { out += CanonicalJSON.string(c.json) }
    }
    out += "extra canvases: \(Set(doc.canvases.keys).subtracting(doc.canvasOrder).map(\.rawValue).sorted())\n"
    out += CanonicalJSON.string(doc.theme)
    if assets { out += "assets: \(doc.assets.keys.sorted())\n" }
    return out
}

/// One random local edit on the replica's document, recorded. Returns its ops (empty when
/// the edit was refused or changed nothing).
@discardableResult
func randomEdit(_ r: inout Replica, _ rng: inout SplitMix64) -> [Op] {
    let doc = r.doc
    let kind = Int.random(in: 0..<100, using: &rng)
    // Document-level edits now and then.
    if kind < 8 {
        var after = doc
        switch kind {
        case 0, 1:
            let id = after.makeCanvasID()
            var c = Canvas(id: id, title: "Canvas \(id)", rootText: "Root \(id)")
            c.idSuffix = after.idSuffix
            var undo = UndoStack()
            _ = try? c.edit("Add", undo: &undo) { try $0.addChild(of: $0.canvas.root, text: "First") }
            after.canvases[id] = c
            after.canvasOrder.insert(id, at: Int.random(in: 0...after.canvasOrder.count, using: &rng))
        case 2:
            guard after.canvasOrder.count > 1, let id = after.canvasOrder.randomElement(using: &rng) else { return [] }
            after.canvases[id] = nil
            after.canvasOrder.removeAll { $0 == id }
        case 3, 4:
            after.canvasOrder.shuffle(using: &rng)
        case 5:
            after.theme = .object(
                (after.theme.objectValue ?? [:]).merging([
                    "k\(Int.random(in: 0..<4, using: &rng))": .number(Double(kind))
                ]) {
                    $1
                })
        case 6:
            var t = after.theme.objectValue ?? [:]
            if let k = t.keys.sorted().randomElement(using: &rng) { t[k] = nil }
            after.theme = .object(t)
        default:
            let name = "a\(Int.random(in: 0..<1000, using: &rng)).png"
            return r.record(
                Patch(canvasID: doc.canvasOrder.first ?? "c1"),
                assets: doc.assets.merging([name: Data(name.utf8)]) { a, _ in a })
        }
        let p = doc.canvasSetPatch(to: after, focus: after.canvasOrder.first ?? "c1", actionName: "Doc")
        guard !p.isEmpty else { return [] }
        return r.record(p, assets: doc.assets)
    }
    guard let cid = doc.canvasOrder.randomElement(using: &rng), let canvas = doc.canvases[cid] else { return [] }
    var e = CanvasEditor(canvas)
    let ids = canvas.nodes.keys.sorted()
    let target = ids.randomElement(using: &rng)!
    let other = ids.randomElement(using: &rng)!
    let op = kind % 40
    do {
        switch op {
        case 0, 1, 2: _ = try e.addChild(of: target, text: "c\(Int.random(in: 0..<100, using: &rng))")
        case 3: _ = try e.addSibling(of: target)
        case 4: _ = try e.addSibling(of: target, before: true)
        case 5: _ = try e.addParent(of: target)
        case 6: _ = try e.delete([target])
        case 7: _ = try e.deleteKeepingChildren(target)
        case 8: try e.reorder(target, by: Bool.random(using: &rng) ? 1 : -1)
        case 9: try e.promote(target)
        case 10: try e.demote(target)
        case 11: _ = try e.duplicate(target)
        case 12: try e.toggleFold(target)
        case 13, 14, 15: e.setText(target, "t\(Int.random(in: 0..<100, using: &rng))")
        case 16: if other != target { e.connect(target, to: other) }
        case 17: _ = try e.addBoundary(around: [target])
        case 18:
            if let p = e.canvas.parent(of: target), let kids = e.canvas.nodes[p]?.children, kids.count > 1 {
                _ = try e.addSummary(over: Array(kids.prefix(2)))
            }
        case 19: _ = try e.addCallout(on: target)
        case 20: e.addZone(origin: CanvasPoint(x: Double(op) * 10, y: -300))
        case 21: try e.move(target, toParent: other)
        case 22: try e.detach(target, at: CanvasPoint(x: 400, y: 300))
        case 23: if let z = e.canvas.zones.first { e.moveZone(z.id, by: 25, -10) }
        case 24: if let b = e.canvas.boundaries.first { e.removeElement(.boundary(b.id)) }
        case 25: _ = try e.duplicate(target, toParent: other)
        case 26: if let s = e.canvas.summaries.first { e.removeElement(.summary(s.id)) }
        case 27: if let k = e.canvas.callouts.first { e.removeElement(.callout(k.id)) }
        case 28: if let r = e.canvas.relationships.first { e.removeElement(.relationship(r.id)) }
        case 29:
            e.update(target) {
                $0.comments.append(
                    TopicComment(
                        author: "R", date: "2026-10-2\(Int.random(in: 0..<9, using: &rng))T10:00:00Z", text: "ok"))
            }
        case 30: e.update(target) { if !$0.comments.isEmpty { $0.comments.removeFirst() } }
        case 31: e.update(target) { $0.note = Note(text: "note \(Int.random(in: 0..<9, using: &rng))") }
        case 32: e.update(target) { $0.markers = ["priority-\(Int.random(in: 1..<4, using: &rng))"] }
        case 33: e.update(target) { $0.todo = Bool.random(using: &rng) ? Todo(done: true) : nil }
        case 34:
            if other != target, e.canvas.nodes[other]?.todo != nil, e.canvas.nodes[target]?.todo != nil {
                e.update(target) { $0.todo?.after = [TaskDependency(task: other)] }
            }
        case 35: e.updateMeta { $0.title = "Title \(Int.random(in: 0..<9, using: &rng))" }
        case 36: e.updateMeta { $0.style.theme = ["classic", "ocean", "sunset"].randomElement(using: &rng)! }
        case 37:
            e.updateMeta {
                $0.layout.structure = [.mindmapBalanced, .logicRight, .orgDown].randomElement(using: &rng)!
            }
        case 38: e.update(target) { $0.labels = Bool.random(using: &rng) ? ["l1"] : [] }
        default: e.update(target) { $0.folded.toggle() }
        }
    } catch {
        return []
    }
    guard e.canvas.validate().isEmpty else { return [] }
    let p = e.patch(actionName: "op\(op)")
    guard !p.isEmpty else { return [] }
    return r.record(p, assets: doc.assets)
}
