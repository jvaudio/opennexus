import Foundation
import Testing

@testable import NexusCore

private func id(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }

@Suite struct ChangePlanTests {
    /// Artboard 28's proposed change: three adds under Churn and one rename.
    static func churnPlan(_ c: Canvas) -> ChangePlan {
        let churn = id(c, "Risks")
        return ChangePlan(
            summary: "Risks has one child.",
            ops: [
                .add(
                    parent: churn, parentAdd: nil, text: "Week-4 cohort retention", markers: [], labels: [], todo: false
                ),
                .add(parent: churn, parentAdd: nil, text: "Win-back email", markers: [], labels: [], todo: false),
                .add(parent: nil, parentAdd: 1, text: "Pause instead of cancel", markers: [], labels: [], todo: false),
                .rename(churn, from: "Risks", to: "Risks & churn"),
            ])
    }

    @Test func applyIsOneUndoAndMarksAI() throws {
        var c = sampleCanvas()
        var undo = UndoStack()
        let original = c
        let plan = Self.churnPlan(c)
        #expect(plan.counts() == "+3 · ~1")
        #expect(
            plan.lines(in: c) == [
                "+ Risks › Week-4 cohort retention", "+ Risks › Win-back email",
                "+ Win-back email › Pause instead of cancel", "~ “Risks” → “Risks & churn”",
            ])
        let added = try c.edit("Apply AI Changes", undo: &undo) { try plan.apply(in: &$0) }
        #expect(undo.undoStack.count == 1)
        #expect(added.count == 3)
        #expect(added.allSatisfy { c.nodes[$0]!.ai })
        let pause = c.nodes[added[2]]!
        #expect(pause.text == "Pause instead of cancel")
        #expect(c.parent(of: added[2]) == added[1], "an add can nest under an earlier add")
        #expect(c.nodes[id(original, "Risks")]!.text == "Risks & churn")
        // Editing an AI topic clears its ✦.
        try c.edit("Typing", undo: &undo) { $0.setText(added[0], "Week-4 retention") }
        #expect(!c.nodes[added[0]]!.ai)
        undo.undo()!.apply(to: &c)
        undo.undo()!.apply(to: &c)
        #expect(c == original)
    }

    @Test func planJSONRoundTrip() throws {
        let c = sampleCanvas()
        let p = Self.churnPlan(c)
        #expect(try ChangePlan(json: p.json, path: "p") == p)
        var chat = AIChat(id: "chat1", title: "Pricing review")
        chat.discussion = true
        chat.depth = .deep
        chat.messages = [
            AIMessage(role: "user", text: "Where is @Risks thin?"), AIMessage(role: "assistant", text: "…", plan: p),
        ]
        #expect(try AIChat(json: chat.json, path: "c") == chat)
    }

    @Test func draftResolvesNames() {
        let c = sampleCanvas()
        let pricing = id(c, "Pricing")
        let d = PlanDraft(
            answer: "Add a team tier.",
            adds: [
                .init(parent: "Pricing", text: "Team"), .init(parent: "Team", text: "Seat pricing"),
                .init(parent: "Unknown", text: "Elsewhere"),
            ],
            renames: [.init(from: "Pro", to: "Pro plan"), .init(from: "Nope", to: "x")])
        let p = d.plan(in: c, anchor: pricing)
        #expect(p.ops.count == 4)
        guard case .add(let p0, nil, "Team", _, _, _) = p.ops[0], case .add(nil, 0, "Seat pricing", _, _, _) = p.ops[1],
            case .add(let p2, nil, "Elsewhere", _, _, _) = p.ops[2], case .rename(_, "Pro", "Pro plan") = p.ops[3]
        else {
            Issue.record("unexpected ops \(p.ops)")
            return
        }
        #expect(p0 == pricing && p2 == pricing)
    }
}

@Suite struct MapContextTests {
    @Test func outlineAndDepth() {
        var c = sampleCanvas()
        let pricing = id(c, "Pricing")
        c.nodes[pricing]!.note = Note(text: "Keep the free tier generous.")
        c.nodes[pricing]!.labels = ["Q4"]
        let deep = MapContext.outline(c, depth: .deep)
        #expect(deep.hasPrefix("- Launch plan\n  - Positioning\n    - Developers"))
        #expect(deep.contains("  - Pricing [Q4]\n    note: Keep the free tier generous."))
        let quick = MapContext.outline(c, depth: .quick)
        #expect(!quick.contains("note:"))
        #expect(MapContext.outline(c, from: pricing).hasPrefix("- Pricing"))
        #expect(MapContext.path(c, to: id(c, "Pro")) == "Launch plan › Pricing › Pro")
    }

    @Test func atReferences() {
        let c = sampleCanvas()
        let refs = MapContext.references(in: "Where is @Risks thin compared to @Pricing?", canvas: c)
        #expect(refs == [id(c, "Risks"), id(c, "Pricing")])
    }

    @Test func scriptedEngineHonoursDiscussion() async throws {
        let e = ScriptedEngine(drafts: ["q": PlanDraft(answer: "A", adds: [.init(parent: "x", text: "y")])])
        var r = AIRequest(action: .explain, prompt: "q")
        #expect(try await e.draft(r).adds.count == 1)
        r.discussion = true
        #expect(try await e.draft(r).adds.isEmpty, "Discussion mode never edits")
    }
}
