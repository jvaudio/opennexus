import Foundation
import NexusCanvas
import NexusCore
import NexusInterchange

/// `nexus export --to <format>` and the MCP `export` tool. Every format goes through the
/// app's own exporters (the offscreen canvas for visual formats and draw.io).
public enum CLIFormat: String, CaseIterable, Sendable {
    case md, opml, mermaid, plantuml, json, yaml, csv, txt, drawio, svg, png, jpeg, pdf, docx, pptx, xlsx

    /// Also accepted: the file extensions people type.
    public init?(name: String) {
        let n = name.lowercased()
        let aliases: [String: CLIFormat] = [
            "markdown": .md, "mmd": .mermaid, "puml": .plantuml, "jpg": .jpeg, "word": .docx, "powerpoint": .pptx,
            "excel": .xlsx,
            "text": .txt, "indented": .txt, "yml": .yaml, "dio": .drawio,
        ]
        if let f = CLIFormat(rawValue: n) ?? aliases[n] { self = f } else { return nil }
    }

    public var isText: Bool {
        switch self {
        case .png, .jpeg, .pdf, .docx, .pptx, .xlsx: false
        default: true
        }
    }

    public var fileExtension: String {
        switch self {
        case .mermaid: "mmd"
        case .plantuml: "puml"
        case .jpeg: "jpg"
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
        case .txt: nil
        }
    }

    @MainActor
    public func export(_ doc: DocumentModel, canvas: CanvasID?, scale: Double? = nil) -> Data? {
        if self == .txt {
            guard let c = doc.canvases[canvas ?? doc.canvasOrder.first ?? "c1"] else { return nil }
            return Data(IndentedText.export(c).utf8)
        }
        guard let f = exportFormat else { return nil }
        return HeadlessExport.data(doc, canvas: canvas, format: f, yaml: self == .yaml, scale: scale)
    }
}
