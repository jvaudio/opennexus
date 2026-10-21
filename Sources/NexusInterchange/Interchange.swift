import Foundation
import NexusCore
import NexusFormat

// MARK: JSON · YAML

public enum DocumentJSON {
    /// The whole document as one JSON object in the OpenNexus schema: the manifest, every
    /// canvas in order, and the theme. Assets stay in the .nexus package.
    public static func value(_ doc: DocumentModel) -> JSONValue {
        let files = NexusPackage.files(for: doc)
        func parse(_ path: String) -> JSONValue { files[path].flatMap { try? CanonicalJSON.parse($0) } ?? .null }
        var o: [String: JSONValue] = [
            "manifest": parse("manifest.json"),
            "canvases": .array(doc.canvasOrder.map { parse("canvases/\($0.rawValue).json") }),
            "theme": parse("theme.json"),
        ]
        if files["ai/chats.json"] != nil { o["chats"] = parse("ai/chats.json") }
        return .object(o)
    }

    public static func export(_ doc: DocumentModel, pretty: Bool = true, assets: Bool = false) -> String {
        var v = value(doc)
        // The single-file document (Settings › Files › Save as: Single JSON) carries its
        // assets as base64.
        if assets, !doc.assets.isEmpty, case .object(var o) = v {
            o["assets"] = .object(doc.assets.mapValues { .string($0.base64EncodedString()) })
            v = .object(o)
        }
        return pretty ? CanonicalJSON.string(v) : compact(v) + "\n"
    }

