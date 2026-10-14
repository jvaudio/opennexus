import AppKit
import NexusCore
import NexusFormat

/// Exports and previews without a window: the `nexus` CLI, the MCP server and the Quick
/// Look extensions use the same offscreen canvas as the app, so every output looks
/// exactly like the map.
@MainActor
public enum HeadlessExport {
    /// The file for `format`, with Settings › Export's defaults (not the user's, which
    /// belong to the app) unless `prefs` is given.
    public static func data(
        _ doc: DocumentModel, canvas: CanvasID? = nil, format: ExportFormat, yaml: Bool = false, scale: Double? = nil,
        prefs: Preferences = .isolated()
    ) -> Data? {
        let id = canvas ?? doc.canvasOrder.first ?? "c1"
        guard doc.canvases[id] != nil else { return nil }
        let controller = CanvasController(store: DocumentStore(model: doc), canvasID: id)
        controller.prefs = prefs
        controller.rendersThemeAsNamed = true
        var s = ExportState.remembered(format, prefs: prefs)
        s.image.scope = .canvas
        s.yaml = yaml
        if let scale { s.image.scale = scale }
        return controller.exportData(s)
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
