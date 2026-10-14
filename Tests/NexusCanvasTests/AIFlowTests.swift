import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

/// M6 flows on a scripted engine (no model needed): ghosts, the prompt bar, the panel and
/// the availability states. Every AI change is one undo.
@MainActor
@Suite(.serialized) struct AIFlowTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID {
        h.canvas.nodes.first { $0.value.text == text }!.key
    }

    func harness(_ engine: ScriptedEngine = ScriptedEngine()) -> CanvasHarness {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.ai = engine
        return h
    }

    /// Lets the scripted stream run on the main actor until `done` holds.
    func settle(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done(), "timed out waiting for the engine")
    }

    static let churn = [
        GhostIdea(text: "Week-4 cohort retention"), GhostIdea(text: "Win-back email"),
        GhostIdea(text: "Competitor response"), GhostIdea(text: "Pause instead of cancel"),
    ]

    @Test func ghostsStreamAsChildrenAndAcceptOneByOne() async throws {
        let h = harness(ScriptedEngine(ideas: ["Risks": Self.churn]))
        let risks = node(h, "Risks")
        h.controller.select(risks)
        let before = h.canvas
        let depth = h.undo.stack.undoStack.count
        h.press("opt+space")
        #expect(h.controller.ghosts?.anchor == risks)
        try await settle { h.controller.ghosts?.loading == false }
        let g = try #require(h.controller.ghosts)
        #expect(
            g.ideas.map(\.text) == ["Week-4 cohort retention", "Win-back email", "Pause instead of cancel"],
            "no duplicate of an existing child")
        #expect(h.canvas == before, "ghosts are never in the model")
        #expect(h.controller.lastGhostLatency != nil)

        // Laid out as children of Risks, in the scene only.
        let anchorDepth = h.controller.scene.nodes[risks]!.frame.depth
        for i in 0..<3 {
            let s = try #require(h.controller.scene.nodes[CanvasController.ghostID(i)])
            #expect(s.frame.depth == anchorDepth + 1)
        }

        // ↓ browses, typing ignores ghosts, ⌃↩ takes the highlighted one.
        h.press("down")
        #expect(h.controller.ghosts?.highlighted == 1)
        h.press("ctrl+return")
        #expect(h.undo.stack.undoStack.count == depth + 1)
        let win = node(h, "Win-back email")
        #expect(h.canvas.parent(of: win) == risks && h.canvas.nodes[win]!.ai)
        #expect(h.controller.ghosts?.ideas.map(\.text) == ["Week-4 cohort retention", "Pause instead of cancel"])

        // ⌃⇧↩ takes the rest in one step; undo removes just that step.
        h.press("ctrl+shift+return")
        #expect(h.controller.ghosts == nil)
        #expect(h.undo.stack.undoStack.count == depth + 2)
        #expect(h.canvas.nodes[risks]!.children.count == 4)
        h.undo.undo(h.store)
        #expect(h.canvas.nodes[risks]!.children.count == 2)
        h.undo.undo(h.store)
        #expect(h.canvas == before)
    }

    @Test func escDismissesAndTypingNeverAccepts() async throws {
        let h = harness()
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        h.press("opt+space")
        try await settle { h.controller.ghosts?.loading == false }
        #expect(h.controller.ghosts?.ideas.count == 3)
        h.press("esc")
        #expect(h.controller.ghosts == nil)
        #expect(h.controller.scene.nodes[CanvasController.ghostID(0)] == nil)

        h.press("opt+space")
        try await settle { h.controller.ghosts?.loading == false }
        let count = h.canvas.nodes.count
        h.type("Tiers")
        h.press("return")
        #expect(!h.canvas.nodes.values.contains { $0.text.hasPrefix("Idea") }, "typing doesn’t accept a ghost")
        #expect(h.canvas.nodes.count == count)
        #expect(h.text(pricing) == "Tiers")
    }

    @Test func unavailableShowsNoticeAndChangesNothing() async throws {
        for state in [AIAvailability.off, .downloading, .unsupported] {
            let h = harness(ScriptedEngine(availability: state))
            h.controller.select(node(h, "Risks"))
            let before = h.canvas
            h.press("opt+space")
            #expect(h.controller.ghosts == nil)
            #expect(h.controller.aiNotice == state.explanation)
            h.press("shift+cmd+space")
            #expect(h.controller.promptBar == nil)
            h.controller.ask("Where is @Risks thin?")
            #expect(h.controller.chats.isEmpty)
            #expect(h.canvas == before && h.undo.stack.undoStack.isEmpty)
        }
    }

    @Test func breakdownAndTodosCarryMarkersLabelsAndChecks() async throws {
        let phases = [
            GhostIdea(text: "Content", markers: ["priority-1"], labels: ["2 wk"]),
            GhostIdea(text: "Write docs", parentGhost: 0),
            GhostIdea(text: "QA & launch", markers: ["priority-2"], labels: ["1 wk"]),
        ]
        let h = harness(
            ScriptedEngine(ideas: ["Timeline": phases, "Channels": [GhostIdea(text: "Draft post", todo: true)]]))
        let timeline = node(h, "Timeline")
        h.controller.select(timeline)
        _ = h.controller.perform(.aiBreakdown)
        #expect(h.controller.ghosts?.label == "Breaking down…")
        try await settle { h.controller.ghosts?.loading == false }
        h.press("ctrl+return")  // the phase brings its step
        let content = node(h, "Content")
        #expect(h.canvas.nodes[content]!.markers == ["priority-1"] && h.canvas.nodes[content]!.labels == ["2 wk"])
        #expect(h.canvas.parent(of: node(h, "Write docs")) == content)
        #expect(h.controller.ghosts?.ideas.map(\.text) == ["QA & launch"])
        h.press("esc")

        h.controller.select(node(h, "Channels"))
        _ = h.controller.perform(.aiTodos)
        try await settle { h.controller.ghosts?.loading == false }
        h.press("ctrl+shift+return")
        #expect(h.canvas.nodes[node(h, "Draft post")]!.todo == Todo(done: false))
    }

    @Test func panelPlanPreviewApplyAndDiscussion() async throws {
        let draft = PlanDraft(
            answer: "Risks has one child; churn isn’t covered.",
            adds: [
                .init(parent: "Risks", text: "Week-4 cohort retention"), .init(parent: "Risks", text: "Win-back email"),
            ],
            renames: [.init(from: "Risks", to: "Risks & churn")])
        let h = harness(ScriptedEngine(drafts: ["Where is @Risks thin?": draft]))
        let risks = node(h, "Risks")
        h.press("shift+cmd+j")
        #expect(h.controller.aiPanelVisible)
        h.controller.ask("Where is @Risks thin?")
        try await settle { h.controller.aiBusy == nil && h.controller.currentChat?.messages.count == 2 }
        let chat = try #require(h.controller.currentChat)
        #expect(chat.title == "Where is @Risks thin?")
        let plan = try #require(chat.messages[1].plan)
        #expect(plan.counts() == "+2 · ~1")
        #expect(h.undo.stack.undoStack.isEmpty, "a plan is only a proposal")

        // Preview shows the adds as ghosts in place; the model is untouched.
        h.controller.previewPlan(plan)
        #expect(h.controller.scene.nodes[CanvasController.ghostID(1)]?.displayText == "Win-back email")
        h.controller.applyPlan(plan, chat: chat.id, message: 1)
        #expect(h.undo.stack.undoStack.count == 1)
        #expect(h.text(risks) == "Risks & churn" && h.canvas.nodes[risks]!.children.count == 3)
        #expect(h.controller.currentChat?.messages[1].applied == true)
        #expect(h.controller.scene.nodes[CanvasController.ghostID(0)] == nil)
        h.undo.undo(h.store)
        #expect(h.text(risks) == "Risks" && h.canvas.nodes[risks]!.children.count == 1)
        #expect(h.controller.currentChat?.messages.count == 2, "undo never loses the chat")

        // Discussion mode answers without a plan.
        h.controller.newChat()
        h.controller.setDiscussion(true)
        h.controller.ask("Where is @Risks thin?")
        try await settle { h.controller.aiBusy == nil && h.controller.currentChat?.messages.count == 2 }
        #expect(h.controller.currentChat?.messages[1].plan == nil)
        #expect(h.controller.chats.count == 2)
    }

    @Test func promptBarRoutesToGhostsPanelOrConvert() async throws {
        let h = harness()
        let channels = node(h, "Channels")
        h.controller.select(channels)
        h.press("shift+cmd+space")
        #expect(h.controller.promptBar?.anchor == channels)
        h.controller.submitPrompt("More launch channels")
        #expect(h.controller.promptBar == nil)
        try await settle { h.controller.ghosts?.loading == false }
        #expect(h.controller.ghosts?.anchor == channels)
        h.press("esc")

        h.press("shift+cmd+space")
        h.controller.submitPrompt("", action: .summarize)
        #expect(h.controller.aiPanelVisible)
        try await settle { h.controller.aiBusy == nil && h.controller.currentChat?.messages.count == 2 }
        #expect(h.controller.currentChat?.messages[1].text == "Summary of Channels.")

        h.press("shift+cmd+space")
        h.controller.submitPrompt("Turn this branch into a DFD")
        #expect(h.controller.convert?.highlighted == .dfd)
    }

    @Test func recordToMapNotesTheRootAndSuggests() async throws {
        let h = harness()
        h.controller.finishRecording("We should ship the beta in November and watch churn.")
        #expect(h.canvas.nodes[h.canvas.root]!.note?.text == "We should ship the beta in November and watch churn.")
        #expect(h.undo.stack.undoStack.count == 1)
        try await settle { h.controller.ghosts?.loading == false }
        #expect(h.controller.ghosts?.anchor == h.canvas.root)
    }

    @Test func suggestsAfterAPauseWhenEnabled() async throws {
        let key = AISettingsKeys.suggestAfterPause
        let h = harness()
        h.controller.select(node(h, "Risks"))
        h.press("tab")
        h.type("Legal")
        h.press("return")
        try await Task.sleep(for: .milliseconds(1700))
        #expect(h.controller.ghosts == nil, "off by default")

        h.controller.prefs.set(key, true)
        h.press("tab")
        h.type("Contracts")
        h.press("return")
        let legal = node(h, "Legal")
        try await settle { h.controller.ghosts?.loading == false }
        #expect(h.controller.ghosts?.anchor == node(h, "Contracts"))
        #expect(h.canvas.parent(of: node(h, "Contracts")) == legal)
    }

    @Test func maskedCopyIsANewCanvas() throws {
        let h = harness()
        h.controller.select(node(h, "Pro"))
        h.controller.beginEditing(replacingWith: "Pro · billing@acme.io")
        h.controller.commitEdit()
        let hits = h.controller.maskHits
        #expect(hits.map(\.text) == ["billing@acme.io"])
        let original = h.controller.canvasID
        h.controller.makeMaskedCopy(hits)
        #expect(h.controller.canvasID != original)
        #expect(h.canvas.nodes.values.contains { $0.text == "Pro · ••••••••••••" }, "Settings › Privacy › Replace with")
        #expect(h.store.model.canvases[original]!.nodes.values.contains { $0.text == "Pro · billing@acme.io" })
    }
}

/// Acceptance: zero outbound connections. The sandbox has no network entitlement, and no
/// source uses a networking or cloud-model API.
@Suite struct PrivacyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func entitlementsHaveNoNetwork() throws {
        let url = Self.root.appending(path: "App/Support/OpenNexus.entitlements")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(!plist.keys.contains { $0.hasPrefix("com.apple.security.network") })
    }

    @Test func sourcesUseNoNetworkingOrCloudModels() throws {
        let banned = ["URLSession", "NWConnection", "NWBrowser", "CFSocket", "PrivateCloudCompute", "CFStream"]
        var found: [String] = []
        let dirs = ["Sources", "App"].map { Self.root.appending(path: $0) }
        for dir in dirs {
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
            for case let f as URL in files where f.pathExtension == "swift" {
                let s = try String(contentsOf: f, encoding: .utf8)
                for b in banned where s.contains(b) { found.append("\(f.lastPathComponent): \(b)") }
            }
        }
        #expect(found.isEmpty, "\(found)")
    }
}
