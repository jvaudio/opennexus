import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// M22 (D209): a work breakdown's dates and lengths become task fields; a plan without
/// them makes undated tasks.
@MainActor
@Suite(.serialized) struct AIPlanTaskTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    func settle(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done(), "timed out waiting for the engine")
    }

    @Test func scheduledChainsPhasesOnTheCalendar() {
        let cal = WorkCalendar()
        let ideas = GhostIdea.scheduled(
            [
                GhostIdea(text: "Design", start: TaskDate("2026-11-02"), workingDays: 5),
                GhostIdea(text: "Sketch", parentGhost: 0, workingDays: 2),
                GhostIdea(text: "Build", workingDays: 10),
                GhostIdea(text: "Launch", due: TaskDate("2026-12-04"), workingDays: 3),
                GhostIdea(text: "Party", workingDays: 1),
                GhostIdea(text: "Retro"),
            ], calendar: cal)
        #expect(ideas[0].due == TaskDate("2026-11-06"))
        #expect(ideas[1].start == nil && ideas[1].due == nil, "a sub-step has no dated phase before it")
        #expect(ideas[2].start == TaskDate("2026-11-09") && ideas[2].due == TaskDate("2026-11-20"), "follows Design")
        #expect(ideas[3].start == TaskDate("2026-12-02") && ideas[3].due == TaskDate("2026-12-04"))
        #expect(ideas[4].start == TaskDate("2026-12-07") && ideas[4].due == TaskDate("2026-12-07"))
        #expect(ideas[5].start == nil && ideas[5].due == nil && !ideas[5].isTask)
        #expect(ideas[1].isTask, "a length alone still makes an (undated) task")
    }

    @Test func breakdownGhostsBecomeDatedTasks() async throws {
        let phases = [
            GhostIdea(
                text: "Content", markers: ["priority-1"], labels: ["1 wk"], start: TaskDate("2026-11-02"),
                workingDays: 5),
            GhostIdea(text: "Write docs", parentGhost: 0),
            GhostIdea(text: "QA & launch", markers: ["priority-2"], labels: ["2 wk"], workingDays: 10),
            GhostIdea(text: "Undated", workingDays: 3),
        ]
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.ai = ScriptedEngine(ideas: ["Timeline": phases])
        h.controller.select(node(h, "Timeline"))
        _ = h.controller.perform(.aiBreakdown)
        try await settle { h.controller.ghosts?.loading == false }
        let depth = h.undo.stack.undoStack.count
        h.press("ctrl+return")  // the first phase and its step
        #expect(h.undo.stack.undoStack.count == depth + 1, "one undo step")
        let content = h.canvas.nodes[node(h, "Content")]!
        #expect(content.todo?.start == TaskDate("2026-11-02") && content.todo?.due == TaskDate("2026-11-06"))
        #expect(content.markers == ["priority-1"] && content.labels == ["1 wk"])
        #expect(h.canvas.nodes[node(h, "Write docs")]!.todo == nil, "a plain step stays a plain topic")
        // The next phase keeps the dates worked out from the first after it left.
        h.press("ctrl+shift+return")
        let qa = h.canvas.nodes[node(h, "QA & launch")]!.todo
        #expect(qa?.start == TaskDate("2026-11-09") && qa?.due == TaskDate("2026-11-20"))
        let undated = h.canvas.nodes[node(h, "Undated")]!.todo
        #expect(undated?.start == TaskDate("2026-11-23"), "follows QA & launch")
        #expect(h.canvas.nodes.values.allSatisfy { $0.todo == nil || $0.ai || $0.text == "Pro" })
    }

    @Test func undatedPlansMakeUndatedTasks() async throws {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.ai = ScriptedEngine(ideas: [
            "Channels": [GhostIdea(text: "Draft post", todo: true), GhostIdea(text: "Pitch", workingDays: 2)]
        ])
        h.controller.select(node(h, "Channels"))
        _ = h.controller.perform(.aiTodos)
        try await settle { h.controller.ghosts?.loading == false }
        h.press("ctrl+shift+return")
        #expect(h.canvas.nodes[node(h, "Draft post")]!.todo == Todo(done: false))
        #expect(h.canvas.nodes[node(h, "Pitch")]!.todo == Todo(done: false), "no start, so no dates")
    }
}
