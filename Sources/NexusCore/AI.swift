import Foundation

// MARK: Availability (artboard 29)

/// Whether the on-device model can run, and what to tell the user when it can't.
public enum AIAvailability: Equatable, Sendable {
    case ready
    case working
    /// Apple Intelligence is turned off in System Settings.
    case off
    /// The model is still downloading.
    case downloading
    case unsupported

    public var canRun: Bool { self == .ready || self == .working }

    /// The toolbar chip: "Apple on-device · ready".
    public var chip: String {
        switch self {
        case .ready: "Apple on-device · ready"
        case .working: "Apple on-device · working"
        case .off: "AI off"
        case .downloading: "Apple on-device · downloading"
        case .unsupported: "AI unavailable"
        }
    }

    /// The one-line explanation shown in place of a result.
    public var explanation: String {
        switch self {
        case .off: "Apple Intelligence is off, so ghost ideas can’t run."
        case .downloading: "The on-device model is still downloading. Ideas will work when it’s ready."
        case .unsupported: "This Mac can’t run Apple’s on-device model."
        default: ""
        }
    }
}

// MARK: Map context

/// What the model sees: an indented outline of the canvas or a branch.
public enum MapContext {
    public enum Depth: String, Sendable, CaseIterable {
        case quick, balanced, deep

        public var title: String { rawValue.capitalized }
        /// How many levels and characters of context the model gets.
        var maxDepth: Int { self == .quick ? 2 : self == .balanced ? 4 : 12 }
        var maxCharacters: Int { self == .quick ? 1200 : self == .balanced ? 3500 : 9000 }
        var includeNotes: Bool { self != .quick }
    }

    /// An outline like:
    ///
    ///     - Growth 2027
    ///       - Onboarding
    ///         - Welcome email
    /// `notes: false` keeps notes out (Settings › Privacy & Data › Let AI read notes).
    public static func outline(_ c: Canvas, from top: NodeID? = nil, depth: Depth = .balanced, notes: Bool = true)
        -> String
    {
        var lines: [String] = []
        var count = 0
        func walk(_ id: NodeID, _ d: Int) {
            guard let n = c.nodes[id], d <= depth.maxDepth, count < depth.maxCharacters else { return }
            var line = String(repeating: "  ", count: d) + "- " + n.text.replacingOccurrences(of: "\n", with: " ")
            if !n.labels.isEmpty { line += " [\(n.labels.joined(separator: ", "))]" }
            if let t = n.todo { line += t.done ? " (done)" : " (to-do)" }
            lines.append(line)
            count += line.count
            if notes, depth.includeNotes, let note = n.note?.text, !note.isEmpty {
                let short = note.prefix(240).replacingOccurrences(of: "\n", with: " ")
                lines.append(String(repeating: "  ", count: d + 1) + "note: " + short)
                count += short.count
            }
            for k in n.children { walk(k, d + 1) }
        }
        walk(top ?? c.root, 0)
        if top == nil {
            for f in c.floating { walk(f, 0) }
        }
        return lines.joined(separator: "\n")
    }

    /// "Growth 2027 › Onboarding" — the path that anchors a request.
    public static func path(_ c: Canvas, to id: NodeID) -> String {
        (c.path(to: id) + [id]).compactMap { c.nodes[$0]?.text }.joined(separator: " › ")
    }

    /// `@Churn` references in a question, resolved to nodes by text.
    public static func references(in text: String, canvas c: Canvas) -> [NodeID] {
        var out: [NodeID] = []
        let pattern = try? NSRegularExpression(pattern: "@([\\p{L}\\p{N}][\\p{L}\\p{N} _·&-]*)")
        let ns = text as NSString
        for m in pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            // Longest topic whose text starts the reference.
            let hit = c.nodes.filter { name.hasPrefix($0.value.text.lowercased()) && !$0.value.text.isEmpty }
                .max { $0.value.text.count < $1.value.text.count }
            if let hit, !out.contains(hit.key) { out.append(hit.key) }
        }
        return out
    }
}

// MARK: Change plans (artboard 28, "Proposed change")

