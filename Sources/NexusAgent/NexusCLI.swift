import Foundation
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange

/// The `nexus` command line (README §8; artboard 40). Hand-written argument parsing: no
/// package dependencies, so builds never need the network (D89).
@MainActor
public enum NexusCLI {
    public struct IO {
        public var out: (Data) -> Void
        public var err: (String) -> Void
        public var readLine: () -> String?
        public var stdoutIsTerminal: Bool
        public init(
            out: @escaping (Data) -> Void, err: @escaping (String) -> Void, readLine: @escaping () -> String?,
            stdoutIsTerminal: Bool
        ) {
            self.out = out
            self.err = err
            self.readLine = readLine
            self.stdoutIsTerminal = stdoutIsTerminal
        }
        func print(_ s: String) { out(Data((s + "\n").utf8)) }
    }

    /// Where `nexus mcp` looks for the settings OpenNexus writes.
    public struct Environment {
        public var cwd: URL
        public var home: URL
        public var variables: [String: String]
        /// The team that signed this binary (it shares the app's App Group).
        public var team: String?
        public init(cwd: URL, home: URL, variables: [String: String], team: String?) {
            self.cwd = cwd
            self.home = home
            self.variables = variables
            self.team = team
        }
    }

    public static let usage = """
        usage: nexus <command> [options]

          validate <file>                     Check a .nexus or .nexusjson file against the schema.
          read <file> [--canvas <id|title>]   Print a map as an outline with topic ids, task fields
                 [--tasks]                    and comments (--tasks: only topics with task fields).
          export <file> --to <format>         Export a canvas. Text goes to stdout; files go beside
                 [--canvas <id|title>]        the map unless --out is given.
                 [--out <path>] [--scale <n>]
                 [--branch <topic>]           Only the branch from a topic (id, "A > B" or title):
                                              \(CLIFormat.names(\.exportsBranch)).
                 [--zone <id|title>]          Only one zone and its topics: \(CLIFormat.names(\.exportsZone)).
                 [--zones each|pages]         Every zone, a file each in the --out folder (default
                                              "<map> – Zones"), or one PDF with a page per zone.
                                              Formats: \(CLIFormat.names())
          new "<title>" [--type <type>]       Create a map (mindmap, flowchart, dfd, architecture, …).
                 [--out <path>]
          import <file> [--out <path>]        Convert Xmind, OPML, Markdown, Mermaid, … to .nexus.
          mcp [--config <agent.json>]         Run the MCP server on stdio (enable it in OpenNexus ›
                                              Settings › Integrations).
          --version, --help

        """

    public static func run(_ args: [String], io: IO, env: Environment) -> Int32 {
        guard let command = args.first else {
            io.err(usage)
            return 64
        }
        var rest = Array(args.dropFirst())
        do {
            switch command {
            case "--help", "-h", "help":
                io.print(usage)
                return 0
            case "--version", "-v":
                io.print("nexus \(MCPServer.serverVersion) (OpenNexus)")
                return 0
            case "validate": return try validate(&rest, io: io, env: env)
            case "read": return try read(&rest, io: io, env: env)
            case "export": return try export(&rest, io: io, env: env)
            case "new": return try new(&rest, io: io, env: env)
            case "import": return try importFile(&rest, io: io, env: env)
            case "mcp": return try mcp(&rest, io: io, env: env)
            default:
                io.err("nexus: unknown command “\(command)”\n\n" + usage)
                return 64
            }
        } catch let e as UsageError {
            io.err("nexus \(command): \(e.message)\n")
            return 64
        } catch {
            io.err("nexus \(command): \(error)\n")
            return 1
        }
    }

    struct UsageError: Error { var message: String }

