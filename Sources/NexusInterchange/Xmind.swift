import Foundation
import NexusCore
import NexusFormat

/// `.xmind` import: Xmind 2020+ ("Zen", `content.json`) and XMind 8 (`content.xml`). The
/// migration path, so it is tolerant: anything it can't convert goes in the report.
public enum XmindFormat {
    /// Xmind stores task dates as instants; they become calendar days in `timeZone` (D149).
    public static func parse(_ data: Data, name: String, timeZone: TimeZone = .current) throws -> Imported {
        guard !data.isEmpty else { throw ImportError.empty(name) }
        let files: [String: Data]
        do {
            files = try Zip.read(data)
        } catch {
            throw ImportError.invalid(name, "\(error)")
        }
        var report = ImportReport(source: name, format: "Xmind")
        if let manifest = files["META-INF/manifest.xml"],
            String(decoding: manifest, as: UTF8.self).contains("encryption-data")
        {
            throw ImportError.encrypted(name)
        }
        if let manifest = files["manifest.json"], String(decoding: manifest, as: UTF8.self).contains("encryption") {
            throw ImportError.encrypted(name)
        }
        var assets: [String: Data] = [:]
        var sheets: [ICanvas]
        if let json = files["content.json"] {
            guard let any = try? JSONSerialization.jsonObject(with: json) else {
                throw ImportError.invalid(name, "content.json is not valid JSON")
            }
            var z = Zen(files: files, report: report, zone: timeZone)
            if let cj = files["comments.json"], let any = try? JSONSerialization.jsonObject(with: cj) {
                z.pending = XmindComments.byTopic(json: any)
            }
            sheets = z.sheets(any)
            z.reportUnplaced()
            report = z.report
            assets = z.assets
        } else if let xml = files["content.xml"] {
            var x = Legacy(files: files, report: report, zone: timeZone)
            if let cx = files["comments.xml"], let root = try? XML.parse(cx, name: "comments.xml") {
                x.pending = XmindComments.byTopic(xml: root)
            }
            if let sx = files["styles.xml"], let root = try? XML.parse(sx, name: "styles.xml") { x.readStyles(root) }
            sheets = try x.sheets(xml, name: name)
            x.reportUnplaced()
            report = x.report
            assets = x.assets
        } else {
            throw ImportError.invalid(name, "no content.json or content.xml inside")
        }
        guard !sheets.isEmpty else { throw ImportError.invalid(name, "no sheets") }
        let canvases = CanvasBuilder.build(sheets, report: &report)
        return Imported(canvases: canvases, assets: assets, report: report)
    }

    // MARK: Shared mapping

    /// Xmind marker ids → OpenNexus markers (nil: no equivalent).
    static func marker(_ id: String) -> String? {
        if id.hasPrefix("priority-"), let n = Int(id.dropFirst(9)), (1...9).contains(n) { return "priority-\(n)" }
        switch id {
        case "task-start": return "progress-0"
        // Eighths have markers of their own (D247).
        case "task-oct": return "progress-13"
        case "task-quarter": return "progress-25"
        case "task-3oct": return "progress-38"
        case "task-half": return "progress-50"
        case "task-5oct": return "progress-63"
        case "task-3quar": return "progress-75"
        case "task-7oct": return "progress-88"
        case "task-done": return "progress-100"
        case "flag-red", "flag-orange", "flag-green", "flag-blue": return id
        case "flag-purple", "flag-dark-blue": return "flag-blue"
        case "flag-yellow": return "flag-orange"
        case "star-red": return "star-red"
        case "star-blue", "star-dark-blue": return "star-blue"
        case _ where id.hasPrefix("star-"): return "star-gold"
        case "symbol-question": return "symbol-question"
        case "symbol-exclam", "symbol-attention": return "symbol-exclaim"
        case "symbol-right", "symbol-check": return "symbol-check"
        case "symbol-wrong", "symbol-minus": return "symbol-cross"
        case _ where id.hasPrefix("arrow-"): return "symbol-arrow"
        case "people-red", "people-orange", "c_simbol-person": return "people-me"
        case _ where id.hasPrefix("people-"): return "people-team"
        default: return nil
        }
    }

    static func structure(_ cls: String?) -> LayoutStructure? {
        guard let c = cls else { return nil }
        if c.contains("logic.left") { return .logicLeft }
        if c.contains("logic.right") { return .logicRight }
        // Xmind's default mind map (`map.unbalanced`) puts branches on both sides (D169).
        if c.contains("map.clockwise") { return .mindmapRight }
        if c.contains("map.anticlockwise") { return .mindmapLeft }
        if c.contains("map") { return .mindmapBalanced }
        if c.contains("org-chart") || c.contains("orgchart") { return .orgDown }
        if c.contains("tree.left") || c.contains("tree.right") { return .treeIndented }
        if c.contains("fishbone.rightHeaded") { return .fishboneRight }
        if c.contains("fishbone") { return .fishboneLeft }
        if c.contains("timeline.vertical") { return .timelineVertical }
        if c.contains("timeline") { return .timelineHorizontal }
        if c.contains("spreadsheet") || c.contains("treetable") { return .treeTable }
        if c.contains("brace.left") { return .braceLeft }
        if c.contains("brace") { return .braceRight }
        if c.contains("matrix") { return .matrix }
        return nil
    }

