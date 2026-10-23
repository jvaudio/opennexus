import Foundation
import NexusCanvas
import NexusCore
import NexusInterchange

/// `nexus export --to <format>` and the MCP `export` tool. Every format goes through the
/// app's own exporters (the offscreen canvas for visual formats and draw.io).
public enum CLIFormat: String, CaseIterable, Sendable {
    case md, opml, mermaid, plantuml, json, yaml, csv, txt, drawio, svg, png, jpeg, pdf, docx, pptx, xlsx, xmind, xmind8

    /// Also accepted: the file extensions people type.
    public init?(name: String) {
        let n = name.lowercased()
        let aliases: [String: CLIFormat] = [
            "markdown": .md, "mmd": .mermaid, "puml": .plantuml, "jpg": .jpeg, "word": .docx, "powerpoint": .pptx,
            "excel": .xlsx,
            "text": .txt, "indented": .txt, "yml": .yaml, "dio": .drawio, "xmind-8": .xmind8,
        ]
        if let f = CLIFormat(rawValue: n) ?? aliases[n] { self = f } else { return nil }
    }

    public var isText: Bool {
        switch self {
        case .png, .jpeg, .pdf, .docx, .pptx, .xlsx, .xmind, .xmind8: false
        default: true
        }
    }

    public var fileExtension: String {
        switch self {
        case .mermaid: "mmd"
        case .plantuml: "puml"
        case .jpeg: "jpg"
        case .xmind8: "xmind"
        default: rawValue
        }
    }

    var exportFormat: ExportFormat? {
        switch self {
        case .md: .markdown
        case .opml: .opml
        case .mermaid: .mermaid
        case .plantuml: .plantuml
        case .json, .yaml: .json
        case .csv: .csv
        case .drawio: .drawio
        case .svg: .svg
        case .png: .png
        case .jpeg: .jpeg
        case .pdf: .pdf
        case .docx: .word
        case .pptx: .powerpoint
        case .xlsx: .excel
        case .xmind, .xmind8: .xmind
        case .txt: nil
        }
    }

    /// "md, opml, …": the formats `keep` accepts, for help and messages.
    public static func names(_ keep: (CLIFormat) -> Bool = { _ in true }) -> String {
        allCases.filter(keep).map(\.rawValue).joined(separator: ", ")
    }

    /// The formats the export sheet offers Branch scope for (and indented text).
    public var exportsBranch: Bool {
        switch self {
        case .md, .opml, .txt, .svg, .png, .jpeg, .pdf: true
        default: false
        }
    }

    /// The visual formats, which draw a zone on its own.
    public var exportsZone: Bool {
        switch self {
        case .svg, .png, .jpeg, .pdf: true
        default: false
        }
    }

    /// One file. nil for `.eachZone` (see `zoneFiles`) and for a scope the format doesn't
    /// export (`ExportScope.parse` refuses those first).
    @MainActor
    public func export(_ doc: DocumentModel, canvas: CanvasID?, scope: ExportScope = .canvas, scale: Double? = nil)
        -> Data?
    {
        if self == .txt {
            guard let c = doc.canvases[canvas ?? doc.canvasOrder.first ?? "c1"] else { return nil }
            switch scope {
            case .canvas: return Data(IndentedText.export(c).utf8)
            case .branch(let top): return c.nodes[top] == nil ? nil : Data(IndentedText.export(c, from: top).utf8)
            default: return nil
            }
        }
        guard let f = exportFormat else { return nil }
        let s: HeadlessExport.Scope
        switch scope {
        case .canvas: s = .canvas
        case .branch(let top) where exportsBranch: s = .branch(top)
        case .zone(let z) where exportsZone: s = .zone(z)
        case .zonePages where self == .pdf: s = .zonePages
        default: return nil
        }
        return HeadlessExport.data(
            doc, canvas: canvas, format: f, scope: s, yaml: self == .yaml, scale: scale, xmind8: self == .xmind8)
    }

    /// Each zone as its own file, named after its title (`.eachZone`, D227). Empty for a
    /// format that doesn't draw zones or a canvas without them.
    @MainActor
    public func zoneFiles(_ doc: DocumentModel, canvas: CanvasID?, scale: Double? = nil) -> [(
        name: String, data: Data
    )] {
        guard exportsZone, let f = exportFormat else { return [] }
        return HeadlessExport.zoneFiles(doc, canvas: canvas, format: f, scale: scale)
    }
}

/// What `nexus export` and the MCP `export` tool cover (D227), like the export sheet's Scope
/// and Zones pickers: the canvas (the default), a branch, one zone, or every zone, a file
/// each or, for PDF, a page each. The sheet's Selection scope needs a window, so it's
/// left out.
public enum ExportScope: Equatable, Sendable {
    case canvas
    case branch(NodeID)
    case zone(String)
    case eachZone
    case zonePages

    /// From the `branch` (a topic), `zone` (a zone's id or title) and `zones` (`each` or
    /// `pages`) options, of which at most one is given. Throws a message naming what the
    /// format can export instead.
    @MainActor
    public static func parse(
        branch: String?, zone: String?, zones: String?, format f: CLIFormat, in c: Canvas
    ) throws -> ExportScope {
        let given = [branch, zone, zones].compactMap { $0 }.filter { !$0.isEmpty }
        guard given.count <= 1 else { throw MapTools.ToolError("Give only one of branch, zone and zones.") }
        if let branch, !branch.isEmpty {
            guard f.exportsBranch else {
                throw MapTools.ToolError(
                    "\(f.rawValue) exports the whole canvas; a branch exports as \(CLIFormat.names(\.exportsBranch)).")
            }
            return .branch(try MapTools.topic(branch, in: c))
        }
        if let zone, !zone.isEmpty {
            guard f.exportsZone else {
                throw MapTools.ToolError("A zone exports as \(CLIFormat.names(\.exportsZone)), not \(f.rawValue).")
            }
            let key = zone.lowercased().hasPrefix("zone:") ? String(zone.dropFirst(5)) : zone
            let end = try MapTools.end("zone:" + key, in: c)
            return .zone(end.rawValue)
        }
        guard let zones, !zones.isEmpty else { return .canvas }
        guard zones == "each" || zones == "pages" else {
            throw MapTools.ToolError(
                "zones is “each” (a file per zone) or “pages” (one PDF, a page per zone), not “\(zones)”.")
        }
        guard f.exportsZone else {
            throw MapTools.ToolError("Zones export as \(CLIFormat.names(\.exportsZone)), not \(f.rawValue).")
        }
        guard zones == "each" || f == .pdf else {
            throw MapTools.ToolError("A page per zone needs pdf; “each” writes a file per zone.")
        }
        guard !c.zones.isEmpty else { throw MapTools.ToolError("The canvas has no zones.") }
        return zones == "each" ? .eachZone : .zonePages
    }

    /// What the app's export adds to the file name: " – Pricing" for a branch, the zone's
    /// title for a zone, " – Zones" for a page per zone; "" for the canvas.
    public func nameSuffix(in c: Canvas) -> String {
        switch self {
        case .canvas, .eachZone: ""
        case .branch(let top): " – " + (c.nodes[top]?.text.replacingOccurrences(of: "\n", with: " ") ?? "")
        case .zone(let z): " – " + (c.zones.first { $0.id == z }.map { $0.title.isEmpty ? "Zone" : $0.title } ?? "")
        case .zonePages: " – Zones"
        }
    }
}
