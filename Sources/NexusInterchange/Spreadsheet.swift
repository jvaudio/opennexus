import Foundation
import NexusCore
import NexusFormat

// MARK: Excel (.xlsx)

/// A minimal SpreadsheetML workbook written by hand (D89: no package dependencies): one
/// sheet per canvas, one row per topic in outline order, inline strings, a bold frozen
/// header row and an autofilter.
public enum ExcelFormat {
    public static let columns = ["Level", "Path", "Topic", "Note", "Labels", "Markers", "To-do"]
    /// Added on technical canvases (D157).
    public static let technicalColumns = ["Type", "STRIDE", "Risk", "Status"]
    /// Added when a canvas has tasks (M22, D206).
    public static let taskColumns = ["Owner", "Start", "Due", "Progress", "Depends on"]
    /// Added when a canvas has comments.
    public static let commentColumns = ["Comments"]

    static let widths: [String: Double] = [
        "Level": 7, "Path": 36, "Topic": 32, "Note": 48, "Labels": 18, "Markers": 18, "To-do": 9, "Type": 16,
        "STRIDE": 16, "Risk": 9, "Status": 12, "Owner": 16, "Start": 11, "Due": 11, "Progress": 9,
        "Depends on": 28, "Comments": 48,
    ]
    /// Columns whose cells wrap.
    static let wrapping: Set<String> = ["Note", "Comments"]

    /// True when a topic carries task fields beyond the check box.
    static func isTask(_ t: Todo) -> Bool {
        t.start != nil || t.due != nil || t.owner != nil || (t.progress ?? 0) != 0 || !t.after.isEmpty
    }

    /// The rows of one canvas, header first: the main tree, then each floating topic's
    /// branch. Level is the depth below its top (the central topic is 0).
    public static func rows(_ c: Canvas) -> [[String]] {
        let technical = DiagramCatalog.isTechnical(c.type)
        let parents = c.parentMap()
        let threats = Dictionary(Stride.threats(c).map { ($0.node, $0) }, uniquingKeysWith: { a, _ in a })
        let tasks = c.nodes.values.contains { $0.todo.map(isTask) ?? false }
        let comments = c.nodes.values.contains { !$0.comments.isEmpty }
        var out = [
            columns + (technical ? technicalColumns : []) + (tasks ? taskColumns : [])
                + (comments ? commentColumns : [])
        ]
        for top in [c.root] + c.floating {
            c.walk(from: top) { id, n, d in
                let path = c.path(to: id, parents: parents).compactMap { c.nodes[$0]?.text }.joined(separator: " › ")
                var row = [
                    String(d), path, n.text, n.note?.text ?? "", n.labels.joined(separator: "; "),
                    n.markers.joined(separator: "; "), n.todo.map { $0.done ? "done" : "open" } ?? "",
                ]
                if technical {
                    let type = DiagramCatalog.effectiveType(id, in: c, parents: parents)
                    let threat = threats[id]
                    row += [
                        type.map { DiagramCatalog.info($0, in: c.type)?.name ?? $0.rawValue } ?? "",
                        threat?.category?.name ?? Stride.field(n, Stride.categoryKey) ?? "",
                        threat?.risk ?? Stride.field(n, Stride.riskKey) ?? "",
                        threat?.status ?? Stride.field(n, Stride.statusKey) ?? "",
                    ]
                }
                if tasks {
                    let t = n.todo
                    let deps = (t?.after ?? []).compactMap { d in
                        c.nodes[d.task].map { $0.text + TaskText.dependencySuffix(d) }
                    }
                    row += [
                        t?.owner ?? "", t?.start?.description ?? "", t?.due?.description ?? "",
                        t == nil ? "" : "\(c.progress(of: id))%", deps.joined(separator: "; "),
                    ]
                }
                if comments {
                    row.append(
                        n.comments.map { cm in
                            let who = [cm.author, String(cm.date.prefix(10))].filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            return (who.isEmpty ? "" : who + ": ") + cm.text
                        }
                        .joined(separator: "\n"))
                }
                out.append(row)
            }
        }
        return out
    }

