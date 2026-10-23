import AppKit
import NexusCore
import NexusFormat

/// Exports and previews without a window: the `nexus` CLI, the MCP server and the Quick
/// Look extensions use the same offscreen canvas as the app, so every output looks
/// exactly like the map.
@MainActor
public enum HeadlessExport {
    /// What an export covers (D227), as the export sheet's Scope and Zones pickers set it.
    public enum Scope: Equatable, Sendable {
        case canvas
        /// The branch from this topic down: the visual formats, Markdown and OPML.
        case branch(NodeID)
        /// One zone and its contents: the visual formats.
        case zone(String)
        /// PDF only: one file with a page per zone, in canvas order.
        case zonePages
    }

    /// The file for `format`, with Settings › Export's defaults (not the user's, which
    /// belong to the app) unless `prefs` is given.
    public static func data(
        _ doc: DocumentModel, canvas: CanvasID? = nil, format: ExportFormat, scope: Scope = .canvas,
        yaml: Bool = false, scale: Double? = nil, xmind8: Bool = false, prefs: Preferences = .isolated()
    ) -> Data? {
        guard let (controller, state) = setUp(doc, canvas: canvas, format: format, scope: scope, prefs: prefs) else {
            return nil
        }
        var s = state
        s.yaml = yaml
        s.xmind8 = xmind8
        if let scale { s.image.scale = scale }
        return controller.exportData(s)
    }

    /// Each zone as its own file in `format` (a visual one), named after its title as the
    /// export sheet's "Each zone as its own file" names them (D195, D227). Empty when the
    /// canvas has no zones.
    public static func zoneFiles(
        _ doc: DocumentModel, canvas: CanvasID? = nil, format: ExportFormat, scale: Double? = nil,
        prefs: Preferences = .isolated()
    ) -> [(name: String, data: Data)] {
        let id = canvas ?? doc.canvasOrder.first ?? "c1"
        guard format.isVisual, let first = doc.canvases[id]?.zones.first,
            let (controller, state) = setUp(doc, canvas: id, format: format, scope: .zone(first.id), prefs: prefs)
        else { return [] }
        var s = state
        s.zones = .each
        if let scale { s.image.scale = scale }
        return controller.zoneFiles(s).map { (name: $0.0, data: $0.1) }
    }

    /// An offscreen controller on the canvas, and the sheet's state for the format and
    /// scope. nil when the canvas, topic or zone isn't there.
    private static func setUp(
        _ doc: DocumentModel, canvas: CanvasID?, format: ExportFormat, scope: Scope, prefs: Preferences
    ) -> (CanvasController, ExportState)? {
        let id = canvas ?? doc.canvasOrder.first ?? "c1"
        guard let c = doc.canvases[id] else { return nil }
        var s = ExportState.remembered(format, prefs: prefs)
        s.image.scope = .canvas
        s.pdfScope = "canvas"
        s.split = false
        switch scope {
        case .canvas: break
        case .branch(let top):
            guard c.nodes[top] != nil else { return nil }
            s.image.scope = .branch
            s.image.selection = [top]
        case .zone(let zone):
            guard c.zones.contains(where: { $0.id == zone }) else { return nil }
            s.image.scope = .zone
            s.image.zone = zone
        case .zonePages:
            guard format == .pdf, let first = c.zones.first else { return nil }
            s.image.scope = .zone
            s.image.zone = first.id
            s.zones = .pages
        }
        let controller = CanvasController(store: DocumentStore(model: doc), canvasID: id)
        controller.prefs = prefs
        controller.rendersThemeAsNamed = true
        return (controller, s)
    }

    /// Quick Look's `preview.png`: the first canvas, at most `maxWidth` pixels wide.
    /// Never for an encrypted document (the preview would leak its contents).
    public static func previewPNG(_ doc: DocumentModel, maxWidth: Double = 1200) -> Data? {
        guard !doc.encrypted, let id = doc.canvasOrder.first else { return nil }
        var o = ImageExporter.Options()
        o.padding = 40
        o.scale = 1
        let r = ImageExporter.contentRect(doc, canvas: id, o)
        o.scale = min(2, max(0.25, maxWidth / max(Double(r.width), 1)))
        return ImageExporter.image(doc, canvas: id, o).map(ImageExporter.png)
    }
}
