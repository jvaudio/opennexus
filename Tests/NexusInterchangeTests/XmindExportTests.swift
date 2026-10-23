import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusTheme

/// M15: `.xmind` export. OpenNexus → .xmind → OpenNexus keeps what Xmind can hold, the
/// archive is well formed, and the sample Xmind files survive a re-export.
@Suite struct XmindExportTests {
    let utc = TimeZone(identifier: "UTC")!

    /// Two canvases using every element Xmind has.
    static func document() -> DocumentModel {
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        var c = Canvas(id: "c1", title: "Launch", rootText: "Launch 2.0")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let root = e.canvas.root
            let build = try! e.addChild(of: root, text: "Build")
            let design = try! e.addChild(of: build, text: "Design")
            let code = try! e.addChild(of: build, text: "Code")
            let docs = try! e.addChild(of: build, text: "Docs")
            let launch = try! e.addChild(of: root, text: "Launch day")
            let risks = try! e.addChild(of: root, text: "Risks")
            let churn = try! e.addChild(of: risks, text: "Churn")
            e.update(build) {
                $0.note = Note(text: "Two sprints.\nThen review.")
                $0.labels = ["Q4", "Core"]
                $0.markers = ["priority-1", "flag-red", "star-gold", "symbol-check", "progress-50"]
                $0.structure = .logicRight
            }
            e.update(risks) {
                $0.folded = true
                $0.link = "https://example.com/risks"
                $0.image = AssetRef(asset: "pic.png", width: 40, height: 30)
                $0.comments = [
                    TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "Too vague?"),
                    TopicComment(author: "Sam", date: "", text: "Agreed"),
                ]
            }
            e.update(churn) { $0.link = TopicLink.make(canvas: "c1", node: launch) }
            e.updateTask(design) {
                $0.start = TaskDate("2026-11-02")
                $0.due = TaskDate("2026-11-06")
                $0.owner = "Ana"
                $0.done = true
            }
            e.updateTask(code) {
                $0.start = TaskDate("2026-11-09")
                $0.due = TaskDate("2026-11-20")
                $0.owner = "Sam, Lee"
                $0.progress = 40
            }
            e.updateTask(docs) { $0.start = TaskDate("2026-11-10") }
            e.updateTask(launch) { $0.due = TaskDate("2026-11-24") }
            e.update(launch) { $0.todo?.done = false }
            try! e.addDependency(code, on: design)
            try! e.addDependency(docs, on: code, type: .startToStart, lag: 1)
            try! e.addDependency(launch, on: docs, type: .finishToFinish, lag: -2)
            let eng = try! e.addBoundary(around: [design, code], title: "Engineering")
            let all = try! e.addBoundary(around: [root], title: "")
            _ = try! e.addSummary(over: [design, docs], text: "Six weeks")
            let embargo = try! e.addCallout(on: launch, text: "Press embargo")
            _ = e.connect(code, to: launch, label: "ships")
            // Relationships to a boundary, a summary's bracket and a callout (D183).
            _ = e.connect(.summary(e.canvas.summaries[0].id), to: .boundary(eng), label: "paces")
            _ = e.connect(.topic(churn), to: .topic(embargo), label: "leaks")
            _ = e.connect(.boundary(all), to: .topic(risks))
            let f = e.addFloating(at: CanvasPoint(x: -380, y: 220.5), text: "Parking lot")
            _ = try! e.addChild(of: f, text: "Dark mode")
            e.updateMeta {
                $0.legend = Legend(position: CanvasPoint(x: 400, y: -60), markers: ["flag-red": "Blocked"])
                $0.layout.structure = .mindmapBalanced
            }
        }
        var org = Canvas(id: "c2", title: "Team", type: .org, rootText: "Team")
        org.edit("Sample", undo: &u) { e in
            let a = try! e.addChild(of: e.canvas.root, text: "Design")
            _ = try! e.addChild(of: e.canvas.root, text: "Engineering")
            e.update(a) { $0.labels = ["Ana"] }
        }
        return DocumentModel(canvases: [c, org], assets: ["pic.png": png])
    }

    /// A canvas as comparable text: topics by path, never by id.
    static func outline(_ c: Canvas) -> [String] {
        var out = ["title \(c.title)", "type \(c.type.rawValue)", "structure \(c.layout.structure.rawValue)"]
        let parents = c.parentMap()
        func path(_ id: NodeID) -> String {
            var parts: [String] = []
            var cur: NodeID? = id
            while let x = cur {
                parts.insert(c.nodes[x]?.text ?? "?", at: 0)
                cur = parents[x]
            }
            return parts.joined(separator: "/")
        }
        func dump(_ id: NodeID) {
            guard let n = c.nodes[id] else { return }
            var line = "\(n.kind.rawValue) \(path(id))"
            if let note = n.note?.text { line += " note=\(note.debugDescription)" }
            if !n.labels.isEmpty { line += " labels=\(n.labels)" }
            if !n.markers.isEmpty { line += " markers=\(n.markers.sorted())" }
            if let s = n.structure { line += " structure=\(s.rawValue)" }
            if n.folded { line += " folded" }
            if let l = n.link {
                line += " link=" + (TopicLink.parse(l).map { "topic:\(path($0.node))" } ?? l)
            }
            if let p = n.position { line += " at=\(p.x),\(p.y)" }
            if let img = n.image { line += " image=\(img.width ?? 0)x\(img.height ?? 0)" }
            if let t = n.todo {
                line += " todo(done=\(t.done)"
                if let s = t.start { line += " start=\(s)" }
                if let d = t.due { line += " due=\(d)" }
                if let o = t.owner { line += " owner=\(o)" }
                if let p = t.progress { line += " progress=\(p)" }
                for d in t.after { line += " after=\(path(d.task)):\(d.type.rawValue):\(d.lag)" }
                line += ")"
            }
            for cm in n.comments { line += " comment=\(cm.author)|\(cm.date)|\(cm.text)" }
            out.append(line)
            for k in n.children { dump(k) }
        }
        for t in c.tops { dump(t) }
        func end(_ e: RelationshipEnd) -> String {
            switch e {
            case .topic(let id): path(id)
            case .zone(let id): "zone \(id)"
            case .boundary(let id):
                c.boundaries.first { $0.id == id }.map { "boundary \($0.title) \($0.nodes.map(path).sorted())" } ?? "?"
            case .summary(let id): c.summaries.first { $0.id == id }.map { "summary \(path($0.topic))" } ?? "?"
            }
        }
        for r in c.relationships { out.append("relationship \(end(r.from)) → \(end(r.to)) \(r.label)") }
        for b in c.boundaries { out.append("boundary \(b.title) \(b.nodes.map(path).sorted())") }
        for s in c.summaries { out.append("summary \(path(s.from))…\(path(s.to)) = \(path(s.topic))") }
        for k in c.callouts { out.append("callout \(path(k.host)) = \(path(k.topic))") }
        if let l = c.legend {
            out.append("legend \(l.visible) \(String(describing: l.position)) \(l.markers.sorted { $0.key < $1.key })")
        }
        return out
    }

    func roundTrip(_ doc: DocumentModel) throws -> (XmindWriter.Result, Imported) {
        let r = XmindWriter.export(doc, timeZone: utc)
        return (r, try XmindFormat.parse(r.data, name: "export.xmind", timeZone: utc))
    }

    @Test func roundTripKeepsWhatXmindHolds() throws {
        let doc = Self.document()
        let (_, back) = try roundTrip(doc)
        #expect(back.canvases.count == 2)
        for (a, b) in zip(doc.orderedCanvases, back.canvases) {
            let x = Self.outline(a)
            let y = Self.outline(b)
            #expect(x == y, "\(Set(x).symmetricDifference(Set(y)).sorted())")
        }
        #expect(back.report.skipped.isEmpty, "\(back.report.lines)")
        #expect(back.report.comments == 2 && back.report.tasks == 4 && back.report.dependencies == 3)
        let pic = try #require(back.canvases[0].nodes.values.first { $0.text == "Risks" }?.image)
        #expect(back.assets[pic.asset] == doc.assets["pic.png"], "the image travels in resources/")
        #expect(back.canvases.allSatisfy { $0.validate().isEmpty })
    }

    @Test func archiveAndJSONAreWellFormed() throws {
        let doc = Self.document()
        let r = XmindWriter.export(doc, thumbnail: Data([0x89, 0x50, 0x4E, 0x47]), timeZone: utc)
        #expect(r.data == XmindWriter.export(doc, thumbnail: Data([0x89, 0x50, 0x4E, 0x47]), timeZone: utc).data)
        let files = try Zip.read(r.data)
        #expect(
            Set(files.keys) == [
                "content.json", "metadata.json", "manifest.json", "content.xml", "META-INF/manifest.xml",
                "resources/pic.png", "Thumbnails/thumbnail.png",
            ])
        let content = try #require(try JSONSerialization.jsonObject(with: files["content.json"]!) as? [[String: Any]])
        #expect(content.map { $0["id"] as? String } == ["sheet-c1", "sheet-c2"])
        #expect(content.allSatisfy { $0["class"] as? String == "sheet" && $0["rootTopic"] is [String: Any] })
        let root = try #require(content[0]["rootTopic"] as? [String: Any])
        #expect(root["structureClass"] as? String == "org.xmind.ui.map.unbalanced")
        #expect(
            (content[1]["rootTopic"] as? [String: Any])?["structureClass"] as? String == "org.xmind.ui.org-chart.down")
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: files["manifest.json"]!) as? [String: [String: Any]])
        #expect(
            Set(manifest["file-entries"]!.keys) == [
                "content.json", "metadata.json", "resources/pic.png", "Thumbnails/thumbnail.png",
            ])
        let meta = try #require(try JSONSerialization.jsonObject(with: files["metadata.json"]!) as? [String: Any])
        #expect(meta["activeSheetId"] as? String == "sheet-c1")
        #expect((meta["creator"] as? [String: Any])?["name"] as? String == "OpenNexus")
        _ = try XMLDocument(data: files["content.xml"]!)
        _ = try XMLDocument(data: files["META-INF/manifest.xml"]!)
        // Every topic id is unique, and relationships, summaries and dependencies point at them.
        var ids: [String] = []
        var elements: [String] = []
        func walk(_ t: [String: Any]) {
            ids.append(t["id"] as! String)
            for key in ["boundaries", "summaries"] {
                elements += ((t[key] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            }
            for (_, v) in (t["children"] as? [String: Any]) ?? [:] { for k in v as! [[String: Any]] { walk(k) } }
        }
        for s in content { walk(s["rootTopic"] as! [String: Any]) }
        #expect(Set(ids).count == ids.count && Set(ids + elements).count == ids.count + elements.count)
        // Relationships end on topics, boundaries or summaries (D183).
        let rels = try #require(content[0]["relationships"] as? [[String: Any]])
        #expect(rels.count == 4)
        for rel in rels {
            #expect((ids + elements).contains(rel["end1Id"] as! String))
            #expect((ids + elements).contains(rel["end2Id"] as! String))
        }
        // Task dates are noon in the writer's time zone (D168).
        let json = String(decoding: files["content.json"]!, as: UTF8.self)
        #expect(json.contains("\"start\":1793620800000"), "2026-11-02T12:00Z")
    }

    @Test func reportListsWhatDoesNotCarryOver() throws {
        var doc = Self.document()
        var c = doc.canvases["c1"]!
        let build = c.nodes.first { $0.value.text == "Build" }!.key
        c.nodes[build]!.markers.append("people-external")
        c.nodes[build]!.sticker = AssetRef(asset: "emoji:🚀")
        c.nodes[build]!.style = try TopicStyle(json: ["shape": "star", "shadow": "soft"], path: "s")
        c.style.nodeStyle = "brutal"
        c.zones = [Zone(id: "z1", title: "Area", origin: CanvasPoint(x: 0, y: 0), width: 200, height: 200)]
        c.relationships.append(Relationship(id: "rz", from: .topic(build), to: .zone("z1")))
        c.layout.structure = .flowDown
        doc.canvases["c1"] = c
        let r = XmindWriter.export(doc, timeZone: utc).report
        #expect(r.sheets == 2 && r.topics == 15)
        let lines = r.lines
        #expect(lines.contains("Marker “people-external” (no Xmind equivalent)"))
        #expect(lines.contains("Sticker"))
        #expect(lines.contains("Topic shape “star” (no Xmind equivalent)"))
        #expect(lines.contains("Topic shadow"))
        #expect(lines.contains("Zone (no Xmind equivalent; its topics are kept)"))
        #expect(lines.contains("Relationship to a zone (zones aren't exported)"), "M16 ends on a zone")
        #expect(lines.contains("Layout “flow.down” written as an Xmind org.xmind.ui.logic.right"))
        #expect(lines.contains("Node style, colour mode and background pattern (Xmind keeps the theme's colours)"))
        #expect(XmindWriter.report(doc) == r)
        #expect(r.text.hasPrefix("Xmind · 2 sheets · 15 topics\n"))
    }

    /// M18, D185, D186: the theme, topic styles and relationship styles go out as Xmind's
    /// style properties and come back.
    @Test func stylesAndThemeRoundTrip() throws {
        let (doc, styled, bare) = Self.styledDocument()
        let c = doc.canvases["c1"]!
        let (out, back) = try roundTrip(doc)
        #expect(out.report.skipped.isEmpty, "\(out.report.lines)")
        #expect(back.report.skipped.isEmpty, "\(back.report.lines)")

        // The file: Xmind's keys on the topic, the relationship and the sheet's theme.
        let files = try Zip.read(out.data)
        let sheet = try #require(
            (try JSONSerialization.jsonObject(with: files["content.json"]!) as? [[String: Any]])?.first)
        let theme = try #require(sheet["theme"] as? [String: Any])
        #expect(theme["id"] as? String == "opennexus.graphite")
        func props(_ o: Any?) -> [String: String] {
            ((o as? [String: Any])?["properties"] as? [String: String]) ?? [:]
        }
        #expect(props(theme["map"])["svg:fill"] == "#101820")
        #expect(props(theme["map"])["multi-line-colors"]?.hasPrefix("#8F89FF #F06C4B") == true)
        #expect(props(theme["centralTopic"])["svg:fill"] == "#F2F2F5")
        #expect(props(theme["centralTopic"])["fo:font-family"] == "Georgia")
        #expect(props(theme["mainTopic"])["line-class"] == "org.xmind.branchConnection.elbow")
        let kids = try #require(
            ((sheet["rootTopic"] as? [String: Any])?["children"] as? [String: Any])?["attached"] as? [[String: Any]])
        let p = props(kids[0]["style"])
        #expect(p["shape-class"] == "org.xmind.topicShape.hexagon" && p["svg:fill"] == "#FFCC00")
        #expect(
            p["border-line-pattern"] == "dash" && p["border-line-width"] == "3pt" && p["border-line-color"] == "#112233"
        )
        #expect(p["fo:font-family"] == "Menlo" && p["fo:font-size"] == "18pt" && p["fo:font-weight"] == "bold")
        #expect(p["fo:font-style"] == "italic" && p["fo:text-decoration"] == "underline")
        #expect(p["fo:text-transform"] == "uppercase" && p["fo:text-align"] == "left" && p["fo:color"] == "#334455")
        #expect(p["line-class"] == "org.xmind.branchConnection.straight" && p["line-color"] == "#AA0000")
        #expect(p["line-width"] == "4pt" && p["line-pattern"] == "dot")
        #expect(props(kids[1]["style"])["svg:fill"] == "#C62F35", "a quick style is written as the topic's own")
        let rp = props((sheet["relationships"] as? [[String: Any]])?.first?["style"])
        #expect(rp["shape-class"] == "org.xmind.relationshipShape.straight")
        #expect(rp["arrow-begin-class"] == "org.xmind.arrowShape.dot")
        #expect(rp["arrow-end-class"] == "org.xmind.arrowShape.triangle")
        #expect(rp["line-pattern"] == "solid" && rp["line-width"] == "3pt" && rp["line-color"] == "#00AA00")

        // Back in OpenNexus.
        try Self.expectStyles(back, original: c, styled: styled, bare: bare)
        // A second trip changes nothing.
        let r = back.canvases[0]
        let again = try XmindFormat.parse(
            XmindWriter.export(back.document, timeZone: utc).data, name: "x", timeZone: utc)
        #expect(again.canvases.first?.style == r.style)
        #expect(again.canvases.first.map(Self.outline) == Self.outline(r))
    }

    /// The styled sample's styles, back from either format.
    static func expectStyles(_ back: Imported, original c: Canvas, styled: TopicStyle, bare: TopicStyle) throws {
        let r = try #require(back.canvases.first)
        #expect(r.style == c.style)
        func node(_ text: String) throws -> Node { try #require(r.nodes.values.first { $0.text == text }) }
        #expect(try node("Styled").style == styled)
        #expect(try node("Bare").style == bare)
        let quick = try #require(QuickStyle.named("very-important")).style
        #expect(try node("Quick").style == quick)
        let rel = try #require(r.relationships.first)
        #expect(rel.line == "straight" && rel.ends == ["dot", "filled-arrow"] && rel.dash == "solid")
        #expect(rel.width == 3 && rel.color == "#00AA00")
    }

    /// A canvas with a theme, canvas overrides, topic styles, a quick style and a styled
    /// relationship.
    static func styledDocument() -> (DocumentModel, TopicStyle, TopicStyle) {
        var c = Canvas(id: "c1", title: "Styled", rootText: "Plan")
        var u = UndoStack()
        var (a, b, d) = (NodeID(""), NodeID(""), NodeID(""))
        c.edit("Sample", undo: &u) { e in
            a = try! e.addChild(of: e.canvas.root, text: "Styled")
            b = try! e.addChild(of: e.canvas.root, text: "Quick")
            d = try! e.addChild(of: a, text: "Bare")
            e.connect(a, to: b, label: "rel")
            e.updateMeta {
                $0.style.theme = "graphite"
                $0.style.background = "#101820"
                $0.style.font = "serif"
                $0.style.lineShape = "elbow"
            }
        }
        var styled = TopicStyle()
        styled.shape = "hexagon"
        styled.fill = "solid"
        styled.fillColor = "#FFCC00"
        styled.border = "dashed"
        styled.borderWidth = 3
        styled.borderColor = "#112233"
        styled.font = "mono"
        styled.fontSize = 18
        styled.fontWeight = "bold"
        styled.italic = true
        styled.underline = true
        styled.strikethrough = false
        styled.textCase = "upper"
        styled.align = "leading"
        styled.textColor = "#334455"
        styled.line = LineStyle(shape: "straight", color: "#AA0000", width: 4, dash: "dotted")
        c.nodes[a]!.style = styled
        c.nodes[b]!.quickStyle = "very-important"
        var bare = TopicStyle()
        bare.fill = "none"
        bare.border = "none"
        c.nodes[d]!.style = bare
        c.relationships[0].line = "straight"
        c.relationships[0].ends = ["dot", "filled-arrow"]
        c.relationships[0].dash = "solid"
        c.relationships[0].width = 3
        c.relationships[0].color = "#00AA00"
        return (DocumentModel(canvases: [c]), styled, bare)
    }

    /// M18, D187, D188: XMind 8 export. The archive is XMind 8's, every XML part is well
    /// formed, and it comes back through the XMind 8 importer with everything the Zen
    /// export keeps: relationships to boundaries, summaries and callouts, comments, task
    /// info, the legend and styles.
    @Test func xmind8RoundTrip() throws {
        let doc = Self.document()
        let r = XmindWriter.exportXMind8(doc, thumbnail: Data([0x89, 0x50, 0x4E, 0x47]), timeZone: utc)
        #expect(r.data == XmindWriter.exportXMind8(doc, thumbnail: Data([0x89, 0x50, 0x4E, 0x47]), timeZone: utc).data)
        #expect(r.report.format == "XMind 8" && r.report.skipped.isEmpty, "\(r.report.lines)")
        #expect(XmindWriter.reportXMind8(doc) == XmindWriter.report(doc).renamed("XMind 8"))
        let files = try Zip.read(r.data)
        #expect(
            Set(files.keys) == [
                "content.xml", "meta.xml", "styles.xml", "comments.xml", "META-INF/manifest.xml",
                "attachments/pic.png", "Thumbnails/thumbnail.png",
            ])
        for name in files.keys where name.hasSuffix(".xml") { _ = try XMLDocument(data: files[name]!) }
        let manifest = try XMLDocument(data: files["META-INF/manifest.xml"]!)
        let listed = Set(
            try manifest.nodes(forXPath: "//*[local-name()='file-entry']/@full-path").compactMap(\.stringValue))
        #expect(listed.isSuperset(of: Set(files.keys)))
        let content = try XMLDocument(data: files["content.xml"]!)
        #expect(try content.nodes(forXPath: "//*[local-name()='sheet']").count == 2)
        // Ids are unique; relationships end on topics, boundaries and summaries.
        let ids = try content.nodes(forXPath: "//*[local-name()='topic']/@id").compactMap(\.stringValue)
        let elements = try content.nodes(
            forXPath: "//*[local-name()='boundary' or local-name()='summary']/@id"
        ).compactMap(\.stringValue)
        #expect(Set(ids + elements).count == ids.count + elements.count)
        let ends = try content.nodes(forXPath: "//*[local-name()='relationship']/@*[name()='end1' or name()='end2']")
        #expect(ends.count == 8 && ends.allSatisfy { (ids + elements).contains($0.stringValue ?? "") })
        #expect(String(decoding: files["content.xml"]!, as: UTF8.self).contains("provider=\"org.xmind.ui.taskInfo\""))

        let back = try XmindFormat.parse(r.data, name: "export.xmind", timeZone: utc)
        #expect(back.report.format == "Xmind" && back.canvases.count == 2)
        for (a, b) in zip(doc.orderedCanvases, back.canvases) {
            let x = Self.outline(a)
            let y = Self.outline(b)
            #expect(x == y, "\(Set(x).symmetricDifference(Set(y)).sorted())")
        }
        #expect(back.report.skipped.isEmpty, "\(back.report.lines)")
        #expect(back.report.comments == 2 && back.report.tasks == 4 && back.report.dependencies == 3)
        let pic = try #require(back.canvases[0].nodes.values.first { $0.text == "Risks" }?.image)
        #expect(back.assets[pic.asset] == doc.assets["pic.png"], "the image travels in attachments/")
        #expect(back.canvases.allSatisfy { $0.validate().isEmpty })
    }

    @Test func xmind8KeepsStyles() throws {
        let (doc, styled, bare) = Self.styledDocument()
        let r = XmindWriter.exportXMind8(doc, timeZone: utc)
        let styles = try XMLDocument(data: try #require(try Zip.read(r.data)["styles.xml"]))
        #expect(
            try styles.nodes(forXPath: "//*[local-name()='style'][@type='theme']/@id").first?.stringValue
                == "opennexus.graphite")
        let back = try XmindFormat.parse(r.data, name: "styled.xmind", timeZone: utc)
        #expect(back.report.skipped.isEmpty, "\(back.report.lines)")
        try Self.expectStyles(back, original: doc.canvases["c1"]!, styled: styled, bare: bare)
    }

    /// The sample files go out as XMind 8 and come back with the same outline.
    @Test(arguments: ["zen.xmind", "xmind8.xmind"]) func sampleFilesSurviveAnXMind8Export(_ name: String) throws {
        let first = try XmindFormat.parse(try fixture(name), name: name, timeZone: utc)
        let second = try XmindFormat.parse(
            XmindWriter.exportXMind8(first.document, timeZone: utc).data, name: name, timeZone: utc)
        #expect(first.canvases.map(Self.outline) == second.canvases.map(Self.outline))
        #expect(
            first.assets.values.sorted { $0.count < $1.count } == second.assets.values.sorted { $0.count < $1.count })
    }

    /// A theme Xmind wrote: OpenNexus keeps its own theme and takes the background and the
    /// topics' own styles.
    @Test func xmindThemeAndTopicStylesImport() throws {
        var z = ZipWriter()
        z.add(
            "content.json",
            """
            [{"id": "s1", "title": "Plan", "theme": {"id": "abc123", "title": "Snowbrush",
                "map": {"properties": {"svg:fill": "#FAFAF0", "multi-line-colors": "#FF0000 #00FF00"}},
                "centralTopic": {"properties": {"fo:font-family": "NeverMind", "svg:fill": "#000000"}}},
              "rootTopic": {"id": "root", "title": "Release",
                "style": {"id": "st1", "properties": {"svg:fill": "#ff8800", "shape-class": "org.xmind.topicShape.diamond",
                  "fo:font-weight": "700", "border-line-width": "2px", "border-line-color": "#000000"}},
                "children": {"attached": [{"id": "p", "title": "Pricing",
                  "style": {"properties": {"fo:font-weight": "normal", "fo:text-decoration": "line-through",
                    "line-class": "org.xmind.branchConnection.roundedElbow"}}}]}}}]
            """)
        z.add("manifest.json", #"{"file-entries": {"content.json": {}}}"#)
        let im = try XmindFormat.parse(z.finish(), name: "plan.xmind")
        let c = try #require(im.canvases.first)
        #expect(c.style.theme == "classic" && c.style.background == "#FAFAF0" && c.style.font == "NeverMind")
        // Another app's theme: its branch colours and topic classes travel with the canvas.
        #expect(c.style.palette == "canvas" && c.style.colors == ["#FF0000", "#00FF00"])
        #expect(c.style.roles["root"]?.fillColor == "#000000" && c.style.roles["root"]?.textColor == "auto")
        #expect(c.style.roles["root"]?.font == nil, "the canvas font already says NeverMind")
        #expect(
            im.report.skipped.map(\.0) == [
                "Xmind theme’s boundary, summary and relationship styles (OpenNexus’s are used)"
            ])
        let root = try #require(c.nodes[c.root]?.style)
        #expect(root.fill == "solid" && root.fillColor == "#FF8800" && root.shape == "diamond")
        #expect(
            root.fontWeight == "bold" && root.border == nil && root.borderWidth == 2 && root.borderColor == "#000000")
        let pricing = try #require(c.nodes.values.first { $0.text == "Pricing" }?.style)
        #expect(pricing.fontWeight == "regular" && pricing.strikethrough == true && pricing.underline == false)
        #expect(pricing.line?.shape == "rounded")
    }

    /// A sheet shaped like Xmind 26's own downloads (D210, D211): a theme with topic classes
    /// and branch colours, and the sheet's own fill over the theme's.
    static func themedSheet() -> Data {
        var z = ZipWriter()
        z.add(
            "content.json",
            """
            [{"id": "s1", "class": "sheet", "title": "Program", "style": {"id": "ss", "properties": {"svg:fill": "#111111FF"}},
              "theme": {"id": "a148", "map": {"properties": {"svg:fill": "#F6F5F5",
                  "multi-line-colors": "#FFC947 #E46D57 #1F3C88"}},
                "centralTopic": {"properties": {"fo:font-family": "NeverMind", "fo:font-size": "28pt",
                  "fo:font-weight": "600", "fo:color": "inherited", "svg:fill": "#070D59", "fill-pattern": "solid",
                  "border-line-width": "0pt", "shape-class": "org.xmind.topicShape.roundedRect",
                  "line-class": "org.xmind.branchConnection.roundedfold", "line-color": "#070D59"}},
                "mainTopic": {"properties": {"fo:font-family": "NeverMind", "fo:font-size": "18pt", "fill-pattern": "solid",
                  "border-line-width": "0pt", "line-class": "org.xmind.branchConnection.roundedElbow"}},
                "subTopic": {"properties": {"fo:font-size": "14pt", "fill-pattern": "solid", "fo:font-style": "normal",
                  "fo:text-decoration": "none", "fo:text-transform": "manual"}},
                "floatingTopic": {"properties": {"fill-pattern": "none", "border-line-width": "3"}}},
              "rootTopic": {"id": "r", "class": "topic", "title": "Program", "structureClass": "org.xmind.ui.logic.right",
                "children": {"attached": [{"id": "a", "title": "Governance",
                  "children": {"attached": [{"id": "a1", "title": "Policy"}]}}, {"id": "b", "title": "Pipeline",
                  "branch": "folded", "children": {"attached": [{"id": "b1", "title": "Scanning"}]}}]}}}]
            """)
        z.add("manifest.json", #"{"file-entries": {"content.json": {}}}"#)
        return z.finish()
    }

    @Test func anotherAppsThemeBecomesTheCanvasStyle() throws {
        let c = try #require(XmindFormat.parse(Self.themedSheet(), name: "program.xmind").canvases.first)
        #expect(c.style.background == "#111111", "the sheet's own fill wins, without its alpha byte")
        #expect(c.style.palette == "canvas" && c.style.colors == ["#FFC947", "#E46D57", "#1F3C88"])
        #expect(c.style.lineShape == nil, "roundedfold reads as curved, the classic theme's own line")
        let r = c.style.roles
        #expect(r["root"]?.fillColor == "#070D59" && r["root"]?.fontSize == 28 && r["root"]?.border == "none")
        #expect(r["root"]?.line == nil, "branch lines keep the branch colours")
        #expect(r["main"]?.fill == "solid" && r["main"]?.fillColor == "branch" && r["main"]?.textColor == "auto")
        #expect(r["sub"]?.fillColor == "branch@0.2" && r["sub"]?.fontSize == 14)
        #expect(r["sub"]?.italic == nil && r["sub"]?.underline == nil && r["sub"]?.textCase == nil)
        #expect(r["floating"]?.fillColor == "canvas" && r["floating"]?.borderColor == "branch")
        #expect(r["floating"]?.borderWidth == 3)
    }

    @Test func roleStylesAndCanvasColoursResolve() throws {
        let c = try #require(XmindFormat.parse(Self.themedSheet(), name: "program.xmind").canvases.first)
        let env = StyleEnvironment(theme: Theme.named(c.style.theme), canvasStyle: c.style)
        #expect(env.palette.map(\.hex) == ["#FFC947", "#E46D57", "#1F3C88"])
        #expect(env.canvas.hex == "#111111")
        let main = StyleResolver.merged(role: .main, depth: 1, node: nil, env: env)
        #expect(main.fillColor == "branch" && main.fontSize == 18)
        // A level style still sits over the role.
        var s = c.style
        var white = TopicStyle()
        white.fillColor = "#FFFFFF"
        s.levels[1] = white
        let lv = StyleResolver.merged(
            role: .main, depth: 1, node: nil, env: StyleEnvironment(theme: Theme.named(s.theme), canvasStyle: s))
        #expect(lv.fillColor == "#FFFFFF" && lv.fontSize == 18)
    }

    @Test func anotherAppsThemeSurvivesAReExport() throws {
        let first = try XmindFormat.parse(Self.themedSheet(), name: "program.xmind")
        let (r, again) = try roundTrip(first.document)
        let files = try Zip.read(r.data)
        let sheet = try #require(
            (try JSONSerialization.jsonObject(with: files["content.json"]!) as? [[String: Any]])?.first)
        let theme = try #require(sheet["theme"] as? [String: Any])
        #expect((theme["id"] as? String)?.hasPrefix(XmindStyle.themePrefix) == false, "written untagged")
        let main = (theme["mainTopic"] as? [String: Any])?["properties"] as? [String: String]
        #expect(
            main?["fill-pattern"] == "solid" && main?["svg:fill"] == nil, "a branch fill is Xmind's colourless fill")
        let a = try #require(first.canvases.first?.style)
        let b = try #require(again.canvases.first?.style)
        #expect(b.colors == a.colors && b.palette == "canvas" && b.background == a.background)
        #expect(b.roles["main"]?.fillColor == "branch" && b.roles["sub"]?.fillColor == "branch@0.2")
        #expect(b.roles["root"]?.fillColor == a.roles["root"]?.fillColor)
    }

    @Test func ownThemeStillExportsTagged() throws {
        let (r, again) = try roundTrip(Self.document())
        let files = try Zip.read(r.data)
        let sheet = try #require(
            (try JSONSerialization.jsonObject(with: files["content.json"]!) as? [[String: Any]])?.first)
        #expect(((sheet["theme"] as? [String: Any])?["id"] as? String) == "\(XmindStyle.themePrefix)classic")
        #expect(again.canvases.first?.style.roles.isEmpty == true && again.canvases.first?.style.palette == "theme")
    }

    @Test(arguments: ["zen.xmind", "xmind8.xmind"]) func sampleFilesSurviveAReExport(_ name: String) throws {
        let first = try XmindFormat.parse(try fixture(name), name: name, timeZone: utc)
        let doc = first.document
        let (_, again) = try roundTrip(doc)
        #expect(again.canvases.count == first.canvases.count)
        for (a, b) in zip(first.canvases, again.canvases) {
            let x = Self.outline(a)
            let y = Self.outline(b)
            #expect(x == y, "\(Set(x).symmetricDifference(Set(y)).sorted())")
        }
        #expect(
            again.assets.values.sorted { $0.count < $1.count } == first.assets.values.sorted { $0.count < $1.count })
    }

    /// Manual check in Xmind: NEXUS_XMIND_OUT=<folder> writes the sample document (Zen and
    /// XMind 8) and the styled sample.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_XMIND_OUT"] != nil)) func writeSample() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_XMIND_OUT"]!)
        try XmindWriter.export(Self.document()).data.write(to: dir.appending(path: "OpenNexus sample.xmind"))
        try XmindWriter.exportXMind8(Self.document()).data.write(
            to: dir.appending(path: "OpenNexus sample (XMind 8).xmind"))
        try XmindWriter.export(Self.styledDocument().0).data.write(to: dir.appending(path: "OpenNexus styles.xmind"))
    }

    /// The re-exported Zen sample's content.json, pretty-printed, for review.
    @Test func zenSampleContentGolden() throws {
        let doc = try XmindFormat.parse(try fixture("zen.xmind"), name: "zen.xmind", timeZone: utc).document
        let files = try Zip.read(XmindWriter.export(doc, timeZone: utc).data)
        let any = try JSONSerialization.jsonObject(with: files["content.json"]!)
        let pretty = try JSONSerialization.data(
            withJSONObject: any, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        golden("export/zen.xmind.content.json", String(decoding: pretty, as: UTF8.self) + "\n")
    }
}

extension ExportReport {
    func renamed(_ format: String) -> ExportReport {
        var r = self
        r.format = format
        return r
    }
}
