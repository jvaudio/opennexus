import Foundation
import NexusCore
import NexusFormat
import NexusTheme

/// What an export couldn't carry into the other format, by kind, with counts (M15).
public struct ExportReport: Sendable, Equatable {
    public var format: String
    public var sheets = 0
    public var topics = 0
    /// Things left out or approximated, in first-seen order, with how often each occurred.
    public private(set) var skipped: [(String, Int)] = []

    public init(format: String) { self.format = format }

    public mutating func skip(_ what: String, _ n: Int = 1) {
        if let i = skipped.firstIndex(where: { $0.0 == what }) {
            skipped[i].1 += n
        } else {
            skipped.append((what, n))
        }
    }

    public var notConverted: Int { skipped.reduce(0) { $0 + $1.1 } }
    public var lines: [String] { skipped.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 } }

    public static func == (a: ExportReport, b: ExportReport) -> Bool {
        a.format == b.format && a.sheets == b.sheets && a.topics == b.topics && a.skipped.map(\.0) == b.skipped.map(\.0)
            && a.skipped.map(\.1) == b.skipped.map(\.1)
    }

    /// Plain-text form (the CLI and tests).
    public var text: String {
        var s = "\(format) · \(sheets) sheets · \(topics) topics\n\(notConverted) not converted\n"
        for l in lines { s += "· \(l)\n" }
        return s
    }
}

/// `.xmind` export (M15): a modern Xmind ("Zen", 2020 and later) file with one sheet per
/// canvas, written by hand with `ZipWriter` (D89, D166).
///
/// The archive holds `content.json`, `metadata.json` and `manifest.json`, the topics'
/// images and attachments under `resources/` and `attachments/`, an optional thumbnail,
/// and a `content.xml` that only tells XMind 8 to use a newer Xmind (D167). Ids are
/// derived from canvas and topic ids, so the same document always writes the same bytes.
public enum XmindWriter {
    public struct Result: Sendable {
        public var data: Data
        public var report: ExportReport
    }

