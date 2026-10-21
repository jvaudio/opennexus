import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

/// M14: Xmind comments import (Zen inline, Zen `comments.json`, XMind 8 `comments.xml`);
/// Markdown and Word carry them as an appendix. Xmind legends import too.
@Suite struct CommentInterchangeTests {
    func node(_ c: Canvas, _ text: String) -> Node { c.nodes.values.first { $0.text == text }! }

    func zen(_ topics: String, files: [String: String] = [:]) -> Data {
        var z = ZipWriter()
        z.add(
            "content.json",
            """
            [{"id": "s1", "title": "Plan", "rootTopic": {"id": "root", "title": "Release",
              "children": {"attached": [\(topics)]}}}]
            """)
        z.add("manifest.json", #"{"file-entries": {"content.json": {}}}"#)
        for (k, v) in files.sorted(by: { $0.key < $1.key }) { z.add(k, v) }
        return z.finish()
    }

    @Test func zenInlineCommentsInEveryForm() throws {
        let data = zen(
            """
            {"id": "a", "title": "Pricing", "comments": [
              {"author": "Ana", "content": "Drop the annual tier?", "creationTime": 1792504980000,
               "replies": [{"author": {"name": "Sam"}, "content": "Keep it", "createdTime": "2026-10-20T16:00:00+02:00"}]},
              {"authorName": "Lee", "text": {"plain": {"content": "Check margins"}}, "time": 1792505040}]},
            {"id": "b", "title": "Channels", "comments": {"items": [{"creator": "Kim", "body": "Newsletter first"}]}},
            {"id": "c", "title": "Risks", "comments": [{"weird": true}]}
            """)
        let im = try XmindFormat.parse(data, name: "plan.xmind")
        let c = try #require(im.canvases.first)
        let pricing = node(c, "Pricing").comments
        #expect(pricing.map(\.author) == ["Ana", "Sam", "Lee"], "a reply follows the comment it answers")
        #expect(pricing.map(\.text) == ["Drop the annual tier?", "Keep it", "Check margins"])
        #expect(pricing[0].date == "2026-10-20T14:03:00Z", "epoch milliseconds")
        #expect(pricing[1].date == "2026-10-20T14:00:00Z", "ISO 8601 with an offset, normalised to UTC")
        #expect(pricing[2].date == "2026-10-20T14:04:00Z", "epoch seconds")
        let channels = node(c, "Channels").comments
        #expect(channels == [TopicComment(author: "Kim", date: "", text: "Newsletter first")])
        #expect(node(c, "Risks").comments.isEmpty)
        #expect(im.report.comments == 4)
        let skipped = Dictionary(uniqueKeysWithValues: im.report.skipped.map { ($0.0, $0.1) })
        #expect(skipped["Comment in an unknown form"] == 1)
        #expect(skipped["Comment"] == nil, "comments are no longer skipped")
        #expect(im.report.text.contains("4 comments"))
        // The imported canvas validates and round-trips through the file format.
        let doc = DocumentModel(canvases: im.canvases)
        let back = try NexusPackage.read(files: NexusPackage.files(for: doc))
        #expect(back.canvases["c1"]?.nodes == c.nodes)
        #expect(SchemaValidator.bundled.validate(package: NexusPackage.files(for: doc)).isEmpty)
    }

    @Test func zenCommentsJSONByTopic() throws {
        let keyed = zen(
            #"{"id": "a", "title": "Pricing"}, {"id": "b", "title": "Channels"}"#,
            files: [
                "comments.json":
                    #"{"a": [{"author": "Ana", "content": "One", "creationTime": 1792504980000}], "sheet1": [{"author": "X", "content": "On the sheet"}]}"#
            ])
        let im = try XmindFormat.parse(keyed, name: "keyed.xmind")
        let c = try #require(im.canvases.first)
        #expect(node(c, "Pricing").comments.map(\.text) == ["One"])
        #expect(im.report.skipped.contains { $0.0 == "Comment on a sheet or a missing topic" })
        let listed = zen(
            #"{"id": "a", "title": "Pricing"}"#,
            files: ["comments.json": #"[{"objectId": "a", "author": "Ana", "content": "Two"}]"#])
        let c2 = try #require(try XmindFormat.parse(listed, name: "listed.xmind").canvases.first)
        #expect(node(c2, "Pricing").comments.map(\.text) == ["Two"])
    }

    @Test func xmind8CommentsXML() throws {
        var z = ZipWriter()
        z.add(
            "content.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" version="2.0">
            <sheet id="s1"><title>Plan</title><topic id="root"><title>Release</title>
            <children><topics type="attached"><topic id="a"><title>Pricing</title></topic></topics></children>
            </topic></sheet></xmap-content>
            """)
        z.add(
            "comments.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <comments xmlns="urn:xmind:xmap:xmlns:comments:2.0" version="2.0">
            <comment author="Ana" object-id="a" time="1792504980000"><content>Drop the annual tier?</content></comment>
            <comment author="Sam" object-id="a" time="1792505040000"><content>Keep it
            for now</content></comment>
            <comment author="Lee" object-id="s1" time="1792505040000"><content>Sheet note</content></comment>
            </comments>
            """)
        let im = try XmindFormat.parse(z.finish(), name: "x8.xmind")
        let c = try #require(im.canvases.first)
        let cs = node(c, "Pricing").comments
        #expect(cs.map(\.author) == ["Ana", "Sam"])
        #expect(cs[1].text == "Keep it\nfor now")
        #expect(cs[0].date == "2026-10-20T14:03:00Z")
        #expect(im.report.comments == 2)
        #expect(im.report.skipped.contains { $0.0 == "Comment on a sheet or a missing topic" })
    }

    @Test func zenLegend() throws {
        var z = ZipWriter()
        z.add(
            "content.json",
            """
            [{"id": "s1", "title": "Plan", "rootTopic": {"id": "root", "title": "Release",
              "children": {"attached": [{"id": "a", "title": "A", "markers": [{"markerId": "flag-red"}]}]}},
              "legend": {"visibility": "visible", "position": {"x": 412.25, "y": -90},
                "markers": {"flag-red": {"name": "Blocked"}, "priority-1": {"name": "Now"},
                  "smiley-laugh": {"name": "Fun"}, "task-half": {"name": ""}},
                "groups": {"g1": {"name": "Status"}}}},
             {"id": "s2", "title": "Other", "rootTopic": {"id": "r2", "title": "Other"},
              "legend": {"visibility": "hidden", "markers": [{"markerId": "star-blue", "description": "Pick"}]}}]
            """)
        let im = try XmindFormat.parse(z.finish(), name: "legend.xmind")
        #expect(
            im.canvases[0].legend
                == Legend(
                    position: CanvasPoint(x: 412.5, y: -90), markers: ["flag-red": "Blocked", "priority-1": "Now"]))
        #expect(im.canvases[1].legend == Legend(visible: false, markers: ["star-blue": "Pick"]))
        let skipped = im.report.skipped.map(\.0)
        #expect(skipped.contains("Legend description for marker “smiley-laugh” (no equivalent)"))
        #expect(skipped.contains("Legend marker group names"))
        #expect(!skipped.contains("Legend"))
    }

    @Test func xmind8Legend() throws {
        var z = ZipWriter()
        z.add(
            "content.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" xmlns:svg="http://www.w3.org/2000/svg" version="2.0">
            <sheet id="s1"><title>Plan</title><topic id="root"><title>Release</title></topic>
            <legend visibility="visible"><position svg:x="300" svg:y="-120"/>
            <marker-descriptions><marker-description description="Blocked" marker-id="flag-red"/>
            <marker-description description="Done" marker-id="task-done"/></marker-descriptions></legend>
            </sheet></xmap-content>
            """)
        let im = try XmindFormat.parse(z.finish(), name: "x8.xmind")
        #expect(
            im.canvases[0].legend
                == Legend(
                    position: CanvasPoint(x: 300, y: -120), markers: ["flag-red": "Blocked", "progress-100": "Done"]))
    }

    func commented() -> Canvas {
        var c = launchPlan()
        let pricing = c.nodes.first { $0.value.text == "Pricing" }!.key
        let pro = c.nodes.first { $0.value.text == "Pro" }!.key
        c.nodes[pricing]!.comments = [
            TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "Drop the annual tier?\nOr discount it."),
            TopicComment(author: "", date: "", text: "Agreed"),
        ]
        c.nodes[pro]!.comments = [TopicComment(author: "Sam", date: "2026-10-21T09:00:00Z", text: "Price check")]
        return c
    }

    @Test func markdownAppendix() {
        let c = commented()
        let md = MarkdownFormat.export(c)
        let tail = md.components(separatedBy: "## Comments\n\n").last ?? ""
        #expect(md.contains("## Comments\n\n"))
        #expect(
            tail.hasPrefix(
                """
                - **Pricing** · Ana · 2026-10-20: Drop the annual tier?
                  Or discount it.
                - **Pricing**: Agreed
                - **Pro** · Sam · 2026-10-21: Price check
                """))
        var o = MarkdownFormat.Options()
        o.comments = false
        #expect(!MarkdownFormat.export(c, options: o).contains("## Comments"))
        let pro = c.nodes.first { $0.value.text == "Pro" }!.key
        let branch = MarkdownFormat.export(c, from: pro)
        #expect(branch.contains("Price check") && !branch.contains("Agreed"), "a branch export keeps its own comments")
        #expect(!MarkdownFormat.export(launchPlan()).contains("## Comments"), "no heading without comments")
    }

    @Test func wordAppendix() throws {
        let doc = DocumentModel(canvases: [commented()])
        let files = try Zip.read(WordFormat.export(doc))
        let xml = String(decoding: try #require(files["word/document.xml"]), as: UTF8.self)
        let appendix = try #require(xml.range(of: ">Comments</w:t>"))
        #expect(xml[appendix.upperBound...].contains("Pricing · Ana · 2026-10-20"))
        #expect(xml[appendix.upperBound...].contains("Price check"))
        #expect(String(decoding: files["word/styles.xml"]!, as: UTF8.self).contains("CommentHead"))
        _ = try XMLDocument(data: files["word/document.xml"]!)
    }
}
