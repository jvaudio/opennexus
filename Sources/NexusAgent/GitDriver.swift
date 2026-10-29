import Foundation
import NexusCore
import NexusFormat
import NexusInterchange

/// Git, tier 1 (M45): the user's own `git` merges maps topic by topic and shows readable
/// diffs. `nexus git setup` installs a merge driver and a diff text conversion; Git runs
/// `nexus merge-driver` and `nexus git textconv` itself.
extension NexusCLI {
    /// What `nexus git setup` adds to `.gitattributes` (a package's files are tracked one
    /// by one; what the app derives is in each package's own `.gitignore`).
    static let gitAttributes = [
        "# OpenNexus: merge maps topic by topic and diff them as outlines (nexus git setup).",
        "**/*.nexus/canvases/*.json merge=nexus diff=nexus",
        "**/*.nexus/manifest.json merge=nexus",
        "**/*.nexus/theme.json merge=nexus",
        "*.nexusjson merge=nexus diff=nexus",
    ]

    static func git(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        guard let sub = args.first else { throw UsageError(message: "setup or textconv?") }
        args.removeFirst()
        switch sub {
        case "setup": return try gitSetup(&args, io: io, env: env)
        case "textconv":
            let url = file(try positional(args, "file"), env)
            io.out(Data(textconv(try Data(contentsOf: url)).utf8))
            return 0
        default: throw UsageError(message: "unknown subcommand “\(sub)”: setup or textconv")
        }
    }

    // MARK: setup

