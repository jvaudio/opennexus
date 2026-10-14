import AppKit
import NexusAI
import NexusCore
import NexusKeys

public struct GhostState: Equatable, Sendable {
    public var anchor: NodeID
    public var ideas: [GhostIdea] = []
    public var highlighted = 0
    public var loading = true
    public var action: AIAction
    /// "Breaking down…" while the work breakdown runs.
    public var label: String?
}

public struct PromptBarState: Equatable, Sendable {
    public var anchor: NodeID
    public var text = ""
}

extension CanvasController {
    /// Ghost ids in the scene: `ghost:<index>`.
    public static func ghostID(_ i: Int) -> NodeID { NodeID("ghost:\(i)") }
    public static func ghostIndex(_ id: NodeID) -> Int? {
        id.rawValue.hasPrefix("ghost:") ? Int(id.rawValue.dropFirst(6)) : nil
    }

    /// Checks the model before every entry point; when it can't run, the reason shows in
    /// place (artboard 29) and nothing else happens.
    @discardableResult
    func aiCanRun() -> Bool {
        aiAvailability = ai.availability
        guard aiAvailability.canRun else {
            aiNotice = aiAvailability.explanation
            onSceneChange?(true)
            return false
        }
        aiNotice = nil
        return true
    }

    public func dismissAINotice() { aiNotice = nil }

    func request(_ action: AIAction, anchor: NodeID, prompt: String = "", depth: MapContext.Depth = .balanced)
        -> AIRequest
    {
        let c = canvas
        let n = c.nodes[anchor]
        return AIRequest(
            action: action, prompt: prompt,
            outline: MapContext.outline(c, depth: depth, notes: prefs.bool("privacy.aiReadNotes")),
            anchorPath: MapContext.path(c, to: anchor), anchorText: n?.text ?? "",
            existingChildren: (n?.children ?? []).compactMap { c.nodes[$0]?.text }, depth: depth)
    }

    // MARK: Ghosts (⌥Space)

    /// Streams ideas under the selection; each arrives as a ghost (250 ms in).
    public func requestGhosts(_ action: AIAction = .ideas, prompt: String = "", label: String? = nil) {
        if mode == .edit { commitEdit() }
        guard aiCanRun() else { return }
        let anchor = selection.primary
        let req = request(action, anchor: anchor, prompt: prompt)
        aiTask?.cancel()
        ghosts = GhostState(anchor: anchor, action: action, label: label)
        aiAvailability = .working
        let start = Date()
        lastGhostLatency = nil
        refreshView()
        let engine = ai
        aiTask = Task { @MainActor [weak self] in
            do {
                for try await idea in engine.ideas(req) {
                    guard let self, self.ghosts?.anchor == anchor else { return }
                    if self.lastGhostLatency == nil { self.lastGhostLatency = Date().timeIntervalSince(start) }
                    // No duplicates of existing children or earlier ghosts.
                    let existing = Set(
                        (self.canvas.nodes[anchor]?.children ?? []).compactMap {
                            self.canvas.nodes[$0]?.text.lowercased()
                        })
                    let lower = idea.text.lowercased()
                    guard !existing.contains(lower),
                        !(self.ghosts?.ideas.contains { $0.text.lowercased() == lower } ?? false)
                    else { continue }
                    self.ghosts?.ideas.append(idea)
                    self.refreshView()
                }
                self?.ghosts?.loading = false
                if self?.ghosts?.ideas.isEmpty == true {
                    self?.ghosts = nil
                    self?.showToast("No new ideas for this topic")
                }
            } catch {
                self?.ghosts = nil
                if !(error is CancellationError) { self?.showToast(error.localizedDescription) }
            }
            self?.aiAvailability = engine.availability
            self?.refreshView()
        }
    }

