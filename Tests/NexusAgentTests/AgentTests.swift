import Foundation
import Testing

@testable import NexusAgent
@testable import NexusCore
@testable import NexusFormat

/// A temporary folder holding a copy of the launch-plan fixture.
struct Sandbox {
    let root: URL
    let maps: URL
    var plan: URL { maps.appending(path: "Launch plan.nexus") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nexus-agent-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        maps = root.appending(path: "Maps")
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "NexusFormatTests/Fixtures/LaunchPlan.nexus")
        try FileManager.default.copyItem(at: fixture, to: plan)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func policy(
        read: AgentPolicy.Access = .allow, edit: AgentPolicy.Access = .allow, files: AgentPolicy.Access = .allow
    )
        -> AgentPolicy
    {
        AgentPolicy(enabled: true, folders: [maps.path], read: read, edit: edit, files: files)
    }
}

/// Drives the server with scripted client lines and collects what it writes.
@MainActor
final class Session {
    var lines: [String]
    var sent: [JSONValue] = []
    let server: MCPServer

    init(_ config: MCPServer.Config, _ lines: [String]) {
        self.lines = lines
        var box: Session!
        server = MCPServer(
            config: config,
            input: { box.lines.isEmpty ? nil : box.lines.removeFirst() },
            output: { box.sent.append(try! CanonicalJSON.parse(Data($0.utf8))) })
        box = self
    }