    /// `timeZone` turns task days into instants: noon on the day there (D168).
    public static func export(
        _ doc: DocumentModel, thumbnail: Data? = nil, timeZone: TimeZone = .current, version: String = "1.0"
    ) -> Result {
        let (w, sheets) = build(doc, zone: timeZone)
        var z = ZipWriter()
        z.add("content.json", json(sheets))
        let first = sheets.first?["id"] as? String ?? ""
        z.add(
            "metadata.json",
            json(
                [
                    "creator": ["name": "OpenNexus", "version": version], "dataStructureVersion": "2",
                    "layoutEngineVersion": "3", "activeSheetId": first,
                ] as [String: Any]))
        var entries: [String: Any] = ["content.json": [:] as [String: Any], "metadata.json": [:] as [String: Any]]
        for name in w.files.keys.sorted() {
            z.add(name, w.files[name]!)
            entries[name] = [:] as [String: Any]
        }
        if let thumbnail {
            z.add("Thumbnails/thumbnail.png", thumbnail)
            entries["Thumbnails/thumbnail.png"] = [:] as [String: Any]
        }
        z.add("manifest.json", json(["file-entries": entries]))
        z.add("content.xml", legacyNotice)
        z.add(
            "META-INF/manifest.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="no"?>
            <manifest xmlns="urn:xmind:xmap:xmlns:manifest:1.0"><file-entry full-path="content.xml" media-type="text/xml"/><file-entry full-path="META-INF/" media-type=""/><file-entry full-path="META-INF/manifest.xml" media-type="text/xml"/></manifest>
            """)
        return Result(data: z.finish(), report: w.report)
    }

    /// The export's report alone (the export sheet), without writing the archive.
    public static func report(_ doc: DocumentModel) -> ExportReport { build(doc, zone: .current).0.report }

    static func build(_ doc: DocumentModel, zone: TimeZone) -> (Writer, [[String: Any]]) {
        var w = Writer(doc: doc, zone: zone)
        let sheets = doc.orderedCanvases.map { w.sheet($0) }
        if !doc.chats.isEmpty { w.report.skip("AI chats") }
        return (w, sheets)
    }

    /// What XMind 8 shows: Xmind 2020 and later read `content.json` instead.
    static let legacyNotice = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" version="2.0"><sheet id="notice"><title>Xmind 2020 or later</title><topic id="notice-root" structure-class="org.xmind.ui.logic.right"><title>Open this map in Xmind 2020 or later</title><children><topics type="attached"><topic id="notice-1"><title>It was saved by OpenNexus in the current Xmind format. Saving it in XMind 8 would lose its contents.</title></topic></topics></children></topic></sheet></xmap-content>
        """

    static func json(_ v: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: Mapping

    /// OpenNexus marker → Xmind marker id (nil: no equivalent). Inverse of the importer's
    /// mapping where one exists.
    public static func marker(_ id: String) -> String? {
        if id.hasPrefix("priority-"), let n = Int(id.dropFirst(9)), (1...9).contains(n) { return id }
        switch id {
        case "progress-0": return "task-start"
        case "progress-25": return "task-quarter"
        case "progress-50": return "task-half"
        case "progress-75": return "task-3quar"
        case "progress-100": return "task-done"
        case "flag-red", "flag-orange", "flag-green", "flag-blue": return id
        case "star-gold": return "star-yellow"
        case "star-red", "star-blue": return id
        case "symbol-question": return "symbol-question"
        case "symbol-exclaim": return "symbol-exclam"
        case "symbol-check": return "symbol-right"
        case "symbol-cross": return "symbol-wrong"
        case "symbol-arrow": return "arrow-right"
        case "people-me": return "people-red"
        case "people-team": return "people-blue"
        default: return nil
        }
    }

    /// OpenNexus layout → Xmind structure class, and whether that's only an approximation.
    public static func structure(_ s: LayoutStructure) -> (String, exact: Bool) {
        switch s {
        case .mindmapBalanced: ("org.xmind.ui.map.unbalanced", true)
        case .mindmapRight: ("org.xmind.ui.map.clockwise", true)
        case .mindmapLeft: ("org.xmind.ui.map.anticlockwise", true)
        case .logicRight: ("org.xmind.ui.logic.right", true)
        case .logicLeft: ("org.xmind.ui.logic.left", true)
        case .braceRight: ("org.xmind.ui.brace.right", true)
        case .braceLeft: ("org.xmind.ui.brace.left", true)
        case .orgDown: ("org.xmind.ui.org-chart.down", true)
        case .treeIndented: ("org.xmind.ui.tree.right", true)
        case .treeDown: ("org.xmind.ui.org-chart.down", false)
        // Xmind has one horizontal timeline, drawn like ours alternating (D251).
        case .timelineAlternating: ("org.xmind.ui.timeline.horizontal", true)
        case .timelineHorizontal: ("org.xmind.ui.timeline.horizontal", false)
        case .timelineVertical: ("org.xmind.ui.timeline.vertical", true)
        case .fishboneLeft: ("org.xmind.ui.fishbone.leftHeaded", true)
        case .fishboneRight: ("org.xmind.ui.fishbone.rightHeaded", true)
        case .treeTable: ("org.xmind.ui.treetable", true)
        case .matrix: ("org.xmind.ui.matrix", true)
        default: ("org.xmind.ui.logic.right", false)
        }
    }

    // MARK: Writer

    struct Writer {
        let doc: DocumentModel
        let zone: TimeZone
        var report = ExportReport(format: "Xmind")
        /// Archive path → bytes (images and attachments).
        var files: [String: Data] = [:]
        var canvas = Canvas(id: "c", title: "")
        var parents: [NodeID: NodeID] = [:]
        /// Topics with a boundary or summary of their own, by parent.
        var boundaries: [NodeID: [[String: Any]]] = [:]
        var summaries: [NodeID: [(range: String, topic: NodeID, id: String, style: [String: String])]] = [:]
        var callouts: [NodeID: [NodeID]] = [:]
        /// Boundaries and summaries this sheet writes, which relationships can name.
        var written = Set<RelationshipEnd>()
        /// The document's custom themes, palettes and quick styles.
        let library: StyleLibrary
        /// The sheet's theme and canvas style, as the canvas resolves them (M18).
        var env: StyleEnvironment

        init(doc: DocumentModel, zone: TimeZone) {
            self.doc = doc
            self.zone = zone
            library = StyleLibrary(json: doc.theme)
            env = StyleEnvironment(theme: .classic, canvasStyle: CanvasStyle())
        }

        mutating func lose(_ lost: [String]) { for l in lost { report.skip(l) } }

        /// A colour token on `nid` as hex: its branch colour for `branch`, theme tokens,
        /// or the hex itself.
        func color(_ token: String, on nid: NodeID) -> String? {
            let branch: RGBA =
                if nid == canvas.root {
                    env.theme.ring
                } else if let m = canvas.mainBranch(of: nid, parents: parents),
                    let mains = canvas.nodes[canvas.root]?.children, let i = mains.firstIndex(of: m)
                {
                    env.branchColor(
                        mainIndex: i, count: mains.count,
                        siblingIndex: parents[nid].flatMap { canvas.nodes[$0]?.children.firstIndex(of: nid) })
                } else {
                    env.theme.ink2
                }
            return StyleResolver.resolveColor(token, branch: branch, env: env).map {
                $0.composited(over: env.canvas).hex
            }
        }

        /// The topic's own style in Xmind properties: its level style, quick style and
        /// overrides (the theme's part is in the sheet's theme). Also OpenNexus's record
        /// of the quick style and the unresolved own style, when the properties alone
        /// don't read back as them (D218).
        mutating func style(_ nid: NodeID, _ n: Node) -> (properties: [String: String], record: [String: Any]?) {
            var s = canvas.style.levels[canvas.depth(of: nid, parents: parents)] ?? TopicStyle()
            if let q = n.quickStyle {
                if let qs = QuickStyle.named(q, custom: library.quickStyles) { s = qs.style.merged(over: s) }
            }
            if let o = n.style { s = o.merged(over: s) }
            var p: [String: String] = [:]
            if !s.isEmpty {
                var lost: [String] = []
                p = XmindStyle.properties(s, color: { color($0, on: nid) }, lost: &lost)
                lose(lost)
            }
            let record = XmindStyle.record(
                quickStyle: n.quickStyle, own: n.style, library: library.quickStyles, written: p)
            return (p, record)
        }

        func id(_ n: NodeID) -> String { "\(canvas.id.rawValue)-\(n.rawValue)" }
        func id(_ c: CanvasID, _ n: NodeID) -> String { "\(c.rawValue)-\(n.rawValue)" }

        mutating func sheet(_ c: Canvas) -> [String: Any] {
            canvas = c
            parents = c.parentMap()
            env = StyleEnvironment(
                theme: Theme.named(c.style.theme, custom: library.themes), canvasStyle: c.style,
                customPalettes: library.palettes, customQuickStyles: library.quickStyles)
            report.sheets += 1
            boundaries = [:]
            summaries = [:]
            callouts = [:]
            prepareElements()
            var root = topic(c.root)
            let (cls, exact) = XmindWriter.structure(c.layout.structure)
            root["structureClass"] = cls
            if !exact { report.skip("Layout “\(c.layout.structure.rawValue)” written as an Xmind \(cls)") }
            let detached = c.floating.map { f -> [String: Any] in
                var t = topic(f)
                if let p = c.nodes[f]?.position { t["position"] = ["x": p.x, "y": p.y] }
                return t
            }
            if !detached.isEmpty {
                var kids = root["children"] as? [String: Any] ?? [:]
                kids["detached"] = detached
                root["children"] = kids
            }
            var lost: [String] = []
            let theme = XmindStyle.theme(env, sheet: "sheet-\(c.id.rawValue)", lost: &lost)
            lose(lost)
            var extensions: [[String: Any]] = [
                ["provider": "org.xmind.ui.skeleton.structure.style", "content": ["centralTopic": cls]]
            ]
            let themeID = theme["id"] as? String ?? ""
            if let record = XmindStyle.record(
                c.style, themeID: themeID, tagged: themeID.hasPrefix(XmindStyle.themePrefix))
            {
                extensions.append(["provider": XmindStyle.provider, "content": record])
            }
            var s: [String: Any] = [
                "id": "sheet-\(c.id.rawValue)", "class": "sheet",
                "title": c.title.isEmpty ? (c.nodes[c.root]?.text ?? "") : c.title, "rootTopic": root,
                "theme": theme, "extensions": extensions,
            ]
            var rels: [[String: Any]] = []
            for r in c.relationships {
                // Zones aren't written (no Xmind equivalent), so neither is a relationship
                // that ends on one (M16). Boundaries and summaries are, by id (D183).
                if r.from.zone != nil || r.to.zone != nil {
                    report.skip("Relationship to a zone (zones aren't exported)")
                    continue
                }
                guard let from = end(r.from), let to = end(r.to) else { continue }
                var o: [String: Any] = ["id": "\(c.id.rawValue)-\(r.id)", "end1Id": from, "end2Id": to]
                if !r.label.isEmpty { o["title"] = r.label }
                var lost: [String] = []
                let p = XmindStyle.properties(r, lost: &lost)
                lose(lost)
                if !p.isEmpty { o["style"] = ["id": "\(c.id.rawValue)-\(r.id)-style", "properties": p] }
                rels.append(o)
            }
            if !rels.isEmpty { s["relationships"] = rels }
            if let l = c.legend { s["legend"] = legend(l) }
            elementReport(c)
            return s
        }

        /// A relationship end's Xmind id: a topic's, or a written boundary's or summary's.
        func end(_ e: RelationshipEnd) -> String? {
            switch e {
            case .topic(let n): canvas.nodes[n] == nil ? nil : id(n)
            case .boundary(let b): written.contains(e) ? "\(canvas.id.rawValue)-\(b)" : nil
            case .summary(let s): written.contains(e) ? "\(canvas.id.rawValue)-\(s)" : nil
            case .zone: nil
            }
        }

        /// Boundaries, summaries and callouts hang off their parent topic in Xmind.
        mutating func prepareElements() {
            written = []
            for b in canvas.boundaries {
                let ids = b.nodes.filter { canvas.nodes[$0] != nil }
                guard let first = ids.first else { continue }
                var o: [String: Any] = ["id": "\(canvas.id.rawValue)-\(b.id)"]
                if !b.title.isEmpty { o["title"] = b.title }
                var lost: [String] = []
                let p = XmindStyle.properties(b, theme: env.theme, canvas: env.canvas, lost: &lost)
                lose(lost)
                if !p.isEmpty { o["style"] = ["id": "\(canvas.id.rawValue)-\(b.id)-style", "properties": p] }
                if ids.count == 1, parents[first] == nil {
                    // Around a central or floating topic: the whole branch.
                    o["range"] = "master"
                    boundaries[first, default: []].append(o)
                    written.insert(.boundary(b.id))
                    continue
                }
                let ps = Set(ids.map { parents[$0] })
                guard ps.count == 1, let p = ps.first!, let kids = canvas.nodes[p]?.children else {
                    report.skip("Boundary around topics under different parents")
                    continue
                }
                let idx = ids.compactMap { kids.firstIndex(of: $0) }.sorted()
                guard let lo = idx.first, let hi = idx.last else { continue }
                if hi - lo + 1 != idx.count {
                    report.skip("Boundary around topics that aren't next to each other (widened)")
                }
                o["range"] = "(\(lo),\(hi))"
                boundaries[p, default: []].append(o)
                written.insert(.boundary(b.id))
            }
            for s in canvas.summaries {
                guard let kids = canvas.nodes[s.parent]?.children, let a = kids.firstIndex(of: s.from),
                    let b = kids.firstIndex(of: s.to), canvas.nodes[s.topic] != nil
                else {
                    report.skip("Summary with a missing range")
                    continue
                }
                var lost: [String] = []
                summaries[s.parent, default: []].append(
                    (
                        "(\(min(a, b)),\(max(a, b)))", s.topic, "\(canvas.id.rawValue)-\(s.id)",
                        XmindStyle.properties(s, lost: &lost)
                    ))
                lose(lost)
                written.insert(.summary(s.id))
            }
            for k in canvas.callouts where canvas.nodes[k.topic] != nil {
                callouts[k.host, default: []].append(k.topic)
            }
        }

        mutating func elementReport(_ c: Canvas) {
            if !c.zones.isEmpty { report.skip("Zone (no Xmind equivalent; its topics are kept)", c.zones.count) }
            if !c.diagram.isEmpty { report.skip("Technical diagram settings (lanes, levels, rule checks)") }
            if !c.filters.isEmpty { report.skip("Saved filters", c.filters.count) }
            if !c.schedule.isDefault { report.skip("Work calendar (Xmind uses its own)") }
        }

        mutating func topic(_ nid: NodeID) -> [String: Any] {
            guard let n = canvas.nodes[nid] else { return [:] }
            report.topics += 1
            var t: [String: Any] = ["id": id(nid), "class": "topic", "title": n.text]
            if let note = n.note?.text, !note.isEmpty {
                let html = note.components(separatedBy: "\n").map { "<div>\(XML.escape($0, attribute: false))</div>" }
                t["notes"] = ["plain": ["content": note], "realHTML": ["content": html.joined()]]
            }
            if !n.labels.isEmpty { t["labels"] = n.labels }
            var markers: [[String: Any]] = []
            for m in n.markers {
                if let x = XmindWriter.marker(m) {
                    markers.append(["markerId": x])
                } else {
                    report.skip("Marker “\(m)” (no Xmind equivalent)")
                }
            }
            if !markers.isEmpty { t["markers"] = markers }
            if let link = n.link { t["href"] = href(link) }
            if let img = n.image, let data = doc.assets[img.asset] {
                let path = "resources/\(img.asset)"
                files[path] = data
                var o: [String: Any] = ["src": "xap:\(path)"]
                if let w = img.width { o["width"] = w }
                if let h = img.height { o["height"] = h }
                t["image"] = o
            } else if n.image != nil {
                report.skip("Image whose file is missing")
            }
            for (i, a) in n.attachments.enumerated() {
                guard i == 0, t["href"] == nil, let data = doc.assets[a.asset] else {
                    report.skip("Attachment beyond one per topic (Xmind keeps one link or file)")
                    continue
                }
                let path = "attachments/\(a.asset)"
                files[path] = data
                t["href"] = "xap:\(path)"
            }
            if n.folded && !n.children.isEmpty { t["branch"] = "folded" }
            if let s = n.structure {
                let (cls, exact) = XmindWriter.structure(s)
                t["structureClass"] = cls
                if !exact { report.skip("Branch layout “\(s.rawValue)” written as an Xmind \(cls)") }
            }
            if !n.comments.isEmpty {
                t["comments"] = n.comments.map { c -> [String: Any] in
                    var o: [String: Any] = ["author": c.author, "content": c.text]
                    if let d = c.instant { o["creationTime"] = Int64((d.timeIntervalSince1970 * 1000).rounded()) }
                    return o
                }
            }
            var extensions: [[String: Any]] = []
            if let todo = n.todo { extensions.append(["provider": "org.xmind.ui.task", "content": task(todo)]) }
            let (props, record) = style(nid, n)
            if !props.isEmpty { t["style"] = ["id": "\(id(nid))-style", "properties": props] }
            if let record { extensions.append(["provider": XmindStyle.provider, "content": record]) }
            if !extensions.isEmpty { t["extensions"] = extensions }
            unsupported(n)
            var kids: [String: Any] = [:]
            if !n.children.isEmpty { kids["attached"] = n.children.map { topic($0) } }
            if let ss = summaries[nid], !ss.isEmpty {
                kids["summary"] = ss.map { topic($0.topic) }
                t["summaries"] = ss.map { s -> [String: Any] in
                    var o: [String: Any] = ["id": s.id, "range": s.range, "topicId": id(s.topic)]
                    if !s.style.isEmpty { o["style"] = ["id": "\(s.id)-style", "properties": s.style] }
                    return o
                }
            }
            if let ks = callouts[nid], !ks.isEmpty {
                kids["callout"] = ks.map { k -> [String: Any] in
                    if !(canvas.nodes[k]?.children.isEmpty ?? true) { report.skip("Topics under a callout") }
                    var c = topic(k)
                    c["children"] = nil
                    return c
                }
            }
            if !kids.isEmpty { t["children"] = kids }
            if let bs = boundaries[nid], !bs.isEmpty { t["boundaries"] = bs }
            return t
        }

        /// What Xmind can't hold, reported once per kind.
        mutating func unsupported(_ n: Node) {
            if !n.marks.isEmpty { report.skip("Bold, italic and other text formatting") }
            if !n.metadata.isEmpty { report.skip("Data fields") }
            if n.sticker != nil { report.skip("Sticker") }
            if n.audio != nil { report.skip("Audio note") }
            if n.nodeType != nil || n.edgeLabel != nil || n.lane != nil {
                report.skip("Node type, edge label or lane (technical diagrams)")
            }
            if n.textFormat == "math" || n.textFormat == "code" {
                report.skip("Math or code formatting (kept as text)")
            }
            if n.subCanvas != nil { report.skip("Drill-down to another canvas") }
        }

        /// Topic links become Xmind's `xmind:#id`, which also reaches other sheets.
        func href(_ link: String) -> String {
            if let (c, n) = TopicLink.parse(link) { return "xmind:#\(id(c, n))" }
            return link
        }

        func task(_ t: Todo) -> [String: Any] {
            var o: [String: Any] = ["status": t.done ? "done" : "todo"]
            if let s = t.start { o["start"] = instant(s) }
            if let d = t.due { o["due"] = instant(d) }
            if let owner = t.owner, !owner.isEmpty { o["assignee"] = owner }
            if let p = t.progress, p > 0 { o["progress"] = Double(p) / 100 }
            if !t.after.isEmpty {
                o["dependencies"] = t.after.map { d -> [String: Any] in
                    ["id": id(d.task), "type": d.type.rawValue, "lag": Int64(d.lag) * 86_400_000]
                }
            }
            return o
        }

        /// Noon on the day in the writer's time zone, as epoch milliseconds (D168). Before
        /// March 1973 that number reads as seconds (D149), so those days are ISO strings.
        func instant(_ d: TaskDate) -> Any {
            let utcMidnight = Double(d.day) * 86_400
            let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: utcMidnight + 43_200))
            let ms = Int64((utcMidnight + 43_200 - Double(offset)) * 1000)
            guard ms < 100_000_000_000 else { return ms }
            let f = ISO8601DateFormatter()
            f.timeZone = zone
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }

        mutating func legend(_ l: Legend) -> [String: Any] {
            var o: [String: Any] = ["visibility": l.visible ? "visible" : "hidden"]
            if let p = l.position { o["position"] = ["x": p.x, "y": p.y] }
            var markers: [String: Any] = [:]
            for (m, text) in l.markers.sorted(by: { $0.key < $1.key }) {
                if let x = XmindWriter.marker(m) {
                    markers[x] = ["name": text]
                } else {
                    report.skip("Legend description for marker “\(m)” (no Xmind equivalent)")
                }
            }
            if !markers.isEmpty { o["markers"] = markers }
            return o
        }
    }
}
