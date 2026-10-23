import Foundation
import PDFKit
import Testing

@testable import NexusAgent
@testable import NexusCore
@testable import NexusFormat

/// M27: `nexus export` and the MCP `export` tool take a branch, a zone, or every zone
/// (a file each, or a PDF page each), like the export sheet (D227).
@MainActor
@Suite(.serialized) struct ExportScopeTests {
    /// The launch plan with two zones on its first canvas: "Ideas" around "Parking lot" ›
    /// "Later idea" and "Q3/Q4: plan" around "Someday".
    func sandbox() throws -> Sandbox {
        let box = try Sandbox()
        var doc = try MapFiles.read(box.plan)
        let id = doc.canvasOrder[0]
        var c = doc.canvases[id]!
        var undo = UndoStack()
        try c.edit("Zones", undo: &undo) { e in
            let lot = e.addFloating(at: CanvasPoint(x: 2000, y: 1400), text: "Parking lot")
            _ = try e.addChild(of: lot, text: "Later idea")
            let someday = e.addFloating(at: CanvasPoint(x: 2600, y: 1400), text: "Someday")
            _ = e.addZone(
                title: "Ideas", origin: CanvasPoint(x: 1960, y: 1340), width: 320, height: 200, members: [lot])
            _ = e.addZone(
                title: "Q3/Q4: plan", origin: CanvasPoint(x: 2560, y: 1340), width: 280, height: 200,
                members: [someday])
        }
        doc.canvases[id] = c
        try MapFiles.write(doc, to: box.plan)
        return box
    }

    func run(_ args: [String], in dir: URL) -> (Int32, String, String, Data) {
        let out = CLITests.Capture()
        let io = NexusCLI.IO(
            out: { out.out.append($0) }, err: { out.err += $0 }, readLine: { nil }, stdoutIsTerminal: false)
        let status = NexusCLI.run(args, io: io, env: .init(cwd: dir, home: dir, variables: [:], team: nil))
        return (status, String(decoding: out.out, as: UTF8.self), out.err, out.out)
    }