    static func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> String {
        MCPServer.encode(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    static func call(_ id: Int, _ tool: String, _ args: JSONValue) -> String {
        request(id, "tools/call", ["name": .string(tool), "arguments": args])
    }

    static let initialize = request(
        1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test"]])

    func run() -> [JSONValue] {
        server.run()
        return sent
    }

    func response(_ id: Int) -> JSONValue? { sent.first { $0["id"] == .number(Double(id)) } }

    func text(_ id: Int) -> String {
        response(id)?["result"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
    }

    func isError(_ id: Int) -> Bool { response(id)?["result"]?["isError"]?.boolValue ?? true }
}

@MainActor
@Suite(.serialized) struct MCPTests {
    @Test func handshakeListAndVersions() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let s = Session(
            .enabled(box.policy()),
            [
                Session.initialize,
                MCPServer.encode(["jsonrpc": "2.0", "method": "notifications/initialized"]),
                Session.request(2, "tools/list"), Session.request(3, "ping"), Session.request(4, "resources/subscribe"),
                "{not json", Session.request(5, "initialize", ["protocolVersion": "2099-01-01"]),
            ])
        let out = s.run()
        #expect(out.count == 6, "the notification gets no answer")
        #expect(s.response(1)?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(s.response(1)?["result"]?["serverInfo"]?["name"] == "opennexus")
        let tools = s.response(2)?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(
            tools == [
                "list_maps", "read_map", "add_topic", "add_edge", "set_task", "add_comment", "set_style",
                "convert_type",
                "export",
            ])
        for t in s.response(2)?["result"]?["tools"]?.arrayValue ?? [] {
            #expect(t["inputSchema"]?["type"] == "object" && t["description"]?.stringValue?.isEmpty == false)
        }
        #expect(s.response(3)?["result"] == [:])
        #expect(s.response(4)?["error"]?["code"] == -32601)
        #expect(out.contains { $0["error"]?["code"] == -32700 })
        #expect(s.response(5)?["result"]?["protocolVersion"] == "2025-06-18", "unknown versions get our newest")
    }

    /// D170: add_edge takes "zone:" ends, and read_map lists zones and zone ends.
    @Test func zoneEnds() throws {
        var c = Canvas(id: "c1", title: "Plan", rootText: "Plan")
        var undo = UndoStack()
        var (pricing, zone) = (NodeID("x"), "")
        try c.edit("Setup", undo: &undo) { e in
            pricing = try e.addChild(of: e.canvas.root, text: "Pricing")
            zone = e.addZone(title: "Later", origin: CanvasPoint(x: 400, y: 0))
            e.connect(.topic(pricing), to: .zone(zone))
        }
        #expect(try MapTools.end("zone:Later", in: c) == .zone(zone))
        #expect(try MapTools.end("ZONE:\(zone)", in: c) == .zone(zone))
        #expect(try MapTools.end("Pricing", in: c) == .topic(pricing))
        #expect(throws: MapTools.ToolError.self) { try MapTools.end("zone:Nowhere", in: c) }
        let outline = MapTools.outline(c)
        #expect(outline.contains("Zones:\n- Later [zone:\(zone)]"))
        #expect(outline.contains("- Pricing [\(pricing.rawValue)] → Later [zone:\(zone)]"))
    }

    /// D180: add_edge takes "boundary:" and "summary:" ends, and read_map lists both.
    @Test func boundaryAndSummaryEnds() throws {
        var c = Canvas(id: "c1", title: "Plan", rootText: "Plan")
        var undo = UndoStack()
        var (pricing, boundary, summary) = (NodeID("x"), "", "")
        try c.edit("Setup", undo: &undo) { e in
            pricing = try e.addChild(of: e.canvas.root, text: "Pricing")
            let q = try e.addChild(of: e.canvas.root, text: "Quality")
            boundary = try e.addBoundary(around: [q], title: "Core")
            _ = try e.addSummary(over: [pricing, q], text: "Both")
            summary = e.canvas.summaries[0].id
            e.connect(.summary(summary), to: .boundary(boundary), label: "covers")
        }
        #expect(try MapTools.end("boundary:Core", in: c) == .boundary(boundary))
        #expect(try MapTools.end("Boundary:\(boundary)", in: c) == .boundary(boundary))
        #expect(try MapTools.end("summary:both", in: c) == .summary(summary))
        #expect(throws: MapTools.ToolError.self) { try MapTools.end("summary:Nothing", in: c) }
        let outline = MapTools.outline(c)
        #expect(outline.contains("Boundaries:\n- Core [boundary:\(boundary)] around Quality ["))
        #expect(
            outline.contains("Summaries:\n- Both [summary:\(summary)] over Pricing [\(pricing.rawValue)] to Quality ["))
        #expect(outline.contains("- Both [summary:\(summary)] → Core [boundary:\(boundary)] “covers”"))
    }

    @Test func disabledServerSaysWhere() {
        let s = Session(.disabled(NexusCLI.offMessage), [Session.initialize, Session.request(2, "tools/list")])
        _ = s.run()
        #expect(s.response(1)?["error"]?["message"]?.stringValue?.contains("Settings › Integrations") == true)
        #expect(s.response(2)?["error"] != nil)
    }

    @Test func readAndEditTools() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let p = JSONValue.string(box.plan.path)
        let s = Session(
            .enabled(box.policy()),
            [
                Session.initialize,
                Session.call(2, "list_maps", [:]),
                Session.call(3, "read_map", ["path": "Launch plan.nexus"]),
                Session.call(
                    4, "add_topic",
                    [
                        "path": p, "parent": "Launch plan > Risks", "text": "Churn", "children": ["Week-4 retention"],
                        "note": "From the agent", "labels": ["agent"],
                    ]),
                Session.call(5, "add_edge", ["path": p, "from": "Churn", "to": "Pricing", "label": "informs"]),
                Session.call(
                    6, "set_style",
                    ["path": p, "theme": "graphite", "node_style": "capsule", "structure": "logic.right"]),
                Session.call(7, "set_style", ["path": p, "topic": "Pricing", "shape": "hexagon", "color": "#D6408B"]),
                Session.call(8, "convert_type", ["path": p, "type": "flowchart"]),
                Session.call(9, "read_map", ["path": p, "format": "json", "canvas": "c1"]),
            ])
        _ = s.run()
        #expect(s.text(2).contains("Launch plan.nexus") && s.text(2).contains("20 topics"))
        #expect(s.text(3).contains("- Pricing [") && s.text(3).contains("Relationships:"))
        #expect(s.text(4).hasPrefix("Added “Churn”") && !s.isError(4))
        #expect(s.text(5).hasPrefix("Connected “Churn” → “Pricing”"))
        #expect(!s.isError(6) && !s.isError(7) && !s.isError(8), "\(s.text(6)) \(s.text(7)) \(s.text(8))")
        let doc = try MapFiles.read(box.plan)
        let c = doc.canvases["c1"]!
        let churn = try MapTools.topic("Churn", in: c)
        let pricing = try MapTools.topic("Pricing", in: c)
        #expect(
            c.nodes[churn]!.ai && c.nodes[churn]!.note?.text == "From the agent" && c.nodes[churn]!.labels == ["agent"])
        #expect(
            c.nodes[c.nodes[churn]!.children[0]]!.text == "Week-4 retention" && c.nodes[c.nodes[churn]!.children[0]]!.ai
        )
        #expect(
            c.relationships.contains { $0.from == .topic(churn) && $0.to == .topic(pricing) && $0.label == "informs" })
        #expect(c.style.theme == "graphite" && c.style.nodeStyle == "capsule")
        #expect(
            c.nodes[pricing]!.style?.shape == "hexagon" && c.nodes[pricing]!.style?.fillColor == "#D6408B"
                && c.nodes[pricing]!.ai)
        #expect(c.type == .flowchart)
        #expect(c.validate().isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: box.plan.appending(path: "preview.png").path),
            "agents refresh Quick Look's preview")
        #expect(s.text(9).contains("\"format\""))
        // The file is still a valid map.
        #expect(try NexusCLI.validationIssues(box.plan).issues.isEmpty)
    }

    @Test func exportsTextImagesAndFiles() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let p = JSONValue.string(box.plan.path)
        let s = Session(
            .enabled(box.policy()),
            [
                Session.initialize,
                Session.call(2, "export", ["path": p, "format": "mermaid"]),
                Session.call(3, "export", ["path": p, "format": "png"]),
                Session.call(4, "export", ["path": p, "format": "pdf", "out": "plan.pdf"]),
                Session.call(5, "export", ["path": p, "format": "pdf"]),
                Session.call(6, "export", ["path": p, "format": "md", "out": "/tmp/escape.md"]),
            ])
        _ = s.run()
        #expect(s.text(2).hasPrefix("mindmap"))
        let image = s.response(3)?["result"]?["content"]?.arrayValue?.first
        #expect(image?["type"] == "image" && image?["mimeType"] == "image/png")
        #expect(Data(base64Encoded: image?["data"]?.stringValue ?? "")?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(
            s.text(4).hasPrefix("Wrote")
                && FileManager.default.fileExists(atPath: box.maps.appending(path: "plan.pdf").path))
        #expect(s.isError(5) && s.text(5).contains("give “out”"))
        #expect(s.isError(6) && s.text(6).contains("outside the allowed folders"))
    }

    @Test func permissionsBlockAskAndElicit() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let p = JSONValue.string(box.plan.path)
        let add = { (id: Int) in
            Session.call(id, "add_topic", ["path": p, "parent": "Risks", "text": .string("Agent idea \(id)")])
        }
        // Block.
        let blocked = Session(.enabled(box.policy(edit: .block)), [Session.initialize, add(2)])
        _ = blocked.run()
        #expect(blocked.isError(2) && blocked.text(2).contains("blocked"))
        // Ask, with a client that can't ask.
        let mute = Session(.enabled(box.policy(edit: .ask)), [Session.initialize, add(2)])
        _ = mute.run()
        #expect(mute.isError(2) && mute.text(2).contains("can't ask"))
        // Ask, with elicitation: approve, then decline. A ping while waiting is answered.
        let ask = Session.request(
            1, "initialize",
            [
                "protocolVersion": "2025-06-18", "capabilities": ["elicitation": JSONValue.object([:])],
                "clientInfo": ["name": "test"],
            ])
        func answer(_ n: Int, approve: Bool) -> String {
            MCPServer.encode([
                "jsonrpc": "2.0", "id": .string("opennexus-ask-\(n)"),
                "result": ["action": "accept", "content": ["approve": .bool(approve)]],
            ])
        }
        let s = Session(
            .enabled(box.policy(edit: .ask)),
            [ask, add(2), Session.request(9, "ping"), answer(1, approve: true), add(3), answer(2, approve: false)])
        _ = s.run()
        #expect(s.sent.filter { $0["method"] == "elicitation/create" }.count == 2)
        #expect(!s.isError(2) && s.response(9)?["result"] == [:])
        #expect(s.isError(3) && s.text(3).contains("declined"))
        let c = try MapFiles.read(box.plan).canvases["c1"]!
        #expect(
            c.nodes.values.contains { $0.text == "Agent idea 2" }
                && !c.nodes.values.contains { $0.text == "Agent idea 3" })
    }

    @Test func foldersConfineEveryPath() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let outside = box.root.appending(path: "Maps-private")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: box.plan, to: outside.appending(path: "Secret.nexus"))
        try FileManager.default.createSymbolicLink(at: box.maps.appending(path: "link"), withDestinationURL: outside)
        let scope = FolderScope([box.maps.path])
        #expect(scope.contains(box.plan))
        #expect(!scope.contains(outside.appending(path: "Secret.nexus")), "a sibling with the same prefix")
        #expect(!scope.contains(box.maps.appending(path: "../Maps-private/Secret.nexus")))
        #expect(!scope.contains(box.maps.appending(path: "link/Secret.nexus")), "a symlink out")
        #expect(scope.contains(box.maps.appending(path: "new/out.png")), "a file that doesn't exist yet")
        let s = Session(
            .enabled(box.policy()),
            [
                Session.initialize, Session.call(2, "read_map", ["path": "link/Secret.nexus"]),
                Session.call(3, "list_maps", [:]),
            ])
        _ = s.run()
        #expect(s.isError(2) && s.text(2).contains("outside"))
        #expect(!s.text(3).contains("Secret"), "list_maps doesn't follow links out")
        let none = Session(
            .enabled(AgentPolicy(enabled: true)), [Session.initialize, Session.call(2, "list_maps", [:])])
        _ = none.run()
        #expect(none.isError(2) && none.text(2).contains("No folders"))
    }

    @Test func topicReferences() throws {
        let doc = try NexusPackage.read(from: try Sandbox().plan)
        let c = doc.canvases["c1"]!
        #expect(try MapTools.topic("Launch plan > Pricing > Pro", in: c) == MapTools.topic("Pro", in: c))
        #expect(try MapTools.topic("pricing", in: c) == MapTools.topic("Pricing", in: c))
        #expect(throws: MapTools.ToolError.self) { try MapTools.topic("Nope", in: c) }
    }
}

