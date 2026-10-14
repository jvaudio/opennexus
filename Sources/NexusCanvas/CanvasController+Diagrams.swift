import AppKit
import NexusCore
import NexusKeys
import NexusLayout
import NexusTheme

// MARK: Slash menu

public enum SlashAction: Equatable, Sendable {
    case nodeType(NodeType)
    case textFormat(String)
    case todo, note, link, image, audio, sticker, label
    case boundary, summary, callout, zone
}

public struct SlashItem: Identifiable, Equatable, Sendable {
    public var id: String { slug }
    public var title: String
    public var slug: String
    public var section: String
    /// An icon id from the technical set, or a short glyph.
    public var icon: String?
    public var glyph: String
    public var action: SlashAction
}

public struct SlashState: Equatable, Sendable {
    public var node: NodeID
    public var query: String
    public var highlighted: Int = 0
    /// Opened by typing `/` at the start of an empty topic (vs. `/` in Select mode).
    public var inEditor: Bool
}

// MARK: Convert

public struct ConvertState: Equatable, Sendable {
    public enum Step: Sendable { case pick, confirm }
    public var step: Step = .pick
    public var filter = ""
    public var highlighted: DiagramType
    /// "Confirm node types": first-level branches and their (suggested or chosen) types.
    public var rows: [NodeID] = []
    public var proposals: [NodeID: NodeType] = [:]
    public var suggested: Set<NodeID> = []
    public var confirmIndex = 0
}

extension CanvasController {
    // MARK: Slash

    func slashItems() -> [SlashItem] {
        var out: [SlashItem] = []
        let type = canvas.type
        for info in DiagramCatalog.nodeTypes(for: type) {
            out.append(
                SlashItem(
                    title: info.name, slug: info.slug, section: type.displayName, icon: info.icon,
                    glyph: String(info.name.prefix(1)), action: .nodeType(info.id)))
        }
        if type != .architecture {
            // The icon slugs work everywhere (artboard 13: /client, /db …).
            for info in DiagramCatalog.icons where !out.contains(where: { $0.slug == info.slug }) {
                out.append(
                    SlashItem(
                        title: info.name, slug: info.slug, section: "Icons", icon: info.icon, glyph: "",
                        action: .nodeType(info.id)))
            }
        }
        let content: [(String, String, String, SlashAction)] = [
            ("Equation", "math", "∑", .textFormat("math")), ("Code block", "code", "{}", .textFormat("code")),
            ("Plain text", "text", "T", .textFormat("plain")), ("To-do", "todo", "☐", .todo),
            ("Note", "note", "≡", .note), ("Link", "link", "↗", .link), ("Image", "image", "▣", .image),
            ("Audio note", "audio", "♪", .audio), ("Sticker", "sticker", "☺", .sticker),
            ("Label", "label", "#", .label),
            ("Boundary", "boundary", "▢", .boundary), ("Summary", "summary", "}", .summary),
            ("Callout", "callout", "💬", .callout), ("Zone", "zone", "▭", .zone),
        ]
        for (title, slug, glyph, action) in content {
            out.append(SlashItem(title: title, slug: slug, section: "Insert", icon: nil, glyph: glyph, action: action))
        }
        return out
    }

    /// Items matching the query: slug prefix first, then title words, then anywhere.
    public var slashResults: [SlashItem] {
        guard let q = slash?.query.lowercased(), !q.isEmpty else { return slashItems() }
        let items = slashItems()
        let prefix = items.filter { $0.slug.hasPrefix(q) }
        let words = items.filter { i in
            !prefix.contains(i) && i.title.lowercased().split(separator: " ").contains { $0.hasPrefix(q) }
        }
        let rest = items.filter { i in
            !prefix.contains(i) && !words.contains(i) && (i.slug.contains(q) || i.title.lowercased().contains(q))
        }
        return prefix + words + rest
    }

    /// `/` in Select mode.
    public func openSlash() {
        selectedElement = nil
        slash = SlashState(node: selection.primary, query: "", inEditor: false)
    }

    public func closeSlash() { slash = nil }

    /// Typing `/…` at the start of an empty topic opens (and filters) the menu.
    func updateSlashFromEditor(_ text: String) {
        guard let e = edit, e.element == nil else { return }
        if text.hasPrefix("/"), !text.contains(" "), !text.contains("\n"),
            (canvas.nodes[e.node]?.text.isEmpty ?? true)
                || slash != nil || e.pendingInput == "/" || text.count <= 1
        {
            let q = String(text.dropFirst())
            if slash == nil {
                slash = SlashState(node: e.node, query: q, inEditor: true)
            } else if slash?.query != q {
                slash?.query = q
                slash?.highlighted = 0
            }
        } else if slash?.inEditor == true {
            slash = nil
        }
    }

