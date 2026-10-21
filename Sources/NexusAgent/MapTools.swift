import Foundation
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange

/// The tools an MCP client can call (artboard 40; M22 added set_task and add_comment).
/// Each one checks Settings › Integrations (the folders, then Read / Edit / Create & export:
/// Allow, Ask or Block), works on the file, and marks every topic it creates or changes as
/// AI (✦). Comments an agent adds are signed "… (AI)".
@MainActor
public struct MapTools {
    public struct ToolError: Error, CustomStringConvertible {
        public var description: String
        public init(_ d: String) { description = d }
    }

    /// A tool's result: MCP content blocks (text or image).
    public struct Output: Equatable {
        public var content: [JSONValue]
        public init(text: String) { content = [["type": "text", "text": .string(text)]] }
        public init(content: [JSONValue]) { self.content = content }
        public var text: String { content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n") }
    }

    public var policy: AgentPolicy
    public var scope: FolderScope
    /// Asks the user (MCP elicitation). nil: the client can't ask.
    public var ask: (String) -> Bool?
    /// The MCP client's name, used to sign comments.
    public var client: String?

    public init(policy: AgentPolicy, ask: @escaping (String) -> Bool? = { _ in nil }) {
        self.policy = policy
        self.scope = FolderScope(policy.folders)
        self.ask = ask
    }

    // MARK: Definitions

    static func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    static let pathProp: JSONValue = [
        "type": "string",
        "description": "Path to a .nexus or .nexusjson map: absolute, ~, or relative to the first allowed folder.",
    ]
    static let canvasProp: JSONValue = [
        "type": "string", "description": "Canvas id or title (default: the first canvas).",
    ]
    static let topicDesc =
        "A topic: its id (from read_map, e.g. \"n3\"), a path of titles from the central topic (\"Launch > Pricing\"), or a unique title."
    static let endDesc = topicDesc + " Or a zone: \"zone:\" and its id or title (\"zone:z1\")."

