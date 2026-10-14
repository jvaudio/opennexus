import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusInterchange

/// Visual review of M7 against artboards 30, 33, 50 and 51 (env-gated).
@MainActor
@Suite(.serialized) struct FileSnapshotTests {
    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func shoot(_ h: CanvasHarness, _ name: String) async throws {
        try await Task.sleep(for: .milliseconds(600))
        h.snapshot(to: Self.dir!.appendingPathComponent("m7-\(name).png"))
        h.window.orderOut(nil)
    }

    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    func harness() -> CanvasHarness {
        let h = CanvasHarness(model: launchPlanDocument(), width: 1440, height: 900)
        h.controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("nexus-snap-\(UUID().uuidString)"))
        h.host.canvasView.fitToWindow()
        return h
    }

    @Test(.enabled(if: dir != nil)) func exportSheet() async throws {
        for (name, format) in [
            ("30-png", ExportFormat.png), ("30-svg", .svg), ("30-mermaid", .mermaid), ("30-markdown", .markdown),
        ] {
            let h = harness()
            h.controller.openExport(format)
            var s = h.controller.exportState!
            s.format = format
            s.image.scale = 2
            s.image.background = format == .png ? .transparent : .theme
            h.controller.setExport(s)
            try await shoot(h, name)
        }
    }

    @Test(.enabled(if: dir != nil)) func fileTools() async throws {
        var h = harness()
        let md = FileManager.default.temporaryDirectory.appending(path: "Notes.md")
        try "# Notes\n## A\n## B".write(to: md, atomically: true, encoding: .utf8)
        h.controller.openMerge()
        h.controller.addMergeSource(md)
        try await shoot(h, "50-merge")
        h = harness()
        h.controller.passwordSheet = true
        try await shoot(h, "50-encrypt")
        h = harness()
        h.controller.openPrint()
        try await shoot(h, "50-print")
    }

    @Test(.enabled(if: dir != nil)) func mapShotAndReport() async throws {
        var h = harness()
        h.controller.openMapShot()
        try await shoot(h, "51-mapshot")
        h = harness()
        let im = try Interchange.importFile(
            name: "zen.xmind",
            data: try Data(
                contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "NexusInterchangeTests/Fixtures/zen.xmind")))
        h.controller.showImportReport(im.report)
        try await shoot(h, "33-report")
        // Exported branch images (split by branch) as a sheet of files.
        let files = ImageExporter.splitByBranch(h.store.model, canvas: "c1", ImageExporter.Options())
        for (n, d) in files.prefix(3) { try d.write(to: Self.dir!.appendingPathComponent("m7-51-\(n)")) }
        var o = ImageExporter.Options()
        o.background = .transparent
        try ImageExporter.png(ImageExporter.image(h.store.model, canvas: "c1", o)!).write(
            to: Self.dir!.appendingPathComponent("m7-export.png"))
        try SVGExporter.export(h.store.model, canvas: "c1", ImageExporter.Options()).write(
            to: Self.dir!.appendingPathComponent("m7-export.svg"), atomically: true, encoding: .utf8)
    }
}