    /// Adds the attributes and the repository's `merge.nexus` and `diff.nexus` settings.
    /// Running it again changes nothing.
    static func gitSetup(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        guard args.isEmpty else { throw UsageError(message: "unexpected \(args.joined(separator: " "))") }
        let top = try runGit(["rev-parse", "--show-toplevel"], in: env.cwd)
        guard top.status == 0 else { throw UsageError(message: "not in a Git repository") }
        let root = URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let attributes = root.appending(path: ".gitattributes")
        var text = (try? String(contentsOf: attributes, encoding: .utf8)) ?? ""
        let have = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = gitAttributes.filter { !have.contains($0) }
        if !missing.isEmpty {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += missing.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: attributes, options: .atomic)
        }
        let nexus = shellQuoted(env.executable ?? "nexus")
        let config = [
            ("merge.nexus.name", "OpenNexus maps, topic by topic"),
            ("merge.nexus.driver", "\(nexus) merge-driver %O %A %B %P"),
            ("diff.nexus.textconv", "\(nexus) git textconv"),
        ]
        for (key, value) in config {
            let r = try runGit(["config", "--local", key, value], in: root)
            guard r.status == 0 else { throw UsageError(message: "git config \(key) failed: \(r.output)") }
        }
        io.print(
            missing.isEmpty
                ? "Already set up: .gitattributes and this repository’s merge.nexus and diff.nexus."
                : "Added \(counted(missing.count, "line", "lines")) to .gitattributes and set merge.nexus and diff.nexus in this repository."
        )
        return 0
    }

    static func shellQuoted(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func runGit(_ args: [String], in dir: URL) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: merge-driver

    /// `nexus merge-driver %O %A %B %P`: merges the ancestor, this branch's and the other
    /// branch's versions of one file, writes the result over %A, and exits 1 only when both
    /// branches changed the same thing (this branch's version is kept, and listed).
    static func mergeDriver(_ args: inout [String], io: IO, env: Environment) throws -> Int32 {
        guard args.count == 4 else { throw UsageError(message: "needs %O %A %B %P") }
        let (o, a, b, path) = (file(args[0], env), file(args[1], env), file(args[2], env), args[3])
        func load(_ u: URL) throws -> Data? {
            let d = try Data(contentsOf: u)
            return d.isEmpty ? nil : d
        }
        let merged = try mergeFile(path, base: try load(o), mine: try load(a) ?? Data(), theirs: try load(b) ?? Data())
        try merged.data.write(to: a, options: .atomic)
        for c in merged.clashes { io.err("\(path): both branches changed \(c); this branch’s is kept\n") }
        return merged.clashes.isEmpty ? 0 : 1
    }

    /// The merge of one file of a map, by its path in the repository.
    public static func mergeFile(_ path: String, base: Data?, mine: Data, theirs: Data) throws -> (
        data: Data, clashes: [String]
    ) {
        let name = (path as NSString).lastPathComponent
        if path.lowercased().hasSuffix(".nexusjson") {
            let parse = { (d: Data) in try DocumentJSON.parse(d, name: name) }
            let m = DocumentMerge(base: try base.map(parse), current: try parse(mine), disk: try parse(theirs))
            let text = String(decoding: mine, as: UTF8.self)
            let pretty = text.split(separator: "\n").count > 1
            let assets = (try? CanonicalJSON.parse(mine))?.objectValue?["assets"] != nil
            return (Data(DocumentJSON.export(m.model, pretty: pretty, assets: assets).utf8), m.conflicts)
        }
        if (path as NSString).deletingLastPathComponent.hasSuffix("canvases") {
            let id = (name as NSString).deletingPathExtension
            func canvas(_ d: Data) throws -> DocumentModel {
                var c = try Canvas(json: try CanonicalJSON.parse(d), path: id)
                _ = c.repair()
                return DocumentModel(canvases: [c])
            }
            let m = DocumentMerge(base: try base.map(canvas), current: try canvas(mine), disk: try canvas(theirs))
            guard let c = m.model.canvases[CanvasID(id)] ?? m.model.orderedCanvases.first else {
                return (mine, ["the canvas"])
            }
            return (CanonicalJSON.data(c.json), m.conflicts)
        }
        // manifest.json, theme.json: key by key.
        var clashes: [String] = []
        let merged = mergeJSON(
            try base.map { try CanonicalJSON.parse($0) }, try CanonicalJSON.parse(mine),
            try CanonicalJSON.parse(theirs), path: name == "manifest.json" ? "" : "theme", clashes: &clashes)
        return (CanonicalJSON.data(merged ?? .object([:])), clashes)
    }

    /// Three-way merge of JSON: objects key by key, lists of strings (such as the canvas
    /// order) as lists, and anything both sides changed differently keeps this side's.
    static func mergeJSON(
        _ base: JSONValue?, _ mine: JSONValue?, _ theirs: JSONValue?, path: String, clashes: inout [String]
    ) -> JSONValue? {
        if mine == theirs || base == theirs { return mine }
        if base == mine { return theirs }
        switch (mine, theirs) {
        case (.object(let m)?, .object(let t)?):
            let b = base?.objectValue ?? [:]
            var out: [String: JSONValue] = [:]
            for k in Set(m.keys).union(t.keys) {
                // The app's version and the schema version: the newer, never a clash.
                if path.isEmpty, k == "app" || k == "schemaVersion" {
                    out[k] = [m[k], t[k]].compactMap { $0 }.max { "\($0)" < "\($1)" }
                    continue
                }
                let sub = path.isEmpty ? k : "\(path).\(k)"
                if let v = mergeJSON(b[k], m[k], t[k], path: sub, clashes: &clashes) { out[k] = v }
            }
            return .object(out)
        case (.array(let m)?, .array(let t)?):
            let strings = { (a: [JSONValue]) in a.compactMap { if case .string(let s) = $0 { s } else { nil } } }
            let (ms, ts) = (strings(m), strings(t))
            let bs: [String] = base.flatMap { if case .array(let a) = $0 { strings(a) } else { nil } } ?? []
            guard ms.count == m.count, ts.count == t.count else { break }
            // This side's order, without what the other removed, then what the other added.
            var out = ms.filter { !(bs.contains($0) && !ts.contains($0)) }
            out += ts.filter { !bs.contains($0) && !out.contains($0) }
            return .array(out.map { .string($0) })
        default: break
        }
        clashes.append(path.isEmpty ? "the manifest" : path)
        return mine
    }

    // MARK: textconv

    /// What `git diff` shows for a map file: one topic per line with its parent, so a new
    /// topic reads "+ Pricing (under Launch)". Other files print as they are.
    public static func textconv(_ data: Data) -> String {
        if let doc = try? DocumentJSON.parse(data, name: "document.nexusjson") {
            return doc.orderedCanvases.map(outline).joined(separator: "\n")
        }
        if let v = try? CanonicalJSON.parse(data),
            let id = v.objectValue?["id"].flatMap({ v -> String? in
                if case .string(let s) = v { s } else { nil }
            }), var c = try? Canvas(json: v, path: id)
        {
            _ = c.repair()
            return outline(c)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func outline(_ c: Canvas) -> String {
        var lines = ["# \(c.title)"]
        func walk(_ id: NodeID, parent: String?) {
            guard let n = c.nodes[id] else { return }
            var line = n.text + (parent.map { " (under \($0))" } ?? "")
            if let note = n.note?.text.split(separator: "\n").first, !note.isEmpty { line += " · note: \(note)" }
            lines.append(line)
            for child in n.children { walk(child, parent: n.text) }
        }
        walk(c.root, parent: nil)
        for id in c.floating { walk(id, parent: nil) }
        return lines.joined(separator: "\n") + "\n"
    }
}
