import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusTheme

/// M31: Xmind's remaining gaps. What Xmind writes and OpenNexus doesn't use survives a
/// re-save (D242), XMind 8 themes import (D243), Xmind's quick style classes map both ways
/// (D244), an imported theme's element classes are the canvas's defaults (D245), and
/// progress in eighths keeps its eighths (D247). The files are stand-ins shaped like the
/// M23 samples; real files go through `XmindRealFileTests`.
@Suite struct XmindGapsTests {
    let utc = TimeZone(identifier: "UTC")!

    static func zen(_ content: String) -> Data {
        var z = ZipWriter()
        z.add("content.json", content)
        z.add("manifest.json", #"{"file-entries": {"content.json": {}}}"#)
        return z.finish()
    }

    /// The document through a `.nexus` package and back.
    static func resaved(_ doc: DocumentModel) throws -> DocumentModel {
        try NexusPackage.read(files: NexusPackage.files(for: doc))
    }

    static func sheet(_ data: Data) throws -> [String: Any] {
        try XmindStyleFidelityTests.sheet(data)
    }

    static func attached(_ t: [String: Any]?) -> [[String: Any]] { XmindStyleFidelityTests.kids(t) }

    // MARK: Kept data (D242)

    /// A sheet like the roadmap sample: a Pitch extension, layer order, compact mode and
    /// overlapping settings, plus an unknown extension and a numbered topic.
    static func roadmap() -> Data {
        zen(
            """
            [{"id": "7c1b", "class": "sheet", "title": "Roadmap", "compactLayoutModeLevel": 2,
              "topicOverlapping": "overlap", "zones": [],
              "arrangeableLayerOrder": ["2f9a", {"id": "5d0e", "type": "relationship"}, "gone-1", "9b77"],
              "extensions": [{"provider": "org.xmind.ui.skeleton.structure.style", "content": {"centralTopic": "x"}},
                {"provider": "org.xmind.ui.gantt", "content": {"zoom": "week"}}],
              "rootTopic": {"id": "0a1f", "class": "topic", "title": "Roadmap",
                "extensions": [{"provider": "org.xmind.ui.ice-cream-pancake",
                  "content": {"appearance": "dark", "aspectRatio": "16:9"}}],
                "boundaries": [{"id": "9b77", "range": "(0,1)", "title": "H1"}],
                "children": {"attached": [
                  {"id": "3c44", "title": "Q1", "numbering": {"numberFormat": "arabic"},
                    "extensions": [{"provider": "com.example.notes", "content": {"pinned": true}}]},
                  {"id": "8e21", "title": "Q2"}],
                  "detached": [{"id": "2f9a", "title": "Parking lot", "position": {"x": 300, "y": 40}}]}},
              "relationships": [{"id": "5d0e", "end1Id": "3c44", "end2Id": "8e21"}]}]
            """)
    }

    @Test func keptDataImportsWithoutBeingReported() throws {
        let im = try XmindFormat.parse(Self.roadmap(), name: "roadmap.xmind")
        #expect(im.report.skipped.isEmpty, "\(im.report.lines)")
        let c = try #require(im.canvases.first)
        let kept = try #require(c.extra["xmind"])
        #expect(kept["keys"]?["compactLayoutModeLevel"] == 2 && kept["keys"]?["topicOverlapping"] == "overlap")
        #expect(kept["keys"]?["zones"] == nil, "empty zones aren't kept")
        #expect(kept["extensions"]?.arrayValue?.count == 1, "the structure extension is written afresh")
        let order = try #require(kept["layerOrder"]?.arrayValue)
        let floating = try #require(c.floating.first)
        #expect(
            order.map { $0["ref"] } == [
                ["topic": .string(floating.rawValue)], ["relationship": "r1"], ["boundary": "b1"],
            ])
        #expect(order[1]["item"]?["type"] == "relationship", "an entry's other fields are kept")
        let root = try #require(c.nodes[c.root])
        #expect(root.extra["xmind"]?["extensions"]?.arrayValue?.first?["provider"] == "org.xmind.ui.ice-cream-pancake")
        let q1 = try #require(c.nodes.values.first { $0.text == "Q1" })
        #expect(q1.extra["xmind"]?["keys"]?["numbering"]?["numberFormat"] == "arabic")
        #expect(q1.extra["xmind"]?["extensions"]?.arrayValue?.first?["provider"] == "com.example.notes")
        #expect(c.nodes.values.first { $0.text == "Q2" }?.extra.isEmpty == true)
    }