    static func type(for s: LayoutStructure?) -> DiagramType {
        switch s {
        case .logicLeft?, .logicRight?: .logic
        case .orgDown?: .org
        case .treeIndented?, .treeDown?: .tree
        case .fishboneLeft?, .fishboneRight?: .fishbone
        case .timelineHorizontal?, .timelineVertical?: .timeline
        case .treeTable?: .treeTable
        case .braceLeft?, .braceRight?: .brace
        case .matrix?: .matrix
        default: .mindmap
        }
    }

    /// `(0,2)` → 0...2 (child indices). `master` (a boundary around the topic's whole
    /// branch) is handled by the callers.
    static func range(_ s: String?, count: Int) -> ClosedRange<Int>? {
        guard let s, s != "master" else { return nil }
        let nums = s.split { !$0.isNumber }.compactMap { Int($0) }
        guard nums.count == 2, nums[0] <= nums[1], nums[0] >= 0, nums[1] < count else { return nil }
        return nums[0]...nums[1]
    }

    /// The canvas's element defaults from the sheet's theme or record, then each boundary's
    /// and summary's own properties, read once the canvas colour is known (D245). The
    /// builder gives every element the defaults it doesn't set itself.
    static func elements(
        _ ic: inout ICanvas, theme: [String: Any]?, record: [String: Any]?, groups: [[String: Any]],
        summaries: [[String: Any]], report: inout ImportReport
    ) {
        let canvas = XmindStyle.canvasColor(ic.style)
        let e = XmindStyle.elementStyles(theme, record: record, canvas: canvas, report: &report)
        if !e.isEmpty {
            var style = ic.style ?? CanvasStyle()
            style.elements = e
            ic.style = style
        }
        for (i, own) in groups.enumerated() where !own.isEmpty {
            XmindStyle.apply(own, canvas: canvas, line: e.boundary.color, to: &ic.groups[i], report: &report)
        }
        for (i, own) in summaries.enumerated() where !own.isEmpty { XmindStyle.apply(own, to: &ic.summaries[i]) }
    }

    static func ext(_ path: String) -> String {
        let e = (path as NSString).pathExtension.lowercased()
        return e.isEmpty ? "png" : e
    }

    // MARK: Zen (content.json)

    struct Zen {
        let files: [String: Data]
        var report: ImportReport
        let zone: TimeZone
        var assets: [String: Data] = [:]
        var groups: [ICanvas.Group] = []
        var summaries: [ICanvas.Brace] = []
        /// Each boundary's and summary's own style properties, in the same order, read
        /// once the sheet's theme and background are known.
        var groupProps: [[String: Any]] = []
        var summaryProps: [[String: Any]] = []
        var callouts: [ICanvas.Bubble] = []
        var seenSheets = Set<String>()
        /// Comments from a separate `comments.json`, by topic id, until their topic is read.
        var pending: [String: [TopicComment]] = [:]

        mutating func reportUnplaced() {
            let n = pending.values.reduce(0) { $0 + $1.count }
            if n > 0 { report.skip("Comment on a sheet or a missing topic", n) }
        }

        mutating func sheets(_ any: Any) -> [ICanvas] {
            var out: [ICanvas] = []
            let list: [[String: Any]] =
                (any as? [[String: Any]]) ?? ((any as? [String: Any]).map { [$0] } ?? [])
            for s in list { collect(s, into: &out, nested: false) }
            return out
        }

        /// Some files nest copies of a sheet under numeric keys ("0"); take each distinct one.
        mutating func collect(_ s: [String: Any], into out: inout [ICanvas], nested: Bool) {
            if s["rootTopic"] != nil {
                let id = s["id"] as? String ?? UUID().uuidString
                if seenSheets.insert(id).inserted {
                    if nested { report.skip("Nested sheet copy (an Xmind file quirk), imported as its own canvas") }
                    out.append(sheet(s))
                } else {
                    report.skip("Duplicate nested sheet (skipped)")
                }
            }
            for (k, v) in s where Int(k) != nil {
                if let d = v as? [String: Any] { collect(d, into: &out, nested: true) }
            }
        }

        mutating func sheet(_ s: [String: Any]) -> ICanvas {
            report.sheets += 1
            groups = []
            summaries = []
            groupProps = []
            summaryProps = []
            callouts = []
            let theme = s["theme"] as? [String: Any]
            let record = Self.record(s["extensions"])
            let rt = s["rootTopic"] as? [String: Any] ?? [:]
            var root = topic(rt)
            let detached = ((rt["children"] as? [String: Any])?["detached"] as? [[String: Any]]) ?? []
            let floating = detached.map { d -> ITopic in
                var t = topic(d)
                if let p = d["position"] as? [String: Any] {
                    t.position = CanvasPoint(x: (p["x"] as? Double) ?? 0, y: (p["y"] as? Double) ?? 0)
                }
                return t
            }
            let structure = XmindFormat.structure(rt["structureClass"] as? String)
            root.structure = nil
            let title = (s["title"] as? String).flatMap { $0.trimmed.isEmpty ? nil : $0 } ?? root.text
            var ic = ICanvas(title: title, root: root)
            ic.structure = structure
            ic.type = XmindFormat.type(for: structure)
            ic.floating = floating
            ic.groups = groups
            ic.summaries = summaries
            ic.callouts = callouts
            for r in (s["relationships"] as? [[String: Any]]) ?? [] {
                guard let a = r["end1Id"] as? String, let b = r["end2Id"] as? String else { continue }
                var link = ICanvas.Link(from: a, to: b, label: (r["title"] as? String) ?? "")
                link.ref = r["id"] as? String
                // Its own properties; the theme's class is the canvas's default (D245).
                if let p = Self.properties(r) { XmindStyle.apply(p, to: &link) }
                ic.links.append(link)
            }
            if theme != nil || record != nil {
                ic.style = XmindStyle.canvasStyle(theme ?? [:], sheetStyle: Self.properties(s), record: record)
            }
            XmindFormat.elements(
                &ic, theme: theme, record: record, groups: groupProps, summaries: summaryProps, report: &report)
            var kept = XmindKept()
            for e in (s["extensions"] as? [[String: Any]]) ?? [] {
                switch e["provider"] as? String ?? "" {
                // Derived from the map, and written afresh.
                case "org.xmind.ui.skeleton.structure.style", "org.xmind.ui.map.unbalanced",
                    "org.xmind.ui.branch.style", XmindStyle.provider:
                    break
                default: kept.extensions.append(e)
                }
            }
            for (k, v) in s.sorted(by: { $0.key < $1.key }) where Int(k) == nil && !Self.sheetKeys.contains(k) {
                switch k {
                case "zones":
                    // Xmind's zones aren't imported, and they'd name topics by Xmind's ids.
                    let n = (v as? [Any])?.count ?? 0
                    if n > 0 { report.skip("Xmind zone (not imported)", n) }
                case "arrangeableLayerOrder": kept.layerOrder = XmindKept.layerOrder(v)
                default: kept.keys[k] = v
                }
            }
            ic.extra = kept.json.map { [XmindKept.key: $0] } ?? [:]
            if let l = s["legend"] { ic.legend = XmindLegend.read(l, report: &report) }
            return ic
        }