    func pngSize(_ data: Data) -> (Int, Int)? {
        guard data.count > 24, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else { return nil }
        func be(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16), be(20))
    }

    // MARK: nexus export

    @Test func branchScope() throws {
        let box = try sandbox()
        defer { box.remove() }
        let (s1, md, _, _) = run(["export", box.plan.path, "--to", "md", "--branch", "Pricing"], in: box.root)
        #expect(s1 == 0 && md.contains("Pro") && md.contains("Free tier"))
        #expect(!md.contains("Channels") && !md.contains("Launch plan"), "\(md)")
        let (s2, txt, _, _) = run(
            ["export", box.plan.path, "--to", "txt", "--branch", "Launch plan > Pricing"], in: box.root)
        #expect(s2 == 0 && txt.hasPrefix("Pricing\n\tFree tier\n"))
        // A visual branch goes beside the map, named as the app names it.
        let (s3, path, err, _) = run(["export", box.plan.path, "--to", "png", "--branch", "Pricing"], in: box.root)
        #expect(s3 == 0, "\(err)")
        let file = box.maps.appending(path: "Launch plan – Pricing.png")
        #expect(path.trimmingCharacters(in: .newlines) == file.path)
        let branch = try #require(pngSize(try Data(contentsOf: file)))
        _ = run(["export", box.plan.path, "--to", "png"], in: box.root)
        let whole = try #require(pngSize(try Data(contentsOf: box.maps.appending(path: "Launch plan.png"))))
        #expect(branch.0 < whole.0, "the branch is a crop of the canvas")
        // Formats without a branch scope say which have one.
        let (s4, _, bad, _) = run(["export", box.plan.path, "--to", "mermaid", "--branch", "Pricing"], in: box.root)
        #expect(s4 == 64 && bad.contains("md, opml, txt, svg, png, jpeg, pdf"), "\(bad)")
        #expect(run(["export", box.plan.path, "--to", "md", "--branch", "Nope"], in: box.root).0 == 64)
    }

    @Test func zoneScope() throws {
        let box = try sandbox()
        defer { box.remove() }
        let (s1, svg, err, _) = run(["export", box.plan.path, "--to", "svg", "--zone", "Ideas"], in: box.root)
        #expect(s1 == 0, "\(err)")
        #expect(svg.contains("Parking lot") && svg.contains("Later idea") && !svg.contains("Someday"))
        #expect(!svg.contains("Pricing"), "only the zone and its topics")
        // By id too, and to a file named after the zone (made safe for a file name).
        let (s2, path, _, _) = run(["export", box.plan.path, "--to", "pdf", "--zone", "z2"], in: box.root)
        #expect(s2 == 0)
        #expect(
            path.trimmingCharacters(in: .newlines) == box.maps.appending(path: "Launch plan – Q3-Q4- plan.pdf").path)
        let (s3, _, bad, _) = run(["export", box.plan.path, "--to", "md", "--zone", "Ideas"], in: box.root)
        #expect(s3 == 64 && bad.contains("svg, png, jpeg, pdf"))
        #expect(run(["export", box.plan.path, "--to", "png", "--zone", "Nowhere"], in: box.root).0 == 64)
        let (s4, _, both, _) = run(
            ["export", box.plan.path, "--to", "png", "--zone", "Ideas", "--branch", "Pricing"], in: box.root)
        #expect(s4 == 64 && both.contains("only one"))
    }

    @Test func eachZoneAsItsOwnFile() throws {
        let box = try sandbox()
        defer { box.remove() }
        let (s1, out, err, _) = run(
            ["export", box.plan.path, "--to", "png", "--zones", "each", "--out", "zones"], in: box.root)
        #expect(s1 == 0, "\(err)")
        let folder = box.root.appending(path: "zones")
        let names = ["Ideas.png", "Q3-Q4- plan.png"]
        #expect(out.split(separator: "\n").map(String.init) == names.map { folder.appending(path: $0).path })
        for n in names { #expect(pngSize(try Data(contentsOf: folder.appending(path: n))) != nil) }
        // Without --out, a folder beside the map.
        let (s2, beside, _, _) = run(["export", box.plan.path, "--to", "svg", "--zones", "each"], in: box.root)
        #expect(s2 == 0)
        let dir = box.maps.appending(path: "Launch plan – Zones")
        #expect(beside.split(separator: "\n").first.map(String.init) == dir.appending(path: "Ideas.svg").path)
        let ideas = try String(contentsOf: dir.appending(path: "Ideas.svg"), encoding: .utf8)
        #expect(ideas.contains("Parking lot") && !ideas.contains("Someday"))
        // A page per zone: one PDF.
        let (s3, pdf, _, _) = run(["export", box.plan.path, "--to", "pdf", "--zones", "pages"], in: box.root)
        #expect(s3 == 0)
        let file = box.maps.appending(path: "Launch plan – Zones.pdf")
        #expect(pdf.trimmingCharacters(in: .newlines) == file.path)
        #expect(PDFDocument(url: file)?.pageCount == 2)
        // Refusals: pages needs pdf, stdout can't hold several files, a canvas needs zones.
        #expect(run(["export", box.plan.path, "--to", "png", "--zones", "pages"], in: box.root).0 == 64)
        #expect(run(["export", box.plan.path, "--to", "png", "--zones", "each", "--out", "-"], in: box.root).0 == 64)
        #expect(run(["export", box.plan.path, "--to", "png", "--zones", "all"], in: box.root).0 == 64)
        #expect(
            run(["export", box.plan.path, "--to", "png", "--zones", "each", "--canvas", "c2"], in: box.root).0 == 64)
    }

    @Test func noScopeIsUnchanged() throws {
        let box = try sandbox()
        defer { box.remove() }
        let doc = try MapFiles.read(box.plan)
        let (_, md, _, _) = run(["export", box.plan.path, "--to", "md"], in: box.root)
        #expect(Data(md.utf8) == CLIFormat.md.export(doc, canvas: doc.canvasOrder[0]))
        #expect(NexusCLI.usage.contains("--zones each|pages") && NexusCLI.usage.contains("--branch <topic>"))
        let (_, help, _, _) = run(["--help"], in: box.root)
        #expect(help.contains("--zone <id|title>"))
    }

    // MARK: MCP export

    @Test func mcpExportsBranchesAndZones() throws {
        let box = try sandbox()
        defer { box.remove() }
        let p = JSONValue.string(box.plan.path)
        let s = Session(
            .enabled(box.policy()),
            [
                Session.initialize,
                Session.call(2, "export", ["path": p, "format": "opml", "branch": "Pricing"]),
                Session.call(3, "export", ["path": p, "format": "svg", "zone": "zone:Ideas"]),
                Session.call(4, "export", ["path": p, "format": "png", "zone": "z1"]),
                Session.call(5, "export", ["path": p, "format": "jpeg", "zones": "each", "out": "zones"]),
                Session.call(6, "export", ["path": p, "format": "pdf", "zones": "pages", "out": "zones.pdf"]),
                Session.call(7, "export", ["path": p, "format": "png", "zones": "each"]),
                Session.call(8, "export", ["path": p, "format": "csv", "zone": "Ideas"]),
                Session.call(9, "export", ["path": p, "format": "png", "zones": "each", "out": "/tmp/escape"]),
                Session.request(10, "tools/list"),
            ])
        _ = s.run()
        #expect(s.text(2).contains("Free tier") && !s.text(2).contains("Channels"))
        #expect(s.text(3).contains("Parking lot") && !s.text(3).contains("Someday"))
        let image = s.response(4)?["result"]?["content"]?.arrayValue?.first
        #expect(image?["type"] == "image")
        let zones = box.maps.appending(path: "zones")
        #expect(s.text(5).hasPrefix("Wrote 2 files to \(zones.path)"), "\(s.text(5))")
        for n in ["Ideas.jpg", "Q3-Q4- plan.jpg"] {
            #expect(FileManager.default.fileExists(atPath: zones.appending(path: n).path), "\(n)")
        }
        #expect(PDFDocument(url: box.maps.appending(path: "zones.pdf"))?.pageCount == 2)
        #expect(s.isError(7) && s.text(7).contains("give “out”"))
        #expect(s.isError(8) && s.text(8).contains("svg, png, jpeg, pdf"))
        #expect(s.isError(9) && s.text(9).contains("outside the allowed folders"))
        let export = s.response(10)?["result"]?["tools"]?.arrayValue?.first { $0["name"] == "export" }
        let props = export?["inputSchema"]?["properties"]
        #expect(props?["branch"] != nil && props?["zone"] != nil && props?["zones"]?["enum"] == ["each", "pages"])
    }
}