    public static let definitions: [JSONValue] = [
        tool(
            "list_maps", "List maps",
            "Lists the OpenNexus maps (.nexus, .nexusjson) in the folders the user allowed, newest first, with canvases and topic counts.",
            schema(
                ["query": ["type": "string", "description": "Only maps whose name or topics contain this text."]],
                required: []),
            readOnly: true),
        tool(
            "read_map", "Read a map",
            "Reads a map as an outline with topic ids (for the other tools), notes, labels, task fields, comments and relationships, or as OpenNexus JSON.",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "format": [
                        "type": "string", "enum": ["outline", "json"], "description": "outline (default) or json",
                    ],
                ], required: ["path"]), readOnly: true),
        tool(
            "add_topic", "Add a topic",
            "Adds a topic (and optional children) under a parent topic. One undo step in OpenNexus; marked as AI-created.",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "parent": ["type": "string", "description": .string(topicDesc)],
                    "text": ["type": "string", "description": "The new topic's title."],
                    "children": [
                        "type": "array", "items": ["type": "string"], "description": "Child titles to add under it.",
                    ],
                    "note": ["type": "string", "description": "A note (Markdown)."],
                    "labels": ["type": "array", "items": ["type": "string"]],
                ], required: ["path", "parent", "text"]), readOnly: false),
        tool(
            "add_edge", "Connect two topics or zones",
            "Draws a relationship between two topics or zones, with an optional label (e.g. \"drives\", \"POST /cart\").",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "from": ["type": "string", "description": .string(endDesc)],
                    "to": ["type": "string", "description": .string(endDesc)], "label": ["type": "string"],
                ], required: ["path", "from", "to"]), readOnly: false),
        tool(
            "set_task", "Set task fields",
            "Sets a topic's task fields: dates, owner, progress, priority, done, and the tasks it waits for. Only the fields given change; an empty string clears a text field. Makes the topic a to-do if it isn't. Later tasks move to keep their dependencies. One undo step in OpenNexus; marked as AI-changed.",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "topic": ["type": "string", "description": .string(topicDesc)],
                    "start": ["type": "string", "description": "First day of work, yyyy-MM-dd (\"\" clears)."],
                    "due": [
                        "type": "string",
                        "description":
                            "Last day of work, inclusive, yyyy-MM-dd (\"\" clears). Only a due date makes a milestone.",
                    ],
                    "duration": [
                        "type": "integer", "minimum": 1, "maximum": 3650,
                        "description": "Length in working days; sets the due date from the start.",
                    ],
                    "owner": ["type": "string", "description": "Who does it (\"\" clears)."],
                    "progress": ["type": "integer", "minimum": 0, "maximum": 100, "description": "Percent done."],
                    "priority": [
                        "type": "integer", "minimum": 0, "maximum": 9, "description": "1 (highest) to 9; 0 clears.",
                    ],
                    "done": ["type": "boolean"],
                    "after": [
                        "type": "array",
                        "description":
                            "The tasks this one waits for, replacing the current list ([] clears). Each is a topic, with an optional kind (FS finish-to-start by default, SS, FF, SF) and lag in working days.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "topic": ["type": "string", "description": .string(topicDesc)],
                                "type": ["type": "string", "enum": ["FS", "SS", "FF", "SF"]],
                                "lag": ["type": "integer", "minimum": -3650, "maximum": 3650],
                            ],
                            "required": ["topic"], "additionalProperties": false,
                        ],
                    ],
                ], required: ["path", "topic"]), readOnly: false),
        tool(
            "add_comment", "Add a comment",
            "Adds a review comment to a topic, signed with the author (default: this client's name) and \"(AI)\", at the current time. One undo step in OpenNexus.",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "topic": ["type": "string", "description": .string(topicDesc)],
                    "text": ["type": "string", "description": "The comment."],
                    "author": ["type": "string", "description": "Who is commenting (optional)."],
                ], required: ["path", "topic", "text"]), readOnly: false),
        tool(
            "set_style", "Set style",
            "Changes the canvas theme, node style or layout structure, or one topic's shape and colour.",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "theme": [
                        "type": "string",
                        "description": "classic, paper, graphite, blueprint, pastel, neon, solarized, highContrast…",
                    ],
                    "node_style": [
                        "type": "string",
                        "enum": [
                            "outline", "soft", "solid", "underline", "capsule", "sketch", "brutal", "glow", "minimal",
                        ],
                    ],
                    "structure": [
                        "type": "string",
                        "description":
                            "e.g. mindmap.balanced, logic.right, org.down, tree.indented, timeline.horizontal, fishbone.left",
                    ],
                    "topic": [
                        "type": "string",
                        "description": .string("\(topicDesc) Styles this topic instead of the canvas."),
                    ],
                    "shape": [
                        "type": "string",
                        "description": "rounded, rectangle, pill, ellipse, diamond, hexagon, underline…",
                    ],
                    "color": ["type": "string", "description": "Fill colour as #RRGGBB."],
                ], required: ["path"]), readOnly: false),
        tool(
            "convert_type", "Convert diagram type",
            "Turns a canvas into another diagram type (the same view of the same topics, like ⌥⌘T). Node types are proposed from topic text.",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "type": [
                        "type": "string",
                        "enum": .array(Self.types.map { .string($0.rawValue) }),
                    ],
                ], required: ["path", "type"]), readOnly: false),
        tool(
            "export", "Export",
            "Exports a canvas. Text formats return the text; png returns an image. With \"out\", writes the file (inside an allowed folder).",
            schema(
                [
                    "path": pathProp, "canvas": canvasProp,
                    "format": ["type": "string", "enum": .array(CLIFormat.allCases.map { .string($0.rawValue) })],
                    "out": ["type": "string", "description": "Where to write the file (optional)."],
                ], required: ["path", "format"]), readOnly: true),
    ]

    static let types: [DiagramType] = [
        .mindmap, .logic, .brace, .org, .tree, .treeTable, .timeline, .fishbone, .matrix, .flowchart, .swimlane, .dfd,
        .threatModel, .architecture, .sequence, .whiteboard,
    ]

    static func tool(_ name: String, _ title: String, _ desc: String, _ schema: JSONValue, readOnly: Bool) -> JSONValue
    {
        [
            "name": .string(name), "title": .string(title), "description": .string(desc), "inputSchema": schema,
            "annotations": [
                "readOnlyHint": .bool(readOnly), "destructiveHint": false, "idempotentHint": .bool(readOnly),
                "openWorldHint": false,
            ],
        ]
    }

    // MARK: Calls

    public func call(_ name: String, _ args: [String: JSONValue]) throws -> Output {
        switch name {
        case "list_maps": return try listMaps(args)
        case "read_map": return try readMap(args)
        case "add_topic": return try addTopic(args)
        case "add_edge": return try addEdge(args)
        case "set_task": return try setTask(args)
        case "add_comment": return try addComment(args)
        case "set_style": return try setStyle(args)
        case "convert_type": return try convertType(args)
        case "export": return try export(args)
        default: throw ToolError("Unknown tool \(name).")
        }
    }

    func permit(_ access: AgentPolicy.Access, _ what: String) throws {
        switch access {
        case .allow: return
        case .block:
            throw ToolError(
                "\(what.prefix(1).uppercased() + what.dropFirst()) is blocked in OpenNexus › Settings › Integrations.")
        case .ask:
            guard let ok = ask("Allow the agent to \(what)?") else {
                throw ToolError(
                    "\(what.prefix(1).uppercased() + what.dropFirst()) needs your approval, and this MCP client can't ask. Set it to Allow in OpenNexus › Settings › Integrations."
                )
            }
            if !ok { throw ToolError("The user declined: \(what).") }
        }
    }

    func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let s = args[key]?.stringValue, !s.isEmpty else { throw ToolError("Missing “\(key)”.") }
        return s
    }

    /// A map path inside the allowed folders.
    func mapURL(_ args: [String: JSONValue]) throws -> URL {
        let p = try string(args, "path")
        guard !scope.roots.isEmpty else {
            throw ToolError(
                "No folders are allowed yet. Add one in OpenNexus › Settings › Integrations › Allowed folders.")
        }
        guard let url = scope.url(for: p), scope.contains(url) else {
            throw ToolError("\(p) is outside the allowed folders.")
        }
        guard MapFiles.isMap(url) else { throw ToolError("\(url.lastPathComponent) isn't an OpenNexus map.") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("\(p) doesn't exist.") }
        return url
    }

    func load(_ url: URL) throws -> DocumentModel {
        do { return try MapFiles.read(url) } catch let e as NexusPackage.ReadError {
            if case .encrypted = e {
                throw ToolError("\(url.lastPathComponent) is password-protected; agents can't open it.")
            }
            throw ToolError("\(url.lastPathComponent): \(e)")
        }
    }

    static func canvasID(_ args: [String: JSONValue], in doc: DocumentModel) throws -> CanvasID {
        guard let ref = args["canvas"]?.stringValue, !ref.isEmpty else {
            guard let first = doc.canvasOrder.first else { throw ToolError("The map has no canvases.") }
            return first
        }
        if doc.canvases[CanvasID(ref)] != nil { return CanvasID(ref) }
        if let c = doc.orderedCanvases.first(where: { $0.title.caseInsensitiveCompare(ref) == .orderedSame }) {
            return c.id
        }
        throw ToolError(
            "No canvas “\(ref)”. Canvases: \(doc.orderedCanvases.map { "\($0.id.rawValue) (\($0.title))" }.joined(separator: ", "))."
        )
    }

    /// "Title [id]" for a topic, "Title [zone:id]" for a zone.
    static func name(_ end: RelationshipEnd, in c: Canvas) -> String {
        switch end {
        case .topic(let id): "\(c.nodes[id]?.text ?? id.rawValue) [\(id.rawValue)]"
        case .zone(let id): "\(c.zones.first { $0.id == id }?.title ?? id) [zone:\(id)]"
        }
    }

    /// "zone:" and a zone's id or unique title, or anything `topic` takes.
    static func end(_ ref: String, in c: Canvas) throws -> RelationshipEnd {
        guard ref.lowercased().hasPrefix("zone:") else { return .topic(try topic(ref, in: c)) }
        let key = ref.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if c.zones.contains(where: { $0.id == key }) { return .zone(key) }
        let hits = c.zones.filter { $0.title.caseInsensitiveCompare(key) == .orderedSame }
        if hits.count == 1 { return .zone(hits[0].id) }
        if hits.isEmpty { throw ToolError("No zone “\(key)”. Use read_map to see zone ids.") }
        throw ToolError("“\(key)” matches \(hits.count) zones (\(hits.map(\.id).joined(separator: ", "))); use an id.")
    }

    /// An id, a "A > B" path from the central topic, or a unique title.
    static func topic(_ ref: String, in c: Canvas) throws -> NodeID {
        if c.nodes[NodeID(ref)] != nil { return NodeID(ref) }
        let parts = ref.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        if parts.count > 1 {
            var cur = c.root
            var rest = parts[...]
            if let first = rest.first, same(c.nodes[c.root]?.text ?? "", first) { rest = rest.dropFirst() }
            for p in rest {
                guard let next = c.nodes[cur]?.children.first(where: { same(c.nodes[$0]?.text ?? "", p) }) else {
                    throw ToolError("No topic “\(p)” under “\(c.nodes[cur]?.text ?? "")”.")
                }
                cur = next
            }
            return cur
        }
        let hits = c.nodes.filter { same($0.value.text, ref) }.map(\.key).sorted { $0.rawValue < $1.rawValue }
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty { throw ToolError("No topic “\(ref)”. Use read_map to see topic ids.") }
        throw ToolError(
            "“\(ref)” matches \(hits.count) topics (\(hits.map(\.rawValue).joined(separator: ", "))); use an id.")
    }

    func save(_ doc: DocumentModel, _ url: URL) throws {
        do { try MapFiles.write(doc, to: url) } catch {
            throw ToolError("Couldn't save \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: Tools

    func listMaps(_ args: [String: JSONValue]) throws -> Output {
        guard !scope.roots.isEmpty else {
            throw ToolError(
                "No folders are allowed yet. Add one in OpenNexus › Settings › Integrations › Allowed folders.")
        }
        try permit(policy.read, "read maps in \(scope.roots.map(\.lastPathComponent).joined(separator: ", "))")
        let q = args["query"]?.stringValue?.lowercased() ?? ""
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        for u in scope.maps() {
            guard let doc = try? MapFiles.read(u) else {
                if q.isEmpty || u.lastPathComponent.lowercased().contains(q) {
                    lines.append("\(u.path) — password-protected or unreadable")
                }
                continue
            }
            if !q.isEmpty, !u.lastPathComponent.lowercased().contains(q),
                !doc.canvases.values.contains(where: { $0.nodes.values.contains { $0.text.lowercased().contains(q) } })
            {
                continue
            }
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map {
                iso.string(from: $0)
            }
            let canvases = doc.orderedCanvases.map {
                "\($0.title.isEmpty ? $0.id.rawValue : $0.title) (\($0.type.rawValue))"
            }
            lines.append(
                "\(u.path) — \(canvases.joined(separator: ", ")) · \(doc.topicCount) topics\(date.map { " · modified \($0)" } ?? "")"
            )
        }
        return Output(text: lines.isEmpty ? "No maps found." : lines.joined(separator: "\n"))
    }

    func readMap(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.read, "read \(url.lastPathComponent)")
        let doc = try load(url)
        let ids: [CanvasID] = args["canvas"] != nil ? [try Self.canvasID(args, in: doc)] : doc.canvasOrder
        if args["format"]?.stringValue == "json" {
            var d = doc
            d.canvases = d.canvases.filter { ids.contains($0.key) }
            d.canvasOrder = d.canvasOrder.filter { ids.contains($0) }
            d.assets = [:]
            return Output(text: DocumentJSON.export(d, pretty: true))
        }
        return Output(text: ids.compactMap { doc.canvases[$0] }.map(Self.outline).joined(separator: "\n\n"))
    }

    /// "# Title (c1 · mindmap)" then "- Topic [n3] #label — note" lines, indented by depth.
    static func outline(_ c: Canvas) -> String {
        var out = ["# \(c.title.isEmpty ? "Canvas" : c.title) (\(c.id.rawValue) · \(c.type.rawValue))"]
        func line(_ id: NodeID, _ n: Node, _ d: Int) {
            var s =
                String(repeating: "  ", count: d)
                + "- \(n.text.replacingOccurrences(of: "\n", with: " ")) [\(id.rawValue)]"
            if let t = n.nodeType { s += " (\(t.rawValue))" }
            if !n.labels.isEmpty { s += " " + n.labels.map { "#\($0)" }.joined(separator: " ") }
            if let todo = n.todo { s += todo.done ? " ☑" : " ☐" }
            if n.ai { s += " ✦" }
            if let note = n.note?.text, !note.isEmpty {
                s += " — note: " + note.replacingOccurrences(of: "\n", with: " ").prefix(200)
            }
            if let link = n.link { s += " <\(link)>" }
            out.append(s)
            let pad = String(repeating: "  ", count: d + 2)
            if let task = taskLine(c, id) { out.append(pad + "task: " + task) }
            for cm in n.comments {
                let who = [cm.author, cm.date].filter { !$0.isEmpty }.joined(separator: " · ")
                out.append(
                    pad + "comment" + (who.isEmpty ? "" : " by \(who)") + ": "
                        + cm.text.replacingOccurrences(of: "\n", with: " "))
            }
        }
        c.walk(line)
        for f in c.floating { c.walk(from: f) { line($0, $1, $2 + 1) } }
        if !c.zones.isEmpty {
            out.append("Zones:")
            for z in c.zones {
                let members = z.members.map { "\(c.nodes[$0]?.text ?? "") [\($0.rawValue)]" }
                out.append(
                    "- \(z.title.isEmpty ? "Zone" : z.title) [zone:\(z.id)]\(members.isEmpty ? "" : " holds \(members.joined(separator: ", "))")"
                )
            }
        }
        if !c.relationships.isEmpty {
            out.append("Relationships:")
            for r in c.relationships {
                let label = r.label.isEmpty ? "" : " “\(r.label)”"
                out.append("- \(name(r.from, in: c)) → \(name(r.to, in: c))\(label) [\(r.id)]")
            }
        }
        return out.joined(separator: "\n")
    }

    /// "owner Ana · start 2026-11-02 · due 2026-11-06 · 5 working days · 40% · priority 2 ·
    /// after Research [n2], Code [n4] (SS +1)": a topic's task fields, nil for a plain to-do.
    static func taskLine(_ c: Canvas, _ id: NodeID) -> String? {
        guard let n = c.nodes[id], let t = n.todo,
            t.isScheduled || t.owner != nil || t.progress != nil || !t.after.isEmpty
        else { return nil }
        var parts: [String] = []
        if let o = t.owner { parts.append("owner \(o)") }
        if let s = t.start { parts.append("start \(s)") }
        if let d = t.due { parts.append(t.start == nil ? "milestone \(d)" : "due \(d)") }
        if let span = c.span(of: id), !span.milestone {
            parts.append("\(span.workingDays) working day\(span.workingDays == 1 ? "" : "s")")
        }
        parts.append("\(c.progress(of: id))%")
        if let p = n.priority { parts.append("priority \(p)") }
        let after = t.after.map { d in
            "\(c.nodes[d.task]?.text ?? "?") [\(d.task.rawValue)]" + TaskText.dependencySuffix(d)
        }
        if !after.isEmpty { parts.append("after " + after.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    func addTopic(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.edit, "edit \(url.lastPathComponent)")
        var doc = try load(url)
        let cid = try Self.canvasID(args, in: doc)
        var e = CanvasEditor(doc.canvases[cid]!)
        let parent = try Self.topic(try string(args, "parent"), in: e.canvas)
        let id = try e.addChild(of: parent, text: try string(args, "text"))
        e.update(id) { n in
            n.ai = true
            if let note = args["note"]?.stringValue, !note.isEmpty { n.note = Note(text: note) }
            if let labels = args["labels"]?.arrayValue { n.labels = labels.compactMap(\.stringValue) }
        }
        var added = [id]
        for child in args["children"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !child.isEmpty {
            let k = try e.addChild(of: id, text: child)
            e.update(k) { $0.ai = true }
            added.append(k)
        }
        doc.canvases[cid] = e.canvas
        try save(doc, url)
        return Output(
            text:
                "Added “\(e.canvas.nodes[id]?.text ?? "")” [\(id.rawValue)] under “\(e.canvas.nodes[parent]?.text ?? "")”\(added.count > 1 ? " with \(added.count - 1) children (\(added.dropFirst().map(\.rawValue).joined(separator: ", ")))" : "")."
        )
    }

    func addEdge(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.edit, "edit \(url.lastPathComponent)")
        var doc = try load(url)
        let cid = try Self.canvasID(args, in: doc)
        var e = CanvasEditor(doc.canvases[cid]!)
        let from = try Self.end(try string(args, "from"), in: e.canvas)
        let to = try Self.end(try string(args, "to"), in: e.canvas)
        guard from != to else { throw ToolError("A relationship needs two different ends.") }
        let rid = e.connect(from, to: to, label: args["label"]?.stringValue ?? "")
        doc.canvases[cid] = e.canvas
        try save(doc, url)
        func title(_ end: RelationshipEnd) -> String {
            switch end {
            case .topic(let id): "“\(e.canvas.nodes[id]?.text ?? "")”"
            case .zone(let id): "zone “\(e.canvas.zones.first { $0.id == id }?.title ?? id)”"
            }
        }
        return Output(text: "Connected \(title(from)) → \(title(to)) [\(rid)].")
    }

    /// A date argument: yyyy-MM-dd, or what the Task editor accepts ("today", "+3", "fri").
    static func date(_ s: String, key: String, calendar: WorkCalendar) throws -> TaskDate {
        guard
            let d = TaskDate(s)
                ?? TaskDateParser.parse(
                    s, today: .today(), calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        else { throw ToolError("“\(s)” isn't a date for \(key); use yyyy-MM-dd.") }
        return d
    }

    func setTask(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.edit, "edit \(url.lastPathComponent)")
        var doc = try load(url)
        let cid = try Self.canvasID(args, in: doc)
        var e = CanvasEditor(doc.canvases[cid]!)
        let id = try Self.topic(try string(args, "topic"), in: e.canvas)
        let cal = e.canvas.workCalendar
        func optionalDate(_ key: String) throws -> TaskDate?? {
            guard let v = args[key] else { return nil }
            guard let s = v.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return .some(nil) }
            return .some(try Self.date(s, key: key, calendar: cal))
        }
        func int(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let v = args[key] else { return nil }
            guard case .number(let n) = v, n == n.rounded(), range.contains(Int(n)) else {
                throw ToolError("“\(key)” must be a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return Int(n)
        }
        let start = try optionalDate("start")
        var due = try optionalDate("due")
        let duration = try int("duration", 1...3650)
        let progress = try int("progress", 0...100)
        let priority = try int("priority", 0...9)
        let done = args["done"]?.boolValue
        let owner = args["owner"]?.stringValue
        var after: [TaskDependency]?
        if let list = args["after"]?.arrayValue {
            after = try list.map { item in
                guard let ref = item["topic"]?.stringValue ?? item.stringValue else {
                    throw ToolError("Each item in “after” needs a topic.")
                }
                let type = try item["type"]?.stringValue.map { t in
                    guard let k = DependencyType(rawValue: t.uppercased()) else {
                        throw ToolError("“\(t)” isn't a dependency kind; use FS, SS, FF or SF.")
                    }
                    return k
                }
                var lag = 0
                if case .number(let n)? = item["lag"] { lag = Int(max(-3650, min(3650, n.rounded()))) }
                return TaskDependency(task: try Self.topic(ref, in: e.canvas), type: type ?? .finishToStart, lag: lag)
            }
        }
        if let duration {
            guard let s = (start ?? nil) ?? e.canvas.nodes[id]?.todo?.start else {
                throw ToolError("“duration” needs a start date.")
            }
            due = .some(cal.finish(start: s, days: duration))
        }
        guard
            start != nil || due != nil || progress != nil || priority != nil || done != nil || owner != nil
                || after != nil
        else {
            throw ToolError("Nothing to change: give start, due, duration, owner, progress, priority, done or after.")
        }
        e.updateTask(id) { t in
            if let start { t.start = start }
            if let due { t.due = due }
            if let owner { t.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let progress { t.progress = progress == 0 ? nil : progress }
            if let done { t.done = done }
            if after != nil { t.after = [] }
        }
        e.update(id) { n in
            if let priority { n.priority = priority == 0 ? nil : priority }
            n.ai = true
        }
        for d in after ?? [] {
            do { try e.addDependency(id, on: d.task, type: d.type, lag: d.lag) } catch let r as TaskRefusal {
                throw ToolError("\(e.canvas.nodes[d.task]?.text ?? d.task.rawValue): \(r)")
            }
        }
        if start != nil || due != nil { e.pushDependants(of: [id]) }
        doc.canvases[cid] = e.canvas
        try save(doc, url)
        let line = Self.taskLine(e.canvas, id) ?? (e.canvas.nodes[id]?.todo?.done == true ? "done" : "to-do")
        return Output(text: "Set “\(e.canvas.nodes[id]?.text ?? "")” [\(id.rawValue)]: \(line).")
    }

    func addComment(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.edit, "edit \(url.lastPathComponent)")
        var doc = try load(url)
        let cid = try Self.canvasID(args, in: doc)
        var e = CanvasEditor(doc.canvases[cid]!)
        let id = try Self.topic(try string(args, "topic"), in: e.canvas)
        let text = try string(args, "text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("Missing “text”.") }
        let given = args["author"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = !given.isEmpty ? given : client.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent"
        let comment = TopicComment(author: "\(name) (AI)", at: Date(), text: text)
        e.update(id) { $0.comments.append(comment) }
        doc.canvases[cid] = e.canvas
        try save(doc, url)
        return Output(
            text:
                "Commented on “\(e.canvas.nodes[id]?.text ?? "")” [\(id.rawValue)] as \(comment.author) (\(e.canvas.nodes[id]?.comments.count ?? 1) comments)."
        )
    }

    func setStyle(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.edit, "edit \(url.lastPathComponent)")
        var doc = try load(url)
        let cid = try Self.canvasID(args, in: doc)
        var e = CanvasEditor(doc.canvases[cid]!)
        var changed: [String] = []
        if let t = args["topic"]?.stringValue, !t.isEmpty {
            let id = try Self.topic(t, in: e.canvas)
            let shape = args["shape"]?.stringValue
            let color = args["color"]?.stringValue
            if let color, color.wholeMatch(of: /#?[0-9a-fA-F]{6}([0-9a-fA-F]{2})?/) == nil {
                throw ToolError("“\(color)” isn't a colour; use #RRGGBB.")
            }
            guard shape != nil || color != nil else { throw ToolError("Give a shape or a color for the topic.") }
            e.update(id) { n in
                var s = n.style ?? TopicStyle()
                if let shape { s.shape = shape }
                if let color {
                    s.fillColor = color
                    s.fill = s.fill ?? "solid"
                }
                n.style = s
                n.ai = true
            }
            changed.append("topic “\(e.canvas.nodes[id]?.text ?? "")”")
        }
        let theme = args["theme"]?.stringValue
        let nodeStyle = args["node_style"]?.stringValue
        let structure = args["structure"]?.stringValue
        if theme != nil || nodeStyle != nil || structure != nil {
            e.updateMeta { c in
                if let theme { c.style.theme = theme }
                if let nodeStyle { c.style.nodeStyle = nodeStyle }
                if let structure { c.layout.structure = LayoutStructure(rawValue: structure) }
            }
            changed += [
                theme.map { "theme \($0)" }, nodeStyle.map { "node style \($0)" }, structure.map { "structure \($0)" },
            ]
            .compactMap { $0 }
        }
        guard !changed.isEmpty else {
            throw ToolError("Nothing to change: give theme, node_style, structure, or a topic with shape or color.")
        }
        doc.canvases[cid] = e.canvas
        try save(doc, url)
        return Output(text: "Set \(changed.joined(separator: ", ")).")
    }

    func convertType(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.edit, "edit \(url.lastPathComponent)")
        let doc = try load(url)
        let cid = try Self.canvasID(args, in: doc)
        let t = DiagramType(rawValue: try string(args, "type"))
        guard Self.types.contains(t) else { throw ToolError("Unknown diagram type “\(t.rawValue)”.") }
        let store = DocumentStore(model: doc)
        let c = CanvasController(store: store, canvasID: cid)
        c.prefs = .isolated()
        c.openConvert()
        c.chooseConvertType(t)
        if let proposals = c.convert?.proposals {
            c.performConvert(t, nodeTypes: proposals)
            c.closeConvert()
        }
        try save(store.model, url)
        let typed = store.model.canvases[cid]?.nodes.values.compactMap(\.nodeType).count ?? 0
        return Output(text: "Converted to \(t.displayName)\(typed > 0 ? " (\(typed) topics typed)" : "").")
    }

    func export(_ args: [String: JSONValue]) throws -> Output {
        let url = try mapURL(args)
        try permit(policy.read, "read \(url.lastPathComponent)")
        let doc = try load(url)
        let cid = try Self.canvasID(args, in: doc)
        guard let f = CLIFormat(name: try string(args, "format")) else {
            throw ToolError(
                "Unknown format. Use one of: \(CLIFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let data = f.export(doc, canvas: cid) else { throw ToolError("Couldn't export \(f.rawValue).") }
        if let out = args["out"]?.stringValue, !out.isEmpty {
            guard let target = scope.url(for: out), scope.contains(target) else {
                throw ToolError("\(out) is outside the allowed folders.")
            }
            try permit(policy.files, "create \(target.lastPathComponent)")
            do { try MapFiles.write(data, to: target) } catch { throw ToolError("Couldn't write \(out): \(error)") }
            return Output(
                text:
                    "Wrote \(target.path) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))."
            )
        }
        if f.isText { return Output(text: String(decoding: data, as: UTF8.self)) }
        if f == .png || f == .jpeg {
            return Output(content: [
                [
                    "type": "image", "data": .string(data.base64EncodedString()),
                    "mimeType": f == .png ? "image/png" : "image/jpeg",
                ]
            ])
        }
        throw ToolError("\(f.rawValue) is a binary format; give “out” to write it to a file.")
    }
}
