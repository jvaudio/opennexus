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

/// A small plan with every M11 task field, a dependency of each kind and a custom
/// work calendar (the TaskPlan golden).
func taskPlanDocument() -> DocumentModel {
    var c = Canvas(id: "c1", title: "Release plan", rootText: "Release 2.0")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let phase = try! e.addChild(of: e.canvas.root, text: "Build")
        let design = try! e.addChild(of: phase, text: "Design")
        let code = try! e.addChild(of: phase, text: "Code")
        let docs = try! e.addChild(of: phase, text: "Docs")
        let launch = try! e.addChild(of: e.canvas.root, text: "Launch")
        e.updateTask(design) {
            $0.start = TaskDate("2026-11-02")
            $0.due = TaskDate("2026-11-06")
            $0.owner = "Ana"
            $0.done = true
        }
        e.updateTask(code) {
            $0.start = TaskDate("2026-11-09")
            $0.due = TaskDate("2026-11-20")
            $0.owner = "Sam, Lee"
            $0.progress = 40
        }
        e.updateTask(docs) { $0.start = TaskDate("2026-11-10") }
        e.updateTask(launch) { $0.due = TaskDate("2026-11-24") }
        e.update(code) { $0.priority = 1 }
        try! e.addDependency(code, on: design)
        try! e.addDependency(docs, on: code, type: .startToStart, lag: 1)
        try! e.addDependency(launch, on: code, type: .finishToStart, lag: 1)
        try! e.addDependency(launch, on: docs, type: .finishToFinish)
        e.updateMeta {
            $0.schedule.holidays = [TaskDate("2026-11-26")!]
            $0.schedule.workdays = [1, 2, 3, 4, 5]
        }
    }
    return DocumentModel(canvases: [c], theme: ["name": "classic"])
}

/// A reviewed map (M14): comments on two topics, one with an unknown key and one
/// without a date (the Review golden).
func reviewDocument() -> DocumentModel {
    var c = Canvas(id: "c1", title: "Pricing review", rootText: "Pricing")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let annual = try! e.addChild(of: e.canvas.root, text: "Annual tier")
        let pro = try! e.addChild(of: e.canvas.root, text: "Pro")
        e.update(annual) {
            $0.markers = ["priority-1", "flag-red"]
            $0.comments = [
                TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "Drop it?"),
                TopicComment(author: "Sam", date: "2026-10-20T16:30:05+02:00", text: "Keep it,\nbut discount it."),
            ]
        }
        e.update(pro) {
            var c = TopicComment(author: "Lee", date: "", text: "Check margins")
            c.extra["resolved"] = true
            $0.comments = [c]
            $0.labels = ["Q4"]
        }
        e.updateMeta {
            $0.legend = Legend(position: CanvasPoint(x: 320, y: -140.5), markers: ["flag-red": "Blocked"])
        }
    }
    return DocumentModel(canvases: [c], theme: ["name": "classic"])
}

