import Foundation
import Testing

@testable import NexusAgent
@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

/// M49: `nexus bundle`, the viewer bundle Obsidian draws (A3), and `import --viewer-copy`.
extension CLITests {
    /// A note with everything the reader skips or moves: front matter, a fence, a comment
    /// appendix in the middle, floating topics and a table.
    static let note = """
        ---
        tags: [plan]
        ---
        # Trip

        Intro, a note on the root.

        ## Packing
        - Passport
          - Visa copy
        - [ ] Charger

        ## Comments
        - **Passport** · Ana · 2026-10-20T14:03:00Z: Check the expiry

        ## Trains
        ```
        not a topic
        ```
        | a | b |
        - Night train

        <!-- Floating topics -->
        - Loose idea
        """

    func json(_ s: String) throws -> JSONValue { try CanonicalJSON.parse(Data(s.utf8)) }

    /// The bundle without the first canvas's `lines`, and those lines.
    func split(_ b: JSONValue) -> (JSONValue, [String: Int]) {
        guard case .object(var o) = b, case .array(var cs)? = o["canvases"], case .object(var c)? = cs.first
        else { return (b, [:]) }
        var lines: [String: Int] = [:]
        if case .object(let l)? = c["lines"] {
            for (k, v) in l { if case .number(let n) = v { lines[k] = Int(n) } }
        }
        c["lines"] = nil
        cs[0] = .object(c)
        o["canvases"] = .array(cs)
        return (.object(o), lines)
    }

    @Test func bundleOfAMapIsItsViewerCopy() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (status, out, err, _) = run(["bundle", "Maps/Launch plan.nexus"], in: box.root)
        #expect(status == 0, "\(err)")
        let doc = try MapFiles.read(box.plan)
        #expect(try json(out) == ViewerCopy.bundle(doc))
        #expect(SchemaValidator.viewer.validate(try json(out)).isEmpty)
        #expect(run(["bundle", "Maps/Launch plan.nexus", "--structure", "org.down"], in: box.root).0 == 64)
        #expect(run(["bundle", "Maps/Nope.nexus"], in: box.root).0 == 1)
        #expect(run(["bundle"], in: box.root).0 == 64)
    }

    /// A3: the note as a map is the map `nexus import` makes of it, and every topic knows
    /// its line.
    @Test func markdownEqualsImportWithLines() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.note.write(to: box.root.appending(path: "Trip.md"), atomically: true, encoding: .utf8)
        #expect(run(["import", "Trip.md"], in: box.root).0 == 0)
        let saved = try MapFiles.read(box.root.appending(path: "Trip.nexus"))
        let imported = try #require(ViewerCopy.bundle(saved))
        // Import keeps no lines.
        #expect(!saved.orderedCanvases[0].nodes.values.contains { $0.extra[MarkdownFormat.sourceLineKey] != nil })

        let source = Self.note.components(separatedBy: "\n")
        for args in [["bundle", "-", "--title", "Trip"], ["bundle", "Trip.md"]] {
            let (status, out, err, _) = run(args, in: box.root, stdin: source)
            #expect(status == 0, "\(err)")
            let (bundle, lines) = split(try json(out))
            #expect(bundle == imported, "\(args)")
            #expect(SchemaValidator.viewer.validate(try json(out)).isEmpty)
            // Every heading and bullet, each on its own line of the note.
            let topics = try #require(bundle["canvases"]?.arrayValue?.first?["topics"]?.objectValue)
            #expect(lines.count == 8 && topics.count == 8, "\(lines)")
            for (id, line) in lines {
                let text = try #require(topics[id]?["text"]?.stringValue)
                #expect(source[line - 1].contains(text), "\(text) on line \(line)")
            }
        }
    }

    @Test func markdownStructures() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let source = Self.note.components(separatedBy: "\n")
        let (_, plain, _, _) = run(["bundle", "-", "--title", "Trip"], in: box.root, stdin: source)
        let (status, org, _, _) = run(
            ["bundle", "-", "--title", "Trip", "--structure", "org.down"], in: box.root, stdin: source)
        #expect(status == 0)
        let svg = { (s: String) in
            try self.json(s)["canvases"]?.arrayValue?.first?["layouts"]?["saved"]?["svg"]?.stringValue
        }
        #expect(try svg(plain) != svg(org))
        // As the app lays out an imported note after choosing the structure.
        var doc = try MapFiles.read(box.plan)
        let r = Interchange.parsePasted(Self.note, title: "Trip")
        var report = ImportReport(source: "x", format: "Markdown")
        var c = CanvasBuilder.build([try #require(r?.0)], report: &report)[0]
        c.layout.structure = .orgDown
        doc = DocumentModel(canvases: [c])
        #expect(try split(json(org)).0 == ViewerCopy.bundle(doc))
        let (bad, _, err, _) = run(["bundle", "-", "--structure", "spiral"], in: box.root, stdin: source)
        #expect(bad == 64 && err.contains("mindmap.balanced"))
    }

    @Test func importWritesTheViewerCopyWhenAsked() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try Self.note.write(to: box.root.appending(path: "Trip.md"), atomically: true, encoding: .utf8)
        #expect(run(["import", "Trip.md", "--out", "Plain.nexusjson"], in: box.root).0 == 0)
        #expect(run(["import", "Trip.md", "--out", "Copy.nexusjson", "--viewer-copy"], in: box.root).0 == 0)
        let plain = try json(String(contentsOf: box.root.appending(path: "Plain.nexusjson"), encoding: .utf8))
        let copy = try json(String(contentsOf: box.root.appending(path: "Copy.nexusjson"), encoding: .utf8))
        #expect(plain["render"] == nil)
        let doc = try MapFiles.read(box.root.appending(path: "Copy.nexusjson"))
        #expect(copy["render"] == ViewerCopy.bundle(doc))
        // A package gets render/viewer.json either way (the setting's default).
        #expect(run(["import", "Trip.md", "--out", "Trip.nexus", "--viewer-copy"], in: box.root).0 == 0)
        #expect(FileManager.default.fileExists(atPath: box.root.appending(path: "Trip.nexus/render/viewer.json").path))
    }
}