    /// Removes `--name value` from args.
    static func option(_ name: String, _ args: inout [String]) throws -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { throw UsageError(message: "\(name) needs a value") }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    static func file(_ path: String, _ env: Environment) -> URL {
        let p = (path as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : env.cwd.appending(path: p)
    }

    static func positional(_ args: [String], _ what: String) throws -> String {
        guard args.count == 1, let a = args.first, !a.hasPrefix("--") else {
            throw UsageError(message: args.isEmpty ? "missing \(what)" : "unexpected \(args.joined(separator: " "))")
        }
        return a
    }

    /// "1 canvas", "2 canvases": a count with its noun, as the CLI's English output says it.
    static func counted(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    // MARK: validate

    /// The summary `validate` prints after "valid": "1 canvas, 1 topic" (D257).
    static func contentSummary(_ doc: DocumentModel) -> String {
        "\(counted(doc.canvases.count, "canvas", "canvases")), \(counted(doc.topicCount, "topic", "topics"))"
    }

    /// Checks the files as they are on disk (not a re-serialisation), then each canvas.
    public static func validationIssues(_ url: URL) throws -> (issues: [String], summary: String) {
        if url.pathExtension.lowercased() == "nexusjson" {
            let doc = try DocumentJSON.parse(Data(contentsOf: url), name: url.lastPathComponent)
            let issues =
                doc.repairs.map { "needs repair: \($0)" }
                + doc.orderedCanvases.flatMap { c in c.validate().map { "\(c.id.rawValue): \($0)" } }
            return (issues, contentSummary(doc))
        }
        let files = NexusPackage.flatten(try FileWrapper(url: url, options: [.immediate]))
        if PackageCrypto.isEncrypted(files) {
            let issues = SchemaValidator.bundled.validate(package: files.filter { $0.key == "manifest.json" })
            return (issues.map(\.description), "encrypted; contents not checked without the password")
        }
        var issues = SchemaValidator.bundled.validate(package: files).map(\.description)
        do {
            let doc = try NexusPackage.read(files: files)
            issues += doc.repairs.map { "needs repair: \($0)" }
            for c in doc.orderedCanvases { issues += c.validate().map { "canvases/\(c.id.rawValue).json: \($0)" } }
            return (issues, contentSummary(doc))
        } catch {
            return (issues + ["\(error)"], "")
        }
    }

    static func validate(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        let url = file(try positional(args, "file"), env)
        let (issues, summary) = try validationIssues(url)
        if issues.isEmpty {
            io.print("\(url.lastPathComponent): valid (\(summary))")
            return 0
        }
        issues.forEach { io.print("\(url.lastPathComponent): \($0)") }
        return 1
    }

    // MARK: read

    /// The same outline as the MCP `read_map` tool, or with `--tasks` a task list:
    /// "Design [n3] ☐ — owner Ana · start 2026-11-02 · …".
    static func read(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        let canvasRef = try option("--canvas", &args)
        let tasksOnly = args.contains("--tasks")
        args.removeAll { $0 == "--tasks" }
        let url = file(try positional(args, "file"), env)
        let doc = try MapFiles.read(url)
        var ids = doc.canvasOrder
        if let canvasRef {
            do { ids = [try MapTools.canvasID(["canvas": .string(canvasRef)], in: doc)] } catch {
                throw UsageError(message: "\(error)")
            }
        }
        let canvases = ids.compactMap { doc.canvases[$0] }
        guard tasksOnly else {
            io.print(canvases.map(MapTools.outline).joined(separator: "\n\n"))
            return 0
        }
        var lines: [String] = []
        for c in canvases {
            lines.append("# \(c.title.isEmpty ? "Canvas" : c.title) (\(c.id.rawValue) · \(c.type.rawValue))")
            for top in c.tops {
                c.walk(from: top) { id, n, _ in
                    guard let task = MapTools.taskLine(c, id) else { return }
                    let box = n.todo?.done == true ? "☑" : "☐"
                    lines.append(
                        "- \(n.text.replacingOccurrences(of: "\n", with: " ")) [\(id.rawValue)] \(box) — \(task)")
                }
            }
        }
        io.print(lines.joined(separator: "\n"))
        return 0
    }

    // MARK: export

    static func export(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        guard let to = try option("--to", &args) ?? option("--format", &args) else {
            throw UsageError(message: "--to <format> is required")
        }
        guard let format = CLIFormat(name: to) else {
            throw UsageError(
                message: "unknown format “\(to)”; use \(CLIFormat.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let canvasRef = try option("--canvas", &args)
        let out = try option("--out", &args) ?? option("-o", &args)
        let scale = try option("--scale", &args).map { s -> Double in
            guard let v = Double(s), v > 0, v <= 8 else { throw UsageError(message: "--scale must be between 0 and 8") }
            return v
        }
        let branch = try option("--branch", &args)
        let zone = try option("--zone", &args)
        let zones = try option("--zones", &args)
        let url = file(try positional(args, "file"), env)
        let doc = try MapFiles.read(url)
        let cid: CanvasID
        let scope: ExportScope
        do {
            cid = try MapTools.canvasID(canvasRef.map { ["canvas": .string($0)] } ?? [:], in: doc)
            scope = try ExportScope.parse(
                branch: branch, zone: zone, zones: zones, format: format, in: doc.canvases[cid]!)
        } catch {
            throw UsageError(message: "\(error)")
        }
        if scope == .eachZone { return try exportZones(doc, cid, format, url: url, out: out, scale: scale, io, env) }
        guard let data = format.export(doc, canvas: cid, scope: scope, scale: scale) else {
            io.err("nexus export: couldn't export \(format.rawValue)\n")
            return 1
        }
        if out == "-" || (out == nil && format.isText) {
            io.out(data)
            return 0
        }
        // Beside the map, named as the app names a branch or zone export ("Plan – Pricing").
        let suffix = scope.nameSuffix(in: doc.canvases[cid]!)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let beside =
            suffix.isEmpty
            ? url.deletingPathExtension().appendingPathExtension(format.fileExtension)
            : url.deletingLastPathComponent().appending(
                path: url.deletingPathExtension().lastPathComponent + suffix + "." + format.fileExtension)
        let target = out.map { file($0, env) } ?? beside
        try MapFiles.write(data, to: target)
        io.print(target.path)
        return 0
    }

    /// `--zones each`: a file per zone in the `--out` folder (made if needed), or in
    /// "<map> – Zones" beside the map. Prints each file's path.
    static func exportZones(
        _ doc: DocumentModel, _ cid: CanvasID, _ format: CLIFormat, url: URL, out: String?, scale: Double?, _ io: IO,
        _ env: Environment
    ) throws -> Int32 {
        guard out != "-" else { throw UsageError(message: "--zones each writes a file per zone; give a folder") }
        let folder =
            out.map { file($0, env) }
            ?? url.deletingLastPathComponent().appending(
                path: url.deletingPathExtension().lastPathComponent + " – Zones")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), !isDir.boolValue {
            throw UsageError(message: "\(folder.path) is a file; --zones each needs a folder")
        }
        let files = format.zoneFiles(doc, canvas: cid, scale: scale)
        guard !files.isEmpty else {
            io.err("nexus export: couldn't export \(format.rawValue)\n")
            return 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in files {
            let target = folder.appending(path: f.name)
            try MapFiles.write(f.data, to: target)
            io.print(target.path)
        }
        return 0
    }

    // MARK: new and import

    static func new(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        let type = DiagramType(rawValue: try option("--type", &args) ?? "mindmap")
        guard MapTools.types.contains(type) else {
            throw UsageError(message: "unknown type; use \(MapTools.types.map(\.rawValue).joined(separator: ", "))")
        }
        let out = try option("--out", &args)
        let title = try positional(args, "title")
        var doc = CanvasController.newDocumentModel(prefs: .isolated(), type: type)
        if let id = doc.canvasOrder.first, let root = doc.canvases[id]?.root {
            doc.canvases[id]?.nodes[root]?.text = title
            doc.canvases[id]?.title = title
        }
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let target = out.map { file($0, env) } ?? env.cwd.appending(path: "\(safe).nexus")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            io.err("nexus new: \(target.path) already exists\n")
            return 1
        }
        try MapFiles.write(doc, to: target)
        io.print(target.path)
        return 0
    }

    static func importFile(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        let out = try option("--out", &args)
        let url = file(try positional(args, "file"), env)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let imported =
            isDir.boolValue
            ? try Interchange.importFile(
                name: url.lastPathComponent,
                files: NexusPackage.flatten(try FileWrapper(url: url, options: [.immediate])))
            : try Interchange.importFile(name: url.lastPathComponent, data: Data(contentsOf: url))
        let doc = DocumentModel(canvases: imported.canvases, assets: imported.assets)
        let target = out.map { file($0, env) } ?? url.deletingPathExtension().appendingPathExtension("nexus")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            io.err("nexus import: \(target.path) already exists (use --out)\n")
            return 1
        }
        try MapFiles.write(doc, to: target)
        let r = imported.report
        let extras = [
            r.tasks > 0 ? "\(r.tasks) tasks" : nil, r.dependencies > 0 ? "\(r.dependencies) dependencies" : nil,
            r.comments > 0 ? "\(r.comments) comments" : nil,
        ]
        .compactMap { $0 }.map { " · " + $0 }.joined()
        io.print(
            "\(target.path)\n\(r.canvases) canvases · \(r.topics) topics\(extras) · \(r.notConverted) not converted")
        for item in r.lines { io.print("  · \(item)") }
        return 0
    }

    // MARK: mcp

    /// The policy file: --config, $OPENNEXUS_AGENT_CONFIG, the App Group (when this binary
    /// is signed by the app's team), then the app's own container.
    public static func policyURL(config: String?, env: Environment) -> URL? {
        if let config { return file(config, env) }
        if let v = env.variables["OPENNEXUS_AGENT_CONFIG"], !v.isEmpty { return file(v, env) }
        var candidates: [URL] = []
        if let team = env.team {
            candidates.append(AppGroup.container(team: team, home: env.home).appending(path: AgentPolicy.fileName))
        }
        candidates.append(
            env.home.appending(
                path:
                    "Library/Containers/com.opennexus.OpenNexus/Data/Library/Application Support/OpenNexus/\(AgentPolicy.fileName)"
            ))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let offMessage =
        "The OpenNexus MCP server is off. Turn it on in OpenNexus › Settings › Integrations › Local MCP server, and allow at least one folder."

    public static func serverConfig(config: String?, env: Environment) -> MCPServer.Config {
        guard let url = policyURL(config: config, env: env) else { return .disabled(offMessage) }
        guard let policy = try? AgentPolicy.read(from: url) else {
            return .disabled("Couldn't read OpenNexus's agent settings at \(url.path).")
        }
        return policy.enabled ? .enabled(policy) : .disabled(offMessage)
    }

    static func mcp(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        let config = try option("--config", &args)
        guard args.isEmpty else { throw UsageError(message: "unexpected \(args.joined(separator: " "))") }
        let server = MCPServer(
            config: serverConfig(config: config, env: env), input: io.readLine,
            output: { io.out(Data(($0 + "\n").utf8)) }, log: { io.err("nexus mcp: \($0)\n") })
        if case .disabled(let why) = server.config { io.err("nexus mcp: \(why)\n") }
        server.run()
        return 0
    }
}
