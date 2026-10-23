import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusTheme

/// M23: real Xmind files, checked by hand on request. Nothing here runs unless
/// `NEXUS_XMIND_REAL` names one or more `.xmind` files (separated by `|`); the files stay
/// where they are and nothing from them is kept in the repository.
///
///     NEXUS_XMIND_REAL="/path/a.xmind|/path/b.xmind" NEXUS_XMIND_OUT=<folder> \
///         swift test --filter XmindRealFileTests
///
/// For each file:
/// 1. Every Xmind topic is found at its path, in order, with its fold and marker count;
///    the walk reads Xmind's JSON directly, not through the importer.
/// 2. Export to .xmind and XMind 8 and import again: the outline and canvas style match.
/// 3. With `NEXUS_XMIND_OUT`: an edited copy (an "OpenNexus export test" branch using
///    every element the export writes, plus notes and tasks on existing topics) and a plain
///    copy are saved as .nexus for `nexus export --to xmind`/`xmind8`, with a report. The
///    edited copy's .xmind and XMind 8 exports are imported again and must match the edits.
@Suite(.serialized) struct XmindRealFileTests {
    static let files: [URL] = (ProcessInfo.processInfo.environment["NEXUS_XMIND_REAL"] ?? "")
        .split(separator: "|").map { URL(fileURLWithPath: String($0)) }
    static var enabled: Bool { !files.isEmpty }

    /// Xmind's own topics, read straight from content.json: "kind path", in order.
    static func xmindOutline(_ data: Data) throws -> [[String]] {
        let files = try Zip.read(data)
        let content = try #require(files["content.json"])
        let sheets = try #require(try JSONSerialization.jsonObject(with: content) as? [[String: Any]])
        return sheets.map { sheet in
            var out: [String] = []
            func walk(_ t: [String: Any], _ path: String, floating: Bool) {
                let title = t["title"] as? String ?? ""
                let p = path.isEmpty ? title : path + "/" + title
                var line = "\(floating ? "floating" : "topic") \(p)"
                if (t["branch"] as? String) == "folded" { line += " folded" }
                let markers = (t["markers"] as? [Any])?.count ?? 0
                if markers > 0 { line += " markers=\(markers)" }
                out.append(line)
                let kids = t["children"] as? [String: Any] ?? [:]
                for k in kids["attached"] as? [[String: Any]] ?? [] { walk(k, p, floating: false) }
                for k in kids["detached"] as? [[String: Any]] ?? [] { walk(k, "", floating: true) }
            }
            if let root = sheet["rootTopic"] as? [String: Any] { walk(root, "", floating: false) }
            return out
        }
    }

    /// The same shape from an imported canvas (main tree, then floating branches).
    static func ourOutline(_ c: Canvas) -> [String] {
        var out: [String] = []
        func walk(_ id: NodeID, _ path: String, floating: Bool) {
            guard let n = c.nodes[id] else { return }
            let p = path.isEmpty ? n.text : path + "/" + n.text
            var line = "\(floating ? "floating" : "topic") \(p)"
            if n.folded { line += " folded" }
            if !n.markers.isEmpty { line += " markers=\(n.markers.count)" }
            out.append(line)
            for k in n.children where c.nodes[k]?.kind == .topic { walk(k, p, floating: false) }
        }
        walk(c.root, "", floating: false)
        for f in c.floating { walk(f, "", floating: true) }
        return out
    }

    static func diff(_ a: [String], _ b: [String]) -> String {
        let only = Set(a).symmetricDifference(Set(b)).sorted().prefix(12)
        return only.isEmpty ? "same lines, different order" : only.joined(separator: "\n")
    }

    @Test(.enabled(if: enabled)) func everyTopicImports() throws {
        for url in Self.files {
            let data = try Data(contentsOf: url)
            let im = try XmindFormat.parse(data, name: url.lastPathComponent)
            let theirs = try Self.xmindOutline(data)
            #expect(im.canvases.count == theirs.count, "\(url.lastPathComponent): sheets")
            for (c, x) in zip(im.canvases, theirs) {
                let ours = Self.ourOutline(c)
                #expect(ours == x, "\(url.lastPathComponent) › \(c.title):\n\(Self.diff(ours, x))")
            }
        }
    }