/// A reviewable set of edits: the diff the panel shows before "Apply · one undo".
public struct ChangePlan: Hashable, Sendable, JSONRepresentable {
    public enum Op: Hashable, Sendable {
        /// Add `text` under `parent` (a node), or under the plan's add at `parentAdd`.
        case add(parent: NodeID?, parentAdd: Int?, text: String, markers: [String], labels: [String], todo: Bool)
        case rename(NodeID, from: String, to: String)
        case note(NodeID, String)
        case move(NodeID, toParent: NodeID)
        case todo(NodeID)
    }

    public var summary: String
    public var ops: [Op]

    public init(summary: String = "", ops: [Op] = []) {
        self.summary = summary
        self.ops = ops
    }

    public var isEmpty: Bool { ops.isEmpty }

    /// "+3 · ~1"
    public func counts() -> String {
        let adds = ops.filter { if case .add = $0 { true } else { false } }.count
        let changes = ops.count - adds
        return [adds > 0 ? "+\(adds)" : nil, changes > 0 ? "~\(changes)" : nil].compactMap { $0 }.joined(
            separator: " · ")
    }

    /// Diff lines: "+ Churn › Win-back email", "~ “Churn” → “Retention & churn”".
    public func lines(in c: Canvas) -> [String] {
        var addText: [String] = []
        return ops.map { op in
            switch op {
            case .add(let p, let pa, let text, _, _, _):
                addText.append(text)
                let parentName =
                    p.flatMap { c.nodes[$0]?.text } ?? pa.flatMap { $0 < addText.count ? addText[$0] : nil } ?? "?"
                return "+ \(parentName) › \(text)"
            case .rename(_, let from, let to): return "~ “\(from)” → “\(to)”"
            case .note(let id, _): return "~ note on \(c.nodes[id]?.text ?? "?")"
            case .move(let id, let p): return "~ move \(c.nodes[id]?.text ?? "?") under \(c.nodes[p]?.text ?? "?")"
            case .todo(let id): return "~ \(c.nodes[id]?.text ?? "?") becomes a to-do"
            }
        }
    }

    /// Applies every op as part of one edit. New topics are marked AI-created (✦).
    @discardableResult
    public func apply(in e: inout CanvasEditor, markAI: Bool = true) throws -> [NodeID] {
        var added: [NodeID] = []
        for op in ops {
            switch op {
            case .add(let p, let pa, let text, let markers, let labels, let todo):
                let parent = p ?? pa.flatMap { $0 < added.count ? added[$0] : nil } ?? e.canvas.root
                guard e[parent] != nil else { continue }
                let n = try e.addChild(of: parent, text: text)
                e.update(n) {
                    $0.ai = markAI
                    $0.markers = markers
                    $0.labels = labels
                    if todo { $0.todo = Todo(done: false) }
                }
                added.append(n)
            case .rename(let id, _, let to):
                guard e[id] != nil else { continue }
                e.update(id) {
                    $0.text = to
                    $0.ai = markAI
                }
            case .note(let id, let text):
                e.update(id) { $0.note = Note(text: text) }
            case .move(let id, let p):
                try? e.move(id, toParent: p)
            case .todo(let id):
                e.update(id) { if $0.todo == nil { $0.todo = Todo(done: false) } }
            }
        }
        return added
    }

    // JSON (plans are kept in chats).
    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        summary = try r.optionalString("summary") ?? ""
        ops = try r.array("ops").enumerated().compactMap { i, v in
            var o = try ObjectReader(v, path: "\(path).ops[\(i)]")
            let kind = try o.string("op")
            switch kind {
            case "add":
                return .add(
                    parent: try o.optionalString("parent").map(NodeID.init(rawValue:)),
                    parentAdd: try o.optionalDouble("parentAdd").map { Int($0) }, text: try o.string("text"),
                    markers: try o.strings("markers"), labels: try o.strings("labels"),
                    todo: try o.bool("todo", default: false))
            case "rename":
                return .rename(
                    NodeID(try o.string("node")), from: try o.optionalString("from") ?? "", to: try o.string("to"))
            case "note": return .note(NodeID(try o.string("node")), try o.string("text"))
            case "move": return .move(NodeID(try o.string("node")), toParent: NodeID(try o.string("parent")))
            case "todo": return .todo(NodeID(try o.string("node")))
            default: return nil
            }
        }
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: [:])
        w.set("summary", summary)
        w.set(
            "ops",
            .array(
                ops.map { op in
                    var o = ObjectWriter(extra: [:])
                    switch op {
                    case .add(let p, let pa, let text, let markers, let labels, let todo):
                        o.set("op", "add")
                        o.set("parent", p?.rawValue)
                        o.set("parentAdd", pa.map(Double.init))
                        o.set("text", text)
                        o.set("markers", markers, omitEmpty: true)
                        o.set("labels", labels, omitEmpty: true)
                        o.set("todo", todo, omitting: false)
                    case .rename(let id, let from, let to):
                        o.set("op", "rename")
                        o.set("node", id.rawValue)
                        o.set("from", from)
                        o.set("to", to)
                    case .note(let id, let text):
                        o.set("op", "note")
                        o.set("node", id.rawValue)
                        o.set("text", text)
                    case .move(let id, let p):
                        o.set("op", "move")
                        o.set("node", id.rawValue)
                        o.set("parent", p.rawValue)
                    case .todo(let id):
                        o.set("op", "todo")
                        o.set("node", id.rawValue)
                    }
                    return o.value
                }))
        return w.value
    }
}