@MainActor
@Suite(.serialized) struct CLITests {
    final class Capture {
        var out = Data()
        var err = ""
    }

    func run(_ args: [String], in dir: URL, stdin: [String] = [], env: [String: String] = [:]) -> (
        Int32, String, String, Data
    ) {
        let c = Capture()
        var input = stdin
        let io = NexusCLI.IO(
            out: { c.out.append($0) }, err: { c.err += $0 }, readLine: { input.isEmpty ? nil : input.removeFirst() },
            stdoutIsTerminal: false)
        let status = NexusCLI.run(
            args, io: io, env: .init(cwd: dir, home: dir, variables: env, team: nil))
        return (status, String(decoding: c.out, as: UTF8.self), c.err, c.out)
    }

    @Test func validateGoodAndBroken() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (ok, out, _, _) = run(["validate", "Launch plan.nexus"], in: box.maps)
        #expect(ok == 0 && out.contains("valid (2 canvases, 20 topics)"))
        // Break a canvas on disk: a child that doesn't exist.
        let url = box.plan.appending(path: "canvases/c1.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "\"format\"", with: "\"format\": 7, \"x\"", options: [], range: text.range(of: "\"format\""))
        try text.write(to: url, atomically: true, encoding: .utf8)
        let (bad, badOut, _, _) = run(["validate", box.plan.path], in: box.root)
        #expect(bad == 1 && !badOut.isEmpty, "\(badOut)")
        #expect(run(["validate"], in: box.root).0 == 64)
    }

    @Test(arguments: CLIFormat.allCases) func exportEveryFormat(_ f: CLIFormat) throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (status, out, err, data) = run(["export", box.plan.path, "--to", f.rawValue], in: box.root)
        #expect(status == 0, "\(err)")
        if f.isText {
            #expect(data.count > 40, "\(f) wrote \(data.count) bytes")
        } else {
            let file = box.maps.appending(path: "Launch plan.\(f.fileExtension)")
            #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == file.path)
            #expect(((try? Data(contentsOf: file))?.count ?? 0) > 1000)
        }
    }

    @Test func exportOptionsNewAndImport() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let (s1, mmd, _, _) = run(["export", "Maps/Launch plan.nexus", "--to", "mmd", "--canvas", "c2"], in: box.root)
        #expect(s1 == 0 && !mmd.isEmpty)
        #expect(run(["export", "Maps/Launch plan.nexus", "--to", "gif"], in: box.root).0 == 64)
        let (s2, _, _, _) = run(
            ["export", "Maps/Launch plan.nexus", "--to", "png", "--scale", "1", "--out", "small.png"], in: box.root)
        #expect(s2 == 0 && FileManager.default.fileExists(atPath: box.root.appending(path: "small.png").path))
        // new
        let (s3, path, _, _) = run(["new", "Q3 plan", "--type", "dfd"], in: box.root)
        #expect(s3 == 0)
        let made = try MapFiles.read(URL(fileURLWithPath: path.trimmingCharacters(in: .newlines)))
        #expect(
            made.orderedCanvases[0].type == .dfd
                && made.orderedCanvases[0].nodes[made.orderedCanvases[0].root]?.text == "Q3 plan")
        #expect(run(["new", "Q3 plan"], in: box.root).0 == 1, "never overwrites")
        // import
        try "# Trip\n## Packing\n- Passport\n- Charger\n## Trains\n".write(
            to: box.root.appending(path: "trip.md"), atomically: true, encoding: .utf8)
        let (s4, report, _, _) = run(["import", "trip.md"], in: box.root)
        #expect(s4 == 0 && report.contains("1 canvases · 5 topics"), "\(report)")
        #expect(try MapFiles.read(box.root.appending(path: "trip.nexus")).orderedCanvases[0].nodes.count == 5)
    }

    @Test func mcpReadsPolicyFile() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let cfg = box.root.appending(path: "agent.json")
        try box.policy().write(to: cfg)
        let (status, out, _, _) = run(
            ["mcp", "--config", cfg.path], in: box.root,
            stdin: [Session.initialize, Session.call(2, "list_maps", [:])])
        #expect(status == 0)
        let lines = out.split(separator: "\n").map { try? CanonicalJSON.parse(Data($0.utf8)) }
        #expect(lines.count == 2 && lines[1]?["result"]?["isError"] == false)
        // Off: the policy says so, or there's none.
        var off = box.policy()
        off.enabled = false
        try off.write(to: cfg)
        let (_, offOut, offErr, _) = run(
            ["mcp"], in: box.root, stdin: [Session.initialize], env: ["OPENNEXUS_AGENT_CONFIG": cfg.path])
        #expect(offOut.contains("Settings › Integrations") && offErr.contains("off"))
        #expect(
            NexusCLI.policyURL(config: nil, env: .init(cwd: box.root, home: box.root, variables: [:], team: nil)) == nil
        )
    }
}

