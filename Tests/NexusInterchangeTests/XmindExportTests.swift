import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

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
            _ = try! e.addBoundary(around: [design, code], title: "Engineering")
            _ = try! e.addBoundary(around: [root], title: "")
            _ = try! e.addSummary(over: [design, docs], text: "Six weeks")
            _ = try! e.addCallout(on: launch, text: "Press embargo")
            _ = e.connect(code, to: launch, label: "ships")
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
        for r in c.relationships { out.append("relationship \(path(r.from)) → \(path(r.to)) \(r.label)") }
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
        func walk(_ t: [String: Any]) {
            ids.append(t["id"] as! String)
            for (_, v) in (t["children"] as? [String: Any]) ?? [:] { for k in v as! [[String: Any]] { walk(k) } }
        }
        for s in content { walk(s["rootTopic"] as! [String: Any]) }
        #expect(Set(ids).count == ids.count)
        let rel = try #require((content[0]["relationships"] as? [[String: Any]])?.first)
        #expect(ids.contains(rel["end1Id"] as! String) && ids.contains(rel["end2Id"] as! String))
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
        c.nodes[build]!.style = try TopicStyle(json: ["fill": "#FF0000"], path: "s")
        c.zones = [Zone(id: "z1", title: "Area", origin: CanvasPoint(x: 0, y: 0), width: 200, height: 200)]
        c.layout.structure = .flowDown
        doc.canvases["c1"] = c
        let r = XmindWriter.export(doc, timeZone: utc).report
        #expect(r.sheets == 2 && r.topics == 15)
        let lines = r.lines
        #expect(lines.contains("Marker “people-external” (no Xmind equivalent)"))
        #expect(lines.contains("Sticker"))
        #expect(lines.contains("Topic style (Xmind uses its default theme)"))
        #expect(lines.contains("Zone (no Xmind equivalent; its topics are kept)"))
        #expect(lines.contains("Layout “flow.down” written as an Xmind org.xmind.ui.logic.right"))
        #expect(lines.contains("Theme, colours and topic shapes (Xmind uses its default theme)"))
        #expect(XmindWriter.report(doc) == r)
        #expect(r.text.hasPrefix("Xmind · 2 sheets · 15 topics\n"))
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