    /// One canvas's rows as tab-separated text (tabs and line breaks inside a cell become
    /// spaces).
    public static func tsv(_ c: Canvas) -> String {
        rows(c).map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }
        .joined(separator: "\n") + "\n"
    }

    public static func export(_ doc: DocumentModel, canvases: [Canvas]? = nil) -> Data {
        let list = canvases ?? doc.orderedCanvases
        var names: [String] = []
        for c in list { names.append(sheetName(c.title.isEmpty ? c.nodes[c.root]?.text ?? "" : c.title, taken: names)) }
        if names.isEmpty { names = ["Sheet1"] }

        var z = ZipWriter()
        var overrides = ""
        for i in names.indices {
            overrides +=
                "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        z.add(
            "[Content_Types].xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
            """)
        z.add(
            "_rels/.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
            """)
        z.add(
            "docProps/core.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(XML.escape(clean(list.first?.title ?? ""), attribute: false))</dc:title></cp:coreProperties>
            """)
        var sheets = ""
        var rels = ""
        for (i, name) in names.enumerated() {
            sheets += "<sheet name=\"\(XML.escape(name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels +=
                "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        rels +=
            "<Relationship Id=\"rId\(names.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        z.add(
            "xl/workbook.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheets)</sheets></workbook>
            """)
        z.add(
            "xl/_rels/workbook.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """)
        // Style 0 is the default; style 1 is bold (the header row); style 2 wraps (notes).
        z.add(
            "xl/styles.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
            """)
        for i in names.indices {
            z.add("xl/worksheets/sheet\(i + 1).xml", sheet(i < list.count ? rows(list[i]) : [columns]))
        }
        return z.finish()
    }

    static func sheet(_ rows: [[String]]) -> String {
        let header = rows.first ?? []
        let width = max(header.count, 1)
        var cols = ""
        for i in 0..<width {
            let w = i < header.count ? widths[header[i]] ?? 12 : 12
            cols += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(Int(w))\" customWidth=\"1\"/>"
        }
        let wraps = Set(header.indices.filter { wrapping.contains(header[$0]) })
        var data = ""
        for (r, row) in rows.enumerated() {
            data += "<row r=\"\(r + 1)\">"
            for (ci, value) in row.enumerated() {
                let ref = column(ci) + String(r + 1)
                if r == 0 {
                    data += "<c r=\"\(ref)\" s=\"1\" t=\"inlineStr\"><is><t>\(text(value))</t></is></c>"
                } else if ci == 0, let n = Int(value) {
                    data += "<c r=\"\(ref)\"><v>\(n)</v></c>"
                } else if !value.isEmpty {
                    let style = wraps.contains(ci) ? " s=\"2\"" : ""
                    data +=
                        "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(text(value))</t></is></c>"
                }
            }
            data += "</row>"
        }
        let last = column(width - 1) + String(rows.count)
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1:\(last)"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>\(cols)</cols><sheetData>\(data)</sheetData><autoFilter ref="A1:\(last)"/></worksheet>
            """
    }

    /// A, B … Z, AA …
    static func column(_ i: Int) -> String {
        var n = i + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Cell text: XML-safe and within Excel's 32,767-character cell limit.
    static func text(_ s: String) -> String {
        XML.escape(String(clean(s).prefix(32_767)), attribute: false)
    }

    /// XML 1.0 has no place for most control characters; tabs and line breaks stay.
    static func clean(_ s: String) -> String {
        String(
            String.UnicodeScalarView(
                s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" }))
    }

    /// Excel's rules: 1–31 characters, none of `[]:*?/\`, not quoted at either end, and
    /// unique ignoring case.
    static func sheetName(_ title: String, taken: [String]) -> String {
        let forbidden = Set("[]:*?/\\")
        var base = String(clean(title).filter { !forbidden.contains($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "' ").union(.whitespaces))
        if base.isEmpty || base.lowercased() == "history" { base = "Sheet" }
        base = String(base.prefix(31))
        let lower = Set(taken.map { $0.lowercased() })
        var name = base
        var n = 2
        while lower.contains(name.lowercased()) {
            let suffix = " (\(n))"
            name = String(base.prefix(31 - suffix.count)) + suffix
            n += 1
        }
        return name
    }
}
