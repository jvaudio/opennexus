import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusTheme

/// M25: Xmind style fidelity. Boundary and summary styles travel both ways (D217), level
/// and quick styles and branch-colour tokens survive a round trip through OpenNexus's
/// record (D218), and another app's boundary, summary and relationship classes import
/// onto each element (D219).
@Suite struct XmindStyleFidelityTests {
    let utc = TimeZone(identifier: "UTC")!

    func export(_ doc: DocumentModel, _ format: String) -> XmindWriter.Result {
        format == "xmind8" ? XmindWriter.exportXMind8(doc, timeZone: utc) : XmindWriter.export(doc, timeZone: utc)
    }

    func roundTrip(_ doc: DocumentModel, _ format: String) throws -> (XmindWriter.Result, Imported) {
        let r = export(doc, format)
        return (r, try XmindFormat.parse(r.data, name: "export.xmind", timeZone: utc))
    }

    /// The first sheet of a Zen export's `content.json`.
    static func sheet(_ data: Data) throws -> [String: Any] {
        let files = try Zip.read(data)
        return try #require(
            (try JSONSerialization.jsonObject(with: files["content.json"]!) as? [[String: Any]])?.first)
    }

    /// The archive with its `content.json` replaced, as if Xmind had saved a change.
    static func edited(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var files = try Zip.read(data)
        var sheets = try #require(try JSONSerialization.jsonObject(with: files["content.json"]!) as? [[String: Any]])
        change(&sheets[0])
        files["content.json"] = try JSONSerialization.data(withJSONObject: sheets, options: [.sortedKeys])
        var z = ZipWriter()
        for name in files.keys.sorted() { z.add(name, files[name]!) }
        return z.finish()
    }

    static func props(_ o: Any?) -> [String: String] {
        (((o as? [String: Any])?["style"] as? [String: Any])?["properties"] as? [String: String]) ?? [:]
    }

    static func kids(_ t: [String: Any]?) -> [[String: Any]] {
        ((t?["children"] as? [String: Any])?["attached"] as? [[String: Any]]) ?? []
    }

    /// A boundary or summary without its ids, for comparing across an import.
    static func look(_ b: Boundary) -> Boundary {
        var b = b
        b.id = ""
        b.nodes = []
        return b
    }

    static func look(_ s: Summary) -> Summary {
        var s = s
        (s.id, s.parent, s.from, s.to, s.topic) = ("", "", "", "", "")
        return s
    }

    // MARK: Boundaries and summaries (D217)

    /// Three boundaries (styled, plain, unfilled) and a styled summary.
    static func elementsDocument() -> DocumentModel {
        var c = Canvas(id: "c1", title: "Elements", rootText: "Plan")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let root = e.canvas.root
            let a = try! e.addChild(of: root, text: "Alpha")
            let b = try! e.addChild(of: root, text: "Beta")
            let g = try! e.addChild(of: root, text: "Gamma")
            let a1 = try! e.addChild(of: a, text: "A1")
            let a2 = try! e.addChild(of: a, text: "A2")
            _ = try! e.addBoundary(around: [a], title: "Styled")
            _ = try! e.addBoundary(around: [b], title: "Plain")
            _ = try! e.addBoundary(around: [g], title: "Open")
            _ = try! e.addSummary(over: [a1, a2], text: "Both")
        }
        c.boundaries[0].color = "#CC3300"
        c.boundaries[0].fillOpacity = 0.2
        c.boundaries[0].dash = "dotted"
        c.boundaries[0].width = 3
        c.boundaries[0].shape = "scallop"
        c.boundaries[2].fillOpacity = 0
        c.boundaries[2].shape = "rectangle"
        c.summaries[0].color = "#117733"
        c.summaries[0].width = 3
        c.summaries[0].bracket = "square"
        return DocumentModel(canvases: [c])
    }

    @Test(arguments: ["zen", "xmind8"]) func boundaryAndSummaryStylesRoundTrip(_ format: String) throws {
        let doc = Self.elementsDocument()
        let c = doc.canvases["c1"]!
        let (out, back) = try roundTrip(doc, format)
        #expect(out.report.skipped.isEmpty, "\(out.report.lines)")
        #expect(back.report.skipped.isEmpty, "\(back.report.lines)")
        let r = try #require(back.canvases.first)
        #expect(r.boundaries.map(Self.look) == c.boundaries.map(Self.look))
        #expect(r.summaries.map(Self.look) == c.summaries.map(Self.look))
        #expect(r.boundaries.map(\.title) == ["Styled", "Plain", "Open"])
    }

    @Test func boundaryAndSummaryStylesUseXmindsKeys() throws {
        let doc = Self.elementsDocument()
        let sheet = try Self.sheet(export(doc, "zen").data)
        let root = sheet["rootTopic"] as? [String: Any]
        let bs = try #require(root?["boundaries"] as? [[String: Any]])
        let styled = Self.props(bs[0])
        let env = StyleEnvironment(theme: .classic, canvasStyle: CanvasStyle())
        #expect(styled["line-color"] == "#CC3300" && styled["line-pattern"] == "dot" && styled["line-width"] == "3pt")
        #expect(styled["shape-class"] == "org.xmind.boundaryShape.scallops" && styled["fill-pattern"] == "solid")
        #expect(styled["svg:fill"] == RGBA(hex: "#CC3300").alpha(0.2).composited(over: env.canvas).hex)
        #expect(Self.props(bs[1]).isEmpty, "a default boundary takes the theme's class")
        #expect(Self.props(bs[2]) == ["fill-pattern": "none", "shape-class": "org.xmind.boundaryShape.rect"])
        let summary = try #require(
            Self.kids(root).first { $0["title"] as? String == "Alpha" }?["summaries"] as? [[String: Any]])
        #expect(
            Self.props(summary[0]) == [
                "line-color": "#117733", "line-width": "3pt", "shape-class": "org.xmind.summaryShape.square",
            ])
        // The theme's classes hold OpenNexus's defaults, so Xmind draws plain ones the same.
        let theme = try #require(sheet["theme"] as? [String: Any])
        let boundary = ((theme["boundary"] as? [String: Any])?["properties"] as? [String: String]) ?? [:]
        #expect(boundary["line-pattern"] == "solid" && boundary["line-color"] == Theme.classic.ring.hex)
        #expect(boundary["svg:fill"] == XmindStyle.fill(Theme.classic.ring, opacity: 0.06, canvas: env.canvas))
        let summaryClass = ((theme["summary"] as? [String: Any])?["properties"] as? [String: String]) ?? [:]
        #expect(summaryClass["shape-class"] == "org.xmind.summaryShape.curly")
    }

    @Test func nearBoundaryShapesAndMeaningsAreReported() throws {
        var doc = Self.elementsDocument()
        var c = doc.canvases["c1"]!
        c.boundaries[1].shape = "stadium"
        c.boundaries[2].meaning = "trust"
        c.boundaries[2].trust = "low"
        c.summaries[0].bracket = "line"
        doc.canvases["c1"] = c
        let (out, back) = try roundTrip(doc, "zen")
        #expect(
            out.report.lines == [
                "Boundary shape “stadium” (written as a near shape)",
                "Boundary meaning (zone, VPC, subnet, trust level)",
                "Summary bracket “line” (written square)",
            ])
        let r = try #require(back.canvases.first)
        #expect(r.boundaries[1].shape == "rounded")
        // A trust boundary is written in the colour and dash the canvas draws it with.
        #expect(r.boundaries[2].color == Theme.classic.critical.hex && r.boundaries[2].dash == "dashed")
        #expect(r.summaries[0].bracket == "square")
    }

    // MARK: Level styles, quick styles and branch colours (D218)

    /// Level styles in branch colours, a quick style, and a topic style in the branch
    /// colour with a shadow Xmind can't draw.
    static func levelsDocument() -> (DocumentModel, TopicStyle) {
        var c = Canvas(id: "c1", title: "Levels", rootText: "Plan")
        var u = UndoStack()
        var (a, a1, b) = (NodeID(""), NodeID(""), NodeID(""))
        c.edit("Sample", undo: &u) { e in
            a = try! e.addChild(of: e.canvas.root, text: "Alpha")
            a1 = try! e.addChild(of: a, text: "Alpha one")
            b = try! e.addChild(of: e.canvas.root, text: "Beta")
            _ = try! e.addChild(of: b, text: "Beta one")
        }
        var main = TopicStyle()
        main.fill = "solid"
        main.fillColor = "branch"
        main.textColor = "#FFFFFF"
        var sub = TopicStyle()
        sub.border = "dashed"
        sub.borderWidth = 2
        sub.borderColor = "branch@0.5"
        c.style.levels = [1: main, 2: sub]
        c.nodes[b]!.quickStyle = "risk"
        var own = TopicStyle()
        own.border = "solid"
        own.borderWidth = 3
        own.borderColor = "branch"
        own.shadow = "soft"
        c.nodes[a1]!.style = own
        return (DocumentModel(canvases: [c]), own)
    }

    @Test(arguments: ["zen", "xmind8"]) func levelAndQuickStylesRoundTrip(_ format: String) throws {
        let (doc, own) = Self.levelsDocument()
        let (out, back) = try roundTrip(doc, format)
        #expect(back.report.skipped.isEmpty, "\(back.report.lines)")
        if format == "xmind8" {
            let xml = try XMLDocument(data: try #require(try Zip.read(out.data)["content.xml"]))
            let records = try xml.nodes(
                forXPath: "//*[local-name()='extension'][@provider='\(XmindStyle.provider)']/*[local-name()='content']")
            #expect(records.count == 5, "the sheet's and four topics' records, as JSON text")
        }
        let r = try #require(back.canvases.first)
        #expect(r.style.levels == doc.canvases["c1"]!.style.levels, "level styles, branch tokens and all")
        func node(_ text: String) throws -> Node { try #require(r.nodes.values.first { $0.text == text }) }
        #expect(try node("Alpha").style == nil && node("Alpha").quickStyle == nil, "its look is the level's")
        #expect(try node("Beta").quickStyle == "risk" && node("Beta").style == nil)
        #expect(try node("Alpha one").style == own, "the branch colour stays a token; the shadow comes back")
        #expect(try node("Beta one").style == nil)
        // A second trip changes nothing.
        let again = try XmindFormat.parse(export(back.document, format).data, name: "x", timeZone: utc)
        #expect(again.canvases.first?.style == r.style)
        #expect(again.canvases.first?.nodes == r.nodes)
    }

    @Test func xmindStillGetsTheResolvedStyles() throws {
        let (doc, _) = Self.levelsDocument()
        let sheet = try Self.sheet(export(doc, "zen").data)
        let record = try #require(
            (sheet["extensions"] as? [[String: Any]])?.first { $0["provider"] as? String == XmindStyle.provider })
        #expect(((record["content"] as? [String: Any])?["levels"] as? [String: Any])?.keys.sorted() == ["1", "2"])
        let alpha = try #require(Self.kids(sheet["rootTopic"] as? [String: Any]).first)
        let p = Self.props(alpha)
        let env = StyleEnvironment(theme: .classic, canvasStyle: doc.canvases["c1"]!.style)
        #expect(p["svg:fill"] == env.branchColor(mainIndex: 0, count: 2).hex && p["fo:color"] == "#FFFFFF")
        let ext = (alpha["extensions"] as? [[String: Any]])?.first { $0["provider"] as? String == XmindStyle.provider }
        let content = try #require(ext?["content"] as? [String: Any])
        #expect(content["written"] as? String == XmindStyle.fingerprint(p) && content["style"] == nil)
        let one = try #require(Self.kids(alpha).first)
        #expect(Self.props(one)["border-line-color"]?.hasPrefix("#") == true)
    }

    @Test func aStyleChangedInXmindWinsOverTheRecord() throws {
        let (doc, _) = Self.levelsDocument()
        let data = try Self.edited(export(doc, "zen").data) { sheet in
            var root = sheet["rootTopic"] as! [String: Any]
            var kids = Self.kids(root)
            var grand = Self.kids(kids[0])
            var style = grand[0]["style"] as! [String: Any]
            var p = style["properties"] as! [String: String]
            p["svg:fill"] = "#00FF00"
            style["properties"] = p
            grand[0]["style"] = style
            var children = kids[0]["children"] as! [String: Any]
            children["attached"] = grand
            kids[0]["children"] = children
            var rc = root["children"] as! [String: Any]
            rc["attached"] = kids
            root["children"] = rc
            sheet["rootTopic"] = root
        }
        let r = try #require(try XmindFormat.parse(data, name: "edited.xmind", timeZone: utc).canvases.first)
        let one = try #require(r.nodes.values.first { $0.text == "Alpha one" }?.style)
        #expect(one.fillColor == "#00FF00" && one.borderColor?.hasPrefix("#") == true && one.shadow == nil)
        #expect(r.nodes.values.first { $0.text == "Beta" }?.quickStyle == "risk", "other topics keep their record")
    }

    // MARK: Theme classes (D219)

    /// Another app's theme with boundary, summary and relationship classes.
    static func classesSheet() -> Data {
        var z = ZipWriter()
        z.add(
            "content.json",
            """
            [{"id": "s1", "title": "Plan", "theme": {"id": "t1", "map": {"properties": {"svg:fill": "#FFFFFF"}},
                "boundary": {"properties": {"line-color": "#FF0000", "svg:fill": "#FFE5E5", "fill-pattern": "solid",
                  "line-pattern": "dash", "line-width": "3pt", "shape-class": "org.xmind.boundaryShape.waves"}},
                "summary": {"properties": {"line-color": "#0000FF", "line-width": "4pt",
                  "shape-class": "org.xmind.summaryShape.round"}},
                "relationship": {"properties": {"line-color": "#00AA00", "line-pattern": "solid",
                  "shape-class": "org.xmind.relationshipShape.straight"}}},
              "rootTopic": {"id": "r", "title": "Plan",
                "boundaries": [{"id": "b1", "range": "(0,0)"},
                  {"id": "b2", "range": "(1,1)", "style": {"properties": {"line-color": "#000000",
                    "shape-class": "org.xmind.boundaryShape.tension"}}}],
                "summaries": [{"id": "s1", "range": "(0,1)", "topicId": "st"}],
                "children": {"attached": [{"id": "a", "title": "A"}, {"id": "b", "title": "B"}, {"id": "c", "title": "C"}],
                  "summary": [{"id": "st", "title": "Both"}]}},
              "relationships": [{"id": "r1", "end1Id": "a", "end2Id": "c"},
                {"id": "r2", "end1Id": "b", "end2Id": "c", "style": {"properties": {"line-color": "#123456"}}}]}]
            """)
        z.add("manifest.json", #"{"file-entries": {"content.json": {}}}"#)
        return z.finish()
    }

    @Test func anotherAppsElementClassesImport() throws {
        let im = try XmindFormat.parse(Self.classesSheet(), name: "plan.xmind")
        let c = try #require(im.canvases.first)
        // The classes are the canvas's element defaults (M31, D245): each element takes
        // their shape, dash, width and fill, and is drawn in their colour unless it has one.
        let e = c.style.elements
        #expect(e.boundary.color == "#FF0000" && e.summary.color == "#0000FF" && e.relationship.color == "#00AA00")
        let plain = c.boundaries[0]
        #expect(plain.color == nil && plain.dash == "dashed" && plain.width == 3 && plain.shape == "wave")
        #expect(plain.fillOpacity == 0.1, "#FFE5E5 is #FF0000 at 10 % over the white map")
        let own = c.boundaries[1]
        #expect(own.color == "#000000" && own.dash == "dashed" && own.shape == "rounded", "its own colour wins")
        #expect(c.summaries.first?.color == nil && c.summaries.first?.width == 4)
        #expect(c.summaries.first?.bracket == "round")
        #expect(c.relationships[0].color == "theme" && c.relationships[0].dash == "solid")
        #expect(c.relationships[0].line == "straight")
        #expect(c.relationships[1].color == "#123456" && c.relationships[1].line == "straight")
        #expect(im.report.lines == ["Boundary shape “tension” (drawn rounded)"])
    }

    @Test func ownUntaggedThemeKeepsItsElementsAndTheme() throws {
        var c = Canvas(id: "c1", title: "Roles", rootText: "Plan")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let a = try! e.addChild(of: e.canvas.root, text: "Alpha")
            let b = try! e.addChild(of: e.canvas.root, text: "Beta")
            _ = try! e.addBoundary(around: [a])
            _ = e.connect(a, to: b)
        }
        c.style.theme = "graphite"
        var main = TopicStyle()
        main.fillColor = "branch"
        c.style.roles = ["main": main]
        let doc = DocumentModel(canvases: [c])
        let (out, back) = try roundTrip(doc, "zen")
        let r = try #require(back.canvases.first)
        // Untagged because of its roles (D211); the record names the theme (D218).
        #expect(r.style.theme == "graphite" && r.style.roles["main"]?.fillColor == "branch")
        #expect(r.boundaries.map(Self.look) == c.boundaries.map(Self.look), "no theme class stamped on it")
        #expect(r.relationships.first?.color == "theme" && r.relationships.first?.dash == "dashed")

        // Picking another theme in Xmind replaces the theme and its id: the record no
        // longer names it, and the new theme's classes apply.
        let changed = try Self.edited(out.data) { sheet in
            var theme = sheet["theme"] as! [String: Any]
            theme["id"] = "xmind-theme"
            theme["relationship"] = ["properties": ["line-color": "#00AA00"]]
            sheet["theme"] = theme
        }
        let x = try #require(try XmindFormat.parse(changed, name: "x.xmind", timeZone: utc).canvases.first)
        #expect(x.style.theme == "classic" && x.style.elements.relationship.color == "#00AA00")
        #expect(x.relationships.first?.color == "theme", "drawn in the canvas's default (D245)")
    }

    @Test func filesWithoutARecordImportAsBefore() throws {
        // A plain Xmind file: no record, so topic styles still come from their properties.
        let (doc, _) = Self.levelsDocument()
        let data = try Self.edited(export(doc, "zen").data) { sheet in
            func strip(_ t: [String: Any]) -> [String: Any] {
                var t = t
                t["extensions"] = nil
                if var ch = t["children"] as? [String: Any] {
                    ch["attached"] = Self.kids(t).map(strip)
                    t["children"] = ch
                }
                return t
            }
            sheet["rootTopic"] = strip(sheet["rootTopic"] as! [String: Any])
            sheet["extensions"] = nil
        }
        let r = try #require(try XmindFormat.parse(data, name: "plain.xmind", timeZone: utc).canvases.first)
        #expect(r.style.levels.isEmpty)
        let alpha = try #require(r.nodes.values.first { $0.text == "Alpha" }?.style)
        #expect(alpha.fillColor?.hasPrefix("#") == true && r.nodes.values.allSatisfy { $0.quickStyle == nil })
    }
}
