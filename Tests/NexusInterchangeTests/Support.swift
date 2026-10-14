import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: testDir.appending(path: "Fixtures/\(name)"))
}

/// Compares `text` with `Goldens/<name>`; `REGENERATE_GOLDENS=1` rewrites it instead.
func golden(_ name: String, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let url = testDir.appending(path: "Goldens/\(name)")
    if ProcessInfo.processInfo.environment["REGENERATE_GOLDENS"] == "1" {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return
    }
    guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
        Issue.record("missing golden \(name); run with REGENERATE_GOLDENS=1", sourceLocation: sourceLocation)
        return
    }
    if expected != text {
        let a = expected.components(separatedBy: "\n")
        let b = text.components(separatedBy: "\n")
        let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        Issue.record(
            "golden \(name) differs at line \(i + 1):\n- \(i < a.count ? a[i] : "∅")\n+ \(i < b.count ? b[i] : "∅")",
            sourceLocation: sourceLocation)
    }
}

/// A canvas as stable text: canonical JSON plus the report.
func dump(_ imported: Imported) -> String {
    var s = imported.report.text + "\n"
    for c in imported.canvases { s += CanonicalJSON.string(c.json) }
    for name in imported.assets.keys.sorted() { s += "asset \(name) \(imported.assets[name]!.count) bytes\n" }
    return s
}

// MARK: Samples

func launchPlan() -> Canvas {
    var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let tree: [(String, [String])] = [
            ("Positioning", ["Developers", "Teams"]), ("Pricing", ["Free tier", "Pro", "Annual discount"]),
            ("Channels", ["Product Hunt", "Newsletter"]), ("Timeline", ["Beta · Nov", "GA · Jan"]),
            ("Risks", ["Competitor response"]),
        ]
        for (m, subs) in tree {
            let id = try! e.addChild(of: e.canvas.root, text: m)
            for s in subs { try! e.addChild(of: id, text: s) }
        }
        let pricing = e.canvas.nodes.first { $0.value.text == "Pricing" }!.key
        let pro = e.canvas.nodes.first { $0.value.text == "Pro" }!.key
        let risks = e.canvas.nodes.first { $0.value.text == "Risks" }!.key
        let channels = e.canvas.nodes.first { $0.value.text == "Channels" }!.key
        e.update(pricing) {
            $0.note = Note(text: "Keep the free tier generous.")
            $0.labels = ["Q4"]
        }
        e.update(pro) {
            $0.markers = ["priority-1"]
            $0.todo = Todo(done: false)
        }
        e.update(risks) { $0.link = "https://example.com/risks" }
        _ = e.connect(channels, to: risks, label: "feeds")
    }
    return c
}

func flowchart() -> Canvas {
    var c = Canvas(id: "c2", title: "Forgot password", type: .flowchart, rootText: "Forgot password")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let root = e.canvas.root
        e.update(root) { $0.nodeType = .start }
        let email = try! e.addChild(of: root, text: "Enter email")
        let exists = try! e.addChild(of: email, text: "Account exists?")
        e.update(exists) { $0.nodeType = .decision }
        let token = try! e.addChild(of: exists, text: "Create reset token")
        e.update(token) { $0.edgeLabel = "Yes" }
        let mail = try! e.addChild(of: token, text: "Email the link")
        e.update(mail) { $0.nodeType = .io }
        let neutral = try! e.addChild(of: exists, text: "Show neutral message")
        e.update(neutral) { $0.edgeLabel = "No" }
        let done = try! e.addChild(of: mail, text: "Done")
        e.update(done) { $0.nodeType = .end }
        _ = e.connect(neutral, to: done)
    }
    return c
}

func sequence() -> Canvas {
    var c = Canvas(id: "c3", title: "Checkout", type: .sequence, rootText: "Checkout")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let u = try! e.addChild(of: e.canvas.root, text: "Shopper")
        e.update(u) { $0.nodeType = "actor" }
        let api = try! e.addChild(of: e.canvas.root, text: "API")
        e.update(api) { $0.nodeType = .participant }
        let id = e.connect(u, to: api, label: "POST /cart")
        let back = e.connect(api, to: u, label: "201")
        e.updateRelationship(back) { $0.kind = "return" }
        _ = id
    }
    return c
}

func threatModel() -> Canvas {
    var c = Canvas(id: "c4", title: "Payments", type: .threatModel, rootText: "Payments")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let api = try! e.addChild(of: e.canvas.root, text: "Payments API")
        e.update(api) { $0.nodeType = .process }
        _ = try! e.addThreat(on: api, category: .spoofing, title: "Stolen API key", risk: "High")
        _ = try! e.addThreat(on: api, category: .tampering, title: "Replayed charge", risk: "Medium")
    }
    return c
}
