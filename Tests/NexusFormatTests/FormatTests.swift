import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat

/// Loads a fixture package directory as relative path → bytes.
func fixtureFiles(_ name: String) throws -> [String: Data] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "nexus", subdirectory: "Fixtures"))
    return try readTree(url)
}

func readTree(_ url: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    let fm = FileManager.default
    let base = url.standardizedFileURL.path
    let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [])!
    for case let f as URL in e {
        guard try f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let rel = String(f.standardizedFileURL.path.dropFirst(base.count + 1))
        out[rel] = try Data(contentsOf: f)
    }
    return out
}

func launchPlanDocument() -> DocumentModel {
    var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let tree: [(String, [String])] = [
            ("Positioning", ["Developers", "Teams"]),
            ("Pricing", ["Free tier", "Pro", "Annual discount"]),
            ("Channels", ["Product Hunt", "Newsletter"]),
            ("Timeline", ["Beta · Nov", "GA · Jan"]),
            ("Risks", ["Competitor response"]),
        ]
        var mains: [NodeID] = []
        for (main, subs) in tree {
            let m = try! e.addChild(of: e.canvas.root, text: main)
            mains.append(m)
            for s in subs { try! e.addChild(of: m, text: s) }
        }
        e.connect(mains[2], to: mains[3], label: "drives")
        e.update(mains[0]) {
            $0.markers = ["priority-1"]
            $0.labels = ["Q4"]
            $0.todo = Todo(done: false)
            $0.note = Note(text: "Who is this for?\n\n- Developers\n- Teams")
            $0.link = "https://example.com/brief"
        }
        e.update(mains[4]) { $0.folded = true }
        e.addFloating(at: CanvasPoint(x: -420, y: 180.5), text: "Launch event")
    }
    var flow = Canvas(id: "c2", title: "Rollout flow", type: .flowchart, rootText: "Start")
    flow.edit("Sample", undo: &undo) { e in
        let a = try! e.addChild(of: e.canvas.root, text: "Build")
        try! e.addChild(of: a, text: "Ship?")
    }
    return DocumentModel(canvases: [c, flow], theme: ["name": "classic"])
}