        /// What a sheet holds that OpenNexus reads (or rewrites) itself; everything else is
        /// kept (D242). Numeric keys are nested sheet copies.
        static let sheetKeys: Set<String> = [
            "id", "class", "title", "rootTopic", "theme", "style", "relationships", "extensions", "legend",
        ]

        /// What a topic holds that OpenNexus reads itself; everything else is kept (D242).
        /// A floating topic's `position` is read and written afresh; an attached topic's
        /// isn't kept, since OpenNexus lays it out.
        static let topicKeys: Set<String> = [
            "id", "class", "title", "attributedTitle", "notes", "markers", "labels", "href", "image", "branch",
            "structureClass", "comments", "extensions", "style", "children", "boundaries", "summaries", "position",
        ]

        func text(_ t: [String: Any]) -> String {
            if let s = t["title"] as? String { return s }
            if let runs = t["attributedTitle"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined()
            }
            return ""
        }

        mutating func topic(_ t: [String: Any]) -> ITopic {
            var it = ITopic(text(t), ref: t["id"] as? String)
            if let notes = t["notes"] as? [String: Any] {
                it.note = (notes["plain"] as? [String: Any])?["content"] as? String
                if it.note == nil, notes["realHTML"] != nil { report.skip("Rich-text note without plain text") }
            }
            for m in (t["markers"] as? [[String: Any]]) ?? [] {
                guard let id = m["markerId"] as? String else { continue }
                if let mapped = XmindFormat.marker(id) {
                    it.markers.append(mapped)
                } else {
                    report.skip("Marker “\(id)” (no equivalent)")
                }
            }
            it.labels = (t["labels"] as? [String]) ?? []
            if let href = t["href"] as? String {
                if href.hasPrefix("xap:") {
                    attach(href, to: &it, kind: "attachment")
                } else if href.hasPrefix("xmind:#") || href.hasPrefix("#") || href.contains("://")
                    || href.hasPrefix("mailto:")
                {
                    it.link = href
                } else {
                    report.skip("Link to a local file")
                }
            }
            if let img = t["image"] as? [String: Any], let src = img["src"] as? String {
                if let data = file(src) {
                    let name = CanvasBuilder.assetName(data, ext: XmindFormat.ext(src))
                    assets[name] = data
                    it.image = AssetRef(asset: name, width: img["width"] as? Double, height: img["height"] as? Double)
                } else {
                    report.skip("Image that isn’t inside the file")
                }
            }
            if t["branch"] as? String == "folded" { it.folded = true }
            it.structure = XmindFormat.structure(t["structureClass"] as? String)
            if let raw = t["comments"] {
                it.comments = XmindComments.list(raw)
                if it.comments.isEmpty, !XmindComments.isEmpty(raw) { report.skip("Comment in an unknown form") }
            }
            if let id = it.ref, let more = pending.removeValue(forKey: id) { it.comments += more }
            var kept = XmindKept()
            for e in (t["extensions"] as? [[String: Any]]) ?? [] {
                let p = e["provider"] as? String ?? ""
                if p.contains("task"), let content = e["content"] as? [String: Any] {
                    var task = it.task ?? ITask()
                    XmindTask.read(content, into: &task, zone: zone, report: &report)
                    it.task = task
                } else if p.contains("audio") {
                    report.skip("Audio note on “\(it.text)” (kept as attachment)")
                } else if p != XmindStyle.provider {
                    // Pitch slides and other extensions travel with the topic (D242).
                    kept.extensions.append(e)
                }
            }
            for (k, v) in t where !Self.topicKeys.contains(k) { kept.keys[k] = v }
            it.extra = kept.json.map { [XmindKept.key: $0] } ?? [:]
            let props = Self.properties(t)
            if let record = Self.record(t["extensions"]), let own = XmindStyle.restore(record, written: props) {
                // OpenNexus's record of the topic's quick style and own style (D218).
                it.quickStyle = own.quickStyle
                it.style = own.style
            } else {
                // Xmind's quick styles are classes (D244).
                it.quickStyle = XmindStyle.quickStyle(class: t["class"])
                it.style = props.flatMap(XmindStyle.style)
            }
            let children = t["children"] as? [String: Any] ?? [:]
            let attached = (children["attached"] as? [[String: Any]]) ?? []
            it.children = attached.map { topic($0) }
            let kidRefs = it.children.map { $0.ref ?? "" }
            for b in (t["boundaries"] as? [[String: Any]]) ?? [] {
                let title = (b["title"] as? String) ?? ""
                if let r = XmindFormat.range(b["range"] as? String, count: kidRefs.count) {
                    groups.append(ICanvas.Group(refs: Array(kidRefs[r]), title: title, ref: b["id"] as? String))
                } else if let parent = it.ref, b["range"] as? String == "master" {
                    // Around the topic and its whole branch.
                    groups.append(ICanvas.Group(refs: [parent], title: title, ref: b["id"] as? String))
                } else {
                    continue
                }
                groupProps.append(Self.properties(b) ?? [:])
            }
            let summaryTopics = (children["summary"] as? [[String: Any]]) ?? []
            for s in (t["summaries"] as? [[String: Any]]) ?? [] {
                guard let r = XmindFormat.range(s["range"] as? String, count: kidRefs.count), let parent = it.ref,
                    let st = summaryTopics.first(where: { ($0["id"] as? String) == (s["topicId"] as? String) })
                else { continue }
                summaries.append(
                    ICanvas.Brace(
                        parent: parent, from: kidRefs[r.lowerBound], to: kidRefs[r.upperBound], topic: topic(st),
                        ref: s["id"] as? String))
                summaryProps.append(Self.properties(s) ?? [:])
            }
            for c in (children["callout"] as? [[String: Any]]) ?? [] {
                if let host = it.ref { callouts.append(ICanvas.Bubble(host: host, topic: topic(c))) }
            }
            return it
        }