    func handleSlashKey(_ chord: KeyChord, characters: String?) -> Bool {
        let results = slashResults
        switch chord.key {
        case .escape:
            slash = nil
            return true
        case .up:
            slash?.highlighted = max(0, (slash?.highlighted ?? 0) - 1)
            return true
        case .down:
            slash?.highlighted = min(max(results.count - 1, 0), (slash?.highlighted ?? 0) + 1)
            return true
        case .return, .tab:
            let i = slash?.highlighted ?? 0
            if i < results.count { applySlash(results[i]) } else { slash = nil }
            return true
        case .delete:
            if slash?.inEditor == false {
                if slash?.query.isEmpty ?? true { slash = nil } else { slash?.query.removeLast() }
                slash?.highlighted = 0
            }
            return slash?.inEditor == false
        default:
            guard slash?.inEditor == false, chord.modifiers.subtracting(.shift).isEmpty, let c = characters,
                !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return slash?.inEditor == false }
            slash?.query += c
            slash?.highlighted = 0
            return true
        }
    }

    /// Keys the editor routes here while the slash menu is open over it.
    public func handleEditorSlashKey(_ chord: KeyChord) -> Bool {
        guard slash?.inEditor == true else { return false }
        switch chord.key {
        case .escape, .up, .down, .return, .tab: return handleSlashKey(chord, characters: nil)
        default: return false
        }
    }

    public func applySlash(_ item: SlashItem) {
        guard let s = slash else { return }
        let id = s.node
        slash = nil
        if s.inEditor {
            // Drop the typed `/query`; the topic keeps editing.
            edit?.text = ""
            onEditorReplaceText?("")
        }
        switch item.action {
        case .nodeType(let t):
            perform("Node Type") { $0.update(id) { $0.nodeType = t } }
        case .textFormat(let f):
            perform(f == "math" ? "Equation" : f == "code" ? "Code Block" : "Plain Text") {
                $0.update(id) { $0.textFormat = f == "plain" ? nil : f }
            }
        case .todo: perform("To-do") { $0.update(id) { $0.todo = $0.todo == nil ? Todo(done: false) : nil } }
        case .note: onRequest?(.note(id))
        case .link: onRequest?(.link(id))
        case .image: onRequest?(.image(id))
        case .audio: onRequest?(.audio(id))
        case .sticker: onRequest?(.stickers(id))
        case .label: onRequest?(.labels(id))
        case .boundary: if mode == .select { addBoundary() }
        case .summary: if mode == .select { addSummary() }
        case .callout: if mode == .select { addCallout() }
        case .zone: if mode == .select { addZone() }
        }
        rebuildScene()
        onSceneChange?(true)
    }

    // MARK: Convert (⌥⌘T)

    /// The eight tiles on artboard 10, numbered 1–8.
    public static let featuredTypes: [DiagramType] = [
        .mindmap, .logic, .org, .timeline, .flowchart, .dfd, .architecture, .sequence,
    ]
    public static let moreTypes: [DiagramType] = [
        .brace, .tree, .fishbone, .matrix, .treeTable, .swimlane, .threatModel,
    ]

    public var convertResults: [DiagramType] {
        let all = Self.featuredTypes + Self.moreTypes
        guard let f = convert?.filter.lowercased(), !f.isEmpty else { return all }
        return all.filter { $0.displayName.lowercased().contains(f) || $0.rawValue.lowercased().contains(f) }
    }

    public func openConvert() {
        if mode == .edit { commitEdit() }
        if mode == .connect { cancelConnect() }
        slash = nil
        let current = canvas.type
        let first = Self.featuredTypes.first { $0 != current } ?? .mindmap
        convert = ConvertState(highlighted: first)
    }

    public func closeConvert() { convert = nil }

    func handleConvertKey(_ chord: KeyChord, characters: String?) -> Bool {
        guard var s = convert else { return false }
        if s.step == .confirm {
            switch chord.key {
            case .escape: s.step = .pick
            case .up: s.confirmIndex = max(0, s.confirmIndex - 1)
            case .down: s.confirmIndex = min(max(s.rows.count - 1, 0), s.confirmIndex + 1)
            case .left, .right:
                if s.confirmIndex < s.rows.count {
                    let row = s.rows[s.confirmIndex]
                    let options = DiagramCatalog.nodeTypes(for: s.highlighted).map(\.id)
                    let cur = options.firstIndex(of: s.proposals[row] ?? options[0]) ?? 0
                    let next = (cur + (chord.key == .left ? options.count - 1 : 1)) % max(options.count, 1)
                    s.proposals[row] = options[next]
                    s.suggested.remove(row)
                }
            case .return:
                convert = nil
                performConvert(s.highlighted, nodeTypes: s.proposals)
                return true
            default: return true
            }
            convert = s
            return true
        }
        let results = convertResults
        let i = results.firstIndex(of: s.highlighted) ?? 0
        switch chord.key {
        case .escape:
            convert = nil
            return true
        case .left: s.highlighted = results[max(0, i - 1)]
        case .right: s.highlighted = results[min(results.count - 1, i + 1)]
        case .up: s.highlighted = results[max(0, i - 4)]
        case .down: s.highlighted = results[min(results.count - 1, i + 4)]
        case .return:
            chooseConvertType(s.highlighted)
            return true
        case .delete:
            if !s.filter.isEmpty { s.filter.removeLast() }
        default:
            guard chord.modifiers.subtracting(.shift).isEmpty, let c = characters, !c.isEmpty,
                c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return true }
            if s.filter.isEmpty, let n = Int(c), n >= 1, n <= Self.featuredTypes.count {
                convert = s
                chooseConvertType(Self.featuredTypes[n - 1])
                return true
            }
            s.filter += c
            if let first = Self.filtered(s.filter).first { s.highlighted = first }
        }
        convert = s
        return true
    }

    static func filtered(_ f: String) -> [DiagramType] {
        let all = featuredTypes + moreTypes
        let q = f.lowercased()
        return q.isEmpty ? all : all.filter { $0.displayName.lowercased().contains(q) }
    }

    /// ↩ on a tile: hierarchy types convert now; technical ones confirm node types first.
    public func chooseConvertType(_ t: DiagramType) {
        guard var s = convert else { return }
        s.highlighted = t
        if DiagramCatalog.asksForNodeTypes(t) {
            let rows = canvas.nodes[canvas.root]?.children ?? []
            s.rows = rows
            s.proposals = [:]
            s.suggested = []
            for r in rows {
                guard let n = canvas.nodes[r] else { continue }
                if let existing = n.nodeType, DiagramCatalog.nodeTypes(for: t).contains(where: { $0.id == existing }) {
                    s.proposals[r] = existing
                } else {
                    s.proposals[r] = NodeTypeSuggester.suggest(n.text, for: t)
                    s.suggested.insert(r)
                }
            }
            s.confirmIndex = 0
            s.step = .confirm
            convert = s
            return
        }
        convert = nil
        performConvert(t, nodeTypes: [:])
    }

    public func setConvertProposal(_ row: NodeID, _ t: NodeType) {
        convert?.proposals[row] = t
        convert?.suggested.remove(row)
    }

    /// One undoable step; the view morphs over 600 ms (artboard 10).
    public func performConvert(_ t: DiagramType, nodeTypes: [NodeID: NodeType]) {
        morphSerial += 1
        perform("Convert to \(t.displayName)") { $0.convert(to: t, nodeTypes: nodeTypes) }
        showToast("Converted to \(t.displayName) · ⌘Z returns")
        onReveal?(selection.primary)
    }

    /// The canvas as it would look after converting (live previews).
    public func previewScene(for t: DiagramType) -> Scene {
        var editor = CanvasEditor(canvas)
        var types: [NodeID: NodeType] = [:]
        if DiagramCatalog.asksForNodeTypes(t) {
            for r in canvas.nodes[canvas.root]?.children ?? [] where canvas.nodes[r]?.nodeType == nil {
                types[r] = NodeTypeSuggester.suggest(canvas.nodes[r]?.text ?? "", for: t)
            }
        }
        editor.convert(to: t, nodeTypes: types)
        return builder.build(editor.canvas, env: styleEnvironment)
    }

    // MARK: Technical keys

    /// Tab on technical canvases. Returns true when handled.
    func techAddChild() -> Bool {
        let id = selection.primary
        let c = canvas
        switch c.type {
        case .flowchart, .swimlane:
            guard DiagramCatalog.effectiveType(id, in: c) == .decision else { return false }
            // A decision's branches open their edge label pre-filled: "Yes", then "No".
            let count = c.nodes[id]?.children.count ?? 0
            let label = count == 0 ? "Yes" : count == 1 ? "No" : ""
            guard
                let child = perform(
                    "Add Branch", selectionAfter: { Selection($0) },
                    { e -> NodeID in
                        let n = try e.addChild(of: id)
                        e.update(n) {
                            $0.edgeLabel = label.isEmpty ? nil : label
                            if c.type == .swimlane { $0.lane = c.nodes[id]?.lane }
                        }
                        return n
                    })
            else { return true }
            if label.isEmpty {
                beginEditing(child, selectAll: true)
            } else {
                selection = Selection(child)
                beginEditingElement(.relationship(FlowGraph.treeFlowID(child)))
                edit?.then = child
                onEditChange?(edit)
            }
            return true
        case .sequence:
            guard c.parent(of: id) == c.root else { return false }
            addMessage(from: id, after: nil)
            return true
        default:
            return false
        }
    }

    /// ⌥↑ / ⌥↓: move a step to the lane above or below (swimlanes).
    public func moveLane(_ delta: Int) {
        let c = canvas
        guard c.type == .swimlane, !c.diagram.lanes.isEmpty else { return }
        let lanes = c.diagram.lanes
        let ids = selection.nodes
        perform("Move to Lane") { e in
            for id in ids {
                // Effective lane: own, else inherited.
                var cur: NodeID? = id
                var lane: String?
                while let x = cur, lane == nil {
                    lane = e.canvas.nodes[x]?.lane
                    cur = e.canvas.parent(of: x)
                }
                let i = lanes.firstIndex { $0.id == lane } ?? 0
                let j = min(max(i + delta, 0), lanes.count - 1)
                e.update(id) { $0.lane = lanes[j].id }
            }
        }
    }

    /// Architecture: an edge into a newly named node defaults to its protocol.
    func defaultProtocolLabel(for id: NodeID, text: String) -> String? {
        let c = canvas
        guard c.type == .architecture, let n = c.nodes[id], n.edgeLabel == nil, let p = c.parent(of: id), p != c.root
        else { return nil }
        let t = n.nodeType ?? NodeTypeSuggester.architecture(text)
        return DiagramCatalog.defaultProtocol(for: t)
    }

    /// Suggestions under an architecture edge label while it's edited (artboard 22).
    public var protocolSuggestions: [String] {
        guard canvas.type == .architecture, let e = edit, case .relationship(let rid)? = e.element else { return [] }
        let target: NodeID? =
            rid.hasPrefix("t:") ? NodeID(String(rid.dropFirst(2))) : canvas.relationships.first { $0.id == rid }?.to
        let t = target.flatMap { DiagramCatalog.effectiveType($0, in: canvas) }
        let all = DiagramCatalog.protocolSuggestions(for: t)
        let q = e.text.lowercased()
        return q.isEmpty ? all : all.filter { $0.lowercased().hasPrefix(q) || $0.lowercased().contains(q) }
    }

    /// ↑ ↓ ↩ over the protocol suggestions; returns true when handled.
    public func handleSuggestionKey(_ chord: KeyChord) -> Bool {
        let list = protocolSuggestions
        guard !list.isEmpty, chord.modifiers.isEmpty else { return false }
        switch chord.key {
        case .down:
            suggestionIndex = min(list.count - 1, (suggestionIndex ?? -1) + 1)
            return true
        case .up:
            guard let i = suggestionIndex else { return false }
            suggestionIndex = i == 0 ? nil : i - 1
            return true
        case .return:
            guard let i = suggestionIndex, i < list.count else { return false }
            suggestionIndex = nil
            edit?.text = list[i]
            commitEdit()
            return true
        default:
            return false
        }
    }

    // MARK: Sequence

    public var sequenceParticipants: [NodeID] { canvas.nodes[canvas.root]?.children ?? [] }

    /// A message from `from` to the next participant on its right (adding one if needed),
    /// inserted after `after` in time, with its label open.
    public func addMessage(from: NodeID, to target: NodeID? = nil, after: String?, kind: String = "message") {
        let ps = sequenceParticipants
        guard let i = ps.firstIndex(of: from) else { return }
        let next: NodeID? = target ?? (i + 1 < ps.count ? ps[i + 1] : nil)
        let rid = perform("Message") { e -> String in
            let to = try next ?? e.addChild(of: e.canvas.root, text: "Participant")
            e.connect(from, to: to)
            let id = e.canvas.relationships.last!.id
            e.updateRelationship(id) {
                $0.kind = kind
                $0.line = "straight"
                $0.dash = kind == "return" ? "dashed" : "solid"
                $0.ends = ["none", kind == "return" ? "arrow" : "filled-arrow"]
                $0.color = "theme"
            }
            if let after, let ai = e.canvas.relationships.firstIndex(where: { $0.id == after }) {
                e.updateMeta { c in
                    let r = c.relationships.removeLast()
                    c.relationships.insert(r, at: ai + 1)
                }
            }
            return id
        }
        if let rid {
            beginEditingElement(.relationship(rid))
        }
    }

    /// Keys on a selected sequence message.
    func sequenceMessageKey(_ chord: KeyChord, _ id: String) -> KeyResult? {
        guard canvas.type == .sequence, let r = canvas.relationships.first(where: { $0.id == id }) else { return nil }
        let messages = Mermaid.messages(canvas)
        let i = messages.firstIndex { $0.id == id } ?? 0
        let mods = chord.modifiers
        switch chord.key {
        case .tab where mods.isEmpty:
            addMessage(from: r.to, after: id)
        case .return where mods == [.option]:
            addMessage(from: r.to, to: r.from, after: id, kind: "return")
        case .return where mods.isEmpty:
            addMessage(from: r.from, to: r.to, after: id)
        case .up where mods.isEmpty:
            if i > 0 { selectElement(.relationship(messages[i - 1].id)) }
        case .down where mods.isEmpty:
            if i + 1 < messages.count { selectElement(.relationship(messages[i + 1].id)) }
        default:
            return nil
        }
        return .handled
    }

    public func copyMermaid() {
        let text = canvas.type == .sequence ? Mermaid.sequence(canvas) : Mermaid.flowchart(canvas)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("Copied as Mermaid")
    }

    // MARK: DFD

    public var violations: [DFDRules.Violation] { scene.violations }

    /// The card shows the focused violation, else the first error.
    public var shownViolation: DFDRules.Violation? {
        let v = scene.violations.filter { $0.severity == .error }
        return v.first { $0.id == focusedViolation } ?? v.first
    }

    public func focusViolation(_ id: String?) {
        focusedViolation = id
        if let v = scene.violations.first(where: { $0.id == id }) {
            switch v.subject {
            case .flow(let f): selectElement(.relationship(f))
            case .node(let n): select(n)
            }
        }
    }

    public func applyFix(_ fix: DFDRules.Fix, violation: String) {
        let next = perform(fix == .ignore ? "Ignore Rule" : "Fix Flow") { e -> NodeID? in
            try e.apply(fix, violation: violation)
        }
        focusedViolation = nil
        if let n = next ?? nil {
            selectElement(nil)
            beginEditing(n, selectAll: true)
        }
    }

    /// ⌘. on a DFD process: open (or create) its next level.
    func drillIntoProcess() -> Bool {
        let c = canvas
        guard c.type == .dfd || c.type == .threatModel else { return false }
        let id = selection.primary
        guard DiagramCatalog.effectiveType(id, in: c) == .process, let node = c.nodes[id] else { return false }
        if let sub = node.subCanvas, store.canvas(sub) != nil {
            switchCanvas(to: sub)
            return true
        }
        let number = DFDRules.numbers(c)[id] ?? "1.0"
        let prefix = number.hasSuffix(".0") ? String(number.dropLast(2)) : number
        let newID = store.model.makeCanvasID()
        var level = Canvas(id: newID, title: "\(number) \(node.text)", type: c.type, rootText: node.text)
        level.diagram.parent = LevelLink(canvas: c.id, node: id)
        level.diagram.levelNumber = prefix
        // Seed with the process's neighbours (as context) and one sub-process.
        let g = FlowGraph(c)
        var undo = UndoStack()
        level.edit("Seed", undo: &undo) { e in
            let sub = try! e.addChild(of: e.canvas.root, text: "\(node.text) detail")
            e.update(sub) { $0.nodeType = .process }
            for f in g.flows where f.to == id || f.from == id {
                let other = f.to == id ? f.from : f.to
                guard let on = c.nodes[other], let ot = g.types[other] else { continue }
                let ctx = try! e.addChild(of: f.to == id ? e.canvas.root : sub, text: on.text)
                e.update(ctx) {
                    $0.nodeType = ot == .process ? .entity : ot
                    if f.to != id { $0.edgeLabel = f.label.isEmpty ? nil : f.label }
                }
                if f.to == id {
                    // An inbound flow feeds the sub-process.
                    e.connect(ctx, to: sub)
                    let rid = e.canvas.relationships.last!.id
                    e.updateRelationship(rid) {
                        $0.label = f.label
                        $0.line = "elbow"
                        $0.dash = "solid"
                        $0.ends = ["none", "filled-arrow"]
                    }
                }
            }
        }
        // The level canvas and the process's link to it are one undo step.
        let here = canvasID
        store.commitDocument("Drill Into Process", focus: here) { d in
            d.canvases[level.id] = level
            d.canvasOrder.append(level.id)
            d.canvases[here]?.nodes[id]?.subCanvas = newID
        }
        switchCanvas(to: newID)
        showToast("Level \(prefix) · ⌘[ climbs back")
        return true
    }

    /// Breadcrumb: Context › Level 1 › 2.0 Authorize payment.
    public var levelPath: [(id: CanvasID, title: String)] {
        var out: [(CanvasID, String)] = []
        var cur: Canvas? = canvas
        while let c = cur {
            out.insert((c.id, c.diagram.parent == nil ? "Level 1" : c.title), at: 0)
            cur = c.diagram.parent.flatMap { store.canvas($0.canvas) }
        }
        return out
    }

    /// Climb to the parent level (⌘[ on a drilled DFD).
    func climbLevel() -> Bool {
        guard let p = canvas.diagram.parent, store.canvas(p.canvas) != nil else { return false }
        switchCanvas(to: p.canvas)
        select(p.node)
        return true
    }

    // MARK: Threat model

    public var strideSuggestionsForSelection: [(Stride, String, String)] {
        guard canvas.type == .threatModel else { return [] }
        return Stride.suggestions(for: selection.primary, in: canvas)
    }

    public func acceptStride(_ s: Stride, _ title: String, _ risk: String, on element: NodeID? = nil) {
        let target = element ?? selection.primary
        perform("Add Threat") { try $0.addThreat(on: target, category: s, title: title, risk: risk, suggested: true) }
    }

    /// ⌃⇧↩ on a threat-model element: accept every suggestion.
    func acceptAllStride() -> Bool {
        let all = strideSuggestionsForSelection
        guard !all.isEmpty else { return false }
        let target = selection.primary
        perform("Accept Suggested Threats") { e in
            for (s, t, r) in all { try e.addThreat(on: target, category: s, title: t, risk: r, suggested: true) }
        }
        showToast("\(all.count) STRIDE threat\(all.count == 1 ? "" : "s") added")
        return true
    }

    /// ✦ Suggest STRIDE threats across the canvas (the toolbar button).
    public func suggestStrideEverywhere() {
        let g = FlowGraph(canvas)
        var added = 0
        let c = canvas
        perform("Suggest STRIDE Threats") { e in
            for id in g.elements where [.process, .store, .entity].contains(g.types[id] ?? "") {
                for (s, t, r) in Stride.suggestions(for: id, in: c) {
                    try e.addThreat(on: id, category: s, title: t, risk: r, suggested: true)
                    added += 1
                }
            }
        }
        showToast(added == 0 ? "Every element is covered" : "✦ \(added) threats suggested")
    }

    public func setThreatField(_ id: NodeID, _ key: String, _ value: String) {
        perform("Threat") { $0.setThreatField(id, key, value) }
    }

    public func toggleColorByRisk() {
        perform("Colour by Risk") { $0.updateMeta { $0.diagram.colorByRisk.toggle() } }
    }

    public var threats: [Stride.Threat] { Stride.threats(canvas) }

    public func exportThreatsCSV(_ rows: [Stride.Threat]) {
        onSaveText?("\(canvas.title) threats.csv", Stride.csv(rows))
    }

    public func copyThreatsMarkdown(_ rows: [Stride.Threat]) {
        pasteboard.clearContents()
        pasteboard.setString(Stride.markdown(rows), forType: .string)
        showToast("Copied threat table as Markdown")
    }

    // MARK: Icon library (⇧⌘Y)

    /// ↩ in the library: insert as a child of the selection.
    public func insertIcon(_ info: NodeTypeInfo) {
        let parent = selection.primary
        let label = canvas.type == .architecture ? DiagramCatalog.defaultProtocol(for: info.id) : nil
        let c = canvas
        if let id = perform(
            "Insert \(info.name)", selectionAfter: { Selection($0) },
            { e -> NodeID in
                let n = try e.addChild(of: parent, text: info.name.lowercased())
                e.update(n) {
                    $0.nodeType = info.id
                    if parent != c.root { $0.edgeLabel = label }
                }
                return n
            })
        {
            beginEditing(id, selectAll: true)
        }
    }
}
