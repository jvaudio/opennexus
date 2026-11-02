import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusScene

/// M49: the maps in the Obsidian plugin's test vault (`web/obsidian/test-vault/Maps/`),
/// which is committed so the iOS check can use it (D452). Written as the app saves them:
/// a `.nexusjson` with its viewer copy and links into the vault, one without a copy, a
/// package with one, and a crafted map. Rewrite them after a change to the viewer bundle:
///
///     NEXUS_WRITE_OBSIDIAN_VAULT=1 swift test --filter ObsidianVault
///
/// The package's own `.gitignore` leaves `render/` out, so a new file there needs `git add -f`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NEXUS_WRITE_OBSIDIAN_VAULT"] == "1"))
struct ObsidianVault {
    nonisolated static let dir = ViewerFixtures.dir.deletingLastPathComponent().appending(
        path: "obsidian/test-vault/Maps")

    static var prefs: Preferences {
        let p = Preferences.isolated()
        p.set("files.viewerCopy", true)
        p.set("files.viewerCopyJSON", true)
        return p
    }

    /// The launch plan with a second canvas, a note with wikilinks, and links to a note and the web.
    static func launchPlan() -> DocumentModel {
        var c = launchPlanDocument().canvases["c1"]!
        let node = { (text: String) in ViewerBundleTests.node(c, text) }
        c.nodes[c.root]?.note = Note(
            text: "Background is in [[Risks]]; costs are in [[Budget|the budget]], not written yet.")
        c.nodes[node("Pricing")]?.note = Note(text: "Ask about the discount.")
        c.nodes[node("Channels")]?.link = "obsidian://open?file=Notes%2FRisks"
        c.nodes[node("Positioning")]?.link = "https://example.com/positioning"
        var roadmap = Canvas(id: "c2", title: "Roadmap", rootText: "Roadmap")
        let root = roadmap.root
        var undo = UndoStack()
        roadmap.edit("Roadmap", undo: &undo) { e in
            for (quarter, items) in [("Q1", ["Beta", "Pricing page"]), ("Q2", ["GA", "Teams"])] {
                guard let q = try? e.addChild(of: root, text: quarter) else { continue }
                for item in items { _ = try? e.addChild(of: q, text: item) }
            }
        }
        return DocumentModel(canvases: [c, roadmap])
    }

    /// M43's crafted bundle with tricks aimed at the plugin: hostile wikilinks in a note, a
    /// link into another vault and a topic link out of this one.
    static func crafted() throws -> JSONValue {
        var bundle = try #require(ViewerFixtures.malicious().objectValue)
        var canvas = try #require(bundle["canvases"]?.arrayValue?.first?.objectValue)
        var topics = try #require(canvas["topics"]?.objectValue)
        var t1 = try #require(topics["t1"]?.objectValue)
        t1["note"] = .string(
            "<script>window.__pwned=9</script> [[<img src=x onerror=\"window.__pwned=16\">]] "
                + "[[Risks|<b onmouseover=\"window.__pwned=17\">Risks</b>]]")
        topics["t1"] = .object(t1)
        let links = [
            "t2": "obsidian://open?vault=Elsewhere&file=Secrets",
            "t3": "obsidian://opennexus?file=..%2F..%2F..%2Fetc%2Fpasswd&topic=%3Cimg%20src%3Dx%3E",
        ]
        var layouts = try #require(canvas["layouts"]?.objectValue)
        var saved = try #require(layouts["saved"]?.objectValue)
        var frames = try #require(saved["topics"]?.objectValue)
        var outline = try #require(canvas["outline"]?.arrayValue)
        for (i, (id, href)) in links.sorted(by: { $0.key < $1.key }).enumerated() {
            topics[id] = .object([
                "text": .string(id), "label": .string(id),
                "link": .object(["href": .string(href), "kind": .string("other")]),
            ])
            frames[id] = .object([
                "frame": .array([10, 60 + 50 * Double(i), 100, 40].map { .number($0) }), "depth": .number(0),
            ])
            outline.append(.object(["id": .string(id)]))
        }
        saved["topics"] = .object(frames)
        layouts["saved"] = .object(saved)
        canvas["layouts"] = .object(layouts)
        canvas["topics"] = .object(topics)
        canvas["outline"] = .array(outline)
        bundle["canvases"] = .array([.object(canvas)])
        return .object(bundle)
    }

    static func write(_ text: String, _ name: String) throws {
        try Data(text.utf8).write(to: dir.appending(path: name))
    }

    @Test func writeVaultMaps() throws {
        try? FileManager.default.removeItem(at: Self.dir)
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)

        try Self.write(ViewerCopy.json(Self.launchPlan(), pretty: true, prefs: Self.prefs), "Launch plan.nexusjson")
        try Self.write(
            DocumentJSON.export(try ViewerBundleTests.fixture("TaskPlan"), pretty: true, assets: true),
            "Plain.nexusjson")

        let plan = ViewerBundleTests.richDocument()
        var files = NexusPackage.files(for: plan)
        ViewerCopy.add(to: &files, plan, prefs: Self.prefs)
        #expect(files[ViewerCopy.path] != nil)
        try NexusPackage.directoryWrapper(from: files).write(
            to: Self.dir.appending(path: "Plan.nexus"), options: [.atomic], originalContentsURL: nil)

        // The crafted bundle as a map's viewer copy; the map itself is harmless.
        var doc = try #require(
            CanonicalJSON.parse(Data(DocumentJSON.export(launchPlanDocument(), pretty: true, assets: true).utf8))
                .objectValue)
        doc[ViewerCopy.jsonKey] = try Self.crafted()
        try Self.write(CanonicalJSON.string(.object(doc)), "Crafted.nexusjson")
    }
}