// MARK: Chats (artboard 28 / 52)

public struct AIMessage: Hashable, Sendable, JSONRepresentable {
    public var role: String  // user | assistant
    public var text: String
    public var plan: ChangePlan?
    public var applied: Bool = false

    public init(role: String, text: String, plan: ChangePlan? = nil) {
        self.role = role
        self.text = text
        self.plan = plan
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        role = try r.optionalString("role") ?? "user"
        text = try r.optionalString("text") ?? ""
        if let p = r.raw("plan"), p != .null { plan = try ChangePlan(json: p, path: "\(path).plan") }
        applied = try r.bool("applied", default: false)
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: [:])
        w.set("role", role)
        w.set("text", text)
        if let plan { w.set("plan", plan.json) }
        w.set("applied", applied, omitting: false)
        return w.value
    }
}

public struct AIChat: Hashable, Sendable, Identifiable, JSONRepresentable {
    public var id: String
    public var title: String
    /// The canvas the chat is about.
    public var canvas: CanvasID?
    public var depth: MapContext.Depth = .balanced
    /// Discussion mode: the model answers but never proposes edits.
    public var discussion = false
    public var messages: [AIMessage] = []
    public var extra: [String: JSONValue] = [:]

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        id = try r.string("id")
        title = try r.optionalString("title") ?? "Chat"
        canvas = try r.optionalString("canvas").map(CanvasID.init(rawValue:))
        depth = MapContext.Depth(rawValue: try r.optionalString("depth") ?? "balanced") ?? .balanced
        discussion = try r.bool("discussion", default: false)
        messages = try r.array("messages").enumerated().map { try AIMessage(json: $1, path: "\(path).messages[\($0)]") }
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("id", id)
        w.set("title", title)
        w.set("canvas", canvas?.rawValue)
        if depth != .balanced { w.set("depth", depth.rawValue) }
        w.set("discussion", discussion, omitting: false)
        w.set("messages", .array(messages.map(\.json)))
        return w.value
    }
}

// MARK: Actions (⌘K, panel chips, prompt bar)

public enum AIAction: String, Sendable, CaseIterable {
    case ideas, expand, findGaps, rewrite, summarize, reorganize, generateMap, importToMap, describeToDiagram
    case threats, explain, writeUp, diagramAsCode, breakdown, todos, sprintPlan

    public var title: String {
        switch self {
        case .ideas: "Suggest ideas"
        case .expand: "Expand branch"
        case .findGaps: "Find gaps"
        case .rewrite: "Rewrite shorter"
        case .summarize: "Summarize"
        case .reorganize: "Reorganize"
        case .generateMap: "Generate map"
        case .importToMap: "Import to map"
        case .describeToDiagram: "Describe to diagram"
        case .threats: "Threat suggestions"
        case .explain: "Explain"
        case .writeUp: "Write it up"
        case .diagramAsCode: "Diagram as code"
        case .breakdown: "Break down"
        case .todos: "Make to-dos"
        case .sprintPlan: "Expand into a sprint plan"
        }
    }

    public enum Output: Sendable { case ghosts, plan, text }

