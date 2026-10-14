import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// Visual review of M4 canvases against artboards 18–23 (env-gated: NEXUS_SNAPSHOT_DIR).
@MainActor
@Suite(.serialized) struct TechSnapshotTests {
    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func shoot(_ c: Canvas, _ name: String, theme: String? = nil, width: CGFloat = 1440, height: CGFloat = 900) {
        var c = c
        if let theme { c.style.theme = theme }
        let h = CanvasHarness(model: DocumentModel(canvases: [c]), width: width, height: height)
        h.host.canvasView.fitToWindow()
        h.snapshot(to: Self.dir!.appendingPathComponent("m4-\(name).png"))
        h.window.orderOut(nil)
    }

    @Test(.enabled(if: dir != nil)) func structures() {
        let all: [(String, LayoutStructure)] = [
            ("logic", .logicRight), ("org", .orgDown), ("timeline", .timelineHorizontal), ("fishbone", .fishboneLeft),
            ("matrix", .matrix), ("brace", .braceRight), ("treetable", .treeTable), ("tree", .treeIndented),
        ]
        for (name, s) in all { shoot(TechSamples.structures(s), "s-\(name)", width: 900, height: 640) }
        var mixed = TechSamples.structures(.mindmapBalanced)
        mixed.nodes[mixed.nodes[mixed.root]!.children[3]]!.structure = .fishboneLeft
        shoot(mixed, "s-mixed", width: 1100, height: 700)
    }

    @Test(.enabled(if: dir != nil)) func technical() {
        shoot(TechSamples.flowchart(), "flowchart")
        shoot(TechSamples.swimlane(), "swimlane")
        shoot(TechSamples.dfd(), "dfd", theme: "graphite")
        shoot(TechSamples.threatModel(), "threat")
        shoot(TechSamples.architecture(), "architecture", theme: "blueprint")
        shoot(TechSamples.sequence(), "sequence", theme: "paper")
    }

    func shootHarness(_ h: CanvasHarness, _ name: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        h.snapshot(to: Self.dir!.appendingPathComponent("m4-\(name).png"))
        h.window.orderOut(nil)
    }

    @Test(.enabled(if: dir != nil)) func overlays() {
        // Convert (artboard 10), on the DFD-shaped map so the confirm step has rows.
        var map = TechSamples.dfd()
        map.type = .mindmap
        map.layout.structure = .mindmapBalanced
        for k in map.nodes.keys { map.nodes[k]!.nodeType = nil }
        var h = CanvasHarness(model: DocumentModel(canvases: [map]), width: 1440, height: 900)
        h.host.canvasView.fitToWindow()
        h.press("opt+cmd+t")
        h.press("right")
        shootHarness(h, "o-convert")
        h = CanvasHarness(model: DocumentModel(canvases: [map]), width: 1440, height: 900)
        h.press("opt+cmd+t")
        h.type("6")
        shootHarness(h, "o-convert-confirm")
        // DFD panel and violation card (artboard 20).
        var dfd = TechSamples.dfd()
        dfd.style.theme = "graphite"
        h = CanvasHarness(model: DocumentModel(canvases: [dfd]), width: 1440, height: 900)
        h.host.canvasView.fitToWindow()
        shootHarness(h, "o-dfd")
        // Threat model with the table and STRIDE suggestions (artboard 21).
        h = CanvasHarness(model: DocumentModel(canvases: [TechSamples.threatModel()]), width: 1440, height: 900)
        h.controller.threatTableVisible = true
        h.controller.select(h.canvas.nodes.first { $0.value.text == "Authorize payment" }!.key)
        h.host.canvasView.fitToWindow()
        shootHarness(h, "o-threat")
        // Icon library and the slash menu (artboard 22, 13).
        var arch = TechSamples.architecture()
        arch.style.theme = "blueprint"
        h = CanvasHarness(model: DocumentModel(canvases: [arch]), width: 1440, height: 900)
        h.controller.iconLibraryVisible = true
        h.host.canvasView.fitToWindow()
        h.controller.select(h.canvas.nodes.first { $0.value.text == "orders" }!.key)
        h.press("/")
        h.type("d")
        shootHarness(h, "o-arch")
    }
}
