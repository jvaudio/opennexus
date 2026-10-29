import Foundation
import Testing

@testable import NexusAgent
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusScene

/// M45 (A8): the user's own `git` merges maps topic by topic with `nexus merge-driver`, and
/// diffs them as outlines with `nexus git textconv`, once `nexus git setup` has run. Real
/// Git in a temporary repository, running the `nexus` this package builds.
@MainActor
@Suite(.serialized) struct GitDriverTests {
    static let nexus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".build/debug/nexus").path

    @MainActor struct Repo {
        let dir: URL
        var plan: URL { dir.appending(path: "Launch.nexus", directoryHint: .isDirectory) }

        init() throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "git-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try git("init", "-q", "-b", "main")
            try git("config", "user.name", "Test")
            try git("config", "user.email", "test@example.com")
            try git("config", "commit.gpgsign", "false")
        }

        @discardableResult func git(_ args: String...) throws -> (status: Int32, output: String) {
            try NexusCLI.runGit(args, in: dir)
        }

        func commit(_ message: String) throws {
            try git("add", "-A")
            let r = try git("commit", "-q", "-m", message)
            #expect(r.status == 0, "\(r.output)")
        }

        func read() throws -> DocumentModel { try NexusPackage.read(from: plan) }

        func edit(_ body: (inout CanvasEditor) throws -> Void) throws {
            var doc = try read()
            var e = CanvasEditor(doc.canvases["c1"]!)
            try body(&e)
            doc.canvases["c1"] = e.canvas
            try NexusPackage.write(doc, to: plan)
        }

        func run(_ args: [String]) -> (status: Int32, out: String, err: String) {
            let out = CLITests.Capture()
            let io = NexusCLI.IO(
                out: { out.out.append($0) }, err: { out.err += $0 }, readLine: { nil }, stdoutIsTerminal: false)
            let status = NexusCLI.run(
                args, io: io,
                env: .init(cwd: dir, home: dir, variables: [:], team: nil, executable: GitDriverTests.nexus))
            return (status, String(decoding: out.out, as: UTF8.self), out.err)
        }
    }

    /// The launch plan sample: five main topics with subtopics.
    func launchPlanDocument() -> DocumentModel {
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
        }
        return DocumentModel(canvases: [c])
    }

    func node(_ e: CanvasEditor, _ text: String) -> NodeID { e.canvas.nodes.first { $0.value.text == text }!.key }

    func texts(_ doc: DocumentModel) -> Set<String> { Set(doc.canvases["c1"]!.nodes.values.map(\.text)) }

    /// main and feature each rename a topic and add one; returns the repository on main.
    func branches(sameTopic: Bool = false) throws -> Repo {
        let repo = try Repo()
        try NexusPackage.write(launchPlanDocument(), to: repo.plan)
        try repo.commit("Launch plan")
        try repo.git("checkout", "-q", "-b", "feature")
        try repo.edit { e in
            e.setText(node(e, sameTopic ? "Pricing" : "Channels"), sameTopic ? "Pricing (feature)" : "Go-to-market")
            _ = try e.addChild(of: node(e, "Timeline"), text: "Q3")
        }
        try repo.commit("Feature")
        try repo.git("checkout", "-q", "main")
        try repo.edit { e in
            e.setText(node(e, "Pricing"), sameTopic ? "Pricing (main)" : "Pricing model")
            _ = try e.addChild(of: node(e, "Risks"), text: "Churn")
        }
        try repo.commit("Main")
        return repo
    }

    @Test func differentTopicsMergeCleanlyWhereGitAloneConflicts() throws {
        #expect(FileManager.default.isExecutableFile(atPath: Self.nexus), "swift build makes \(Self.nexus)")
        let repo = try branches()
        // Plain Git: both branches added a topic, so the canvas file conflicts.
        #expect(try repo.git("merge", "--no-edit", "feature").status != 0)
        try repo.git("merge", "--abort")

        #expect(repo.run(["git", "setup"]).status == 0)
        try repo.commit("Set up OpenNexus merges")
        let r = try repo.git("merge", "--no-edit", "feature")
        #expect(r.status == 0, "\(r.output)")
        let doc = try repo.read()
        #expect(texts(doc).isSuperset(of: ["Go-to-market", "Q3", "Pricing model", "Churn"]))
        #expect(!texts(doc).contains("Channels") && !texts(doc).contains("Pricing"))
        #expect(doc.canvases["c1"]!.validate().isEmpty)
        #expect(repo.run(["validate", "Launch.nexus"]).status == 0)
        // Written as the app writes it.
        let file = try Data(contentsOf: repo.plan.appending(path: "canvases/c1.json"))
        #expect(file == CanonicalJSON.data(doc.canvases["c1"]!.json))
    }

    @Test func theSameTopicExitsWithTheClash() throws {
        let repo = try branches(sameTopic: true)
        #expect(repo.run(["git", "setup"]).status == 0)
        try repo.commit("Set up OpenNexus merges")
        let r = try repo.git("merge", "--no-edit", "feature")
        #expect(r.status != 0)
        #expect(r.output.contains("canvases/c1.json: both branches changed “Pricing (main)”"), "\(r.output)")
        let unmerged = try repo.git("diff", "--name-only", "--diff-filter=U").output
        #expect(unmerged.contains("Launch.nexus/canvases/c1.json"))
        // This branch's side is in the file, with everything else merged.
        let doc = try repo.read()
        #expect(
            texts(doc).isSuperset(of: ["Pricing (main)", "Q3", "Churn"]) && !texts(doc).contains("Pricing (feature)"))
    }

    @Test func setupIsIdempotent() throws {
        let repo = try Repo()
        let first = repo.run(["git", "setup"])
        #expect(first.status == 0 && first.out.contains("Added 5 lines"))
        let attributes = try String(contentsOf: repo.dir.appending(path: ".gitattributes"), encoding: .utf8)
        let second = repo.run(["git", "setup"])
        #expect(second.status == 0 && second.out.contains("Already set up"))
        #expect(try String(contentsOf: repo.dir.appending(path: ".gitattributes"), encoding: .utf8) == attributes)
        let driver = try repo.git("config", "--get-all", "merge.nexus.driver").output
        #expect(driver == "\(Self.nexus) merge-driver %O %A %B %P\n")
        #expect(try repo.git("config", "--get-all", "diff.nexus.textconv").output == "\(Self.nexus) git textconv\n")
        // Lines already there are kept, not repeated.
        try Data("*.png binary\n**/*.nexus/theme.json merge=nexus".utf8).write(
            to: repo.dir.appending(path: ".gitattributes"))
        #expect(repo.run(["git", "setup"]).out.contains("Added 4 lines"))
        let lines = try String(contentsOf: repo.dir.appending(path: ".gitattributes"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.first == "*.png binary" && lines.filter { $0.contains("theme.json") }.count == 1)
        // Outside a repository it says so.
        let outside = FileManager.default.temporaryDirectory.appending(path: "nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let out = CLITests.Capture()
        let status = NexusCLI.run(
            ["git", "setup"],
            io: .init(out: { out.out.append($0) }, err: { out.err += $0 }, readLine: { nil }, stdoutIsTerminal: false),
            env: .init(cwd: outside, home: outside, variables: [:], team: nil))
        #expect(status == 64 && out.err.contains("not in a Git repository"))
    }

    @Test func diffsReadAsOutlines() throws {
        let repo = try Repo()
        try NexusPackage.write(launchPlanDocument(), to: repo.plan)
        let canvas = try Data(contentsOf: repo.plan.appending(path: "canvases/c1.json"))
        let outline = NexusCLI.textconv(canvas)
        #expect(outline.hasPrefix("# Launch plan\nLaunch plan\nPositioning (under Launch plan)\n"))
        #expect(outline.contains("\nPro (under Pricing)\n"))
        #expect(repo.run(["git", "setup"]).status == 0)
        try repo.commit("Launch plan")
        try repo.edit { e in
            let q3 = try e.addChild(of: node(e, "Timeline"), text: "Q3")
            e.update(q3) { $0.note = Note(format: "plain", text: "Board review\nand more") }
        }
        let diff = try repo.git("diff", "--", "Launch.nexus/canvases/c1.json").output
        #expect(diff.contains("+Q3 (under Timeline) · note: Board review"), "\(diff)")
        // A single-file document reads the same way.
        let json = Data(DocumentJSON.export(launchPlanDocument()).utf8)
        #expect(NexusCLI.textconv(json).contains("Risks (under Launch plan)"))
    }

    @Test func manifestsAndSingleFilesMergeToo() throws {
        let base = launchPlanDocument()
        var mine = base
        mine.canvases["c2"] = Canvas(id: "c2", title: "Roadmap", rootText: "Roadmap")
        mine.canvasOrder.append("c2")
        var theirs = base
        theirs.canvases["c3"] = Canvas(id: "c3", title: "Team", rootText: "Team")
        theirs.canvasOrder.append("c3")
        theirs.manifestExtra["documentID"] = .string("doc-1")
        let files = { (d: DocumentModel) in NexusPackage.files(for: d)["manifest.json"]! }
        let m = try NexusCLI.mergeFile(
            "Launch.nexus/manifest.json", base: files(base), mine: files(mine), theirs: files(theirs))
        #expect(m.clashes.isEmpty)
        let manifest = try CanonicalJSON.parse(m.data).objectValue!
        #expect(manifest["canvases"] == JSONValue.array([.string("c1"), .string("c2"), .string("c3")]))
        #expect(manifest["documentID"] == JSONValue.string("doc-1"))

        // .nexusjson: one rename on each side.
        func json(_ edit: (inout CanvasEditor) -> Void) -> Data {
            var d = base
            var e = CanvasEditor(d.canvases["c1"]!)
            edit(&e)
            d.canvases["c1"] = e.canvas
            return Data(DocumentJSON.export(d).utf8)
        }
        let a = json { e in e.setText(node(e, "Pricing"), "Prices") }
        let b = json { e in e.setText(node(e, "Risks"), "Open risks") }
        let j = try NexusCLI.mergeFile(
            "Launch.nexusjson", base: Data(DocumentJSON.export(base).utf8), mine: a, theirs: b)
        #expect(j.clashes.isEmpty)
        let merged = try DocumentJSON.parse(j.data, name: "Launch.nexusjson")
        #expect(texts(merged).isSuperset(of: ["Prices", "Open risks"]))
        let clash = try NexusCLI.mergeFile(
            "Launch.nexusjson", base: Data(DocumentJSON.export(base).utf8), mine: a,
            theirs: json { e in e.setText(node(e, "Pricing"), "Cost") })
        #expect(clash.clashes == ["“Prices”"])
    }
}