    public var output: Output {
        switch self {
        case .ideas, .expand, .findGaps, .breakdown, .todos, .sprintPlan, .threats: .ghosts
        case .rewrite, .reorganize, .generateMap, .importToMap, .describeToDiagram: .plan
        case .summarize, .explain, .writeUp, .diagramAsCode: .text
        }
    }

    /// The panel's action chips (artboard 28), in order.
    public static let panel: [AIAction] = [
        .generateMap, .expand, .rewrite, .summarize, .reorganize, .findGaps, .importToMap, .describeToDiagram,
        .threats, .explain, .writeUp, .diagramAsCode,
    ]
}

/// One ghost suggestion: a child to add, with optional markers, labels, a to-do box and,
/// from a work breakdown, task dates (M22, D209).
public struct GhostIdea: Hashable, Sendable {
    public var text: String
    public var markers: [String] = []
    public var labels: [String] = []
    public var todo = false
    /// A sub-step under the ghost at this index (work breakdown).
    public var parentGhost: Int?
    /// Task dates and length in working days, when the model's plan has them.
    public var start: TaskDate?
    public var due: TaskDate?
    public var workingDays: Int?

    public init(
        text: String, markers: [String] = [], labels: [String] = [], todo: Bool = false, parentGhost: Int? = nil,
        start: TaskDate? = nil, due: TaskDate? = nil, workingDays: Int? = nil
    ) {
        self.text = text
        self.markers = markers
        self.labels = labels
        self.todo = todo
        self.parentGhost = parentGhost
        self.start = start
        self.due = due
        self.workingDays = workingDays
    }

    /// True when accepting it makes a to-do (a task when it has dates or a length).
    public var isTask: Bool { todo || start != nil || due != nil || workingDays != nil }

    /// Fills in the dates a plan implies, on `calendar`: a length with a start gives the
    /// due date (and with a due date, the start), and a phase with only a length starts the
    /// working day after the dated phase before it at the same level. Anything else stays
    /// as it is, so an undated plan makes undated tasks.
    public static func scheduled(_ ideas: [GhostIdea], calendar cal: WorkCalendar) -> [GhostIdea] {
        var out = ideas
        var lastDue: [Int: TaskDate] = [:]  // by parentGhost (-1 for top-level ghosts)
        for i in out.indices {
            var g = out[i]
            let level = g.parentGhost ?? -1
            let days = g.workingDays.map { max(1, $0) }
            if g.start == nil, g.due == nil, days != nil, let prev = lastDue[level] {
                g.start = cal.shift(prev, by: 1)
            }
            if let s = g.start, g.due == nil, let days {
                g.due = cal.finish(start: s, days: days)
            } else if g.start == nil, let d = g.due, let days, days > 1 {
                g.start = cal.shift(cal.snapBack(d), by: -(days - 1))
            }
            if let s = g.start, let d = g.due, d < s { g.due = s }
            if let d = g.due { lastDue[level] = d }
            out[i] = g
        }
        return out
    }
}

/// What a request is about.
public struct AIRequest: Sendable {
    public var action: AIAction
    /// Free text: the prompt bar's instruction, a chat question, or pasted text to import.
    public var prompt: String
    public var outline: String
    public var anchorPath: String
    public var anchorText: String
    public var existingChildren: [String]
    public var depth: MapContext.Depth
    public var discussion: Bool
    public var history: [AIMessage]

    public init(
        action: AIAction, prompt: String = "", outline: String = "", anchorPath: String = "", anchorText: String = "",
        existingChildren: [String] = [], depth: MapContext.Depth = .balanced, discussion: Bool = false,
        history: [AIMessage] = []
    ) {
        self.action = action
        self.prompt = prompt
        self.outline = outline
        self.anchorPath = anchorPath
        self.anchorText = anchorText
        self.existingChildren = existingChildren
        self.depth = depth
        self.discussion = discussion
        self.history = history
    }
}