    @Test func reSavingKeepsWhatXmindWrote() throws {
        let doc = try Self.resaved(try XmindFormat.parse(Self.roadmap(), name: "roadmap.xmind").document)
        let out = XmindWriter.export(doc, timeZone: utc)
        #expect(!out.report.lines.contains { $0.contains("Settings kept") })
        let s = try Self.sheet(out.data)
        #expect(s["compactLayoutModeLevel"] as? Int == 2 && s["topicOverlapping"] as? String == "overlap")
        let providers = ((s["extensions"] as? [[String: Any]]) ?? []).compactMap { $0["provider"] as? String }
        #expect(providers.contains("org.xmind.ui.gantt") && providers.contains("org.xmind.ui.skeleton.structure.style"))
        let root = try #require(s["rootTopic"] as? [String: Any])
        let pitch = try #require(
            (root["extensions"] as? [[String: Any]])?.first {
                $0["provider"] as? String == "org.xmind.ui.ice-cream-pancake"
            })
        #expect((pitch["content"] as? [String: Any])?["aspectRatio"] as? String == "16:9")
        let q1 = try #require(Self.attached(root).first)
        #expect((q1["numbering"] as? [String: Any])?["numberFormat"] as? String == "arabic")
        // The layer order names this file's ids, in the same order; the missing entry is gone.
        let detached = try #require(((root["children"] as? [String: Any])?["detached"] as? [[String: Any]])?.first)
        let rel = try #require((s["relationships"] as? [[String: Any]])?.first)
        let boundary = try #require((root["boundaries"] as? [[String: Any]])?.first)
        let order = try #require(s["arrangeableLayerOrder"] as? [Any])
        #expect(order.count == 3)
        #expect(order[0] as? String == detached["id"] as? String)
        #expect((order[1] as? [String: Any])?["id"] as? String == rel["id"] as? String)
        #expect((order[1] as? [String: Any])?["type"] as? String == "relationship")
        #expect(order[2] as? String == boundary["id"] as? String)

