import Foundation
import NexusCore
import NexusFormat

/// XMind 8 export (M18, D187, D188): the same sheets the Zen writer builds, written as
/// XMind 8 stores them. `content.xml` holds the topics (titles, notes, labels, markers,
/// links, images, folding, positions, typed child lists for attached, floating, summary and
/// callout topics, boundaries, summaries, task info and OpenNexus's style records),
/// relationships and the legend; `styles.xml` the topic, relationship, boundary and
/// summary styles and the theme (M25); `comments.xml` the
/// comments; `meta.xml` and `META-INF/manifest.xml` the rest. Images and attachments go
/// under `attachments/`, as XMind 8 keeps them.
extension XmindWriter {
    public static func exportXMind8(
        _ doc: DocumentModel, thumbnail: Data? = nil, timeZone: TimeZone = .current, version: String = "1.0"
    ) -> Result {
        let (w, sheets) = build(doc, zone: timeZone)
        var x = Legacy8()
        let content = x.content(sheets)
        var z = ZipWriter()
        var entries = ["content.xml", "meta.xml"]
        z.add("content.xml", content)
        z.add(
            "meta.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="no"?>
            <meta xmlns="urn:xmind:xmap:xmlns:meta:2.0" version="2.0"><Creator><Name>OpenNexus</Name><Version>\(XML.escape(version))</Version></Creator></meta>
            """)
        if !x.styles.isEmpty {
            z.add("styles.xml", x.stylesXML)
            entries.append("styles.xml")
        }
        if !x.comments.isEmpty {
            z.add("comments.xml", x.commentsXML)
            entries.append("comments.xml")
        }
        for name in w.files.keys.sorted() {
            let path = legacyPath(name)
            z.add(path, w.files[name]!)
            entries.append(path)
        }
        if let thumbnail {
            z.add("Thumbnails/thumbnail.png", thumbnail)
            entries.append("Thumbnails/thumbnail.png")
        }
        let manifest =
            entries.map { "<file-entry full-path=\"\(XML.escape($0))\" media-type=\"\(mediaType($0))\"/>" }
            + [
                "<file-entry full-path=\"META-INF/\" media-type=\"\"/>",
                "<file-entry full-path=\"META-INF/manifest.xml\" media-type=\"text/xml\"/>",
            ]
        z.add(
            "META-INF/manifest.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="no"?>
            <manifest xmlns="urn:xmind:xmap:xmlns:manifest:1.0">\(manifest.joined())</manifest>
            """)
        var report = w.report
        report.format = "XMind 8"
        keptLosses(doc, into: &report)
        return Result(data: z.finish(), report: report)
    }

    /// The XMind 8 export's report alone (the export sheet).
    public static func reportXMind8(_ doc: DocumentModel) -> ExportReport {
        var r = report(doc)
        r.format = "XMind 8"
        keptLosses(doc, into: &r)
        return r
    }

    /// What OpenNexus kept from an Xmind 2020 or later file is in that format's terms, so
    /// XMind 8 doesn't get it (D242).
    static func keptLosses(_ doc: DocumentModel, into r: inout ExportReport) {
        let n = doc.canvases.values.reduce(0) { n, c in
            n + (c.extra[XmindKept.key] == nil ? 0 : 1) + c.nodes.values.filter { $0.extra[XmindKept.key] != nil }.count
        }
        if n > 0 { r.skip("Settings kept from an Xmind 2020 or later file (Pitch slides, extensions, layer order)", n) }
    }

    /// Zen keeps images under `resources/`; XMind 8 keeps everything under `attachments/`.
    static func legacyPath(_ zen: String) -> String {
        zen.hasPrefix("resources/") ? "attachments/" + zen.dropFirst("resources/".count) : zen
    }