    /// Settings › AI › “Suggest ideas after a pause when creating nodes” (off by default):
    /// 1.5 s after a new topic is named, with nothing else changed, ghosts appear under it.
    /// When the model can't run this stays silent; the explicit entry points explain why.
    func scheduleIdleSuggestion(for id: NodeID, after delay: Duration = .milliseconds(1500)) {
        idleSuggestion?.cancel()
        guard prefs.bool(AISettingsKeys.suggestAfterPause), ai.availability.canRun else {
            return
        }
        let before = canvas
        idleSuggestion = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.mode == .select, self.edit == nil, self.ghosts == nil,
                self.selection.primary == id, self.canvas == before
            else { return }
            self.requestGhosts(.ideas)
        }
    }

    /// Stop (the "Breaking down… Stop" chip).
    public func stopAI() {
        aiTask?.cancel()
        aiTask = nil
        ghosts?.loading = false
        aiBusy = nil
        aiStreaming = nil
        aiAvailability = ai.availability
        if ghosts?.ideas.isEmpty == true { ghosts = nil }
        refreshView()
    }

    public func dismissGhosts() {
        aiTask?.cancel()
        ghosts = nil
        previewPlan = nil
        aiAvailability = ai.availability
        refreshView()
    }

    /// ⌃↩: accept the highlighted ghost (one undo).
    public func acceptGhost(_ index: Int? = nil) {
        guard let g = ghosts else { return }
        let i = index ?? g.highlighted
        guard i < g.ideas.count else { return }
        // A phase brings its sub-steps along.
        let take = [i] + g.ideas.indices.filter { g.ideas[$0].parentGhost == i }
        accept(take, from: g)
    }

    /// ⌃⇧↩: accept every ghost (one undo).
    public func acceptAllGhosts() {
        guard let g = ghosts else { return }
        accept(Array(g.ideas.indices), from: g)
    }

    /// Settings › AI › “Mark AI-created nodes with ✦ until edited” (on unless turned off).
    var markAI: Bool { prefs.bool(AISettingsKeys.markAI) }

    func accept(_ indices: [Int], from g: GhostState) {
        let markAI = markAI
        let ideas = g.ideas
        var created: [Int: NodeID] = [:]
        let made = perform(ideas.count == indices.count ? "Accept Suggestions" : "Accept Suggestion") { e -> [NodeID] in
            var out: [NodeID] = []
            for i in indices.sorted() {
                let idea = ideas[i]
                let parent = idea.parentGhost.flatMap { created[$0] } ?? g.anchor
                let n = try e.addChild(of: parent, text: idea.text)
                e.update(n) {
                    $0.ai = markAI
                    $0.markers = idea.markers
                    $0.labels = idea.labels
                    if idea.todo { $0.todo = Todo(done: false) }
                }
                created[i] = n
                out.append(n)
            }
            return out
        }
        // Remaining ghosts re-index after the accepted ones leave.
        var rest = ghosts?.ideas ?? []
        for i in indices.sorted(by: >) where i < rest.count { rest.remove(at: i) }
        if rest.isEmpty || indices.count == ideas.count {
            ghosts = nil
        } else {
            ghosts?.ideas = rest.map {
                var x = $0; x.parentGhost = nil; return x
            }
            ghosts?.highlighted = min(g.highlighted, rest.count - 1)
        }
        if let first = made?.first, ghosts == nil { select(first) }
        refreshView()
    }

    /// ↑↓ browse, ⌃↩ accept, ⌃⇧↩ accept all, Esc dismiss. Other keys pass through
    /// (typing ignores ghosts).
    func handleGhostKey(_ chord: KeyChord) -> Bool {
        guard var g = ghosts, mode == .select else { return false }
        switch (chord.key, chord.modifiers) {
        case (.up, []):
            g.highlighted = max(0, g.highlighted - 1)
        case (.down, []):
            g.highlighted = min(max(g.ideas.count - 1, 0), g.highlighted + 1)
        case (.escape, []):
            dismissGhosts()
            return true
        default:
            return false
        }
        ghosts = g
        refreshView()
        return true
    }

    // MARK: Prompt bar (⇧⌘Space)

    public func openPromptBar() {
        if mode == .edit { commitEdit() }
        guard aiCanRun() else { return }
        promptBar = PromptBarState(anchor: selection.primary)
        ai.prewarm()
        onSceneChange?(true)
    }

    public func closePromptBar() {
        promptBar = nil
        onRestoreFocus?()
        onSceneChange?(true)
    }

    public static let promptChips: [(String, AIAction)] = [
        ("Expand into a sprint plan", .sprintPlan), ("Find gaps", .findGaps), ("Rewrite shorter", .rewrite),
        ("Summarize", .summarize),
    ]

    /// Runs the prompt bar's text (or a chip). Results arrive as ghosts or a plan in the
    /// panel; nothing is applied silently.
    public func submitPrompt(_ text: String, action: AIAction? = nil) {
        guard let bar = promptBar else { return }
        promptBar = nil
        onRestoreFocus?()
        select(bar.anchor)
        let t = text.trimmingCharacters(in: .whitespaces)
        // "Turn this branch into a DFD" opens Convert on the chosen type.
        if action == nil, let type = Self.conversionTarget(t) {
            openConvert()
            chooseConvertType(type)
            return
        }
        let a = action ?? .ideas
        switch a.output {
        case .ghosts: requestGhosts(a, prompt: t, label: a == .breakdown || a == .sprintPlan ? "Breaking down…" : nil)
        case .plan, .text:
            aiPanelVisible = true
            ask(t.isEmpty ? a.title : t, action: a)
        }
    }

    static func conversionTarget(_ t: String) -> DiagramType? {
        let l = t.lowercased()
        guard l.contains("into a") || l.contains("into an") || l.hasPrefix("convert") else { return nil }
        let table: [(String, DiagramType)] = [
            ("dfd", .dfd), ("data flow", .dfd), ("flowchart", .flowchart), ("architecture", .architecture),
            ("sequence", .sequence), ("threat", .threatModel), ("org chart", .org), ("timeline", .timeline),
            ("fishbone", .fishbone), ("swimlane", .swimlane), ("mind map", .mindmap), ("logic", .logic),
        ]
        return table.first { l.contains($0.0) }?.1
    }

    // MARK: AI panel (⇧⌘J)

    public var chats: [AIChat] { store.model.chats.filter { $0.canvas == nil || $0.canvas == canvasID } }

    public var currentChat: AIChat? {
        chats.first { $0.id == activeChat } ?? chats.last
    }

    public func toggleAIPanel() {
        aiPanelVisible.toggle()
        if aiPanelVisible {
            aiAvailability = ai.availability
            ai.prewarm()
        }
    }

    @discardableResult
    public func newChat(title: String = "New chat") -> String {
        let id = store.model.makeChatID()
        var chat = AIChat(id: id, title: title)
        chat.canvas = canvasID
        chat.discussion = prefs.bool(AISettingsKeys.discussionDefault)
        chat.depth =
            MapContext.Depth(rawValue: prefs.string(AISettingsKeys.depth)) ?? .balanced
        store.updateDocument { $0.chats.append(chat) }
        activeChat = id
        return id
    }

    func updateChat(_ id: String, _ body: (inout AIChat) -> Void) {
        store.updateDocument { d in
            if let i = d.chats.firstIndex(where: { $0.id == id }) { body(&d.chats[i]) }
        }
    }

    public func selectChat(_ id: String) { activeChat = id }

    public func setChatDepth(_ d: MapContext.Depth) {
        guard let c = currentChat else { return }
        updateChat(c.id) { $0.depth = d }
    }

    public func setDiscussion(_ on: Bool) {
        let id = currentChat?.id ?? newChat()
        updateChat(id) { $0.discussion = on }
    }

    /// Ask in the panel. `@Topic` references anchor the question; plans come back as a
    /// proposed change card (never applied without Apply).
    public func ask(_ question: String, action: AIAction? = nil) {
        guard aiCanRun() else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || action != nil else { return }
        let chatID = currentChat?.id ?? newChat(title: String(q.prefix(32)))
        guard let chat = chats.first(where: { $0.id == chatID }) else { return }
        if chat.messages.isEmpty, chat.title == "New chat" { updateChat(chatID) { $0.title = String(q.prefix(32)) } }
        updateChat(chatID) { $0.messages.append(AIMessage(role: "user", text: q)) }
        let refs = MapContext.references(in: q, canvas: canvas)
        let anchor = refs.first ?? selection.primary
        // A free question gets an answer and, outside Discussion, a proposed change.
        let textOnly = action?.output == .text
        var req = request(action ?? .explain, anchor: anchor, prompt: q, depth: chat.depth)
        req.discussion = chat.discussion
        req.history = chat.messages
        let engine = ai
        aiBusy = action?.title ?? "Thinking"
        aiAvailability = .working
        aiTask?.cancel()
        aiTask = Task { @MainActor [weak self] in
            defer {
                self?.aiBusy = nil
                self?.aiStreaming = nil
                self?.aiAvailability = engine.availability
            }
            do {
                if textOnly {
                    var answer = ""
                    for try await part in engine.text(req) {
                        answer = part
                        self?.aiStreaming = answer
                    }
                    self?.updateChat(chatID) { $0.messages.append(AIMessage(role: "assistant", text: answer)) }
                } else {
                    let d = try await engine.draft(req)
                    guard let self else { return }
                    let plan = d.plan(in: self.canvas, anchor: anchor)
                    self.updateChat(chatID) {
                        $0.messages.append(
                            AIMessage(
                                role: "assistant", text: d.answer, plan: plan.isEmpty || req.discussion ? nil : plan))
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    self?.updateChat(chatID) {
                        $0.messages.append(
                            AIMessage(role: "assistant", text: "Couldn’t answer: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    /// The panel's question in `ask` form for a non-chat action chip.
    public func runAction(_ a: AIAction) {
        switch a.output {
        case .ghosts: requestGhosts(a, label: a == .breakdown ? "Breaking down…" : nil)
        default:
            aiPanelVisible = true
            ask(a.title, action: a)
        }
    }

    /// Preview on canvas: the plan's new topics appear as ghosts in place.
    public func previewPlan(_ plan: ChangePlan?) {
        previewPlan = previewPlan == plan ? nil : plan
        refreshView()
    }

    /// Apply · one undo.
    public func applyPlan(_ plan: ChangePlan, chat: String? = nil, message: Int? = nil) {
        let markAI = markAI
        let added = perform("Apply AI Changes") { e in try plan.apply(in: &e, markAI: markAI) }
        previewPlan = nil
        if let chat, let message {
            updateChat(chat) { c in if message < c.messages.count { c.messages[message].applied = true } }
        }
        if let first = added?.first { select(first) }
        refreshView()
    }
}

/// Settings › AI keys (artboard 29).
public enum AISettingsKeys {
    public static let suggestAfterPause = "ai.suggestAfterPause"
    public static let depth = "ai.depth"
    public static let discussionDefault = "ai.discussionDefault"
    public static let markAI = "ai.markAI"
    public static let statusChip = "ai.statusChip"
}