        // A second trip changes nothing.
        let again = try XmindFormat.parse(out.data, name: "again.xmind")
        #expect(again.report.skipped.isEmpty, "\(again.report.lines)")
        let a = try #require(doc.canvases["c1"])
        let b = try #require(again.canvases.first)
        #expect(a.extra == b.extra)
        #expect(a.nodes[a.root]?.extra == b.nodes[b.root]?.extra)
    }

    @Test func layerOrderDropsWhatWasDeleted() throws {
        var doc = try XmindFormat.parse(Self.roadmap(), name: "roadmap.xmind").document
        var c = try #require(doc.canvases["c1"])
        var u = UndoStack()
        c.edit("Delete", undo: &u) { e in
            _ = try? e.delete([e.canvas.floating[0]])
            e.updateMeta { $0.relationships = [] }
        }
        doc.canvases["c1"] = c
        let s = try Self.sheet(XmindWriter.export(doc).data)
        #expect((s["arrangeableLayerOrder"] as? [Any])?.count == 1, "only the boundary is left")
    }

    @Test func zonesAreReportedAndXMind8IsToldWhatItMisses() throws {
        let data = Self.zen(
            """
            [{"id": "s", "title": "Z", "zones": [{"id": "z1"}, {"id": "z2"}],
              "rootTopic": {"id": "r", "title": "Z", "extensions": [{"provider": "org.xmind.ui.ice-cream-pancake"}]}}]
            """)
        let im = try XmindFormat.parse(data, name: "z.xmind")
        #expect(im.report.lines == ["Xmind zone (not imported) ×2"])
        let x8 = XmindWriter.exportXMind8(im.document)
        #expect(
            x8.report.lines.contains(
                "Settings kept from an Xmind 2020 or later file (Pitch slides, extensions, layer order)"))
        #expect(XmindWriter.reportXMind8(im.document) == x8.report)
        #expect(!XmindWriter.export(im.document).report.lines.contains { $0.contains("Settings kept") })
    }

    @Test func keptDataIsSchemaValid() throws {
        let doc = try XmindFormat.parse(Self.roadmap(), name: "roadmap.xmind").document
        let issues = SchemaValidator.bundled.validate(package: NexusPackage.files(for: doc))
        #expect(issues.isEmpty, "\(issues)")
    }

    // MARK: XMind 8 themes (D243)

    /// An XMind 8 file shaped like XMind 8's own: styles in `automatic-styles`, the theme
    /// in `master-styles`, lower-case hex, a single branch colour, "none" fills and a sheet
    /// style with its own background.
    static func xmind8() -> Data {
        var z = ZipWriter()
        z.add(
            "content.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="no"?>
            <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" xmlns:fo="http://www.w3.org/1999/XSL/Format" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="2.0">
            <sheet id="s1" theme="t8" style-id="sheetbg"><topic id="r" structure-class="org.xmind.ui.logic.right"><title>Business</title>
            <children><topics type="attached"><topic id="a"><title>Sales</title><children><topics type="attached"><topic id="a1"><title>Leads</title></topic></topics></children></topic><topic id="b"><title>Ops</title></topic></topics></children>
            <boundaries><boundary id="bd" range="(0,1)"><title>Core</title></boundary></boundaries></topic>
            <relationships><relationship end1="a" end2="b" id="rl"/></relationships><title>Business</title></sheet></xmap-content>
            """)
        z.add(
            "styles.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="no"?>
            <xmap-styles xmlns="urn:xmind:xmap:xmlns:style:2.0" xmlns:fo="http://www.w3.org/1999/XSL/Format" xmlns:svg="http://www.w3.org/2000/svg" version="2.0">
            <automatic-styles><style id="sheetbg" type="map"><map-properties svg:fill="#2b2b2b"/></style></automatic-styles>
            <styles>
            <style id="m" type="map"><map-properties color-gradient="none" line-tapered="none" multi-line-colors="none" svg:fill="#ffffff"/></style>
            <style id="c" type="topic"><topic-properties border-line-color="#558ed5" border-line-width="3pt" fo:font-family="Microsoft YaHei" fo:font-weight="bold" line-class="org.xmind.branchConnection.curve" line-color="#558ed5" shape-class="org.xmind.topicShape.roundedRect" svg:fill="#dce6f2"/></style>
            <style id="mt" type="topic"><topic-properties fo:color="#333333" line-color="#558ed5" svg:fill="#f2f2f2"/></style>
            <style id="st" type="topic"><topic-properties fo:font-size="12pt" svg:fill="none"/></style>
            <style id="bs" type="boundary"><boundary-properties line-color="#558ed5" line-pattern="dot" svg:fill="#dde8f7"/></style>
            <style id="rs" type="relationship"><relationship-properties line-color="#ff6600" line-pattern="solid" shape-class="org.xmind.relationshipShape.angled"/></style>
            </styles>
            <master-styles><style id="t8" name="Professional" type="theme"><theme-properties>
            <default-style style-family="map" style-id="m"/><default-style style-family="centralTopic" style-id="c"/>
            <default-style style-family="mainTopic" style-id="mt"/><default-style style-family="subTopic" style-id="st"/>
            <default-style style-family="boundary" style-id="bs"/><default-style style-family="relationship" style-id="rs"/>
            </theme-properties></style></master-styles></xmap-styles>
            """)
        return z.finish()
    }

    @Test func xmind8ThemeClassesImport() throws {
        let im = try XmindFormat.parse(Self.xmind8(), name: "business.xmind")
        #expect(im.report.skipped.isEmpty, "\(im.report.lines)")
        let c = try #require(im.canvases.first)
        let s = c.style
        #expect(s.background == "#2B2B2B", "the sheet's own map style is the background")
        #expect(s.palette == "canvas" && s.colors == ["#558ED5"], "no branch colours: the central topic's line colour")
        #expect(s.font == "Microsoft YaHei")
        #expect(s.roles["root"]?.fillColor == "#DCE6F2" && s.roles["root"]?.borderColor == "#558ED5")
        #expect(s.roles["root"]?.border == "solid" && s.roles["root"]?.borderWidth == 3)
        #expect(s.roles["main"]?.fillColor == "#F2F2F2" && s.roles["main"]?.textColor == "#333333")
        #expect(s.roles["sub"]?.fillColor == "canvas" && s.roles["sub"]?.fontSize == 12, "XMind 8's none fill")
        #expect(s.elements.boundary.color == "#558ED5" && s.elements.boundary.dash == "dotted")
        #expect(s.elements.relationship.color == "#FF6600" && s.elements.relationship.line == "elbow")
        #expect(c.boundaries.first?.dash == "dotted" && c.relationships.first?.line == "elbow")
        let env = StyleEnvironment(theme: Theme.named(s.theme), canvasStyle: s)
        let main = StyleResolver.appearance(role: .main, depth: 1, node: nil, branch: env.palette[0], env: env)
        #expect(main.fill == .solid(RGBA(hex: "#F2F2F2")))
    }

    @Test(arguments: ["zen", "xmind8"]) func xmind8ThemeSurvivesAReExport(_ format: String) throws {
        let first = try XmindFormat.parse(Self.xmind8(), name: "business.xmind", timeZone: utc)
        let data =
            format == "xmind8"
            ? XmindWriter.exportXMind8(first.document, timeZone: utc).data
            : XmindWriter.export(first.document, timeZone: utc).data
        let again = try #require(try XmindFormat.parse(data, name: "again.xmind", timeZone: utc).canvases.first)
        let a = try #require(first.canvases.first)
        #expect(XmindRealFileTests.look(a) == XmindRealFileTests.look(again))
        #expect(again.style.elements == a.style.elements)
        #expect(again.boundaries.map(XmindStyleFidelityTests.look) == a.boundaries.map(XmindStyleFidelityTests.look))
        #expect(again.relationships.map(\.line) == a.relationships.map(\.line))
    }

    // MARK: Quick style classes (D244)

    static func quickSheet() -> Data {
        zen(
            """
            [{"id": "s", "title": "Q", "theme": {"id": "x1", "map": {"properties": {"svg:fill": "#FFFFFF"}},
                "importantTopic": {"properties": {"svg:fill": "#E02020", "fill-pattern": "solid", "fo:color": "#FFFFFF"}},
                "minorTopic": {"properties": {"svg:fill": "#FFE08A", "fill-pattern": "solid"}},
                "expiredTopic": {"properties": {"fo:text-decoration": "line-through", "fo:color": "#999999"}}},
              "rootTopic": {"id": "r", "class": "topic", "title": "Q", "children": {"attached": [
                {"id": "a", "class": "topic importantTopic", "title": "Ship"},
                {"id": "b", "class": "minorTopic", "title": "Polish"},
                {"id": "c", "class": "topic expiredTopic", "title": "Beta"},
                {"id": "d", "class": "topic", "title": "Plain"}]}}}]
            """)
    }

    @Test func xmindQuickStyleClassesImport() throws {
        let im = try XmindFormat.parse(Self.quickSheet(), name: "q.xmind")
        let c = try #require(im.canvases.first)
        func quick(_ t: String) -> String? { c.nodes.values.first { $0.text == t }?.quickStyle }
        #expect(quick("Ship") == "very-important" && quick("Polish") == "important" && quick("Beta") == "cross-out")
        #expect(quick("Plain") == nil)
        // The theme's classes are this canvas's look for those quick styles.
        #expect(c.style.quickStyles["very-important"]?.fillColor == "#E02020")
        #expect(c.style.quickStyles["cross-out"]?.strikethrough == true)
        let env = StyleEnvironment(theme: Theme.named(c.style.theme), canvasStyle: c.style)
        let ship = c.nodes.values.first { $0.text == "Ship" }
        let a = StyleResolver.appearance(role: .main, depth: 1, node: ship, branch: env.palette[0], env: env)
        #expect(a.fill == .solid(RGBA(hex: "#E02020")))
    }

    @Test func quickStylesExportAsXmindClasses() throws {
        var c = Canvas(id: "c1", title: "Q", rootText: "Q")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            for (text, q) in [
                ("Ship", "very-important"), ("Polish", "important"), ("Beta", "cross-out"), ("Risk", "risk"),
            ] {
                let id = try! e.addChild(of: e.canvas.root, text: text)
                e.update(id) { $0.quickStyle = q }
            }
        }
        let out = XmindWriter.export(DocumentModel(canvases: [c]), timeZone: utc)
        let s = try Self.sheet(out.data)
        let kids = Self.attached(s["rootTopic"] as? [String: Any])
        #expect(
            kids.map { $0["class"] as? String } == [
                "topic importantTopic", "topic minorTopic", "topic expiredTopic", "topic",
            ])
        let theme = try #require(s["theme"] as? [String: Any])
        let important = XmindStyleFidelityTests.props(theme["importantTopic"].map { ["style": $0] })
        #expect(important["svg:fill"] == "#C62F35" && important["fo:color"] == "#FFFFFF")
        // Without OpenNexus's record, the classes alone bring the quick styles back.
        let plain = try XmindStyleFidelityTests.edited(out.data) { sheet in
            var root = sheet["rootTopic"] as! [String: Any]
            var ch = root["children"] as! [String: Any]
            ch["attached"] = Self.attached(root).map { t -> [String: Any] in
                var t = t
                t["extensions"] = nil
                return t
            }
            root["children"] = ch
            sheet["rootTopic"] = root
        }
        let back = try #require(try XmindFormat.parse(plain, name: "q.xmind", timeZone: utc).canvases.first)
        func quick(_ t: String) -> String? { back.nodes.values.first { $0.text == t }?.quickStyle }
        #expect(quick("Ship") == "very-important" && quick("Polish") == "important" && quick("Beta") == "cross-out")
        #expect(back.style.quickStyles.isEmpty, "OpenNexus's own theme doesn't make overrides")
    }

    @Test func anotherAppsQuickStylesSurviveAReExport() throws {
        let first = try XmindFormat.parse(Self.quickSheet(), name: "q.xmind", timeZone: utc)
        let out = XmindWriter.export(first.document, timeZone: utc)
        let theme = try #require(try Self.sheet(out.data)["theme"] as? [String: Any])
        let important = XmindStyleFidelityTests.props(theme["importantTopic"].map { ["style": $0] })
        #expect(important["svg:fill"] == "#E02020", "the canvas's look goes back as the class")
        let again = try #require(try XmindFormat.parse(out.data, name: "q.xmind", timeZone: utc).canvases.first)
        #expect(again.style.quickStyles == first.canvases[0].style.quickStyles)
        #expect(again.nodes.values.first { $0.text == "Ship" }?.quickStyle == "very-important")
    }

    // MARK: Element defaults (D245)

    @Test(arguments: ["zen", "xmind8"]) func elementDefaultsRoundTrip(_ format: String) throws {
        let first = try XmindFormat.parse(XmindStyleFidelityTests.classesSheet(), name: "plan.xmind", timeZone: utc)
        var doc = first.document
        var c = try #require(doc.canvases["c1"])
        // New elements after the import take the theme's look (the M25 gap).
        var u = UndoStack()
        c.edit("Add", undo: &u) { e in
            let kids = e.canvas.nodes[e.canvas.root]!.children
            _ = try! e.addBoundary(around: [kids[2]], title: "New")
            _ = try! e.addSummary(over: [kids[1], kids[2]], text: "Later")
            _ = e.connect(kids[2], to: kids[0])
        }
        let nb = try #require(c.boundaries.last)
        #expect(nb.color == nil && nb.dash == "dashed" && nb.width == 3 && nb.shape == "wave" && nb.fillOpacity == 0.1)
        let ns = try #require(c.summaries.last)
        #expect(ns.width == 4 && ns.bracket == "round" && ns.color == nil)
        let nr = try #require(c.relationships.last)
        #expect(nr.line == "straight" && nr.dash == "solid" && nr.color == "theme")
        doc.canvases["c1"] = c
        doc = try Self.resaved(doc)
        let data =
            format == "xmind8"
            ? XmindWriter.exportXMind8(doc, timeZone: utc).data : XmindWriter.export(doc, timeZone: utc).data
        if format == "zen" {
            // Xmind gets the defaults as the theme's classes; elements write only changes.
            let s = try Self.sheet(data)
            let theme = try #require(s["theme"] as? [String: Any])
            let b = XmindStyleFidelityTests.props(theme["boundary"].map { ["style": $0] })
            #expect(b["line-color"] == "#FF0000" && b["shape-class"] == "org.xmind.boundaryShape.waves")
            let root = try #require(s["rootTopic"] as? [String: Any])
            let plain = try #require((root["boundaries"] as? [[String: Any]])?.first)
            #expect(plain["style"] == nil, "a boundary in the defaults writes nothing")
        }
        let again = try #require(try XmindFormat.parse(data, name: "again.xmind", timeZone: utc).canvases.first)
        #expect(again.style.elements == c.style.elements)
        #expect(again.boundaries.map(XmindStyleFidelityTests.look) == c.boundaries.map(XmindStyleFidelityTests.look))
        #expect(again.summaries.map(XmindStyleFidelityTests.look) == c.summaries.map(XmindStyleFidelityTests.look))
        #expect(
            again.relationships.map { [$0.line, $0.dash, $0.color, "\($0.width)"] }
                == c.relationships.map { [$0.line, $0.dash, $0.color, "\($0.width)"] })
    }

    @Test func canvasStyleKeepsItsNewFields() throws {
        var s = CanvasStyle()
        s.elements.boundary = .init(color: "#FF0000", fillOpacity: 0.1, dash: "dashed", width: 3, shape: "wave")
        s.elements.summary = .init(color: "#0000FF", width: 4, bracket: "round")
        s.elements.relationship = .init(color: "#00AA00", line: "straight", ends: ["dot", "arrow"], dash: "solid")
        var q = TopicStyle()
        q.fillColor = "#E02020"
        s.quickStyles = ["very-important": q]
        #expect(try CanvasStyle(json: s.json, path: "style") == s)
        #expect(CanvasStyle().json == (try CanvasStyle(json: CanvasStyle().json, path: "s")).json)
        #expect(CanvasStyle().json["elements"] == nil && CanvasStyle().json["quickStyles"] == nil)
        let v = SchemaValidator.bundled
        func canvas(_ style: JSONValue) -> JSONValue {
            [
                "id": "c1", "type": "mindmap", "root": "n1", "style": style,
                "nodes": ["n1": ["text": "a", "kind": "root", "children": []]],
            ]
        }
        #expect(v.validate(canvas(s.json), definition: "canvas").isEmpty)
        #expect(!v.validate(canvas(["elements": ["boundary": ["width": "3"]]]), definition: "canvas").isEmpty)
    }

    // MARK: Eighths (D247)

    @Test(arguments: ["zen", "xmind8"]) func progressEighthsRoundTrip(_ format: String) throws {
        let data = Self.zen(
            """
            [{"id": "s", "title": "P", "rootTopic": {"id": "r", "title": "P", "children": {"attached": [
              {"id": "a", "title": "A", "markers": [{"markerId": "task-oct"}]},
              {"id": "b", "title": "B", "markers": [{"markerId": "task-3oct"}]},
              {"id": "c", "title": "C", "markers": [{"markerId": "task-5oct"}]},
              {"id": "d", "title": "D", "markers": [{"markerId": "task-7oct"}]},
              {"id": "e", "title": "E", "markers": [{"markerId": "task-quarter"}]}]}}}]
            """)
        let im = try XmindFormat.parse(data, name: "p.xmind")
        let c = try #require(im.canvases.first)
        let kids = c.nodes[c.root]!.children
        #expect(
            kids.map { c.nodes[$0]!.markers } == [
                ["progress-13"], ["progress-38"], ["progress-63"], ["progress-88"], ["progress-25"],
            ])
        #expect(kids.map { c.progress(of: $0) } == [13, 38, 63, 88, 25])
        let out =
            format == "xmind8" ? XmindWriter.exportXMind8(im.document).data : XmindWriter.export(im.document).data
        #expect(XmindWriter.export(im.document).report.skipped.isEmpty)
        let back = try #require(try XmindFormat.parse(out, name: "p.xmind").canvases.first)
        #expect(back.nodes[back.root]!.children.map { back.nodes[$0]!.markers } == kids.map { c.nodes[$0]!.markers })
        if format == "zen" {
            let ids = Self.attached(try Self.sheet(out)["rootTopic"] as? [String: Any]).compactMap {
                (($0["markers"] as? [[String: Any]])?.first)?["markerId"] as? String
            }
            #expect(ids == ["task-oct", "task-3oct", "task-5oct", "task-7oct", "task-quarter"])
        }
    }
}