        /// An object's `style.properties` (topics, relationships, boundaries, summaries).
        static func properties(_ o: [String: Any]) -> [String: Any]? {
            ((o["style"] as? [String: Any])?["properties"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The content of OpenNexus's style extension among `extensions` (D218).
        static func record(_ extensions: Any?) -> [String: Any]? {
            ((extensions as? [[String: Any]]) ?? []).first { $0["provider"] as? String == XmindStyle.provider }?[
                "content"] as? [String: Any]
        }

        func file(_ src: String) -> Data? {
            let path = src.hasPrefix("xap:") ? String(src.dropFirst(4)) : src
            return files[path] ?? files[path.removingPercentEncoding ?? path]
        }

        mutating func attach(_ src: String, to it: inout ITopic, kind: String) {
            guard let data = file(src) else {
                report.skip("Attachment that isn’t inside the file")
                return
            }
            let name = CanvasBuilder.assetName(data, ext: XmindFormat.ext(src))
            assets[name] = data
            it.attachments.append(AssetRef(asset: name, name: (src as NSString).lastPathComponent))
        }
    }

    // MARK: XMind 8 (content.xml)

    struct Legacy {
        let files: [String: Data]
        var report: ImportReport
        let zone: TimeZone
        var assets: [String: Data] = [:]
        var groups: [ICanvas.Group] = []
        var summaries: [ICanvas.Brace] = []
        /// Each boundary's and summary's own style properties, as in `Zen`.
        var groupProps: [[String: Any]] = []
        var summaryProps: [[String: Any]] = []
        var callouts: [ICanvas.Bubble] = []
        /// Comments from `comments.xml`, by topic id, until their topic is read.
        var pending: [String: [TopicComment]] = [:]
        /// `styles.xml`: each style's properties by id, and each theme as Zen shapes it
        /// (`{id, title, map: {properties}, centralTopic: {properties}, …}`).
        var styleProps: [String: [String: Any]] = [:]
        var themes: [String: [String: Any]] = [:]

        mutating func reportUnplaced() {
            let n = pending.values.reduce(0) { $0 + $1.count }
            if n > 0 { report.skip("Comment on a sheet or a missing topic", n) }
        }

        /// Reads XMind 8's `styles.xml`: styles hold one `*-properties` element whose
        /// attributes are the same keys Zen uses; themes name a default style per family.
        mutating func readStyles(_ root: XMLElement) {
            for st in root.descendants("style") {
                guard let id = st.attr("id") else { continue }
                if st.attr("type") == "theme" { continue }
                var props: [String: Any] = [:]
                for p in st.kids() where (p.localName ?? "").hasSuffix("-properties") {
                    for a in p.attributes ?? [] { props[a.name ?? ""] = a.stringValue ?? "" }
                }
                if !props.isEmpty { styleProps[id] = props }
            }
            for st in root.descendants("style") where st.attr("type") == "theme" {
                guard let id = st.attr("id") else { continue }
                var t: [String: Any] = ["id": id, "title": st.attr("name") ?? ""]
                for d in st.descendants("default-style") {
                    guard let family = d.attr("style-family"), let sid = d.attr("style-id"), let p = styleProps[sid]
                    else { continue }
                    t[family] = ["properties": p]
                }
                themes[id] = t
            }
        }

        func style(_ e: XMLElement) -> [String: Any]? { e.attr("style-id").flatMap { styleProps[$0] } }

        /// OpenNexus's style extension among an element's `<extensions>`: JSON in its
        /// `<content>` (D218).
        static func record(_ e: XMLElement) -> [String: Any]? {
            guard
                let x = e.kid("extensions")?.kids("extension").first(where: {
                    $0.attr("provider") == XmindStyle.provider
                }),
                let text = x.kid("content")?.stringValue
            else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }

        mutating func sheets(_ xml: Data, name: String) throws -> [ICanvas] {
            let root = try XML.parse(xml, name: name)
            return root.kids("sheet").map { sheet($0) }
        }

        mutating func sheet(_ s: XMLElement) -> ICanvas {
            report.sheets += 1
            groups = []
            summaries = []
            groupProps = []
            summaryProps = []
            callouts = []
            let theme = s.attr("theme").flatMap { themes[$0] }
            let record = Self.record(s)
            let rt = s.kid("topic") ?? XMLElement(name: "topic")
            var root = topic(rt)
            var floating: [ITopic] = []
            for ts in rt.kid("children")?.kids("topics") ?? [] where ts.attr("type") == "detached" {
                for d in ts.kids("topic") {
                    var t = topic(d)
                    if let p = d.kid("position") {
                        t.position = CanvasPoint(
                            x: Double(p.attr("svg:x") ?? "") ?? 0, y: Double(p.attr("svg:y") ?? "") ?? 0)
                    }
                    floating.append(t)
                }
            }
            let structure = XmindFormat.structure(rt.attr("structure-class"))
            // The central topic's class is the canvas's structure, as in Zen files.
            root.structure = nil
            let title = s.kid("title")?.stringValue?.trimmed ?? root.text
            var ic = ICanvas(title: title.isEmpty ? root.text : title, root: root)
            ic.structure = structure
            ic.type = XmindFormat.type(for: structure)
            ic.floating = floating
            ic.groups = groups
            ic.summaries = summaries
            ic.callouts = callouts
            for r in s.kid("relationships")?.kids("relationship") ?? [] {
                guard let a = r.attr("end1"), let b = r.attr("end2") else { continue }
                var link = ICanvas.Link(from: a, to: b, label: r.kid("title")?.stringValue ?? "")
                link.ref = r.attr("id")
                if let p = style(r) { XmindStyle.apply(p, to: &link) }
                ic.links.append(link)
            }
            if theme != nil || record != nil {
                // The sheet's own style, a map style, is its background when set, as in Zen
                // files (D213, D243).
                ic.style = XmindStyle.canvasStyle(theme ?? [:], sheetStyle: style(s), record: record)
            }
            XmindFormat.elements(
                &ic, theme: theme, record: record, groups: groupProps, summaries: summaryProps, report: &report)
            if let l = s.kid("legend") { ic.legend = XmindLegend.read(xml: l, report: &report) }
            return ic
        }

        mutating func topic(_ e: XMLElement) -> ITopic {
            var it = ITopic(e.kid("title")?.stringValue ?? "", ref: e.attr("id"))
            if let plain = e.kid("notes")?.kid("plain")?.stringValue { it.note = plain }
            for m in e.kid("marker-refs")?.kids("marker-ref") ?? [] {
                guard let id = m.attr("marker-id") else { continue }
                if let mapped = XmindFormat.marker(id) {
                    it.markers.append(mapped)
                } else {
                    report.skip("Marker “\(id)” (no equivalent)")
                }
            }
            it.labels = e.kid("labels")?.kids("label").compactMap { $0.stringValue?.trimmed } ?? []
            if let href = e.attr("xlink:href") {
                if href.hasPrefix("xap:") {
                    let path = String(href.dropFirst(4))
                    if let data = files[path] {
                        let name = CanvasBuilder.assetName(data, ext: XmindFormat.ext(path))
                        assets[name] = data
                        it.attachments.append(AssetRef(asset: name, name: (path as NSString).lastPathComponent))
                    } else {
                        report.skip("Attachment that isn’t inside the file")
                    }
                } else {
                    it.link = href
                }
            }
            if let img = e.kid("img"), let src = img.attr("xhtml:src") ?? img.attr("src") {
                let path = src.hasPrefix("xap:") ? String(src.dropFirst(4)) : src
                if let data = files[path] {
                    let name = CanvasBuilder.assetName(data, ext: XmindFormat.ext(path))
                    assets[name] = data
                    it.image = AssetRef(
                        asset: name, width: Double(img.attr("svg:width") ?? ""),
                        height: Double(img.attr("svg:height") ?? ""))
                } else {
                    report.skip("Image that isn’t inside the file")
                }
            }
            if e.attr("branch") == "folded" { it.folded = true }
            if let id = it.ref, let more = pending.removeValue(forKey: id) { it.comments = more }
            it.structure = XmindFormat.structure(e.attr("structure-class"))
            if let record = Self.record(e), let own = XmindStyle.restore(record, written: style(e)) {
                it.quickStyle = own.quickStyle
                it.style = own.style
            } else {
                it.quickStyle = XmindStyle.quickStyle(class: e.attr("class"))
                it.style = style(e).flatMap(XmindStyle.style)
            }
            for x in e.kid("extensions")?.kids("extension") ?? [] {
                if x.attr("provider")?.contains("task") == true, let content = x.kid("content") {
                    var fields: [String: Any] = [:]
                    for k in content.kids() {
                        let name = k.localName ?? k.name ?? ""
                        fields[name] =
                            k.kids().isEmpty
                            ? (k.stringValue?.trimmed ?? "")
                            : k.kids().map { g -> Any in
                                var o: [String: Any] = [:]
                                for a in g.attributes ?? [] { o[a.localName ?? a.name ?? ""] = a.stringValue ?? "" }
                                return o.isEmpty ? (g.stringValue?.trimmed ?? "") : o
                            }
                    }
                    for a in content.attributes ?? [] { fields[a.localName ?? a.name ?? ""] = a.stringValue ?? "" }
                    var task = it.task ?? ITask()
                    XmindTask.read(fields, into: &task, zone: zone, report: &report)
                    it.task = task
                } else if x.attr("provider") != XmindStyle.provider {
                    report.skip("XMind 8 extension (audio, other)")
                }
            }
            var summaryTopics: [XMLElement] = []
            for ts in e.kid("children")?.kids("topics") ?? [] {
                switch ts.attr("type") {
                case "attached": it.children += ts.kids("topic").map { topic($0) }
                case "summary": summaryTopics += ts.kids("topic")
                case "callout":
                    for c in ts.kids("topic") {
                        if let host = it.ref { callouts.append(ICanvas.Bubble(host: host, topic: topic(c))) }
                    }
                case "detached": break
                default: break
                }
            }
            let kidRefs = it.children.map { $0.ref ?? "" }
            for b in e.kid("boundaries")?.kids("boundary") ?? [] {
                if let r = XmindFormat.range(b.attr("range"), count: kidRefs.count) {
                    let title = b.kid("title")?.stringValue ?? ""
                    groups.append(ICanvas.Group(refs: Array(kidRefs[r]), title: title, ref: b.attr("id")))
                } else if let parent = it.ref, b.attr("range") == "master" {
                    groups.append(
                        ICanvas.Group(refs: [parent], title: b.kid("title")?.stringValue ?? "", ref: b.attr("id")))
                } else {
                    continue
                }
                groupProps.append(style(b) ?? [:])
            }
            for s in e.kid("summaries")?.kids("summary") ?? [] {
                guard let r = XmindFormat.range(s.attr("range"), count: kidRefs.count), let parent = it.ref,
                    let st = summaryTopics.first(where: { $0.attr("id") == s.attr("topic-id") })
                else { continue }
                summaries.append(
                    ICanvas.Brace(
                        parent: parent, from: kidRefs[r.lowerBound], to: kidRefs[r.upperBound], topic: topic(st),
                        ref: s.attr("id")))
                summaryProps.append(style(s) ?? [:])
            }
            return it
        }
    }
}

/// What an Xmind sheet or topic holds that OpenNexus doesn't use, kept on the canvas or
/// node (`extra["xmind"]`) and written back by the `.xmind` export (D242): unknown keys
/// (`compactLayoutModeLevel`, `topicOverlapping`, a topic's `numbering`), extensions
/// (Pitch's `org.xmind.ui.ice-cream-pancake`), and the sheet's `arrangeableLayerOrder`,
/// whose entries name elements by id and are kept by this file's ids instead.
struct XmindKept {
    static let key = "xmind"

    var keys: [String: Any] = [:]
    var extensions: [[String: Any]] = []
    var layerOrder: [JSONValue]?

    /// `{"keys": {…}, "extensions": […], "layerOrder": […]}`, or nil when there's nothing.
    var json: JSONValue? {
        var o: [String: JSONValue] = [:]
        let k = keys.compactMapValues(Self.value)
        if !k.isEmpty { o["keys"] = .object(k) }
        let e = extensions.compactMap(XmindStyle.jsonValue)
        if !e.isEmpty { o["extensions"] = .array(e) }
        if let layerOrder { o["layerOrder"] = .array(layerOrder) }
        return o.isEmpty ? nil : .object(o)
    }

    /// Any JSON value, a bare number or string included.
    static func value(_ v: Any) -> JSONValue? { XmindStyle.jsonValue(["v": v])?["v"] }

    /// Each entry of Xmind's layer order (an id, or an object with an `id`) as
    /// `{"ref": {"sourceRef": id}, "item": …}`; the builder turns the source id into this
    /// file's element, or drops the entry (D242).
    static func layerOrder(_ v: Any) -> [JSONValue] {
        ((v as? [Any]) ?? []).compactMap { item -> JSONValue? in
            if let id = item as? String { return ["ref": ["sourceRef": .string(id)]] }
            guard var o = item as? [String: Any], let id = o["id"] as? String else { return nil }
            // The export writes the element's id afresh.
            o["id"] = nil
            return ["ref": ["sourceRef": .string(id)], "item": XmindStyle.jsonValue(o) ?? [:]]
        }
    }
}

/// Xmind's legend (M14): visibility, position and marker descriptions (D165). Zen files
/// carry `legend` on the sheet; XMind 8 a `<legend>` element with `<marker-descriptions>`.
enum XmindLegend {
    static func read(_ v: Any, report: inout ImportReport) -> Legend? {
        guard let o = v as? [String: Any] else { return nil }
        var l = Legend()
        if let vis = o["visibility"] as? String { l.visible = vis.lowercased() != "hidden" }
        if let vis = o["visible"] as? Bool { l.visible = vis }
        if let p = o["position"] as? [String: Any], let x = XmindTask.number(p["x"] ?? 0),
            let y = XmindTask.number(p["y"] ?? 0)
        {
            l.position = CanvasPoint(x: x, y: y)
        }
        var pairs: [(String, String)] = []
        for key in ["markers", "markerDescriptions", "marker-descriptions"] {
            if let d = o[key] as? [String: Any] {
                for (id, v) in d.sorted(by: { $0.key < $1.key }) { pairs.append((id, description(v))) }
            } else if let a = o[key] as? [[String: Any]] {
                for m in a {
                    guard let id = (m["markerId"] ?? m["marker-id"] ?? m["id"]) as? String else { continue }
                    pairs.append((id, description(m)))
                }
            }
        }
        add(pairs, to: &l, report: &report)
        if o["groups"] != nil { report.skip("Legend marker group names") }
        return l
    }

    static func read(xml e: XMLElement, report: inout ImportReport) -> Legend {
        var l = Legend(visible: e.attr("visibility")?.lowercased() != "hidden")
        if let p = e.kid("position"), let x = Double(p.attr("svg:x") ?? ""), let y = Double(p.attr("svg:y") ?? "") {
            l.position = CanvasPoint(x: x, y: y)
        }
        let pairs = e.descendants("marker-description").compactMap { d -> (String, String)? in
            d.attr("marker-id").map { ($0, d.attr("description") ?? d.stringValue ?? "") }
        }
        add(pairs, to: &l, report: &report)
        return l
    }

    static func description(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let o = v as? [String: Any] {
            return (o["name"] ?? o["description"] ?? o["title"] ?? o["text"]) as? String ?? ""
        }
        return ""
    }

    /// Descriptions keyed by the OpenNexus marker; the first wins when two Xmind markers
    /// map to one. An empty description keeps the marker's own name.
    static func add(_ pairs: [(String, String)], to l: inout Legend, report: inout ImportReport) {
        for (id, text) in pairs {
            let t = text.trimmed
            guard !t.isEmpty else { continue }
            guard let mapped = XmindFormat.marker(id) else {
                report.skip("Legend description for marker “\(id)” (no equivalent)")
                continue
            }
            if l.markers[mapped] == nil { l.markers[mapped] = t }
        }
    }
}

/// Xmind's topic comments (M14), read tolerantly (D161). Zen files carry them on the
/// topic (`comments`) or in a top-level `comments.json`; XMind 8 in `comments.xml`
/// (`<comment object-id author time><content>`). Replies follow the comment they answer.
enum XmindComments {
    static let authorKeys = ["author", "authorName", "creator", "creatorName", "user", "userName", "name"]
    static let textKeys = ["content", "text", "body", "title", "message"]
    static let timeKeys = ["creationTime", "createdTime", "createTime", "created", "time", "date", "modifiedTime"]

    /// A `comments` value: a list of comments, one comment, or an object holding a list.
    static func list(_ v: Any) -> [TopicComment] {
        if let a = v as? [Any] { return a.flatMap(list) }
        guard let o = v as? [String: Any] else {
            if let s = v as? String, !s.trimmed.isEmpty { return [TopicComment(author: "", date: "", text: s.trimmed)] }
            return []
        }
        if textKeys.contains(where: { o[$0] != nil }) { return comment(o) }
        for k in ["comments", "items", "list", "data"] { if let inner = o[k] { return list(inner) } }
        return []
    }

    static func comment(_ o: [String: Any]) -> [TopicComment] {
        let text =
            textKeys.lazy.compactMap { k -> String? in
                if let s = o[k] as? String { return s }
                // Rich text: {"plain": {"content": …}} or runs [{"text": …}].
                if let d = o[k] as? [String: Any] {
                    return ((d["plain"] as? [String: Any])?["content"] as? String) ?? (d["content"] as? String)
                }
                if let runs = o[k] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
                return nil
            }.first?.trimmed ?? ""
        let author =
            authorKeys.lazy.compactMap { k -> String? in
                if let s = o[k] as? String { return s }
                if let d = o[k] as? [String: Any] { return (d["name"] ?? d["displayName"] ?? d["email"]) as? String }
                return nil
            }.first?.trimmed ?? ""
        let date = timeKeys.lazy.compactMap { o[$0] }.compactMap(Self.date).first ?? ""
        var out = text.isEmpty ? [] : [TopicComment(author: author, date: date, text: text)]
        for k in ["replies", "children", "comments"] { if let r = o[k] { out += list(r) } }
        return out
    }

    static func isEmpty(_ v: Any) -> Bool {
        if let a = v as? [Any] { return a.isEmpty }
        if let o = v as? [String: Any] { return o.isEmpty }
        return (v as? String)?.trimmed.isEmpty ?? true
    }

    /// Epoch milliseconds (or seconds), or ISO 8601, as a UTC ISO 8601 string.
    static func date(_ v: Any) -> String? {
        if let s = v as? String {
            let x = s.trimmed
            if !x.isEmpty, x.allSatisfy(\.isNumber), let n = Double(x) { return epoch(n) }
            let c = TopicComment(author: "", date: x, text: "")
            return c.instant.map(TopicComment.format)
        }
        return XmindTask.number(v).flatMap(epoch)
    }

    static func epoch(_ n: Double) -> String? {
        let seconds = abs(n) < 1e11 ? n : n / 1000
        guard seconds > 0, seconds < 2.5e11 else { return nil }
        return TopicComment.format(Date(timeIntervalSince1970: seconds))
    }

    /// A top-level `comments.json`: `{topicId: [comments]}` or a list naming each topic.
    static func byTopic(json v: Any) -> [String: [TopicComment]] {
        var out: [String: [TopicComment]] = [:]
        if let o = v as? [String: Any] {
            if let inner = o["comments"] ?? o["items"] { return byTopic(json: inner) }
            for (k, list) in o.sorted(by: { $0.key < $1.key }) {
                let cs = Self.list(list)
                if !cs.isEmpty { out[k, default: []] += cs }
            }
        } else if let a = v as? [[String: Any]] {
            for o in a {
                guard let id = (o["objectId"] ?? o["topicId"] ?? o["targetId"] ?? o["object-id"]) as? String else {
                    continue
                }
                out[id, default: []] += comment(o)
            }
        }
        return out
    }

    /// XMind 8's `comments.xml`.
    static func byTopic(xml root: XMLElement) -> [String: [TopicComment]] {
        var out: [String: [TopicComment]] = [:]
        for c in root.descendants("comment") {
            guard let id = c.attr("object-id"), let text = (c.kid("content")?.stringValue ?? c.stringValue)?.trimmed,
                !text.isEmpty
            else { continue }
            let date = c.attr("time").flatMap { Self.date($0) } ?? ""
            out[id, default: []].append(TopicComment(author: c.attr("author")?.trimmed ?? "", date: date, text: text))
        }
        return out
    }
}

/// Xmind's task extension (`org.xmind.ui.task`, Zen; `org.xmind.ui.taskInfo`, XMind 8), read
/// tolerantly: key spellings vary between versions (D149).
enum XmindTask {
    static func read(_ c: [String: Any], into t: inout ITask, zone: TimeZone, report: inout ImportReport) {
        var duration: Double?
        for (key, value) in c.sorted(by: { $0.key < $1.key }) {
            switch key.lowercased() {
            case "status": t.done = (value as? String)?.lowercased() == "done" || t.done
            case "progress":
                if let p = number(value) { t.progress = Int(max(0, min(100, (p > 1 ? p : p * 100).rounded()))) }
            case "priority": if let p = number(value), p >= 1, p <= 9 { t.priority = Int(p) }
            case "start", "startdate", "start-date": t.start = date(value, zone: zone) ?? t.start
            case "due", "duedate", "due-date", "end", "end-date", "enddate": t.due = date(value, zone: zone) ?? t.due
            case "duration": duration = number(value)
            case "assignee", "assignees", "assigned-to", "assignedto", "owner":
                let names = self.names(value)
                if !names.isEmpty { t.owner = names.joined(separator: ", ") }
            case "dependencies", "prerequisite", "prerequisites", "predecessors":
                t.after += dependencies(value)
            case "creator", "creatorname": report.skip("Task creator")
            default: report.skip("Task field “\(key)”")
            }
        }
        if t.due == nil, let s = t.start, let ms = duration, ms > 0, ms < 3.2e11 {
            let days = max(1, Int((ms / 86_400_000).rounded()))
            t.due = s.adding(days: days - 1)
        }
    }

    static func number(_ v: Any) -> Double? {
        if let d = v as? Double, d.isFinite { return d }
        if let n = v as? NSNumber, !(v is Bool) { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = v as? String, let d = Double(s.trimmed), d.isFinite { return d }
        return nil
    }

    /// Epoch milliseconds (number or digits), ISO 8601 with a time, or a plain date.
    static func date(_ v: Any, zone: TimeZone) -> TaskDate? {
        if let s = v as? String {
            let x = s.trimmed
            if let d = TaskDate(String(x.prefix(10))), x.count == 10 { return d }
            if x.allSatisfy(\.isNumber), let ms = Double(x) { return epoch(ms, zone) }
            let iso = ISO8601DateFormatter()
            for o: ISO8601DateFormatter.Options in [
                [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
            ] {
                iso.formatOptions = o
                if let d = iso.date(from: x) { return TaskDate(d, in: zone) }
            }
            return TaskDate(String(x.prefix(10)))
        }
        return number(v).flatMap { epoch($0, zone) }
    }

    static func epoch(_ ms: Double, _ zone: TimeZone) -> TaskDate? {
        // Anything below 1e11 is seconds (before 1973 in milliseconds), as some tools write.
        let seconds = abs(ms) < 1e11 ? ms : ms / 1000
        guard abs(seconds) < 2.5e11 else { return nil }
        return TaskDate(Date(timeIntervalSince1970: seconds), in: zone)
    }

    static func names(_ v: Any) -> [String] {
        if let s = v as? String { return s.trimmed.isEmpty ? [] : [s.trimmed] }
        if let list = v as? [Any] {
            return list.flatMap { item -> [String] in
                if let o = item as? [String: Any] {
                    return [o["name"], o["title"], o["email"], o["id"]].compactMap { $0 as? String }.prefix(1).map(
                        \.trimmed)
                }
                return names(item)
            }.filter { !$0.isEmpty }
        }
        if let o = v as? [String: Any] { return names([o]) }
        return []
    }

    static func dependencies(_ v: Any) -> [ITask.Dependency] {
        if let s = v as? String {
            return s.split(whereSeparator: { $0 == "," || $0 == " " }).map { ITask.Dependency(ref: String($0)) }
        }
        if let list = v as? [Any] {
            return list.flatMap { item -> [ITask.Dependency] in
                guard let o = item as? [String: Any] else { return dependencies(item) }
                guard let ref = (o["id"] ?? o["topicId"] ?? o["taskId"] ?? o["target"]) as? String else { return [] }
                let type = DependencyType(rawValue: ((o["type"] as? String) ?? "FS").uppercased()) ?? .finishToStart
                var lag = number(o["lag"] ?? 0) ?? 0
                if abs(lag) >= 3_600_000 { lag /= 86_400_000 }
                return [ITask.Dependency(ref: ref, type: type, lag: Int(max(-3650, min(3650, lag.rounded()))))]
            }
        }
        return []
    }
}