/// A model's draft of edits, before node ids are resolved.
public struct PlanDraft: Sendable, Equatable {
    public struct Add: Sendable, Equatable {
        public var parent: String
        public var text: String
        public init(parent: String, text: String) {
            self.parent = parent
            self.text = text
        }
    }
    public struct Rename: Sendable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }
    public var answer: String
    public var adds: [Add]
    public var renames: [Rename]

    public init(answer: String, adds: [Add] = [], renames: [Rename] = []) {
        self.answer = answer
        self.adds = adds
        self.renames = renames
    }

    /// Resolves topic names to ids (adds under unknown parents go under the anchor, or under
    /// an earlier add with that name).
    public func plan(in c: Canvas, anchor: NodeID) -> ChangePlan {
        func find(_ name: String) -> NodeID? {
            let n = name.trimmingCharacters(in: .whitespaces).lowercased()
            return c.nodes.first { $0.value.text.lowercased() == n }?.key
        }
        var ops: [ChangePlan.Op] = []
        var addNames: [String] = []
        for a in adds {
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let i = addNames.firstIndex(where: { $0.lowercased() == a.parent.lowercased() }) {
                ops.append(.add(parent: nil, parentAdd: i, text: text, markers: [], labels: [], todo: false))
            } else {
                ops.append(
                    .add(
                        parent: find(a.parent) ?? anchor, parentAdd: nil, text: text, markers: [], labels: [],
                        todo: false))
            }
            addNames.append(text)
        }
        for r in renames {
            guard let id = find(r.from), !r.to.isEmpty, r.to != c.nodes[id]?.text else { continue }
            ops.append(.rename(id, from: c.nodes[id]?.text ?? r.from, to: r.to))
        }
        return ChangePlan(summary: answer, ops: ops)
    }
}

/// The model behind every AI feature. Implementations: `AppleEngine` (NexusAI), and
/// `ScriptedEngine` for tests.
public protocol AIEngine: Sendable {
    /// Current availability (cheap; checked before every request).
    var availability: AIAvailability { get }
    /// Load the model ahead of the first request.
    func prewarm()
    /// Ghost ideas, streamed one at a time as they arrive.
    func ideas(_ request: AIRequest) -> AsyncThrowingStream<GhostIdea, any Error>
    /// A plan of changes (or, in Discussion mode, an answer with no edits).
    func draft(_ request: AIRequest) async throws -> PlanDraft
    /// A text answer (summaries, explanations, write-ups), streamed.
    func text(_ request: AIRequest) -> AsyncThrowingStream<String, any Error>
}

/// Deterministic engine for tests and previews: answers from fixed tables.
public struct ScriptedEngine: AIEngine {
    public var availability: AIAvailability
    public var ideasByAnchor: [String: [GhostIdea]]
    public var drafts: [String: PlanDraft]
    public var defaultIdeas: [GhostIdea]
    public var delay: Duration

    public init(
        availability: AIAvailability = .ready, ideas: [String: [GhostIdea]] = [:], drafts: [String: PlanDraft] = [:],
        defaultIdeas: [GhostIdea] = [
            GhostIdea(text: "Idea one"), GhostIdea(text: "Idea two"), GhostIdea(text: "Idea three"),
        ],
        delay: Duration = .milliseconds(5)
    ) {
        self.availability = availability
        self.ideasByAnchor = ideas
        self.drafts = drafts
        self.defaultIdeas = defaultIdeas
        self.delay = delay
    }

    public func prewarm() {}

    public func ideas(_ r: AIRequest) -> AsyncThrowingStream<GhostIdea, any Error> {
        let list = ideasByAnchor[r.anchorText] ?? defaultIdeas
        let delay = delay
        return AsyncThrowingStream { c in
            Task {
                for i in list {
                    try? await Task.sleep(for: delay)
                    c.yield(i)
                }
                c.finish()
            }
        }
    }

    public func draft(_ r: AIRequest) async throws -> PlanDraft {
        try? await Task.sleep(for: delay)
        let d = drafts[r.prompt] ?? drafts[r.anchorText] ?? PlanDraft(answer: "No changes suggested.")
        return r.discussion ? PlanDraft(answer: d.answer) : d
    }

    public func text(_ r: AIRequest) -> AsyncThrowingStream<String, any Error> {
        let d = drafts[r.prompt]?.answer ?? "Summary of \(r.anchorText)."
        return AsyncThrowingStream { c in
            c.yield(d)
            c.finish()
        }
    }
}

extension DocumentModel {
    public func makeChatID() -> String {
        var i = chats.count + 1
        while chats.contains(where: { $0.id == "chat\(i)" }) { i += 1 }
        return "chat\(i)"
    }
}