    /// How a canvas looks, role by role: what a re-export must keep. The writer writes
    /// whole resolved styles, so their fields differ even when the result is the same.
    static func look(_ c: Canvas) -> [String] {
        let env = StyleEnvironment(theme: Theme.named(c.style.theme), canvasStyle: c.style)
        var out = [
            "canvas \(env.canvas.hex)", "palette \(env.palette.map(\.hex))", "font \(c.style.font ?? "-")",
            "line \(c.style.lineShape ?? "-")",
        ]
        for (role, depth) in [(NodeRoleStyle.root, 0), (.main, 1), (.sub, 2), (.floating, 1)] {
            let a = StyleResolver.appearance(
                role: role, depth: depth, node: nil, branch: env.palette.first ?? env.theme.ring, env: env)
            out.append("\(role) \(a)")
        }
        return out
    }

    @Test(.enabled(if: enabled)) func reExportsKeepEverything() throws {
        for url in Self.files {
            let first = try XmindFormat.parse(try Data(contentsOf: url), name: url.lastPathComponent)
            for (format, data) in [
                ("xmind", XmindWriter.export(first.document).data),
                ("xmind8", XmindWriter.exportXMind8(first.document).data),
            ] {
                let again = try XmindFormat.parse(data, name: "again.xmind")
                #expect(again.canvases.count == first.canvases.count)
                for (a, b) in zip(first.canvases, again.canvases) {
                    let x = XmindExportTests.outline(a)
                    let y = XmindExportTests.outline(b)
                    #expect(x == y, "\(url.lastPathComponent) › \(format):\n\(Self.diff(x, y))")
                    if format == "xmind" {
                        #expect(
                            Self.look(a) == Self.look(b),
                            "\(url.lastPathComponent): look after a re-export\n\(Self.look(a))\n\(Self.look(b))")
                    }
                }
            }
        }
    }

    /// The edits: a test branch using every element the .xmind export writes, and
    /// annotations on the first two main topics. Returns the document and what was added.
    static func edited(_ doc: DocumentModel) -> DocumentModel {
        var doc = doc
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        doc.assets["opennexus-test.png"] = png
        for id in doc.orderedCanvases.map(\.id) {
            var c = doc.canvases[id]!
            var u = UndoStack()
            c.edit("OpenNexus export test", undo: &u) { e in
                let root = e.canvas.root
                let mains = e.canvas.nodes[root]?.children ?? []
                // Annotate existing topics without changing their text.
                if let a = mains.first {
                    e.update(a) {
                        $0.note = Note(text: "Added by OpenNexus.\nSecond line of the note.")
                        $0.labels.append("OpenNexus")
                    }
                    e.updateTask(a) {
                        $0.start = TaskDate("2026-11-02")
                        $0.due = TaskDate("2026-11-13")
                        $0.owner = "Security team"
                        $0.progress = 30
                    }
                }
                if mains.count > 1 {
                    let b = mains[1]
                    e.update(b) {
                        $0.markers.append("priority-1")
                        $0.comments.append(
                            TopicComment(author: "OpenNexus", date: "2026-10-22T15:00:00Z", text: "Review this branch"))
                    }
                    _ = e.connect(mains[0], to: b, label: "depends on")
                }
                // The test branch.
                let t = try! e.addChild(of: root, text: "OpenNexus export test")
                e.update(t) {
                    $0.note = Note(text: "Everything under this topic was added by OpenNexus to test its export.")
                    $0.markers = ["flag-red", "star-gold"]
                    var s = TopicStyle()
                    s.fill = "solid"
                    s.fillColor = "#2E7D4F"
                    s.textColor = "#FFFFFF"
                    s.shape = "pill"
                    $0.style = s
                }
                let plan = try! e.addChild(of: t, text: "Plan the pilot")
                let build = try! e.addChild(of: t, text: "Build the scanner")
                let ship = try! e.addChild(of: t, text: "Roll out")
                let links = try! e.addChild(of: t, text: "Links and media")
                let web = try! e.addChild(of: links, text: "OWASP Top 10")
                let jump = try! e.addChild(of: links, text: "Jump to Plan the pilot")
                let pic = try! e.addChild(of: links, text: "A picture")
                e.update(web) { $0.link = "https://owasp.org/www-project-top-ten/" }
                e.update(jump) { $0.link = TopicLink.make(canvas: id, node: plan) }
                e.update(pic) { $0.image = AssetRef(asset: "opennexus-test.png", width: 48, height: 48) }
                e.update(links) { $0.folded = true }
                e.updateTask(plan) {
                    $0.start = TaskDate("2026-11-02")
                    $0.due = TaskDate("2026-11-06")
                    $0.owner = "Ana"
                    $0.done = true
                }
                e.updateTask(build) {
                    $0.start = TaskDate("2026-11-09")
                    $0.due = TaskDate("2026-11-20")
                    $0.owner = "Sam, Lee"
                    $0.progress = 40
                }
                e.updateTask(ship) { $0.due = TaskDate("2026-11-27") }
                e.update(ship) { $0.todo?.done = false }
                try! e.addDependency(build, on: plan)
                try! e.addDependency(ship, on: build, type: .startToStart, lag: 2)
                e.update(build) {
                    $0.labels = ["pilot", "Q4"]
                    $0.markers = ["progress-50"]
                }
                let zone = try! e.addBoundary(around: [plan, build], title: "Pilot")
                _ = try! e.addSummary(over: [plan, ship], text: "Four weeks")
                let risk = try! e.addCallout(on: ship, text: "Change freeze in December")
                _ = e.connect(.boundary(zone), to: .topic(ship), label: "feeds")
                _ = e.connect(.topic(risk), to: .topic(t))
                let parked = e.addFloating(at: CanvasPoint(x: -420, y: 360), text: "Parked: OpenNexus idea")
                _ = try! e.addChild(of: parked, text: "Revisit in Q1")
                e.updateMeta {
                    $0.legend = Legend(
                        // Below and left of the central topic, clear of logic and timeline maps.
                        position: CanvasPoint(x: -760, y: 620),
                        markers: ["flag-red": "Needs a decision", "priority-1": "Do first"])
                }
            }
            doc.canvases[id] = c
        }
        return doc
    }

    @Test(.enabled(if: enabled)) func editedCopiesExportAndReadBack() throws {
        let out = ProcessInfo.processInfo.environment["NEXUS_XMIND_OUT"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var report = ""
        for url in Self.files {
            let base = url.deletingPathExtension().lastPathComponent
            let first = try XmindFormat.parse(try Data(contentsOf: url), name: url.lastPathComponent)
            let doc = Self.edited(first.document)
            let plain = XmindWriter.export(first.document)
            let zen = XmindWriter.export(doc)
            let x8 = XmindWriter.exportXMind8(doc)
            // What we wrote reads back as the edits.
            for (format, data) in [("xmind", zen.data), ("xmind8", x8.data)] {
                let again = try XmindFormat.parse(data, name: "edited.xmind")
                for (a, b) in zip(doc.orderedCanvases, again.canvases) {
                    let x = XmindExportTests.outline(a)
                    let y = XmindExportTests.outline(b)
                    #expect(x == y, "\(base) edited › \(format):\n\(Self.diff(x, y))")
                }
                #expect(again.document.assets.values.contains(doc.assets["opennexus-test.png"]!), "\(format): image")
            }
            report += "\(base)\n  import: \(first.canvases.count) sheet(s), "
            report += "\(first.canvases.map { $0.nodes.count }.reduce(0, +)) elements\n"
            for (what, n) in first.report.skipped { report += "    not converted: \(what)\(n > 1 ? " ×\(n)" : "")\n" }
            for (name, r) in [
                ("re-export", plain.report), ("edited .xmind", zen.report), ("edited XMind 8", x8.report),
            ] {
                report += "  \(name): \(r.topics) topics"
                report += r.skipped.isEmpty ? "\n" : ", left out or approximated:\n"
                for (what, n) in r.skipped { report += "    \(what)\(n > 1 ? " ×\(n)" : "")\n" }
            }
            if let out {
                // The maps, for `nexus export --to xmind` (which adds Xmind's thumbnail) or
                // opening in OpenNexus.
                let maps = out.appending(path: "OpenNexus maps")
                try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
                for (name, d) in [("\(base) – OpenNexus re-export", first.document), ("\(base) – OpenNexus edit", doc)]
                {
                    let u = maps.appending(path: "\(name).nexus")
                    try? FileManager.default.removeItem(at: u)
                    try NexusPackage.write(d, to: u)
                }
            }
        }
        if let out {
            try report.write(to: out.appending(path: "OpenNexus export report.txt"), atomically: true, encoding: .utf8)
        }
        print(report)
    }
}
