import Foundation
import NexusCore
import NexusFormat

// MARK: draw.io

public enum DrawIOFormat {
    /// A node's box and colours, from the canvas layout (falls back to a simple grid).
    public struct Frame: Sendable, Equatable {
        public var x, y, width, height: Double
        public var fill: String?
        public var stroke: String?
        public var shape: String?
        public init(
            x: Double, y: Double, width: Double, height: Double, fill: String? = nil, stroke: String? = nil,
            shape: String? = nil
        ) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.fill = fill
            self.stroke = stroke
            self.shape = shape
        }
    }

    public static func export(_ c: Canvas, frames: [NodeID: Frame] = [:]) -> String {
        var cells = ["    <mxCell id=\"0\"/>", "    <mxCell id=\"1\" parent=\"0\"/>"]
        var row = 0
        var fallback: [NodeID: Frame] = [:]
        c.walk { id, n, d in
            fallback[id] = Frame(
                x: Double(d) * 220, y: Double(row) * 60, width: max(120, Double(n.text.count) * 8), height: 40)
            row += 1
        }
        for id in c.floating { fallback[id] = Frame(x: 0, y: Double(row) * 60, width: 140, height: 40); row += 1 }
        let parents = c.parentMap()
        let ids = [c.root] + c.tops.flatMap { c.subtree($0) }.filter { $0 != c.root }
        for id in ids {
            guard let n = c.nodes[id], let f = frames[id] ?? fallback[id] else { continue }
            var style = ["whiteSpace=wrap", "html=1"]
            let type = DiagramCatalog.effectiveType(id, in: c, parents: parents)
            switch f.shape ?? type?.rawValue {
            case "diamond"?, "decision"?: style.append("rhombus")
            case "stadium"?, "start"?, "end"?: style += ["rounded=1", "arcSize=50"]
            case "cylinder"?, "store"?, "db"?: style.append("shape=cylinder3")
            case "parallelogram"?, "io"?: style.append("shape=parallelogram")
            case "circle"?, "ellipse"?: style.append("ellipse")
            default: style.append("rounded=1")
            }
            style.append("fillColor=\(f.fill ?? (id == c.root ? "#1D1D22" : "#FFFFFF"))")
            style.append("strokeColor=\(f.stroke ?? "#5850EC")")
            if id == c.root && f.fill == nil { style.append("fontColor=#FFFFFF") }
            cells.append(
                "    <mxCell id=\"\(id.rawValue)\" value=\"\(XML.escape(n.text))\" style=\"\(style.joined(separator: ";"));\" vertex=\"1\" parent=\"1\">\n"
                    + "      <mxGeometry x=\"\(fmt(f.x))\" y=\"\(fmt(f.y))\" width=\"\(fmt(f.width))\" height=\"\(fmt(f.height))\" as=\"geometry\"/>\n    </mxCell>"
            )
        }
        var e = 0
        for id in ids {
            guard let p = parents[id], let n = c.nodes[id] else { continue }
            e += 1
            cells.append(edge("e\(e)", p, id, n.edgeLabel ?? "", dashed: false, color: frames[id]?.stroke))
        }
        for r in c.relationships where c.nodes[r.from] != nil && c.nodes[r.to] != nil {
            e += 1
            cells.append(edge("e\(e)", r.from, r.to, r.label, dashed: true, color: nil))
        }
        let name = XML.escape(c.title.isEmpty ? "Page-1" : c.title)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <mxfile host="OpenNexus">
              <diagram name="\(name)" id="\(c.id.rawValue)">
                <mxGraphModel grid="1" gridSize="10" page="0">
                  <root>
            \(cells.map { "  " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n"))
                  </root>
                </mxGraphModel>
              </diagram>
            </mxfile>

            """
    }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    static func edge(_ id: String, _ a: NodeID, _ b: NodeID, _ label: String, dashed: Bool, color: String?) -> String {
        var style = ["edgeStyle=orthogonalEdgeStyle", "curved=1", "html=1", "endArrow=\(dashed ? "classic" : "none")"]
        if dashed { style.append("dashed=1") }
        if let color { style.append("strokeColor=\(color)") }
        return
            "    <mxCell id=\"\(id)\" value=\"\(XML.escape(label))\" style=\"\(style.joined(separator: ";"));\" edge=\"1\" parent=\"1\" source=\"\(a.rawValue)\" target=\"\(b.rawValue)\">\n"
            + "      <mxGeometry relative=\"1\" as=\"geometry\"/>\n    </mxCell>"
    }

    /// Plain or compressed (`deflate` + base64 + URL-encoded) diagrams; one canvas per page.
    public static func parse(_ data: Data, name: String, report: inout ImportReport) throws -> [ICanvas] {
        let root = try XML.parse(data, name: name)
        var models: [(String, XMLElement)] = []
        if root.localName == "mxGraphModel" {
            models = [(name, root)]
        } else {
            for (i, d) in root.kids("diagram").enumerated() {
                let title = d.attr("name") ?? "Page \(i + 1)"
                if let m = d.kid("mxGraphModel") {
                    models.append((title, m))
                } else if let text = d.stringValue?.trimmed, !text.isEmpty {
                    guard let raw = Data(base64Encoded: text),
                        let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data,
                        let xml = String(data: inflated, encoding: .utf8)?.removingPercentEncoding,
                        let m = try? XML.parse(Data(xml.utf8), name: name)
                    else {
                        report.skip("Page “\(title)” couldn’t be decompressed")
                        continue
                    }
                    models.append((title, m))
                }
            }
        }
        report.sheets = models.count
        return models.map { canvas($0.0, $0.1, report: &report) }
    }

    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<div>", with: "\n")
        s = s.replacing(/<[^>]+>/, with: "")
        return s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").trimmed
    }

    static func canvas(_ title: String, _ m: XMLElement, report: inout ImportReport) -> ICanvas {
        var g = MermaidFormat.Graph()
        let cells = m.kid("root")?.kids("mxCell") ?? m.descendants("mxCell")
        // Cells wrapped in <object>/<UserObject> carry the label on the wrapper.
        let wrapped = (m.kid("root")?.kids() ?? []).filter { $0.localName == "object" || $0.localName == "UserObject" }
        var all: [(id: String, value: String, cell: XMLElement)] = cells.compactMap { c in
            c.attr("id").map { ($0, c.attr("value") ?? "", c) }
        }
        for w in wrapped {
            if let id = w.attr("id"), let c = w.kid("mxCell") { all.append((id, w.attr("label") ?? "", c)) }
        }
        var containers = Set<String>()
        for (id, value, c) in all where c.attr("vertex") == "1" {
            let style = c.attr("style") ?? ""
            if style.contains("swimlane") || style.contains("container=1") || style.contains("group") {
                containers.insert(id)
                g.groups.append((plain(value), []))
                continue
            }
            let shape: String? =
                style.contains("rhombus")
                ? "diamond"
                : style.contains("ellipse")
                    ? "stadium"
                    : style.contains("cylinder") ? "cylinder" : style.contains("parallelogram") ? "parallelogram" : nil
            let text = plain(value)
            if text.isEmpty && style.contains("text") { continue }
            g.node(id, text, shape)
            if let p = c.attr("parent"), containers.contains(p), let gi = g.groups.indices.last {
                g.groups[gi].1.append(id)
            }
        }
        for (_, value, c) in all where c.attr("edge") == "1" {
            guard let a = c.attr("source"), let b = c.attr("target"), g.text[a] != nil, g.text[b] != nil else {
                report.skip("Connector without both ends")
                continue
            }
            g.edges.append((a, b, plain(value), (c.attr("style") ?? "").contains("dashed=1")))
        }
        let flow = g.shape.values.contains { $0 == "diamond" || $0 == "stadium" }
        return MermaidFormat.graphCanvas(g, title: title, type: flow ? .flowchart : .mindmap)
    }
}

// MARK: FreeMind / Freeplane

public enum FreeMindFormat {
    static func icon(_ b: String) -> String? {
        if b.hasPrefix("full-"), let n = Int(b.dropFirst(5)), (1...9).contains(n) { return "priority-\(n)" }
        switch b {
        case "help": return "symbol-question"
        case "messagebox_warning", "yes": return "symbol-exclaim"
        case "button_ok": return "symbol-check"
        case "button_cancel", "stop-sign": return "symbol-cross"
        case "flag", "flag-red": return "flag-red"
        case "flag-green": return "flag-green"
        case "flag-orange", "flag-yellow": return "flag-orange"
        case "flag-blue": return "flag-blue"
        case "bookmark", "star": return "star-gold"
        case "forward", "back", "up", "down": return "symbol-arrow"
        default: return nil
        }
    }

    public static func parse(_ data: Data, name: String, report: inout ImportReport) throws -> ICanvas {
        let root = try XML.parse(data, name: name)
        guard root.localName == "map", let top = root.kid("node") else {
            throw ImportError.invalid(name, "no FreeMind map")
        }
        var links: [ICanvas.Link] = []
        var groups: [ICanvas.Group] = []
        func topic(_ e: XMLElement) -> ITopic {
            var text = e.attr("TEXT") ?? ""
            var t = ITopic("", ref: e.attr("ID"))
            for rc in e.kids("richcontent") {
                let body = DrawIOFormat.plain(rc.xmlString)
                if rc.attr("TYPE") == "NOTE" {
                    t.note = body
                } else if rc.attr("TYPE") == "NODE" || rc.attr("TYPE") == nil {
                    text = body
                }
                if rc.attr("TYPE") == "DETAILS" { t.note = (t.note.map { $0 + "\n\n" } ?? "") + body }
            }
            t.text = text
            t.link = e.attr("LINK")
            t.folded = e.attr("FOLDED") == "true"
            for i in e.kids("icon") {
                guard let b = i.attr("BUILTIN") else { continue }
                if let m = icon(b) { t.markers.append(m) } else { report.skip("Icon “\(b)” (no equivalent)") }
            }
            for a in e.kids("arrowlink") {
                if let to = a.attr("DESTINATION"), let from = t.ref {
                    links.append(ICanvas.Link(from: from, to: to, label: a.attr("MIDDLE_LABEL") ?? ""))
                }
            }
            for a in e.kids("attribute") {
                if let n = a.attr("NAME"), let v = a.attr("VALUE") { t.labels.append("\(n): \(v)") }
            }
            if e.kid("hook") != nil { report.skip("FreeMind plug-in data") }
            t.children = e.kids("node").map(topic)
            if e.kid("cloud") != nil, let r = t.ref { groups.append(ICanvas.Group(refs: [r])) }
            return t
        }
        let r = topic(top)
        report.sheets = 1
        var ic = ICanvas(title: r.text, root: r)
        ic.links = links
        ic.groups = groups
        return ic
    }
}

// MARK: MindManager (.mmap)

public enum MindManagerFormat {
    public static func parse(_ data: Data, name: String, report: inout ImportReport) throws -> ICanvas {
        guard !data.isEmpty else { throw ImportError.empty(name) }
        let files = try Zip.read(data)
        guard let doc = files["Document.xml"] else { throw ImportError.invalid(name, "no Document.xml inside") }
        let root = try XML.parse(doc, name: name)
        guard let top = root.kid("OneTopic")?.kid("Topic") else { throw ImportError.invalid(name, "no central topic") }
        func topic(_ e: XMLElement) -> ITopic {
            var t = ITopic(e.kid("Text")?.attr("PlainText") ?? "", ref: e.attr("OId"))
            if let n = e.kid("NotesGroup")?.kid("NotesXhtmlData") {
                t.note = n.attr("PreviewPlainText") ?? DrawIOFormat.plain(n.xmlString)
            }
            t.link = e.kid("Hyperlink")?.attr("Url")
            if let pct = e.kid("Task")?.attr("TaskPercentage"), let v = Int(pct) { t.todo = v >= 100 }
            if let p = e.kid("Task")?.attr("TaskPriority"), let n = Int(p.filter(\.isNumber)), (1...9).contains(n) {
                t.markers.append("priority-\(n)")
            }
            for icon in e.kid("IconsGroup")?.descendants("Icon") ?? [] {
                let type = icon.attr("IconType") ?? ""
                if let n = Int(type.filter(\.isNumber)), type.contains("Prio"), (1...9).contains(n) {
                    t.markers.append("priority-\(n)")
                } else if !type.isEmpty {
                    report.skip("Icon “\(type.split(separator: ":").last ?? "")” (no equivalent)")
                }
            }
            t.labels = e.kid("TextLabels")?.descendants("TextLabel").compactMap { $0.attr("TextLabelName") } ?? []
            if e.kid("Image") != nil { report.skip("Topic image") }
            t.children = e.kid("SubTopics")?.kids("Topic").map(topic) ?? []
            return t
        }
        let r = topic(top)
        var ic = ICanvas(title: r.text, root: r)
        ic.floating = root.kid("FloatingTopics")?.kids("Topic").map(topic) ?? []
        for rel in root.descendants("Relationship") {
            let refs = rel.descendants("ObjectReference").compactMap { $0.attr("OIdRef") }
            if refs.count == 2 { ic.links.append(ICanvas.Link(from: refs[0], to: refs[1])) }
        }
        if root.descendants("Boundary").count > 0 { report.skip("Boundary", root.descendants("Boundary").count) }
        report.sheets = 1
        return ic
    }
}

// MARK: MindNode

public enum MindNodeFormat {
    /// A `.mindnode` package (`contents.xml` property list) or its zipped single-file form.
    public static func parse(files: [String: Data], name: String, report: inout ImportReport) throws -> [ICanvas] {
        guard let plist = files["contents.xml"] ?? files.first(where: { $0.key.hasSuffix("/contents.xml") })?.value,
            let any = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        else { throw ImportError.invalid(name, "no MindNode contents") }
        let map = any["mindMap"] as? [String: Any] ?? any
        let mains = map["mainNodes"] as? [[String: Any]] ?? []
        func text(_ n: [String: Any]) -> String {
            if let t = (n["title"] as? [String: Any])?["text"] as? String { return DrawIOFormat.plain(t) }
            return DrawIOFormat.plain(n["title"] as? String ?? "")
        }
        func topic(_ n: [String: Any]) -> ITopic {
            var t = ITopic(text(n), ref: n["nodeID"] as? String)
            if let note = (n["note"] as? [String: Any])?["text"] as? String { t.note = DrawIOFormat.plain(note) }
            if let done = n["task"] as? [String: Any] { t.todo = (done["state"] as? Int ?? 0) == 1 }
            t.link = n["link"] as? String
            t.folded = n["folded"] as? Bool ?? false
            t.children = (n["subnodes"] as? [[String: Any]] ?? []).map(topic)
            return t
        }
        report.sheets = 1
        let tops = mains.map(topic)
        guard !tops.isEmpty else { throw ImportError.invalid(name, "no topics") }
        var out = [ICanvas(title: tops[0].text, root: tops[0])]
        out[0].floating = Array(tops.dropFirst())
        for c in map["crossConnections"] as? [[String: Any]] ?? [] {
            if let a = c["startNodeID"] as? String, let b = c["endNodeID"] as? String {
                out[0].links.append(
                    ICanvas.Link(from: a, to: b, label: (c["title"] as? [String: Any])?["text"] as? String ?? ""))
            }
        }
        return out
    }
}

// MARK: Word (.docx)

public enum WordFormat {
    /// Headings for the outline (Title for the central topic), notes as paragraphs, and an
    /// optional diagram image after the title.
    public static func export(
        _ doc: DocumentModel, canvases: [Canvas]? = nil, images: [CanvasID: (png: Data, width: Int, height: Int)] = [:]
    ) -> Data {
        var body = ""
        var rels = ""
        var media: [(String, Data)] = []
        func para(_ text: String, style: String? = nil, indent: Int = 0) -> String {
            var p = "<w:p>"
            if style != nil || indent > 0 {
                p += "<w:pPr>" + (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "")
                if indent > 0 { p += "<w:ind w:left=\"\(indent * 360)\"/>" }
                p += "</w:pPr>"
            }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if i > 0 { p += "<w:r><w:br/></w:r>" }
                p += "<w:r><w:t xml:space=\"preserve\">\(XML.escape(line, attribute: false))</w:t></w:r>"
            }
            return p + "</w:p>"
        }
        for (ci, c) in (canvases ?? doc.orderedCanvases).enumerated() {
            if ci > 0 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            if let img = images[c.id] {
                let rid = "rIdImg\(media.count + 1)"
                media.append(("image\(media.count + 1).png", img.png))
                rels +=
                    "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image\(media.count).png\"/>"
                // Fit 6.5 in wide.
                let cx = 5_943_600
                let cy = Int(Double(cx) * Double(img.height) / Double(max(img.width, 1)))
                body += para(c.nodes[c.root]?.text ?? c.title, style: "Title")
                body += """
                    <w:p><w:r><w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(media.count)" name="Diagram \(media.count)" descr="\(XML.escape(c.title))"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(media.count)" name="image\(media.count).png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                    """
            }
            c.walk { _, n, d in
                if d == 0 {
                    if images[c.id] == nil { body += para(n.text, style: "Title") }
                } else if d <= 6 {
                    body += para(n.text, style: "Heading\(d)")
                } else {
                    body += para("• " + n.text, indent: d - 6)
                }
                if let note = n.note?.text, !note.trimmed.isEmpty { body += para(note.trimmed, indent: max(d - 6, 0)) }
            }
        }
        let ns =
            "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
        var z = ZipWriter()
        z.add(
            "[Content_Types].xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
            """)
        z.add(
            "_rels/.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
            """)
        let title = (canvases ?? doc.orderedCanvases).first.map { $0.title } ?? ""
        z.add(
            "docProps/core.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(XML.escape(title, attribute: false))</dc:title></cp:coreProperties>
            """)
        z.add(
            "word/_rels/document.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(rels)</Relationships>
            """)
        var styles =
            "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:rPr><w:sz w:val=\"22\"/></w:rPr></w:style>"
        styles +=
            "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"240\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"52\"/></w:rPr></w:style>"
        for (i, size) in [36, 30, 26, 24, 22, 22].enumerated() {
            styles +=
                "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(i + 1)\"><w:name w:val=\"heading \(i + 1)\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"80\"/><w:outlineLvl w:val=\"\(i)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        z.add(
            "word/styles.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:styles \(ns)>\(styles)</w:styles>")
        z.add(
            "word/document.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document \(ns)><w:body>\(body)<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>"
        )
        for (n, d) in media { z.add("word/media/\(n)", d) }
        return z.finish()
    }

    /// Headings and lists become the tree; other paragraphs notes.
    public static func parse(_ data: Data, name: String, report: inout ImportReport) throws -> ICanvas {
        guard !data.isEmpty else { throw ImportError.empty(name) }
        let files = try Zip.read(data)
        guard let xml = files["word/document.xml"] else { throw ImportError.invalid(name, "no word/document.xml") }
        let root = try XML.parse(xml, name: name)
        var md: [String] = []
        // Body paragraphs only: table cells are reported, not imported as notes.
        for p in root.kid("body")?.kids("p") ?? root.descendants("p") {
            let text = p.descendants("t").compactMap(\.stringValue).joined()
            if text.trimmed.isEmpty { continue }
            let style = p.kid("pPr")?.kid("pStyle")?.attr("w:val") ?? ""
            if style == "Title" {
                md.append("# " + text)
            } else if style.lowercased().hasPrefix("heading"), let n = Int(style.filter(\.isNumber)) {
                md.append(String(repeating: "#", count: min(n + 1, 6)) + " " + text)
            } else if let lvl = p.kid("pPr")?.kid("numPr")?.kid("ilvl")?.attr("w:val").flatMap(Int.init) {
                md.append(String(repeating: "  ", count: lvl) + "- " + text)
            } else if p.kid("pPr")?.kid("numPr") != nil || style.lowercased().contains("list") {
                md.append("- " + text)
            } else {
                md.append(text)
            }
        }
        if !root.descendants("drawing").isEmpty {
            report.skip("Image in the document", root.descendants("drawing").count)
        }
        if !root.descendants("tbl").isEmpty { report.skip("Table", root.descendants("tbl").count) }
        report.sheets = 1
        return MarkdownFormat.parse(md.joined(separator: "\n"), title: name, report: &report)
    }
}

// MARK: CSV

public enum CSVFormat {
    static func field(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n")
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// Threat table on threat models (element, STRIDE category, risk, mitigation, status);
    /// a task list everywhere else.
    public static func export(_ c: Canvas) -> String {
        let threats = Stride.threats(c)
        if c.type == .threatModel || !threats.isEmpty { return Stride.csv(threats) }
        var out = "Topic,Path,Status,Priority,Labels,Note\n"
        c.walk { id, n, d in
            guard d > 0 else { return }
            let path = c.path(to: id).compactMap { c.nodes[$0]?.text }.joined(separator: " › ")
            let status = n.todo.map { $0.done ? "done" : "open" } ?? ""
            out +=
                [
                    n.text, path, status, n.priority.map { "P\($0)" } ?? "", n.labels.joined(separator: "; "),
                    n.note?.text ?? "",
                ]
                .map(field).joined(separator: ",") + "\n"
        }
        return out
    }
}