    static func compact(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): return CanonicalJSON.string(.string(s)).trimmed
        case .array(let a): return "[" + a.map(compact).joined(separator: ",") + "]"
        case .object(let o):
            return "{"
                + o.keys.sorted().map { CanonicalJSON.string(.string($0)).trimmed + ":" + compact(o[$0]!) }.joined(
                    separator: ",") + "}"
        }
    }

    /// YAML 1.2 block style (keys sorted, like the JSON files).
    public static func yaml(_ doc: DocumentModel) -> String {
        var out = ""
        func scalar(_ v: JSONValue) -> String? {
            switch v {
            case .null: return "null"
            case .bool(let b): return b ? "true" : "false"
            case .number: return compact(v)
            case .string(let s):
                let plain =
                    !s.isEmpty && s.rangeOfCharacter(from: CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`\n")) == nil
                    && s.trimmed == s && !["true", "false", "null", "yes", "no", "~"].contains(s.lowercased())
                    && Double(s) == nil
                return plain ? s : CanonicalJSON.string(.string(s)).trimmed
            case .array(let a) where a.isEmpty: return "[]"
            case .object(let o) where o.isEmpty: return "{}"
            default: return nil
            }
        }
        func emit(_ v: JSONValue, indent: Int) {
            let pad = String(repeating: "  ", count: indent)
            switch v {
            case .object(let o):
                for k in o.keys.sorted() {
                    let key = scalar(.string(k)) ?? k
                    if let s = scalar(o[k]!) {
                        out += "\(pad)\(key): \(s)\n"
                    } else {
                        out += "\(pad)\(key):\n"
                        emit(o[k]!, indent: indent + 1)
                    }
                }
            case .array(let a):
                for item in a {
                    if let s = scalar(item) {
                        out += "\(pad)- \(s)\n"
                    } else {
                        // The item's first line shares the dash: "- id: c1".
                        let start = out.endIndex
                        emit(item, indent: indent + 1)
                        let inner = String(repeating: "  ", count: indent + 1)
                        if out[start...].hasPrefix(inner) {
                            out.replaceSubrange(start..<out.index(start, offsetBy: inner.count), with: pad + "- ")
                        }
                    }
                }
            default:
                out += pad + (scalar(v) ?? "") + "\n"
            }
        }
        emit(value(doc), indent: 0)
        return out
    }

    /// Reads the JSON form back (lossless except assets).
    public static func parse(_ data: Data, name: String) throws -> DocumentModel {
        guard let v = try? CanonicalJSON.parse(data), let o = v.objectValue, let manifest = o["manifest"],
            case .array(let canvases)? = o["canvases"]
        else { throw ImportError.invalid(name, "not an OpenNexus JSON document") }
        var files: [String: Data] = ["manifest.json": CanonicalJSON.data(manifest)]
        for c in canvases {
            guard let id = c.objectValue?["id"], case .string(let s) = id else { continue }
            files["canvases/\(s).json"] = CanonicalJSON.data(c)
        }
        if let t = o["theme"], t != .null { files["theme.json"] = CanonicalJSON.data(t) }
        if let ch = o["chats"], ch != .null { files["ai/chats.json"] = CanonicalJSON.data(ch) }
        if case .object(let a)? = o["assets"] {
            for (name, v) in a {
                if case .string(let b) = v, let d = Data(base64Encoded: b) { files["assets/\(name)"] = d }
            }
        }
        do {
            return try NexusPackage.read(files: files)
        } catch {
            throw ImportError.invalid(name, "\(error)")
        }
    }
}

// MARK: Format registry

/// Every format the app reads or writes (artboards 30 and 33).
public enum InterchangeFormat: String, CaseIterable, Sendable {
    case nexus, xmind, opml, markdown, text, mermaid, plantuml, drawio, freemind, mindmanager, mindnode, textbundle
    case docx, json, yaml, csv

    public var title: String {
        switch self {
        case .nexus: "OpenNexus"
        case .xmind: "Xmind"
        case .opml: "OPML"
        case .markdown: "Markdown"
        case .text: "Indented text"
        case .mermaid: "Mermaid"
        case .plantuml: "PlantUML"
        case .drawio: "draw.io"
        case .freemind: "FreeMind"
        case .mindmanager: "MindManager"
        case .mindnode: "MindNode"
        case .textbundle: "TextBundle"
        case .docx: "Word"
        case .json: "JSON"
        case .yaml: "YAML"
        case .csv: "CSV"
        }
    }

    public var extensions: [String] {
        switch self {
        case .nexus: ["nexus"]
        case .xmind: ["xmind"]
        case .opml: ["opml"]
        case .markdown: ["md", "markdown", "mdown"]
        case .text: ["txt", "text"]
        case .mermaid: ["mmd", "mermaid"]
        case .plantuml: ["puml", "plantuml", "pu"]
        case .drawio: ["drawio", "dio"]
        case .freemind: ["mm"]
        case .mindmanager: ["mmap"]
        case .mindnode: ["mindnode"]
        case .textbundle: ["textbundle", "textpack"]
        case .docx: ["docx"]
        case .json: ["json"]
        case .yaml: ["yaml", "yml"]
        case .csv: ["csv"]
        }
    }

    /// Formats File › Import… accepts.
    public static let importable: [InterchangeFormat] = [
        .xmind, .opml, .markdown, .text, .mermaid, .plantuml, .drawio, .freemind, .mindmanager, .mindnode, .textbundle,
        .docx, .json, .nexus,
    ]

    public static func detect(name: String) -> InterchangeFormat? {
        let ext = (name as NSString).pathExtension.lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }
}

public enum Interchange {
    /// Imports a file (or a package's files, for `.mindnode` and `.textbundle` folders).
    /// `timeZone` turns timestamps (Xmind task dates) into calendar days.
    public static func importFile(
        name: String, data: Data? = nil, files: [String: Data]? = nil, timeZone: TimeZone = .current
    ) throws -> Imported {
        guard let format = InterchangeFormat.detect(name: name) ?? sniff(data) else {
            throw ImportError.unrecognised(name)
        }
        let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        if let data, data.isEmpty, files == nil { throw ImportError.empty(name) }
        var report = ImportReport(source: (name as NSString).lastPathComponent, format: format.title)
        func one(_ ic: ICanvas) -> Imported {
            if report.sheets == 0 { report.sheets = 1 }
            let canvases = CanvasBuilder.build([ic], report: &report)
            return Imported(canvases: canvases, report: report)
        }
        func text() throws -> String {
            guard let data else { throw ImportError.empty(name) }
            return String(decoding: data, as: UTF8.self)
        }
        switch format {
        case .xmind:
            guard let data else { throw ImportError.empty(name) }
            return try XmindFormat.parse(data, name: report.source, timeZone: timeZone)
        case .opml:
            guard let data else { throw ImportError.empty(name) }
            return one(try OPMLFormat.parse(data, name: report.source, report: &report))
        case .markdown:
            return one(MarkdownFormat.parse(try text(), title: base, report: &report))
        case .text:
            return one(IndentedText.parse(try text(), title: base))
        case .mermaid:
            return one(try MermaidFormat.parse(try text(), title: base, report: &report))
        case .plantuml:
            return one(try PlantUMLFormat.parse(try text(), title: base, report: &report))
        case .drawio:
            guard let data else { throw ImportError.empty(name) }
            let list = try DrawIOFormat.parse(data, name: report.source, report: &report)
            guard !list.isEmpty else { throw ImportError.invalid(name, "no diagrams") }
            return Imported(canvases: CanvasBuilder.build(list, report: &report), report: report)
        case .freemind:
            guard let data else { throw ImportError.empty(name) }
            return one(try FreeMindFormat.parse(data, name: report.source, report: &report))
        case .mindmanager:
            guard let data else { throw ImportError.empty(name) }
            return one(try MindManagerFormat.parse(data, name: report.source, report: &report))
        case .mindnode:
            let f = try files ?? data.map { try Zip.read($0) } ?? [:]
            let list = try MindNodeFormat.parse(files: f, name: report.source, report: &report)
            return Imported(canvases: CanvasBuilder.build(list, report: &report), report: report)
        case .textbundle:
            let f = try files ?? data.map { try Zip.read($0) } ?? [:]
            guard
                let md = f.first(where: {
                    ["text.md", "text.markdown", "text.txt"].contains(($0.key as NSString).lastPathComponent)
                })?.value
            else { throw ImportError.invalid(name, "no text.md inside") }
            return one(MarkdownFormat.parse(String(decoding: md, as: UTF8.self), title: base, report: &report))
        case .docx:
            guard let data else { throw ImportError.empty(name) }
            return one(try WordFormat.parse(data, name: base, report: &report))
        case .json:
            guard let data else { throw ImportError.empty(name) }
            let doc = try DocumentJSON.parse(data, name: report.source)
            return documentImport(doc, report: &report)
        case .nexus:
            let f = try files ?? data.map { try Zip.read($0) } ?? [:]
            do {
                let doc = try NexusPackage.read(files: f)
                return documentImport(doc, report: &report)
            } catch {
                throw ImportError.invalid(name, "\(error)")
            }
        case .yaml, .csv:
            throw ImportError.unrecognised(name)
        }
    }

    static func documentImport(_ doc: DocumentModel, report: inout ImportReport) -> Imported {
        report.sheets = doc.canvases.count
        report.canvases = doc.canvases.count
        for c in doc.canvases.values {
            report.topics += c.nodes.count
            report.markers += c.nodes.values.reduce(0) { $0 + $1.markers.count }
            report.notes += c.nodes.values.filter { $0.note != nil }.count
        }
        return Imported(canvases: doc.orderedCanvases, assets: doc.assets, report: report)
    }

    /// Recognises pasted or extension-less content by its first bytes.
    public static func sniff(_ data: Data?) -> InterchangeFormat? {
        guard let data, !data.isEmpty else { return nil }
        if Zip.looksLikeZip(data) {
            guard let files = try? Zip.read(data) else { return nil }
            if files["content.json"] != nil || files["content.xml"] != nil { return .xmind }
            if files["Document.xml"] != nil { return .mindmanager }
            if files["word/document.xml"] != nil { return .docx }
            if files["manifest.json"] != nil { return .nexus }
            return nil
        }
        // Only real text is sniffed as text.
        guard
            let head = String(data: data.prefix(4096), encoding: .utf8)
                ?? String(data: data.prefix(4093), encoding: .utf8),
            !head.unicodeScalars.contains(where: { $0.value < 0x20 && ![9, 10, 13].contains($0.value) })
        else { return nil }
        return sniff(text: head)
    }

    public static func sniff(text: String) -> InterchangeFormat? {
        let t = text.trimmed
        let first = t.split(separator: "\n").first.map { $0.trimmed.lowercased() } ?? ""
        if t.hasPrefix("<?xml") || t.hasPrefix("<") {
            if t.contains("<opml") { return .opml }
            if t.contains("<mxfile") || t.contains("<mxGraphModel") { return .drawio }
            if t.contains("<map") { return .freemind }
            return nil
        }
        if t.hasPrefix("{"), t.contains("\"manifest\"") { return .json }
        if ["mindmap", "sequencediagram", "classdiagram"].contains(first) || first.hasPrefix("flowchart ")
            || first.hasPrefix("graph ")
        {
            return .mermaid
        }
        if first.hasPrefix("@startmindmap") || first.hasPrefix("@startuml") || first.hasPrefix("@startwbs") {
            return .plantuml
        }
        if t.contains("\n#") || t.hasPrefix("#") || t.contains("\n- ") || t.hasPrefix("- ") || t.hasPrefix("* ") {
            return .markdown
        }
        return .text
    }

    /// Pasted text as one canvas (Markdown, indented text, OPML or Mermaid).
    public static func parsePasted(_ text: String, title: String = "Pasted") -> (ICanvas, ImportReport)? {
        let format = sniff(text: text) ?? .text
        var report = ImportReport(source: "Clipboard", format: format.title)
        switch format {
        case .opml:
            return (try? OPMLFormat.parse(Data(text.utf8), name: "Clipboard", report: &report)).map { ($0, report) }
        case .mermaid: return (try? MermaidFormat.parse(text, title: title, report: &report)).map { ($0, report) }
        case .plantuml: return (try? PlantUMLFormat.parse(text, title: title, report: &report)).map { ($0, report) }
        case .markdown: return (MarkdownFormat.parse(text, title: title, report: &report), report)
        default: return IndentedText.looksLikeOutline(text) ? (IndentedText.parse(text, title: title), report) : nil
        }
    }
}