/// The built binary, as an MCP client or a shell would run it.
@Suite(.serialized) struct BinaryTests {
    /// `swift test` builds every product, so the CLI sits in the same products folder.
    static var binary: URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repo.appending(path: ".build/debug/nexus")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func run(_ args: [String], input: String = "") throws -> (Int32, String) {
        let p = Process()
        p.executableURL = try #require(Self.binary)
        p.arguments = args
        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        try p.run()
        inp.fileHandleForWriting.write(Data(input.utf8))
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(.enabled(if: binary != nil)) func validateExportAndServe() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        #expect(try run(["validate", box.plan.path]).1.contains("valid"))
        #expect(try run(["export", box.plan.path, "--to", "mermaid"]).1.hasPrefix("mindmap"))
        let (_, png) = try run(["export", box.plan.path, "--to", "png"])
        #expect(FileManager.default.fileExists(atPath: png.trimmingCharacters(in: .newlines)))
        let cfg = box.root.appending(path: "agent.json")
        try box.policy().write(to: cfg)
        let script =
            await [Session.initialize, Session.call(2, "read_map", ["path": "Launch plan.nexus"])].joined(
                separator: "\n") + "\n"
        let (status, out) = try run(["mcp", "--config", cfg.path], input: script)
        #expect(status == 0)
        let replies = out.split(separator: "\n").compactMap { try? CanonicalJSON.parse(Data($0.utf8)) }
        #expect(replies.count == 2, "one line per message on stdout: \(out)")
        #expect(
            replies.last?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("Launch plan")
                == true)
        #expect(try run(["--version"]).1.hasPrefix("nexus \(MCPServer.serverVersion) (OpenNexus)"))
        #expect(try run(["bogus"]).0 == 64)
    }
}
