import Foundation
import Testing

@testable import NexusAgent
@testable import NexusCore
@testable import NexusFormat

/// M22: task fields and comments through the MCP tools and the `nexus` CLI.
@MainActor
@Suite(.serialized) struct AgentTaskTests {
    func topic(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }

    @Test func setTaskAddCommentAndReadThemBack() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let p = JSONValue.string(box.plan.path)
        let ask = Session.request(
            1, "initialize",
            [
                "protocolVersion": "2025-06-18", "capabilities": [:],
                "clientInfo": ["name": "test", "title": "Test Agent"],
            ])
        let s = Session(
            .enabled(box.policy()),
            [
                ask,
                Session.call(
                    2, "set_task",
                    [
                        "path": p, "topic": "Beta · Nov", "start": "2026-11-02", "duration": 5, "owner": "Ana",
                        "progress": 40,
                    ]),
                Session.call(
                    3, "set_task",
                    [
                        "path": p, "topic": "GA · Jan", "start": "2026-11-04", "due": "2026-11-10", "priority": 2,
                        "after": [["topic": "Beta · Nov", "type": "FS", "lag": 1]],
                    ]),
                Session.call(4, "add_comment", ["path": p, "topic": "Pricing", "text": "Check the annual tier"]),
                Session.call(5, "add_comment", ["path": p, "topic": "Pricing", "text": "Fine", "author": "Ana"]),
                Session.call(6, "read_map", ["path": p, "canvas": "c1"]),
                // Refusals: a loop, a bad date, nothing to change, an unknown topic.
                Session.call(7, "set_task", ["path": p, "topic": "Beta · Nov", "after": ["GA · Jan"]]),
                Session.call(8, "set_task", ["path": p, "topic": "Pro", "due": "next blue moon"]),
                Session.call(9, "set_task", ["path": p, "topic": "Pro"]),
                Session.call(10, "add_comment", ["path": p, "topic": "Nowhere", "text": "Hi"]),
                Session.call(11, "set_task", ["path": p, "topic": "GA · Jan", "after": [], "owner": "", "done": true]),
            ])
        _ = s.run()
        #expect(!s.isError(2) && s.text(2).contains("owner Ana · start 2026-11-02 · due 2026-11-06"), "\(s.text(2))")
        // GA must start after Beta finishes (6 Nov) plus a working day, so it moves to 10 Nov.
        #expect(!s.isError(3) && s.text(3).contains("start 2026-11-10"), "\(s.text(3))")
        #expect(s.text(4).hasPrefix("Commented on “Pricing”") && s.text(4).contains("Test Agent (AI)"))
        let outline = s.text(6)
        #expect(outline.contains("    task: owner Ana · start 2026-11-02 · due 2026-11-06 · 5 working days · 40%"))
        #expect(outline.contains("· priority 2 · after Beta · Nov ["), "\(outline)")
        #expect(outline.contains("    comment by Test Agent (AI) · 20"))
        #expect(outline.contains(": Check the annual tier") && outline.contains("comment by Ana (AI)"))
        #expect(s.isError(7) && s.text(7).contains("loop"))
        #expect(s.isError(8) && s.text(8).contains("isn't a date"))
        #expect(s.isError(9) && s.text(9).contains("Nothing to change"))
        #expect(s.isError(10) && s.text(10).contains("No topic"))
        #expect(!s.isError(11))

        let c = try MapFiles.read(box.plan).canvases["c1"]!
        let beta = c.nodes[topic(c, "Beta · Nov")]!
        #expect(beta.todo?.due == TaskDate("2026-11-06") && beta.todo?.progress == 40 && beta.ai)
        let ga = c.nodes[topic(c, "GA · Jan")]!
        #expect(ga.todo?.after.isEmpty == true && ga.todo?.owner == nil && ga.todo?.done == true && ga.priority == 2)
        #expect(ga.ai, "agent edits are marked AI (D121)")
        let pricing = c.nodes[topic(c, "Pricing")]!
        #expect(pricing.comments.map(\.author) == ["Test Agent (AI)", "Ana (AI)"])
        #expect(pricing.comments.allSatisfy { $0.instant != nil })
        #expect(try NexusCLI.validationIssues(box.plan).issues.isEmpty)
    }

    @Test func writesNeedEditAccess() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let p = JSONValue.string(box.plan.path)
        let before = try MapFiles.read(box.plan)
        let calls = [
            Session.call(2, "set_task", ["path": p, "topic": "Pro", "due": "2026-11-06"]),
            Session.call(3, "add_comment", ["path": p, "topic": "Pro", "text": "Hi"]),
            Session.call(4, "read_map", ["path": p]),
        ]
        let blocked = Session(.enabled(box.policy(edit: .block)), [Session.initialize] + calls)
        _ = blocked.run()
        #expect(blocked.isError(2) && blocked.text(2).contains("blocked"))
        #expect(blocked.isError(3) && blocked.text(3).contains("blocked"))
        #expect(!blocked.isError(4), "reading still works")
        let mute = Session(.enabled(box.policy(edit: .ask)), [Session.initialize] + calls)
        _ = mute.run()
        #expect(mute.isError(2) && mute.text(2).contains("can't ask"))
        #expect(mute.isError(3) && mute.text(3).contains("can't ask"))
        #expect(try MapFiles.read(box.plan) == before, "nothing was written")
        // Read access is checked too.
        let noRead = Session(.enabled(box.policy(read: .block)), [Session.initialize, calls[2]])
        _ = noRead.run()
        #expect(noRead.isError(4))
    }

    @Test func cliReadPrintsTasksAndComments() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let s = Session(
            .enabled(box.policy()),
            [
                Session.initialize,
                Session.call(
                    2, "set_task",
                    ["path": .string(box.plan.path), "topic": "Pro", "start": "2026-11-09", "due": "2026-11-13"]),
                Session.call(
                    3, "add_comment", ["path": .string(box.plan.path), "topic": "Pro", "text": "Price check"]),
            ])
        _ = s.run()
        // Without a client name, comments are signed "Agent (AI)".
        _ = try MapTools(policy: box.policy()).call(
            "add_comment", ["path": .string(box.plan.path), "topic": "Pro", "text": "Unsigned"])
        let cli = CLITests()
        let (status, out, _, _) = cli.run(["read", "Launch plan.nexus", "--canvas", "c1"], in: box.maps)
        #expect(status == 0)
        #expect(
            out.contains("- Pro [") && out.contains("    task: start 2026-11-09 · due 2026-11-13 · 5 working days · 0%")
        )
        #expect(out.contains("comment by test (AI)") && out.contains("comment by Agent (AI)"), "\(out)")
        let (status2, tasks, _, _) = cli.run(["read", "Launch plan.nexus", "--tasks"], in: box.maps)
        #expect(status2 == 0)
        let lines = tasks.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == 1 && lines[0].contains("Pro [") && lines[0].contains("☐ — start 2026-11-09"))
        #expect(cli.run(["read"], in: box.maps).0 == 64)
        // Import reports tasks and comments.
        try "# Plan\n- [ ] Design @Ana 2026-11-02→2026-11-06 ^d\n- [ ] Code after:^d\n".write(
            to: box.root.appending(path: "plan.md"), atomically: true, encoding: .utf8)
        let (s4, report, _, _) = cli.run(["import", "plan.md"], in: box.root)
        #expect(s4 == 0 && report.contains("3 topics · 2 tasks · 1 dependencies"), "\(report)")
    }
}