@Suite struct FormatTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGENERATE_FIXTURES"] == "1"))
    func regenerateReviewFixture() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Review.nexus")
        try? FileManager.default.removeItem(at: dir)
        try NexusPackage.write(reviewDocument(), to: dir)
    }

    /// M14: comments and the legend round-trip byte-identically (dates as written, unknown
    /// keys kept) and match the schema.
    @Test func reviewGoldenRoundTrips() throws {
        let files = try fixtureFiles("Review")
        let doc = try NexusPackage.read(files: files)
        let out = NexusPackage.files(for: doc)
        #expect(out.keys.sorted() == files.keys.sorted())
        for (path, data) in files { #expect(out[path] == data, "\(path) changed on round trip") }
        for (path, data) in NexusPackage.files(for: reviewDocument()) where files[path] != nil {
            #expect(files[path] == data, "\(path) differs from the golden fixture")
        }
        let issues = SchemaValidator.bundled.validate(package: files)
        #expect(issues.isEmpty, "\(issues)")
        let c = try #require(doc.canvases["c1"])
        let annual = try #require(c.nodes.values.first { $0.text == "Annual tier" })
        #expect(annual.comments[1].date == "2026-10-20T16:30:05+02:00")
        #expect(annual.comments[1].instant == Date(timeIntervalSince1970: 1_792_506_605))
        let pro = try #require(c.nodes.values.first { $0.text == "Pro" })
        #expect(pro.comments[0].extra["resolved"] == true)
        let json = String(decoding: try #require(files["canvases/c1.json"]), as: UTF8.self)
        #expect(!json.contains("\"date\": \"\""), "an unknown date is omitted")
        #expect(c.legend == Legend(position: CanvasPoint(x: 320, y: -140.5), markers: ["flag-red": "Blocked"]))
        #expect(c.legendContents.markers == ["priority-1", "flag-red"] && c.legendContents.labels == ["Q4"])
        #expect(try NexusPackage.read(files: try fixtureFiles("LaunchPlan")).canvases["c1"]?.legend == nil)
    }

    @Test func schemaRejectsBadLegends() {
        let v = SchemaValidator.bundled
        func canvas(_ legend: JSONValue) -> JSONValue {
            [
                "id": "c1", "type": "mindmap", "root": "n1",
                "nodes": ["n1": ["text": "a", "kind": "root", "children": []]],
                "legend": legend,
            ]
        }
        #expect(
            v.validate(canvas(["visible": true, "markers": ["flag-red": "Blocked"]]), definition: "canvas").isEmpty)
        #expect(!v.validate(canvas(["visible": "yes"]), definition: "canvas").isEmpty)
        #expect(!v.validate(canvas(["markers": ["flag-red": 3]]), definition: "canvas").isEmpty)
        #expect(throws: (any Error).self) {
            try Legend(json: ["markers": ["flag-red": 3]], path: "legend")
        }
    }

    @Test func schemaRejectsBadComments() {
        let v = SchemaValidator.bundled
        func node(_ comment: JSONValue) -> JSONValue {
            ["text": "a", "kind": "topic", "children": [], "comments": [comment]]
        }
        #expect(
            v.validate(node(["author": "Ana", "text": "ok", "date": "2026-10-20T14:03:00Z"]), definition: "node")
                .isEmpty)
        #expect(!v.validate(node(["author": "Ana", "text": "ok", "date": "20/10/2026"]), definition: "node").isEmpty)
        #expect(!v.validate(node(["author": "Ana"]), definition: "node").isEmpty)
        #expect(
            TopicComment(author: "", at: Date(timeIntervalSince1970: 1_792_504_980.7), text: "").date
                == "2026-10-20T14:03:00Z")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGENERATE_FIXTURES"] == "1"))
    func regenerateTaskPlanFixture() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TaskPlan.nexus")
        try? FileManager.default.removeItem(at: dir)
        try NexusPackage.write(taskPlanDocument(), to: dir)
    }

    /// M11: task fields round-trip byte-identically and match the schema.
    @Test func taskPlanGoldenRoundTrips() throws {
        let files = try fixtureFiles("TaskPlan")
        let doc = try NexusPackage.read(files: files)
        let out = NexusPackage.files(for: doc)
        #expect(out.keys.sorted() == files.keys.sorted())
        for (path, data) in files { #expect(out[path] == data, "\(path) changed on round trip") }
        for (path, data) in NexusPackage.files(for: taskPlanDocument()) where files[path] != nil {
            #expect(files[path] == data, "\(path) differs from the golden fixture")
        }
        let issues = SchemaValidator.bundled.validate(package: files)
        #expect(issues.isEmpty, "\(issues)")
        let c = try #require(doc.canvases["c1"])
        #expect(c.schedule.holidays == [TaskDate("2026-11-26")!])
        #expect(TaskSchedule(c).violations.isEmpty)
    }

    @Test func schemaRejectsBadTaskFields() {
        let v = SchemaValidator.bundled
        let node: JSONValue = ["text": "a", "kind": "topic", "children": [], "todo": ["done": false, "start": "2/11"]]
        #expect(!v.validate(node, definition: "node").isEmpty)
        let dep: JSONValue = [
            "text": "a", "kind": "topic", "children": [],
            "todo": ["done": false, "after": [["task": "n1", "type": "XY"]]],
        ]
        #expect(!v.validate(dep, definition: "node").isEmpty)
    }

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

    /// What Swift writes for Present and saved filters is in the published schema (M39 A6),
    /// and typed: a wrong value is an issue, not an unknown key passed through.
    @Test func schemaDeclaresPresentationFiltersAndHiddenTopics() throws {
        var c = Canvas(id: "c1", title: "Deck", rootText: "Plan")
        c.presentation.order = ["title", "branch:n2"]
        c.presentation.skipped = ["branch:n3"]
        c.presentation.transition = "zoom"
        c.presentation.legend = false
        c.filters = [NodeFilter(name: "Risky", clauses: [try #require(NodeFilter.parse("risk: high"))], hide: true)]
        c.nodes[c.root]?.presentHidden = true
        let files = NexusPackage.files(for: DocumentModel(canvases: [c]))
        let canvas = try CanonicalJSON.parse(try #require(files["canvases/c1.json"]))
        #expect(canvas["presentation"] != nil && canvas["filters"] != nil, "the canvas writes both")
        #expect(SchemaValidator.bundled.validate(package: files).isEmpty)
        let v = SchemaValidator.bundled
        #expect(!v.validate(["legend": "yes"], definition: "presentation").isEmpty)
        #expect(!v.validate(["clauses": "risk: high"], definition: "filter").isEmpty)
        #expect(!v.validate(["text": "x", "children": [], "presentHidden": 1], definition: "node").isEmpty)
        // M41: a canvas's skipped guide steps.
        #expect(v.validate(["id": "dfd", "skipped": ["stores"]], definition: "guide").isEmpty)
        #expect(!v.validate(["id": "dfd", "skipped": "stores"], definition: "guide").isEmpty)
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

@Suite struct ChatFormatTests {
    /// AI chats live in `ai/chats.json`, only when there are any (artboard 52's chat list).
    @Test func chatsRoundTrip() throws {
        var doc = launchPlanDocument()
        #expect(NexusPackage.files(for: doc)["ai/chats.json"] == nil)
        var chat = AIChat(id: "chat1", title: "Pricing review")
        chat.canvas = "c1"
        chat.discussion = true
        chat.messages = [
            AIMessage(role: "user", text: "Where is @Risks thin?"),
            AIMessage(
                role: "assistant", text: "Risks has one child.",
                plan: ChangePlan(summary: "s", ops: [.rename(NodeID("n1"), from: "Risks", to: "Risks & churn")])),
        ]
        doc.chats = [chat]
        let files = NexusPackage.files(for: doc)
        let json = try #require(files["ai/chats.json"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(json.contains("\"chats\""))
        let back = try NexusPackage.read(files: files)
        #expect(back.chats == [chat])
        #expect(NexusPackage.files(for: back) == files, "byte-identical")
        #expect(SchemaValidator.bundled.validate(package: files).isEmpty)
        let bad: JSONValue = ["chats": [["id": "c", "messages": [["role": "robot", "text": "x"]]]]]
        #expect(!SchemaValidator.bundled.validate(bad, definition: "chats").isEmpty)
    }
}
