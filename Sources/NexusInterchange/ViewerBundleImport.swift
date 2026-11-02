import Foundation
import NexusCore
import NexusFormat

/// Open in OpenNexus (M47d, D441): a share link's viewer bundle as a new document. A bundle
/// is what the app drew, not the document, so what comes back is each canvas's type, title
/// and outline, with every topic's text, note, comments, link, labels, markers and task
/// state, and the attachments the link carried. Styles, connections, images and positions
/// aren't in a bundle; the report names them.
public enum ViewerBundleImport {
    /// `done` is how the sharer's app spelled a finished task ("Done" in English), and
    /// `localized` names a node type as the app shows it (the bundle uses the app's words).
    public static func parse(
        _ bundle: JSONValue, name: String, done: [String] = ["Done"], localized: (String) -> String = { $0 }
    ) throws -> Imported {
        guard bundle["format"]?.stringValue == "opennexus-viewer", let list = bundle["canvases"]?.arrayValue,
            !list.isEmpty
        else { throw ImportError.unrecognised(name) }
        var report = ImportReport(source: name, format: "Share link")
        var assets: [String: Data] = [:]
        var canvases: [Canvas] = []
        var images = 0
        var connections = 0
        for (i, cv) in list.enumerated() {
            report.sheets += 1
            let topics = cv["topics"]?.objectValue ?? [:]
            let type = cv["type"]?.stringValue.flatMap(DiagramType.init(rawValue:)) ?? .mindmap
            var crossCanvas = 0
            var fields = 0
            var tree = Set<String>()
            func topic(_ item: JSONValue) -> ITopic? {
                guard let id = item["id"]?.stringValue, let t = topics[id] else { return nil }
                var out = ITopic(t["text"]?.stringValue ?? "", ref: id)
                out.children = (item["children"]?.arrayValue ?? []).compactMap(topic)
                for c in out.children { tree.insert("\(id)>\(c.ref ?? "")") }
                out.folded = item["folded"]?.boolValue == true
                out.note = t["note"]?.stringValue
                out.labels = (t["labels"]?.arrayValue ?? []).compactMap(\.stringValue)
                // The bundle names markers as the app shows them ("Priority 1" for priority-1).
                out.markers = (t["markers"]?.arrayValue ?? []).compactMap(\.stringValue).map {
                    $0.lowercased().split(separator: " ").joined(separator: "-")
                }
                out.comments = (t["comments"]?.arrayValue ?? []).compactMap { c in
                    c["text"]?.stringValue.map {
                        TopicComment(
                            author: c["author"]?.stringValue ?? "", date: c["date"]?.stringValue ?? "", text: $0)
                    }
                }
                if let task = t["task"]?.stringValue { out.todo = done.contains { task.hasPrefix($0) } }
                if let link = t["link"], let href = link["href"]?.stringValue {
                    if link["kind"]?.stringValue == "topic" {
                        // A topic on this canvas comes back as a link to it; another canvas's can't.
                        if link["canvas"]?.stringValue == cv["id"]?.stringValue, let target = link["topic"]?.stringValue
                        {
                            out.link = "#" + target
                        } else {
                            crossCanvas += 1
                        }
                    } else {
                        out.link = href
                    }
                }
                // A technical diagram's node type, by the name the bundle shows.
                if let name = t["type"]?.stringValue {
                    out.nodeType =
                        DiagramCatalog.nodeTypes(for: type).first { $0.name == name || localized($0.name) == name }?.id
                }
                if let f = t["fields"]?.arrayValue { fields += f.count }
                for a in t["attachments"]?.arrayValue ?? [] {
                    let label = a["name"]?.stringValue ?? ""
                    guard let key = a["asset"]?.stringValue, let b64 = bundle["assets"]?[key]?["data"]?.stringValue,
                        let data = Data(base64Encoded: b64)
                    else {
                        report.skip("Attachment the link didn’t include")
                        continue
                    }
                    let ext = (label as NSString).pathExtension
                    let asset = CanvasBuilder.assetName(data, ext: ext.isEmpty ? "bin" : ext)
                    assets[asset] = data
                    out.attachments.append(AssetRef(asset: asset, name: label))
                }
                return out
            }
            let tops = (cv["outline"]?.arrayValue ?? []).compactMap(topic)
            guard let root = tops.first else { continue }
            let title = cv["title"]?.stringValue ?? ""
            var ic = ICanvas(title: title == root.text ? "" : title, root: root)
            ic.type = type
            ic.floating = Array(tops.dropFirst())
            canvases.append(CanvasBuilder.build(ic, id: CanvasID("c\(i + 1)"), report: &report))
            if crossCanvas > 0 { report.skip("Link to a topic on another canvas", crossCanvas) }
            if fields > 0 { report.skip("Field", fields) }
            // What the drawing shows but the bundle doesn't say.
            let svg = cv["layouts"]?["saved"]?["svg"]?.stringValue ?? ""
            images += svg.components(separatedBy: "data-nexus-asset=").count - 1
            // Technical diagrams draw their tree's edges as connectors too; those come back.
            for g in svg.components(separatedBy: "<g class=\"relationship\"").dropFirst() {
                let ends = g.prefix(while: { $0 != ">" }).matches(of: /data-nexus-(?:from|to)="([^"]*)"/).map {
                    String($0.1)
                }
                if ends.count != 2 || !tree.contains("\(ends[0])>\(ends[1])") { connections += 1 }
            }
        }
        guard !canvases.isEmpty else { throw ImportError.empty(name) }
        report.skip("Styles, themes and positions (the link carries the map as drawn)")
        if connections > 0 { report.skip("Relationship", connections) }
        if images > 0 { report.skip("Image on a topic", images) }
        return Imported(canvases: canvases, assets: assets, report: report)
    }
}
