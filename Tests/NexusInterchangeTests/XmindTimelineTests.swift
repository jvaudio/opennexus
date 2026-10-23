import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

/// D251: Xmind's horizontal timeline is OpenNexus's alternating timeline, both ways; our
/// own horizontal timeline goes out as Xmind's, reported as an approximation.
@Suite struct XmindTimelineTests {
    let utc = TimeZone(identifier: "UTC")!

    func document(_ s: LayoutStructure, branch: LayoutStructure? = nil) -> DocumentModel {
        var c = Canvas(id: "c1", title: "Roadmap", rootText: "Roadmap")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            for q in ["Q1", "Q2", "Q3"] {
                let id = try! e.addChild(of: e.canvas.root, text: q)
                try! e.addChild(of: id, text: "\(q) goal")
                if q == "Q2", let branch { e.update(id) { $0.structure = branch } }
            }
        }
        c.layout.structure = s
        c.type = .timeline
        return DocumentModel(canvases: [c])
    }

    @Test func structureClassesMapBothWays() {
        #expect(XmindFormat.structure("org.xmind.ui.timeline.horizontal") == .timelineAlternating)
        #expect(XmindFormat.structure("org.xmind.ui.timeline.vertical") == .timelineVertical)
        #expect(XmindFormat.type(for: .timelineAlternating) == .timeline)
        #expect(XmindWriter.structure(.timelineAlternating) == ("org.xmind.ui.timeline.horizontal", true))
        #expect(XmindWriter.structure(.timelineHorizontal) == ("org.xmind.ui.timeline.horizontal", false))
        #expect(XmindWriter.structure(.timelineVertical) == ("org.xmind.ui.timeline.vertical", true))
    }

    @Test func anXmindTimelineImportsAlternating() throws {
        var z = ZipWriter()
        z.add(
            "content.json",
            """
            [{"id": "s1", "class": "sheet", "title": "Plan",
              "rootTopic": {"id": "r", "class": "topic", "title": "Plan",
                "structureClass": "org.xmind.ui.timeline.horizontal",
                "children": {"attached": [{"id": "a", "title": "2025",
                  "children": {"attached": [{"id": "a1", "title": "Kickoff"}]}},
                  {"id": "b", "title": "History", "structureClass": "org.xmind.ui.timeline.horizontal",
                   "children": {"attached": [{"id": "b1", "title": "2020"}]}}]}}}]
            """)
        z.add("manifest.json", #"{"file-entries": {"content.json": {}}}"#)
        let c = try #require(XmindFormat.parse(z.finish(), name: "plan.xmind").canvases.first)
        #expect(c.layout.structure == .timelineAlternating && c.type == .timeline)
        let history = try #require(c.nodes.values.first { $0.text == "History" })
        #expect(history.structure == .timelineAlternating)
    }

    @Test(arguments: [false, true]) func theAlternatingTimelineRoundTrips(xmind8: Bool) throws {
        let doc = document(.timelineAlternating, branch: .timelineAlternating)
        let r = xmind8 ? XmindWriter.exportXMind8(doc, timeZone: utc) : XmindWriter.export(doc, timeZone: utc)
        #expect(!r.report.lines.contains { $0.contains("timeline") }, "exact: nothing to report")
        let back = try #require(XmindFormat.parse(r.data, name: "x.xmind", timeZone: utc).canvases.first)
        #expect(back.layout.structure == .timelineAlternating && back.type == .timeline)
        #expect(back.nodes.values.first { $0.text == "Q2" }?.structure == .timelineAlternating)
    }

    @Test(arguments: [false, true]) func ourTimelineGoesOutAsXmindsAndSaysSo(xmind8: Bool) throws {
        let doc = document(.timelineHorizontal, branch: .timelineHorizontal)
        let r = xmind8 ? XmindWriter.exportXMind8(doc, timeZone: utc) : XmindWriter.export(doc, timeZone: utc)
        let lines = r.report.lines
        #expect(lines.contains("Layout “timeline.horizontal” written as an Xmind org.xmind.ui.timeline.horizontal"))
        #expect(
            lines.contains("Branch layout “timeline.horizontal” written as an Xmind org.xmind.ui.timeline.horizontal"))
        // Xmind draws it alternating, and so does the map when it comes back.
        let back = try #require(XmindFormat.parse(r.data, name: "x.xmind", timeZone: utc).canvases.first)
        #expect(back.layout.structure == .timelineAlternating && back.type == .timeline)
    }
}
