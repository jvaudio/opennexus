import AppKit
import NexusCore
import NexusFormat
import QuickLookUI
import UniformTypeIdentifiers

/// The Space-bar preview (artboard 33): the rendered first canvas, and the canvases and
/// topic count under it. No app launch.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        guard let png = PreviewSource.png(for: url) else { throw CocoaError(.fileReadCorruptFile) }
        let doc = PreviewSource.document(at: url)
        let size = NSImage(data: png)?.size ?? CGSize(width: 1200, height: 800)
        let width = min(max(size.width / 2, 480), 1200)
        let height = width * size.height / max(size.width, 1) + (doc == nil ? 40 : 96)
        let canvases =
            doc?.orderedCanvases.map { c in
                Self.escape(c.title.isEmpty ? (c.nodes[c.root]?.text ?? c.id.rawValue) : c.title)
            } ?? []
        let footer =
            doc.map { d in
                "<p>\(canvases.joined(separator: " · ")) <span>\(d.topicCount) topics</span></p>"
            } ?? "<p><span>Open in OpenNexus to unlock</span></p>"
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            :root { color-scheme: light dark; }
            body { margin: 0; padding: 24px; font: 13px -apple-system, system-ui; background: #F6F6F3; color: #17171C; }
            img { display: block; width: 100%; height: auto; border-radius: 12px; background: #fff;
                  box-shadow: 0 1px 2px rgba(0,0,0,.06), 0 8px 24px rgba(0,0,0,.08); }
            p { margin: 16px 2px 0; font-weight: 600; } span { color: #8E8E96; font-weight: 400; margin-left: 6px; }
            @media (prefers-color-scheme: dark) { body { background: #1C1C20; color: #EDEDF0; } }
            </style></head><body><img src="cid:preview.png" alt="Map preview">\(footer)</body></html>
            """
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: width + 48, height: height)) {
            reply in
            reply.attachments = ["preview.png": QLPreviewReplyAttachment(data: png, contentType: .png)]
            reply.title = url.lastPathComponent
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
