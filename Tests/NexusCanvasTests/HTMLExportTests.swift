import AppKit
import CryptoKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat

/// M43: interactive HTML, one self-contained page (A1, A4, A5).
@MainActor
@Suite(.serialized) struct HTMLExportTests {
    /// The text between `open` and the next `close`.
    static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else {
            return nil
        }
        return String(s[a.upperBound..<b.lowerBound])
    }

    static func sha(_ s: String) -> String { Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString() }

    /// A map of `n` topics: the central topic, 9 main topics, 10 subtopics each, and 10
    /// below each of those (1 + 9 + 90 + 900 = 1,000).
    static func largeDocument() -> DocumentModel {
        var c = Canvas(id: "c1", title: "Large", rootText: "Thousand topics")
        var undo = UndoStack()
        c.edit("Seed", undo: &undo) { e in
            for i in 1...9 {
                let m = try! e.addChild(of: e.canvas.root, text: "Main topic \(i)")
                for j in 1...10 {
                    let s = try! e.addChild(of: m, text: "Subtopic \(i).\(j)")
                    for k in 1...10 { try! e.addChild(of: s, text: "Detail \(i).\(j).\(k)") }
                }
            }
        }
        return DocumentModel(canvases: [c])
    }

    @Test func thePageIsSelfContained() throws {
        let html = HTMLExporter.export(ViewerBundleTests.richDocument(), ViewerBundleTests.options())
        #expect(html.hasPrefix("<!doctype html>\n<html lang=\"en\">"))
        let csp = try #require(Self.between(html, "<meta http-equiv=\"Content-Security-Policy\" content=\"", "\">"))
        #expect(csp.hasPrefix("default-src 'none'; "))
        #expect(csp.contains("img-src data: blob:") && !csp.contains("unsafe") && !csp.contains("http"))
        // The hashes cover exactly the inline script and style.
        let script = try #require(Self.between(html, "</script>\n<script>", "</script>\n</body>"))
        let style = try #require(Self.between(html, "<style>", "</style>"))
        #expect(!script.isEmpty && !style.isEmpty, "the built viewer is in the resources")
        #expect(csp.contains("script-src 'sha256-\(Self.sha(script))'"))
        #expect(csp.contains("style-src 'sha256-\(Self.sha(style))'"))
        // One external-looking thing at most: the SVG namespace.
        #expect(!html.contains("src=\"http") && !html.contains("<link"))
        // The bundle reads back as JSON that the schema accepts, and can't close its element.
        let data = try #require(
            Self.between(html, "<script type=\"application/json\" id=\"opennexus-bundle\">", "</script>"))
        #expect(!data.contains("<"))
        let bundle = try CanonicalJSON.parse(Data(data.utf8))
        #expect(SchemaValidator.viewer.validate(bundle).isEmpty)
        #expect(bundle == ViewerBundle.build(ViewerBundleTests.richDocument(), ViewerBundleTests.options()))
    }

    /// Text that looks like markup stays text: escaped in the title, `<` in the bundle.
    @Test func markupInTheMapStaysText() throws {
        var doc = launchPlanDocument()
        doc.canvases["c1"]?.title = "</title><script>alert(1)</script>"
        let root = doc.canvases["c1"]!.root
        doc.canvases["c1"]?.nodes[root]?.text = "</script><script>alert(2)</script><!--"
        let html = HTMLExporter.export(doc, ViewerBundleTests.options())
        #expect(html.contains("<title>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>"))
        #expect(!html.contains("alert(2)</script>") && !html.contains("<!--"))
        #expect(html.components(separatedBy: "<script").count == 3, "the bundle and the viewer, nothing else")
    }

    /// Masked strings and left-out comments aren't in the file at all (A4).
    @Test func maskingAndExclusionsLeaveNoTrace() throws {
        var doc = ViewerBundleTests.richDocument()
        let pricing = ViewerBundleTests.node(doc.canvases["c1"]!, "Pricing")
        doc.canvases["c1"]?.nodes[pricing]?.note = Note(text: "Ask ana.lopez@example.com about the discount")
        let h = CanvasHarness(model: doc)
        h.controller.prefs.set("export.masking", "always")
        h.controller.openExport(.html)
        var s = try #require(h.controller.exportState)
        #expect(s.mask)
        s.html.comments = false
        let html = String(decoding: try #require(h.controller.exportData(s)), as: UTF8.self)
        #expect(!html.contains("ana.lopez@example.com") && !html.contains("Hidden remark"))
        #expect(html.contains("about the discount"))
        // Attachments: only when asked for.
        #expect(!html.contains(Data("%PDF-1.4 brief".utf8).base64EncodedString()))
        s.html.attachments = true
        let with = String(decoding: try #require(h.controller.exportData(s)), as: UTF8.self)
        #expect(with.contains(Data("%PDF-1.4 brief".utf8).base64EncodedString()))
    }

    /// The sheet's scopes: document, canvas, branch, zone.
    @Test func theSheetScopes() throws {
        let h = CanvasHarness(model: ViewerBundleTests.richDocument())
        h.controller.openExport(.html)
        var s = try #require(h.controller.exportState)
        #expect(s.format == .html && s.html.document && s.image.scope == .canvas)
        #expect(h.controller.viewerOptions(s).scope == .document)
        s.html.document = false
        #expect(h.controller.viewerOptions(s).scope == .canvas("c1"))
        let pricing = ViewerBundleTests.node(h.canvas, "Pricing")
        s.image.scope = .branch
        s.image.selection = [pricing]
        #expect(h.controller.viewerOptions(s).scope == .branch("c1", pricing))
        s.image.scope = .zone
        s.image.zone = h.canvas.zones.first?.id
        #expect(h.controller.viewerOptions(s).scope == .zone("c1", h.canvas.zones.first!.id))
        #expect(h.controller.exportSizeLine(s).hasPrefix("2 topics · "))
    }

    /// A5: a 1,000-topic map exports in under a second (debug build).
    @Test func aThousandTopicsExportInUnderASecond() throws {
        let doc = Self.largeDocument()
        #expect(doc.canvases["c1"]!.nodes.count == 1000)
        _ = HTMLExporter.export(launchPlanDocument(), ViewerBundleTests.options())  // warm caches
        let start = Date()
        let html = HTMLExporter.export(doc, ViewerBundleTests.options())
        let t = Date().timeIntervalSince(start)
        #expect(t < 1, "took \(t) s")
        #expect(html.utf8.count < 8_000_000)
    }
}
