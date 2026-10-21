import Foundation
import NexusCore
import NexusFormat
import NexusInterchange
import Testing

@testable import NexusCanvas

/// M15: Xmind in the export sheet: the whole document with a thumbnail, a size line, and
/// the report of what doesn't carry over.
@MainActor
@Suite(.serialized) struct XmindExportSheetTests {
    @Test func sheetWritesTheWholeDocument() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        #expect(ExportFormat.xmind.group == .structural && ExportFormat.xmind.fileExt == "xmind")
        #expect(!ExportFormat.xmind.isText)
        h.controller.openExport(.xmind)
        let s = try #require(h.controller.exportState)
        let data = try #require(h.controller.exportData(s))
        let files = try Zip.read(data)
        #expect(files["Thumbnails/thumbnail.png"].map { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) } == true)
        let back = try XmindFormat.parse(data, name: "Launch plan.xmind")
        #expect(back.canvases.map(\.title) == h.store.model.orderedCanvases.map(\.title))
        #expect(h.controller.exportSizeLine(s) == "1 sheet · 16 topics")
        #expect(h.controller.exportPreview(s) != nil, "the preview shows the canvas")
        // The theme now travels (M18), so a plain map carries over whole.
        let report = XmindWriter.report(h.controller.exportModel(s))
        #expect(report.lines.isEmpty, "\(report.lines)")
        let theme = try #require(
            (try JSONSerialization.jsonObject(with: files["content.json"]!) as? [[String: Any]])?.first?["theme"]
                as? [String: Any])
        #expect(theme["id"] as? String == "opennexus.\(h.canvas.style.theme)")
        var saved: [String] = []
        h.controller.onSaveFile = { _, name in saved.append(name) }
        h.controller.runExport(s)
        #expect(saved == ["Launch plan.xmind"])
        #expect(h.controller.toast?.text == "Saved for Xmind 2020 or later")
    }
}
