import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// Visual review of M6 against artboards 28, 29 and 52 (env-gated).
@MainActor
@Suite(.serialized) struct AISnapshotTests {
    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func shoot(_ h: CanvasHarness, _ name: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        h.snapshot(to: Self.dir!.appendingPathComponent("m6-\(name).png"))
        h.window.orderOut(nil)
    }

    func settle(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    /// Artboard 28's map: Growth 2027 with Onboarding, Checkout and Churn.
    func growth() -> DocumentModel {
        var c = Canvas(id: "c1", title: "Growth strategy", rootText: "Growth 2027")
        var undo = UndoStack()
        c.edit("Seed", undo: &undo) { e in
            let o = try! e.addChild(of: e.canvas.root, text: "Onboarding")
            _ = try! e.addChild(of: e.canvas.root, text: "Checkout")
            _ = try! e.addChild(of: e.canvas.root, text: "Churn")
            _ = try! e.addChild(of: o, text: "Welcome email")
            let s = try! e.addChild(of: o, text: "Sample project")
            e.update(s) { $0.ai = true }
        }
        return DocumentModel(canvases: [c])
    }

    @Test(.enabled(if: dir != nil)) func canvasAI() async throws {
        let h = CanvasHarness(model: growth(), width: 1440, height: 900)
        h.controller.ai = ScriptedEngine(ideas: [
            "Onboarding": [
                GhostIdea(text: "Guided first task"), GhostIdea(text: "Empty-state hints"),
                GhostIdea(text: "Activation metric"),
            ]
        ])
        let onboarding = node(h, "Onboarding")
        let checkout = node(h, "Checkout")
        let churn = node(h, "Churn")
        // The panel's chat with a proposed change.
        let draft = PlanDraft(
            answer:
                "Churn has no children and no measures. Onboarding has five, including an activation metric. I’d add a cohort metric and two win-back ideas.",
            adds: [
                .init(parent: "Churn", text: "Week-4 cohort retention"), .init(parent: "Churn", text: "Win-back email"),
                .init(parent: "Churn", text: "Pause instead of cancel"),
            ],
            renames: [.init(from: "Churn", to: "Retention & churn")])
        var chat = AIChat(id: "chat1", title: "Churn review")
        chat.canvas = "c1"
        chat.messages = [
            AIMessage(role: "user", text: "Where is @Churn thin compared to @Onboarding?"),
            AIMessage(role: "assistant", text: draft.answer, plan: draft.plan(in: h.canvas, anchor: churn)),
        ]
        h.store.updateDocument { $0.chats = [chat] }
        h.controller.aiPanelVisible = true
        try await Task.sleep(for: .milliseconds(100))
        h.host.layoutSubtreeIfNeeded()
        h.host.canvasView.fitToWindow()
        h.controller.select(onboarding)
        h.press("opt+space")
        try await settle { h.controller.ghosts?.loading == false }
        h.controller.promptBar = PromptBarState(anchor: checkout, text: "Turn this branch into a DFD")
        h.controller.onSceneChange?(true)
        shoot(h, "28-canvas")
    }

    @Test(.enabled(if: dir != nil)) func aiOff() {
        var c = Canvas(id: "c1", title: "Q3 offsite", rootText: "Q3 offsite")
        var undo = UndoStack()
        c.edit("Seed", undo: &undo) { e in _ = try! e.addChild(of: e.canvas.root, text: "Agenda") }
        let h = CanvasHarness(model: DocumentModel(canvases: [c]), width: 900, height: 700)
        h.controller.ai = ScriptedEngine(availability: .off)
        h.controller.select(node(h, "Agenda"))
        h.press("opt+space")
        shoot(h, "29-off")
    }

    @Test(.enabled(if: dir != nil)) func settings() {
        let w = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 860, height: 820), styleMask: [.titled], backing: .buffered,
            defer: false)
        w.contentView = NSHostingView(rootView: SettingsView(availability: .ready))
        w.appearance = NSAppearance(named: .aqua)
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = [
            "-x", "-o", "-l", "\(w.windowNumber)", Self.dir!.appendingPathComponent("m6-29-settings.png").path,
        ]
        try? p.run()
        p.waitUntilExit()
        w.orderOut(nil)
    }

    @Test(.enabled(if: dir != nil)) func aiPlus() async throws {
        // Work breakdown and to-dos as ghosts.
        var h = CanvasHarness(model: launchPlanDocument(), width: 1200, height: 800)
        h.controller.ai = ScriptedEngine(
            ideas: [
                "Timeline": [
                    GhostIdea(text: "Phase 1 · Content", markers: ["priority-1"], labels: ["1 wk"]),
                    GhostIdea(text: "Phase 2 · Build", markers: ["priority-1"], labels: ["2 wk"]),
                    GhostIdea(text: "Phase 3 · QA & launch", markers: ["priority-2"], labels: ["1 wk"]),
                ]
            ], delay: .milliseconds(400))
        h.host.canvasView.fitToWindow()
        h.controller.select(node(h, "Timeline"))
        _ = h.controller.perform(.aiBreakdown)
        try await Task.sleep(for: .milliseconds(900))
        shoot(h, "52-breakdown")

        h = CanvasHarness(model: launchPlanDocument(), width: 1200, height: 800)
        h.controller.ai = ScriptedEngine(ideas: [
            "Channels": ["Write role brief", "Post to 3 boards", "Book panel interviews"].map {
                GhostIdea(text: $0, todo: true)
            }
        ])
        h.host.canvasView.fitToWindow()
        h.controller.select(node(h, "Channels"))
        _ = h.controller.perform(.aiTodos)
        try await settle { h.controller.ghosts?.loading == false }
        shoot(h, "52-todos")

        // The panel with Discussion mode.
        h = CanvasHarness(model: launchPlanDocument(), width: 1200, height: 800)
        h.controller.ai = ScriptedEngine()
        var chat = AIChat(id: "chat1", title: "Pricing review")
        chat.canvas = "c1"
        chat.discussion = true
        chat.messages = [
            AIMessage(role: "user", text: "Is this branch clear enough for a board deck?"),
            AIMessage(role: "assistant", text: "Mostly. “Pro” and “Team” overlap; consider merging. No changes made."),
        ]
        h.store.updateDocument { $0.chats = [chat] }
        h.controller.aiPanelVisible = true
        h.controller.onSceneChange?(true)
        shoot(h, "52-panel")

        // Each sheet.
        var masked = launchPlanDocument()
        let pro = masked.canvases["c1"]!.nodes.first { $0.value.text == "Pro" }!.key
        masked.canvases["c1"]!.nodes[pro]!.text = "Owner: dana.ruiz@example.com"
        for (name, sheet) in [("translate", AISheet.translate), ("mask", .mask), ("record", .record)] {
            h = CanvasHarness(model: masked, width: 1200, height: 800)
            h.controller.ai = ScriptedEngine()
            h.controller.openAISheet(sheet)
            shoot(h, "52-\(name)")
        }
        h = CanvasHarness(model: masked, width: 1200, height: 800)
        h.controller.ai = ScriptedEngine()
        h.controller.openAISheet(.sticker(node(h, "Free tier")))
        shoot(h, "52-sticker")
    }
}