@Suite struct FormatTests {
    /// Set REGENERATE_FIXTURES=1 to rewrite the golden fixture after an intended format change.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGENERATE_FIXTURES"] == "1"))
    func regenerateFixture() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LaunchPlan.nexus")
        try? FileManager.default.removeItem(at: dir)
        try NexusPackage.write(launchPlanDocument(), to: dir)
    }

    @Test func goldenRoundTripIsByteIdentical() throws {
        let files = try fixtureFiles("LaunchPlan")
        let doc = try NexusPackage.read(files: files)
        let out = NexusPackage.files(for: doc)
        #expect(out.keys.sorted() == files.keys.sorted())
        for (path, data) in files {
            #expect(out[path] == data, "\(path) changed on round trip")
        }
    }

    @Test func generatedDocumentMatchesGolden() throws {
        let files = try fixtureFiles("LaunchPlan")
        let out = NexusPackage.files(for: launchPlanDocument())
        for (path, data) in files {
            #expect(out[path] == data, "\(path) differs from the golden fixture")
        }
    }

    @Test func writeIsDeterministic() {
        let a = NexusPackage.files(for: launchPlanDocument())
        let b = NexusPackage.files(for: launchPlanDocument())
        #expect(a == b)
    }

    @Test func unknownKeysRoundTrip() throws {
        let files = try fixtureFiles("FutureKeys")
        let doc = try NexusPackage.read(files: files)
        #expect(doc.manifestExtra["generator"] == "OpenNexus 2.0")
        let c = try #require(doc.canvases["c1"])
        #expect(c.extra["futureElements"] != nil)
        #expect(c.nodes["n2"]?.extra["sparkles"] == 3)
        #expect(c.nodes["n2"]?.todo?.extra["dueDate"] == "2027-01-01")
        let out = NexusPackage.files(for: doc)
        for (path, data) in files {
            #expect(out[path] == data, "\(path) lost or reordered unknown keys")
        }
    }

    @Test func goldenValidatesAgainstSchema() throws {
        let issues = SchemaValidator.bundled.validate(package: try fixtureFiles("LaunchPlan"))
        #expect(issues.isEmpty, "\(issues)")
        let future = SchemaValidator.bundled.validate(package: try fixtureFiles("FutureKeys"))
        #expect(future.isEmpty, "\(future)")
    }

    @Test func schemaRejectsBrokenFiles() throws {
        let v = SchemaValidator.bundled
        #expect(
            !v.validate(["format": "opennexus", "schemaVersion": 1, "canvases": []], definition: "manifest").isEmpty)
        #expect(
            !v.validate(["format": "other", "schemaVersion": 1, "canvases": ["c1"]], definition: "manifest").isEmpty)
        #expect(
            !v.validate(
                ["id": "c1", "type": "mindmap", "root": "n1", "nodes": ["n1": ["text": 3]]],
                definition: "canvas"
            ).isEmpty)
        #expect(!v.validate(["id": "c1", "type": "mindmap", "nodes": [:]], definition: "canvas").isEmpty)
        #expect(
            !v.validate(
                ["id": "bad id!", "type": "mindmap", "root": "n1", "nodes": [:]],
                definition: "canvas"
            ).isEmpty)
        #expect(
            v.validate(["format": "opennexus", "schemaVersion": 1, "canvases": ["c1"]], definition: "manifest")
                .isEmpty)
    }

    @Test func publishedSchemaMatchesBundledCopy() throws {
        let published = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/nexus.schema.json")
        let bundled = try #require(SchemaValidator.bundledSchemaURL)
        #expect(try Data(contentsOf: published) == Data(contentsOf: bundled))
    }

    @Test func schemaFileIsCanonical() throws {
        let bundled = try #require(SchemaValidator.bundledSchemaURL)
        let data = try Data(contentsOf: bundled)
        #expect(CanonicalJSON.data(try CanonicalJSON.parse(data)) == data)
    }

    @Test func canonicalWriterFormatting() {
        let v: JSONValue = ["b": [1, 2.5, "x\n\"y\""], "a": [:], "c": [], "é": true, "n": nil]
        #expect(
            CanonicalJSON.string(v) == """
                {
                  "a": {},
                  "b": [
                    1,
                    2.5,
                    "x\\n\\"y\\""
                  ],
                  "c": [],
                  "n": null,
                  "é": true
                }

                """)
    }

    @Test func positionsRoundToHalfPoint() throws {
        var c = Canvas(id: "c1", title: "t")
        var u = UndoStack()
        let f = c.edit("f", undo: &u) { $0.addFloating(at: CanvasPoint(x: 10.26, y: -3.74)) }
        let json = CanonicalJSON.string(c.json)
        #expect(json.contains("\"x\": 10.5"))
        #expect(json.contains("\"y\": -3.5"))
        #expect(c.nodes[f]!.position!.x == 10.5)
    }

    @Test func rejectsWrongFormatAndNewerSchema() throws {
        var files = try fixtureFiles("LaunchPlan")
        files["manifest.json"] = CanonicalJSON.data(["format": "xmind", "schemaVersion": 1, "canvases": ["c1"]])
        #expect(throws: NexusPackage.ReadError.notOpenNexus("xmind")) { try NexusPackage.read(files: files) }
        files["manifest.json"] = CanonicalJSON.data(["format": "opennexus", "schemaVersion": 99, "canvases": ["c1"]])
        #expect(throws: NexusPackage.ReadError.newerSchema(99)) { try NexusPackage.read(files: files) }
        files["manifest.json"] = nil
        #expect(throws: NexusPackage.ReadError.missingFile("manifest.json")) { try NexusPackage.read(files: files) }
    }

    @Test func diskRoundTripThroughFileWrapper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).nexus")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = launchPlanDocument()
        try NexusPackage.write(doc, to: dir)
        let back = try NexusPackage.read(from: dir)
        #expect(back == doc)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".gitignore").path))
    }

    @Test func garbageInputThrowsInsteadOfCrashing() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 0..<200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let files = ["manifest.json": Data(bytes), "canvases/c1.json": Data(bytes)]
            _ = try? NexusPackage.read(files: files)
        }
    }
}
