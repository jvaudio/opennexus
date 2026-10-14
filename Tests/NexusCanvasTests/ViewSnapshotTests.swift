import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// Visual review of M5 views against artboards 25–27, 32 and 47 (env-gated).
@MainActor
@Suite(.serialized) struct ViewSnapshotTests {
    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func shoot(_ h: CanvasHarness, _ name: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        h.snapshot(to: Self.dir!.appendingPathComponent("m5-\(name).png"))
        h.window.orderOut(nil)
    }

    func doc() -> DocumentModel {
        var d = launchPlanDocument()
        var c = d.canvases["c1"]!
        let pricing = c.nodes.first { $0.value.text == "Pricing" }!.key
        let channels = c.nodes.first { $0.value.text == "Channels" }!.key
        let timeline = c.nodes.first { $0.value.text == "Timeline" }!.key
        c.nodes[pricing]!.note = Note(text: "Keep the free tier generous; we compete with a metered incumbent.")
        var undo = UndoStack()
        c.edit("Link", undo: &undo) { e in
            e.connect(channels, to: timeline)
            e.updateRelationship(e.canvas.relationships[0].id) { $0.label = "drives" }
        }
        let risks = c.nodes.first { $0.value.text == "Risks" }!.key
        c.edit("Fold", undo: &undo) { e in
            _ = try! e.addChild(of: risks, text: "Legal")
            _ = try! e.addChild(of: risks, text: "Churn")
            try! e.toggleFold(risks)
        }
        d.canvases["c1"] = c
        var c2 = Canvas(id: "c2", title: "Platform reference", rootText: "Platform reference")
        c2.edit("Seed", undo: &undo) { e in
            let v = try! e.addChild(of: e.canvas.root, text: "VPC")
            _ = try! e.addChild(of: v, text: "Payments service")
        }
        d.canvases["c2"] = c2
        d.canvasOrder.append("c2")
        return d
    }

    @Test(.enabled(if: dir != nil)) func views() {
        var h = CanvasHarness(model: doc(), width: 1440, height: 900)
        h.host.canvasView.fitToWindow()
        h.press("cmd+k")
        h.type("conv")
        shoot(h, "palette")
        h = CanvasHarness(model: doc(), width: 1440, height: 900)
        h.host.canvasView.fitToWindow()
        h.press("cmd+j")
        h.type("pay")
        shoot(h, "jump")
        // Split: outline left, canvas right, Pricing selected in both.
        h = CanvasHarness(model: doc(), width: 1440, height: 900)
        let outline = OutlineView(controller: h.controller)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        outline.frame = CGRect(x: 0, y: 0, width: 560, height: 900)
        h.host.removeFromSuperview()
        h.host.frame = CGRect(x: 561, y: 0, width: 879, height: 900)
        container.addSubview(outline)
        container.addSubview(h.host)
        h.window.contentView = container
        h.controller.select(h.canvas.nodes.first { $0.value.text == "Pricing" }!.key)
        outline.layoutSubtreeIfNeeded()
        h.host.layoutSubtreeIfNeeded()
        h.host.canvasView.fitToWindow()
        shoot(h, "split")
        // Focus on Pricing.
        h = CanvasHarness(model: doc(), width: 900, height: 700)
        h.controller.select(h.canvas.nodes.first { $0.value.text == "Pricing" }!.key)
        h.press("cmd+.")
        shoot(h, "focus")
        // Filter bar on the threat model.
        h = CanvasHarness(model: DocumentModel(canvases: [TechSamples.threatModel()]), width: 1200, height: 800)
        h.host.canvasView.fitToWindow()
        h.press("shift+cmd+f")
        h.controller.addFilterClause("type: Threat")
        h.controller.addFilterClause("risk: High")
        h.controller.addFilterClause("status ≠ Mitigated")
        shoot(h, "filter")
        // Navigation panel: search "pric".
        h = CanvasHarness(model: doc(), width: 1440, height: 900)
        h.host.canvasView.fitToWindow()
        h.press("cmd+f")
        var o = SearchOptions()
        o.notes = true
        o.allCanvases = true
        h.controller.updateSearch(query: "pric", options: o)
        shoot(h, "nav-search")
        h = CanvasHarness(model: doc(), width: 1440, height: 900)
        h.host.canvasView.fitToWindow()
        h.press("ctrl+cmd+4")
        shoot(h, "nav-tags")
        // Present on the DFD (Graphite), slide 3.
        var dfd = TechSamples.dfd()
        dfd.style.theme = "graphite"
        h = CanvasHarness(model: DocumentModel(canvases: [dfd]), width: 1440, height: 900)
        h.press("shift+cmd+p")
        h.press("right")
        h.press("right")
        h.press("right")
        shoot(h, "present")
    }
}
