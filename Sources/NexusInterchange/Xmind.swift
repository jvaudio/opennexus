import Foundation
import NexusCore
import NexusFormat

/// `.xmind` import: Xmind 2020+ ("Zen", `content.json`) and XMind 8 (`content.xml`). The
/// migration path, so it is tolerant: anything it can't convert goes in the report.
public enum XmindFormat {
    public static func parse(_ data: Data, name: String) throws -> Imported {
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
            var z = Zen(files: files, report: report)
            sheets = z.sheets(any)
            report = z.report
            assets = z.assets
        } else if let xml = files["content.xml"] {
            var x = Legacy(files: files, report: report)
            sheets = try x.sheets(xml, name: name)
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
        case "task-oct", "task-quarter": return "progress-25"
        case "task-3oct", "task-half", "task-5oct": return "progress-50"
        case "task-3quar", "task-7oct": return "progress-75"
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
        if c.contains("map.unbalanced") || c.contains("map.clockwise") { return .mindmapRight }
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

    /// `(0,2)` → 0...2 (child indices). Xmind 8 also writes `master` for whole-branch groups.
    static func range(_ s: String?, count: Int) -> ClosedRange<Int>? {
        guard let s else { return nil }
        if s == "master" { return count > 0 ? 0...(count - 1) : nil }
        let nums = s.split { !$0.isNumber }.compactMap { Int($0) }
        guard nums.count == 2, nums[0] <= nums[1], nums[0] >= 0, nums[1] < count else { return nil }
        return nums[0]...nums[1]
    }

    static func ext(_ path: String) -> String {
        let e = (path as NSString).pathExtension.lowercased()
        return e.isEmpty ? "png" : e
    }

    // MARK: Zen (content.json)

    struct Zen {
        let files: [String: Data]
        var report: ImportReport
        var assets: [String: Data] = [:]
        var groups: [ICanvas.Group] = []
        var summaries: [ICanvas.Brace] = []
        var callouts: [ICanvas.Bubble] = []
        var seenSheets = Set<String>()

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
            callouts = []
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
                ic.links.append(ICanvas.Link(from: a, to: b, label: (r["title"] as? String) ?? ""))
            }
            for e in (s["extensions"] as? [[String: Any]]) ?? [] { ext(e, on: title) }
            if s["legend"] != nil { report.skip("Legend") }
            return ic
        }

        mutating func ext(_ e: [String: Any], on title: String) {
            let p = e["provider"] as? String ?? ""
            switch p {
            case "org.xmind.ui.skeleton.structure.style", "org.xmind.ui.map.unbalanced", "org.xmind.ui.branch.style":
                break
            case _ where p.contains("task"): report.skip("Gantt task dates (not in v1)")
            case _ where p.contains("audio"): report.skip("Audio note on “\(title)” (kept as attachment)")
            default: report.skip("Xmind extension \(p.split(separator: ".").last ?? "")")
            }
        }

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
            if t["numbering"] != nil { report.skip("Numbering format") }
            if t["comments"] != nil { report.skip("Comment") }
            for e in (t["extensions"] as? [[String: Any]]) ?? [] { ext(e, on: it.text) }
            let children = t["children"] as? [String: Any] ?? [:]
            let attached = (children["attached"] as? [[String: Any]]) ?? []
            it.children = attached.map { topic($0) }
            let kidRefs = it.children.map { $0.ref ?? "" }
            for b in (t["boundaries"] as? [[String: Any]]) ?? [] {
                if let r = XmindFormat.range(b["range"] as? String, count: kidRefs.count) {
                    groups.append(ICanvas.Group(refs: Array(kidRefs[r]), title: (b["title"] as? String) ?? ""))
                } else if let parent = it.ref, b["range"] as? String == "master" {
                    groups.append(ICanvas.Group(refs: [parent], title: (b["title"] as? String) ?? ""))
                }
            }
            let summaryTopics = (children["summary"] as? [[String: Any]]) ?? []
            for s in (t["summaries"] as? [[String: Any]]) ?? [] {
                guard let r = XmindFormat.range(s["range"] as? String, count: kidRefs.count), let parent = it.ref,
                    let st = summaryTopics.first(where: { ($0["id"] as? String) == (s["topicId"] as? String) })
                else { continue }
                summaries.append(
                    ICanvas.Brace(
                        parent: parent, from: kidRefs[r.lowerBound], to: kidRefs[r.upperBound], topic: topic(st)))
            }
            for c in (children["callout"] as? [[String: Any]]) ?? [] {
                if let host = it.ref { callouts.append(ICanvas.Bubble(host: host, topic: topic(c))) }
            }
            return it
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
        var assets: [String: Data] = [:]
        var groups: [ICanvas.Group] = []
        var summaries: [ICanvas.Brace] = []

        mutating func sheets(_ xml: Data, name: String) throws -> [ICanvas] {
            let root = try XML.parse(xml, name: name)
            return root.kids("sheet").map { sheet($0) }
        }

        mutating func sheet(_ s: XMLElement) -> ICanvas {
            report.sheets += 1
            groups = []
            summaries = []
            let rt = s.kid("topic") ?? XMLElement(name: "topic")
            let root = topic(rt)
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
            let title = s.kid("title")?.stringValue?.trimmed ?? root.text
            var ic = ICanvas(title: title.isEmpty ? root.text : title, root: root)
            ic.structure = structure
            ic.type = XmindFormat.type(for: structure)
            ic.floating = floating
            ic.groups = groups
            ic.summaries = summaries
            for r in s.kid("relationships")?.kids("relationship") ?? [] {
                guard let a = r.attr("end1"), let b = r.attr("end2") else { continue }
                ic.links.append(ICanvas.Link(from: a, to: b, label: r.kid("title")?.stringValue ?? ""))
            }
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
            it.structure = XmindFormat.structure(e.attr("structure-class"))
            if e.kid("extensions") != nil { report.skip("XMind 8 extension (task info, audio)") }
            var summaryTopics: [XMLElement] = []
            for ts in e.kid("children")?.kids("topics") ?? [] {
                switch ts.attr("type") {
                case "attached": it.children += ts.kids("topic").map { topic($0) }
                case "summary": summaryTopics += ts.kids("topic")
                case "detached": break
                default: break
                }
            }
            let kidRefs = it.children.map { $0.ref ?? "" }
            for b in e.kid("boundaries")?.kids("boundary") ?? [] {
                if let r = XmindFormat.range(b.attr("range"), count: kidRefs.count) {
                    groups.append(ICanvas.Group(refs: Array(kidRefs[r]), title: b.kid("title")?.stringValue ?? ""))
                }
            }
            for s in e.kid("summaries")?.kids("summary") ?? [] {
                guard let r = XmindFormat.range(s.attr("range"), count: kidRefs.count), let parent = it.ref,
                    let st = summaryTopics.first(where: { $0.attr("id") == s.attr("topic-id") })
                else { continue }
                summaries.append(
                    ICanvas.Brace(
                        parent: parent, from: kidRefs[r.lowerBound], to: kidRefs[r.upperBound], topic: topic(st)))
            }
            return it
        }
    }
}