    static func mediaType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "xml": "text/xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        default: ""
        }
    }

    /// Writes the Zen writer's sheet dictionaries as XMind 8 XML.
    struct Legacy8 {
        /// `styles.xml` entries: id → (type, properties).
        var styles: [(id: String, type: String, props: [String: String])] = []
        /// The theme per sheet: style id and its default styles by family.
        var themes: [(id: String, name: String, defaults: [(String, String)])] = []
        /// `comments.xml` entries.
        var comments: [(object: String, author: String, time: String, text: String)] = []

        static let namespaces =
            #"xmlns="urn:xmind:xmap:xmlns:content:2.0" xmlns:fo="http://www.w3.org/1999/XSL/Format" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xhtml="http://www.w3.org/1999/xhtml" xmlns:xlink="http://www.w3.org/1999/xlink""#

        func e(_ s: String) -> String { XML.escape(s, attribute: false) }
        func a(_ s: String) -> String { XML.escape(s) }

        mutating func content(_ sheets: [[String: Any]]) -> String {
            var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            out += "<xmap-content \(Self.namespaces) modified-by=\"OpenNexus\" version=\"2.0\">"
            for s in sheets { out += sheet(s) }
            return out + "</xmap-content>\n"
        }

        mutating func sheet(_ s: [String: Any]) -> String {
            let id = s["id"] as? String ?? ""
            var attrs = "id=\"\(a(id))\""
            if let t = s["theme"] as? [String: Any] { attrs += " theme=\"\(a(theme(t, sheet: id)))\"" }
            var out = "<sheet \(attrs)>"
            out += topic(s["rootTopic"] as? [String: Any] ?? [:])
            let rels = (s["relationships"] as? [[String: Any]]) ?? []
            if !rels.isEmpty {
                out += "<relationships>"
                for r in rels {
                    var ra = "end1=\"\(a(r["end1Id"] as? String ?? ""))\" end2=\"\(a(r["end2Id"] as? String ?? ""))\""
                    ra += " id=\"\(a(r["id"] as? String ?? ""))\""
                    if let sid = style(r, type: "relationship") { ra += " style-id=\"\(a(sid))\"" }
                    let title = (r["title"] as? String).map { "<title>\(e($0))</title>" } ?? ""
                    out += "<relationship \(ra)>\(title)</relationship>"
                }
                out += "</relationships>"
            }
            out += "<title>\(e(s["title"] as? String ?? ""))</title>"
            if let l = s["legend"] as? [String: Any] { out += legend(l) }
            out += extensions(s)
            return out + "</sheet>"
        }

        /// A style entry for an object's `style.properties`; returns its id.
        mutating func style(_ o: [String: Any], type: String) -> String? {
            guard let st = o["style"] as? [String: Any], let props = st["properties"] as? [String: String],
                !props.isEmpty
            else { return nil }
            let id = (st["id"] as? String) ?? "\(o["id"] as? String ?? "")-style"
            styles.append((id, type, props))
            return id
        }

        /// The sheet's theme: one style per topic family, the map's, and a theme naming them.
        mutating func theme(_ t: [String: Any], sheet: String) -> String {
            var defaults: [(String, String)] = []
            for family in [
                "map", "centralTopic", "mainTopic", "subTopic", "floatingTopic", "summaryTopic", "calloutTopic",
                "boundary", "summary", "relationship",
            ] {
                guard let c = t[family] as? [String: Any], let props = c["properties"] as? [String: String] else {
                    continue
                }
                let id = (c["id"] as? String) ?? "\(sheet)-theme-\(family)"
                let type = ["map", "boundary", "summary", "relationship"].contains(family) ? family : "topic"
                styles.append((id, type, props))
                defaults.append((family, id))
            }
            let id = t["id"] as? String ?? "\(sheet)-theme"
            themes.append((id, t["title"] as? String ?? "", defaults))
            return id
        }

        mutating func topic(_ t: [String: Any]) -> String {
            let id = t["id"] as? String ?? ""
            var attrs = "id=\"\(a(id))\""
            if let cls = t["structureClass"] as? String { attrs += " structure-class=\"\(a(cls))\"" }
            if t["branch"] as? String == "folded" { attrs += " branch=\"folded\"" }
            if let href = t["href"] as? String { attrs += " xlink:href=\"\(a(legacyHref(href)))\"" }
            if let sid = style(t, type: "topic") { attrs += " style-id=\"\(a(sid))\"" }
            var out = "<topic \(attrs)><title>\(e(t["title"] as? String ?? ""))</title>"
            if let p = t["position"] as? [String: Any] {
                out +=
                    "<position svg:x=\"\(number(p["x"]))\" svg:y=\"\(number(p["y"]))\"/>"
            }
            if let plain = ((t["notes"] as? [String: Any])?["plain"] as? [String: Any])?["content"] as? String {
                let html = plain.components(separatedBy: "\n").map { "<xhtml:p>\(e($0))</xhtml:p>" }.joined()
                out += "<notes><plain>\(e(plain))</plain><html>\(html)</html></notes>"
            }
            if let labels = t["labels"] as? [String], !labels.isEmpty {
                out += "<labels>" + labels.map { "<label>\(e($0))</label>" }.joined() + "</labels>"
            }
            let markers = ((t["markers"] as? [[String: Any]]) ?? []).compactMap { $0["markerId"] as? String }
            if !markers.isEmpty {
                out +=
                    "<marker-refs>" + markers.map { "<marker-ref marker-id=\"\(a($0))\"/>" }.joined() + "</marker-refs>"
            }
            if let img = t["image"] as? [String: Any], let src = img["src"] as? String {
                var ia = "xhtml:src=\"\(a(legacyHref(src)))\""
                if let w = img["width"] { ia += " svg:width=\"\(number(w))\"" }
                if let h = img["height"] { ia += " svg:height=\"\(number(h))\"" }
                out += "<xhtml:img \(ia)/>"
            }
            let kids = t["children"] as? [String: Any] ?? [:]
            var lists = ""
            for type in ["attached", "detached", "summary", "callout"] {
                guard let list = kids[type] as? [[String: Any]], !list.isEmpty else { continue }
                lists += "<topics type=\"\(type)\">" + list.map { topic($0) }.joined() + "</topics>"
            }
            if !lists.isEmpty { out += "<children>\(lists)</children>" }
            if let bs = t["boundaries"] as? [[String: Any]], !bs.isEmpty {
                out += "<boundaries>"
                for b in bs {
                    let title = (b["title"] as? String).map { "<title>\(e($0))</title>" } ?? ""
                    var ba = "id=\"\(a(b["id"] as? String ?? ""))\" range=\"\(a(b["range"] as? String ?? ""))\""
                    if let sid = style(b, type: "boundary") { ba += " style-id=\"\(a(sid))\"" }
                    out += "<boundary \(ba)>\(title)</boundary>"
                }
                out += "</boundaries>"
            }
            if let ss = t["summaries"] as? [[String: Any]], !ss.isEmpty {
                out += "<summaries>"
                for s in ss {
                    var sa =
                        "id=\"\(a(s["id"] as? String ?? ""))\" range=\"\(a(s["range"] as? String ?? ""))\" topic-id=\"\(a(s["topicId"] as? String ?? ""))\""
                    if let sid = style(s, type: "summary") { sa += " style-id=\"\(a(sid))\"" }
                    out += "<summary \(sa)/>"
                }
                out += "</summaries>"
            }
            for c in (t["comments"] as? [[String: Any]]) ?? [] {
                let time = (c["creationTime"] as? Int64).map(String.init) ?? ""
                comments.append((id, c["author"] as? String ?? "", time, c["content"] as? String ?? ""))
            }
            out += extensions(t)
            return out + "</topic>"
        }

        /// A topic's task info, and a sheet's or topic's OpenNexus style record as JSON
        /// text (D218), as XMind 8 `<extensions>`.
        func extensions(_ o: [String: Any]) -> String {
            var out = ""
            for x in (o["extensions"] as? [[String: Any]]) ?? [] {
                guard let content = x["content"] as? [String: Any] else { continue }
                switch x["provider"] as? String {
                case "org.xmind.ui.task"?:
                    out +=
                        "<extension provider=\"org.xmind.ui.taskInfo\"><content>\(taskInfo(content))</content></extension>"
                case XmindStyle.provider?:
                    let json = String(decoding: XmindWriter.json(content), as: UTF8.self)
                    out += "<extension provider=\"\(XmindStyle.provider)\"><content>\(e(json))</content></extension>"
                default: break
                }
            }
            return out.isEmpty ? "" : "<extensions>\(out)</extensions>"
        }

        /// The task fields the importer reads (D149), in XMind 8's element names.
        func taskInfo(_ c: [String: Any]) -> String {
            var out = ""
            if let s = c["status"] as? String { out += "<status>\(e(s))</status>" }
            if let s = c["start"] { out += "<start-date>\(e(text(s)))</start-date>" }
            if let d = c["due"] { out += "<end-date>\(e(text(d)))</end-date>" }
            if let o = c["assignee"] as? String { out += "<assigned-to>\(e(o))</assigned-to>" }
            if let p = c["progress"] { out += "<progress>\(number(p))</progress>" }
            if let deps = c["dependencies"] as? [[String: Any]], !deps.isEmpty {
                out += "<prerequisites>"
                for d in deps {
                    out +=
                        "<prerequisite id=\"\(a(d["id"] as? String ?? ""))\" type=\"\(a(d["type"] as? String ?? "FS"))\" lag=\"\(number(d["lag"]))\"/>"
                }
                out += "</prerequisites>"
            }
            return out
        }

        func legend(_ l: [String: Any]) -> String {
            var out = "<legend visibility=\"\(a(l["visibility"] as? String ?? "visible"))\">"
            if let p = l["position"] as? [String: Any] {
                out += "<position svg:x=\"\(number(p["x"]))\" svg:y=\"\(number(p["y"]))\"/>"
            }
            if let ms = l["markers"] as? [String: Any], !ms.isEmpty {
                out += "<marker-descriptions>"
                for (id, v) in ms.sorted(by: { $0.key < $1.key }) {
                    let name = (v as? [String: Any])?["name"] as? String ?? ""
                    out += "<marker-description description=\"\(a(name))\" marker-id=\"\(a(id))\"/>"
                }
                out += "</marker-descriptions>"
            }
            return out + "</legend>"
        }

        func legacyHref(_ href: String) -> String {
            href.hasPrefix("xap:") ? "xap:" + XmindWriter.legacyPath(String(href.dropFirst(4))) : href
        }

        func text(_ v: Any) -> String { (v as? String) ?? number(v) }

        func number(_ v: Any?) -> String {
            if let i = v as? Int64 { return String(i) }
            if let i = v as? Int { return String(i) }
            guard let d = XmindTask.number(v ?? 0) else { return "0" }
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }

        var stylesXML: String {
            func props(_ p: [String: String]) -> String {
                p.sorted { $0.key < $1.key }.map { "\($0.key)=\"\(a($0.value))\"" }.joined(separator: " ")
            }
            var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            out +=
                "<xmap-styles xmlns=\"urn:xmind:xmap:xmlns:style:2.0\" xmlns:fo=\"http://www.w3.org/1999/XSL/Format\" xmlns:svg=\"http://www.w3.org/2000/svg\" version=\"2.0\"><styles>"
            for s in styles {
                out += "<style id=\"\(a(s.id))\" type=\"\(s.type)\"><\(s.type)-properties \(props(s.props))/></style>"
            }
            out += "</styles><master-styles>"
            for t in themes {
                out += "<style id=\"\(a(t.id))\" name=\"\(a(t.name))\" type=\"theme\"><theme-properties>"
                for (family, id) in t.defaults {
                    out += "<default-style style-family=\"\(family)\" style-id=\"\(a(id))\"/>"
                }
                out += "</theme-properties></style>"
            }
            return out + "</master-styles></xmap-styles>\n"
        }

        var commentsXML: String {
            var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
            out += "<comments xmlns=\"urn:xmind:xmap:xmlns:comments:2.0\" version=\"2.0\">"
            for c in comments {
                out +=
                    "<comment author=\"\(a(c.author))\" object-id=\"\(a(c.object))\" time=\"\(a(c.time))\"><content>\(e(c.text))</content></comment>"
            }
            return out + "</comments>\n"
        }
    }
}
