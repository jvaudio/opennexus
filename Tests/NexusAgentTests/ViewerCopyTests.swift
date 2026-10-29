import Foundation
import Testing

@testable import NexusAgent
@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusScene

/// M43: the viewer copy (A7, D314) and `nexus export --to html` (A8).
@MainActor
@Suite(.serialized) struct ViewerCopyTests {
    static func prefs(copy: Bool = true, json: Bool = false) -> Preferences {
        let p = Preferences.isolated()
        p.set("files.viewerCopy", copy)
        p.set("files.viewerCopyJSON", json)
        return p
    }

    /// The launch plan, with a note and a comment the copy carries.
    static func plan(_ box: Sandbox) throws -> DocumentModel {
        var doc = try MapFiles.read(box.plan)
        let id = doc.canvasOrder[0]
        let pricing = try #require(node(doc.canvases[id]!, "Pricing"))
        doc.canvases[id]?.nodes[pricing]?.note = Note(text: "Ask about the discount")
        doc.canvases[id]?.nodes[pricing]?.comments = [
            TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "Why?")
        ]
        return doc
    }

    static func node(_ c: Canvas, _ text: String) -> NodeID? { c.nodes.first { $0.value.text == text }?.key }

    /// The package's files as written to disk.
    static func written(_ doc: DocumentModel, prefs: Preferences, in box: Sandbox) throws -> [String: Data] {
        let url = box.maps.appending(path: "Copy \(UUID().uuidString).nexus")
        try MapFiles.write(doc, to: url, prefs: prefs)
        return NexusPackage.flatten(try FileWrapper(url: url, options: [.immediate]))
    }

    // MARK: A7

    /// Packages carry `render/viewer.json` by default: one line of schema-valid JSON, kept
    /// out of Git, ignored by reading, accepted by `nexus validate`.
    @Test func packagesCarryAValidCopy() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let doc = try Self.plan(box)
        #expect(Preferences.isolated().bool("files.viewerCopy"), "on by default")
        #expect(!Preferences.isolated().bool("files.viewerCopyJSON"), "off by default")
        let files = try Self.written(doc, prefs: Self.prefs(), in: box)
        let copy = try #require(files[ViewerCopy.path])
        let text = String(decoding: copy, as: UTF8.self)
        #expect(text.hasSuffix("}\n") && text.dropLast().allSatisfy { $0 != "\n" }, "one line")
        let bundle = try CanonicalJSON.parse(copy)
        #expect(SchemaValidator.viewer.validate(bundle).isEmpty)
        #expect(
            bundle.objectValue?["assets"]?.objectValue?.values.allSatisfy { $0.objectValue?["data"] == nil } ?? true,
            "assets are named, not copied")
        #expect(String(decoding: try #require(files[".gitignore"]), as: UTF8.self).contains("render/\n"))
        // Reading ignores it, and the rest of the package is what it would be without it.
        #expect(
            try NexusPackage.read(files: files) == NexusPackage.read(files: files.filter { $0.key != ViewerCopy.path }))
        let without = try Self.written(doc, prefs: Self.prefs(copy: false), in: box)
        #expect(without[ViewerCopy.path] == nil)
        #expect(files.filter { $0.key != ViewerCopy.path } == without)
        let url = box.maps.appending(path: "Valid.nexus")
        try MapFiles.write(doc, to: url, prefs: Self.prefs())
        let issues = try NexusCLI.validationIssues(url).issues
        #expect(issues.isEmpty, "\(issues)")
    }

    /// An encrypted document never gets one: it would be its contents in the clear.
    @Test func neverForEncryptedDocuments() throws {
        let box = try Sandbox()
        defer { box.remove() }
        var doc = try Self.plan(box)
        doc.encrypted = true
        #expect(ViewerCopy.bundle(doc) == nil)
        var files: [String: Data] = [:]
        ViewerCopy.add(to: &files, doc, prefs: Self.prefs(json: true))
        #expect(files.isEmpty)
        let json = ViewerCopy.json(doc, pretty: true, prefs: Self.prefs(json: true))
        #expect(json == DocumentJSON.export(doc, pretty: true, assets: true))
    }

    /// Single-file documents: a `render` key only when both switches are on, and every
    /// other byte as it was.
    @Test func singleFileDocumentsOnlyWhenAsked() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let doc = try Self.plan(box)
        for pretty in [true, false] {
            let plain = DocumentJSON.export(doc, pretty: pretty, assets: true)
            #expect(ViewerCopy.json(doc, pretty: pretty, prefs: Self.prefs()) == plain)
            #expect(ViewerCopy.json(doc, pretty: pretty, prefs: Self.prefs(copy: false, json: true)) == plain)
            let with = ViewerCopy.json(doc, pretty: pretty, prefs: Self.prefs(json: true))
            guard case .object(var o) = try CanonicalJSON.parse(Data(with.utf8)) else {
                Issue.record("not an object")
                return
            }
            let removed = o.removeValue(forKey: ViewerCopy.jsonKey)
            let render = try #require(removed)
            #expect(SchemaValidator.viewer.validate(render).isEmpty)
            let rest = pretty ? CanonicalJSON.string(.object(o)) : DocumentJSON.compact(.object(o)) + "\n"
            #expect(rest == plain, "everything but render keeps its bytes")
            #expect(
                try DocumentJSON.parse(Data(with.utf8), name: "Plan.nexusjson")
                    == DocumentJSON.parse(Data(plain.utf8), name: "Plan.nexusjson"))
        }
    }

    /// A damaged copy can't hurt: reading ignores it, `nexus validate` reports it.
    @Test func aDamagedCopyIsIgnoredByReading() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let doc = try MapFiles.read(box.plan)
        var files = NexusPackage.files(for: doc)
        let clean = try NexusPackage.read(files: files)
        var rng = SystemRandomNumberGenerator()
        for garbage in [
            Data("{".utf8), Data("{\"format\":\"opennexus-viewer\",\"version\":99}".utf8),
            Data((0..<512).map { _ in UInt8.random(in: 0...255, using: &rng) }),
        ] {
            files[ViewerCopy.path] = garbage
            #expect(try NexusPackage.read(files: files) == clean)
            let url = box.maps.appending(path: "Damaged.nexus")
            try? FileManager.default.removeItem(at: url)
            try NexusPackage.directoryWrapper(from: files).write(to: url, options: [], originalContentsURL: nil)
            let issues = try NexusCLI.validationIssues(url).issues
            #expect(issues.contains { $0.contains("render/viewer.json") }, "\(issues)")
        }
        // In a single file, too.
        guard
            case .object(var o) = try CanonicalJSON.parse(
                Data(DocumentJSON.export(doc, pretty: true, assets: true).utf8))
        else { return }
        o[ViewerCopy.jsonKey] = .string("<script>")
        let damaged = Data(CanonicalJSON.string(.object(o)).utf8)
        #expect(
            try DocumentJSON.parse(damaged, name: "Plan.nexusjson")
                == DocumentJSON.parse(Data(DocumentJSON.export(doc).utf8), name: "Plan.nexusjson"))
        let url = box.maps.appending(path: "Damaged.nexusjson")
        try damaged.write(to: url)
        #expect(try NexusCLI.validationIssues(url).issues.contains { $0.hasPrefix("render:") })
    }

    // MARK: A8

    /// `nexus export --to html` writes the bytes the export sheet writes, with the same
    /// options (isolated preferences on both sides).
    @Test func theCLIWritesWhatTheSheetWrites() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let doc = try MapFiles.read(box.plan)
        func sheet(_ edit: (inout ExportState) -> Void = { _ in }) throws -> Data {
            let controller = CanvasController(store: DocumentStore(model: doc), canvasID: doc.canvasOrder[0])
            controller.prefs = .isolated()
            controller.rendersThemeAsNamed = true
            controller.openExport(.html)
            var s = try #require(controller.exportState)
            edit(&s)
            return try #require(controller.exportData(s))
        }
        func cli(_ extra: [String]) throws -> Data {
            let out = box.root.appending(path: "out-\(UUID().uuidString).html")
            let (status, _, err, _) = CLITests().run(
                ["export", box.plan.path, "--to", "html", "--out", out.path] + extra, in: box.root)
            #expect(status == 0, "\(err)")
            return try Data(contentsOf: out)
        }
        #expect(try cli([]) == sheet())
        #expect(
            try cli(["--no-notes", "--no-comments", "--layouts", "saved"])
                == sheet {
                    $0.html.notes = false
                    $0.html.comments = false
                    $0.html.expanded = false
                })
        #expect(try cli(["--canvas", doc.canvasOrder[0].rawValue]) == sheet { $0.html.document = false })
        #expect(
            try cli(["--branch", "Pricing"])
                == sheet {
                    $0.image.scope = .branch
                    $0.image.selection = [Self.node(doc.canvases[doc.canvasOrder[0]]!, "Pricing")!]
                })
        // Without --out it goes beside the map, not to the terminal.
        let (status, printed, _, _) = CLITests().run(["export", box.plan.path, "--to", "html"], in: box.root)
        #expect(status == 0 && printed.hasSuffix("Launch plan.html\n"))
        #expect(try Data(contentsOf: box.maps.appending(path: "Launch plan.html")) == sheet())
        // The options are for html only.
        let (bad, _, err, _) = CLITests().run(["export", box.plan.path, "--to", "svg", "--no-notes"], in: box.root)
        #expect(bad != 0 && err.contains("--to html"))
    }

    /// The MCP `export` tool takes the same options, and wants a file to write.
    @Test func theExportToolTakesTheOptions() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let tools = MapTools(policy: box.policy())
        let out = box.maps.appending(path: "Shared.html")
        _ = try tools.call(
            "export",
            [
                "path": .string(box.plan.path), "format": .string("html"), "out": .string(out.path),
                "comments": .bool(false), "layouts": .string("saved"),
            ])
        let html = try String(contentsOf: out, encoding: .utf8)
        #expect(html.hasPrefix("<!doctype html>") && html.contains("id=\"opennexus-bundle\""))
        #expect(throws: MapTools.ToolError.self) {
            try tools.call("export", ["path": .string(box.plan.path), "format": .string("html")])
        }
        #expect(throws: MapTools.ToolError.self) {
            try tools.call(
                "export",
                ["path": .string(box.plan.path), "format": .string("html"), "out": .string(out.path), "layouts": "all"])
        }
    }
}
