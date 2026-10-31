import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusScene

/// M47d: documents for the open page's browser tests (`web/e2e/open.spec.ts`), in
/// `web/fixtures/open/`: a package with and without its viewer copy, a `.nexusjson` with
/// and without `render`, a Finder zip of a package, an encrypted package and a file that
/// isn't a document. Build products (git-ignored), made by `npm run fixtures` in web/.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NEXUS_WRITE_VIEWER_FIXTURES"] == "1"))
struct OpenFixtures {
    nonisolated static let dir = ViewerFixtures.dir.appending(path: "open")

    /// The rich launch plan, its deck reordered with a slide skipped.
    static func deckDocument() -> DocumentModel {
        var doc = ViewerBundleTests.richDocument()
        var c = doc.canvases["c1"]!
        let ids = Deck.generated(c).map(\.id)
        c.presentation.order = [ids[0], ids[2], ids[1]]
        c.presentation.skipped = [ids[3]]
        doc.canvases["c1"] = c
        return doc
    }

    /// Every topic's text, root and floating topics first, depth first, as the outline shows them.
    static func outline(_ doc: DocumentModel) -> JSONValue {
        .array(
            doc.canvasOrder.compactMap { doc.canvases[$0] }.map { c in
                var out: [JSONValue] = []
                func walk(_ id: NodeID) {
                    guard let n = c.nodes[id] else { return }
                    out.append(.string(n.text))
                    n.children.forEach(walk)
                }
                ([c.root] + c.floating).forEach(walk)
                return .array(out)
            })
    }

    static func writePackage(_ files: [String: Data], _ name: String) throws {
        try NexusPackage.directoryWrapper(from: files).write(
            to: dir.appending(path: name), options: [.atomic], originalContentsURL: nil)
    }

    @Test func writeOpenFixtures() throws {
        try? FileManager.default.removeItem(at: Self.dir)
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let prefs = Preferences.isolated()
        prefs.set("files.viewerCopy", true)
        prefs.set("files.viewerCopyJSON", true)
        var cases: [JSONValue] = []
        func add(_ name: String, _ path: String, _ how: String, _ expect: String, _ extra: [String: JSONValue] = [:]) {
            var o = extra
            o["name"] = .string(name)
            o["path"] = .string(path)
            o["how"] = .string(how)
            o["expect"] = .string(expect)
            cases.append(.object(o))
        }

        // A package with its viewer copy: the map, its attachment and its deck in order.
        let doc = Self.deckDocument()
        let copy = try #require(ViewerCopy.data(doc))
        try copy.write(to: Self.dir.appending(path: "plan.bundle.json"))
        var files = NexusPackage.files(for: doc)
        ViewerCopy.add(to: &files, doc, prefs: prefs)
        #expect(files[ViewerCopy.path] == copy)
        try Self.writePackage(files, "Plan.nexus")
        let slides = JSONValue.array(
            Deck.slides(doc.canvases["c1"]!).filter { !$0.skipped }.map { .string($0.title) })
        let asset = JSONValue.object([
            "topic": .string("Risks"), "name": .string("Brief.pdf"), "bytes": .string("%PDF-1.4 brief"),
        ])
        let plan: [String: JSONValue] = ["bundle": .string("plan.bundle.json"), "slides": slides, "asset": asset]
        add("package", "Plan.nexus", "folder", "bundle", plan)

        // The same package zipped by Finder (Compress), which adds __MACOSX resource forks.
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", "Plan.nexus", "Plan.nexus.zip"]
        zip.currentDirectoryURL = Self.dir
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        add("zip", "Plan.nexus.zip", "file", "bundle", plan)

        // A single-file document with `render`, and its assets inline.
        try Data(ViewerCopy.json(doc, pretty: true, prefs: prefs).utf8).write(
            to: Self.dir.appending(path: "Plan.nexusjson"))
        add("json", "Plan.nexusjson", "file", "bundle", plan)

        // Without a viewer copy: the outline, and how to add one.
        let plain = try ViewerBundleTests.fixture("TaskPlan")
        try Self.writePackage(NexusPackage.files(for: plain), "Tasks.nexus")
        add(
            "package-outline", "Tasks.nexus", "folder", "outline",
            ["outline": Self.outline(plain), "advice": .string("Save a viewer copy")])
        try Data(DocumentJSON.export(plain, pretty: true, assets: true).utf8).write(
            to: Self.dir.appending(path: "Tasks.nexusjson"))
        add(
            "json-outline", "Tasks.nexusjson", "file", "outline",
            ["outline": Self.outline(plain), "advice": .string("Also in single-file documents")])

        // An encrypted package: its hint, and nothing else.
        let info = PackageCrypto.newInfo(hint: "The usual one")
        let sealed = try PackageCrypto.encrypt(
            NexusPackage.files(for: doc), with: PackageCrypto.derive(password: "correct horse", info: info))
        try Self.writePackage(sealed, "Locked.nexus")
        add("encrypted", "Locked.nexus", "folder", "encrypted", ["hint": .string("The usual one")])

        // Not a document.
        try Data("{\"hello\": \"world\"}\n".utf8).write(to: Self.dir.appending(path: "notes.json"))
        add("refused", "notes.json", "file", "refused")

        try CanonicalJSON.data(.object(["cases": .array(cases)])).write(to: Self.dir.appending(path: "manifest.json"))
    }
}
