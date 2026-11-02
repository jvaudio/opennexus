import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusScene

/// M43: writes `web/fixtures/` for the viewer's browser tests (Playwright): interactive
/// exports of the golden documents, the app's PNG of each canvas at 1×, the app's Find
/// counts, scoped and masked exports, a 1,000-topic map and a crafted bundle. They are
/// build products (git-ignored), made by `npm run fixtures` in web/:
///
///     NEXUS_WRITE_VIEWER_FIXTURES=1 swift test --filter ViewerFixtures
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NEXUS_WRITE_VIEWER_FIXTURES"] == "1"))
struct ViewerFixtures {
    nonisolated static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "web/fixtures")

    /// The rich document, with text that tests whole words and case beyond ASCII.
    static func searchDocument() -> DocumentModel {
        var doc = ViewerBundleTests.richDocument()
        var c = doc.canvases["c1"]!
        var undo = UndoStack()
        c.edit("Words", undo: &undo) { e in
            let top = e.addFloating(at: CanvasPoint(x: -900, y: 600), text: "Café crème")
            let a = try? e.addChild(of: top, text: "naïve_test über alles")
            _ = try? e.addChild(of: top, text: "Straße 42 · ÉTÉ")
            if let a { e.update(a) { $0.labels = ["Q4 launch", "café"] } }
        }
        doc.canvases["c1"] = c
        return doc
    }

    static func write(_ name: String, _ data: Data) throws {
        try data.write(to: dir.appending(path: name))
    }

    static func options(_ edit: (inout ViewerBundle.Options) -> Void = { _ in }) -> ViewerBundle.Options {
        ViewerBundleTests.options(edit)
    }

    @Test func writeFixtures() throws {
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        var pages: [JSONValue] = []
        var find: [JSONValue] = []

        // Pages whose drawings must match the app's PNGs (A2), and the reader features (A3).
        let docs: [(String, DocumentModel, Bool)] = [
            ("launchplan", try ViewerBundleTests.fixture("LaunchPlan"), true),
            ("taskplan", try ViewerBundleTests.fixture("TaskPlan"), true),
            ("review", try ViewerBundleTests.fixture("Review"), true),
            ("flowchart", DocumentModel(canvases: [TechSamples.flowchart()]), true),
            ("threat", DocumentModel(canvases: [TechSamples.threatModel()]), true),
            ("rich", Self.searchDocument(), false),
        ]
        for (name, doc, raster) in docs {
            var o = Self.options()
            o.attachments = true
            try Self.write("\(name).html", Data(HTMLExporter.export(doc, o).utf8))
            var canvases: [JSONValue] = []
            for id in doc.canvasOrder {
                let c = doc.canvases[id]!
                var entry: [String: JSONValue] = ["id": .string(id.rawValue), "topics": .number(Double(c.nodes.count))]
                if raster {
                    let io = ViewerBundle.imageOptions(.document, theme: nil)
                    let img = try #require(ImageExporter.image(doc, canvas: id, io))
                    try Self.write("\(name)-\(id.rawValue).png", ImageExporter.png(img))
                    entry["png"] = .string("\(name)-\(id.rawValue).png")
                }
                canvases.append(.object(entry))
            }
            pages.append(.object(["name": .string(name), "canvases": .array(canvases)]))
            // The app's Find, for the same queries and options (A3).
            let queries = [
                "a", "an", "Pr", "pro", "PRO", "plan", "Launch", "e", "é", "É", "café", "CAFÉ", "über", "test",
                "naïve", "42", "4", "q4", "Q4 launch", "tier", "note", "remark", "-", "·",
            ]
            for (ci, cid) in doc.canvasOrder.enumerated() {
                for q in queries {
                    for flags in 0..<16 {
                        var so = SearchOptions()
                        so.matchCase = flags & 1 != 0
                        so.wholeWords = flags & 2 != 0
                        so.notes = flags & 4 != 0
                        so.labels = flags & 8 != 0
                        // All canvases once per query, from the first canvas.
                        for all in ci == 0 && doc.canvasOrder.count > 1 ? [false, true] : [false] {
                            so.allCanvases = all
                            let n = TextSearch.find(q, so, in: doc, current: cid).count
                            find.append(
                                .object([
                                    "page": .string(name), "canvas": .number(Double(ci)), "query": .string(q),
                                    "matchCase": .bool(so.matchCase), "wholeWords": .bool(so.wholeWords),
                                    "notes": .bool(so.notes), "labels": .bool(so.labels), "allCanvases": .bool(all),
                                    "count": .number(Double(n)),
                                ]))
                        }
                    }
                }
            }
        }

        // Scopes (A4): a branch, a zone, and a masked copy without comments.
        let rich = Self.searchDocument()
        let canvas = rich.canvases["c1"]!
        let pricing = ViewerBundleTests.node(canvas, "Pricing")
        let zone = canvas.zones.first!
        try Self.write(
            "branch.html", Data(HTMLExporter.export(rich, Self.options { $0.scope = .branch("c1", pricing) }).utf8))
        try Self.write(
            "zone.html", Data(HTMLExporter.export(rich, Self.options { $0.scope = .zone("c1", zone.id) }).utf8))
        let scopes: JSONValue = .object([
            "branch": .array(canvas.subtree(pricing).map { .string($0.rawValue) }),
            "zone": .array(zone.members.flatMap { canvas.subtree($0) }.map { .string($0.rawValue) }),
        ])

        // A5: 1,000 topics.
        try Self.write("large.html", Data(HTMLExporter.export(HTMLExportTests.largeDocument(), Self.options()).utf8))

        // A4: a crafted bundle (no export makes one; an attacker might).
        try Self.write("malicious.html", Data(HTMLExporter.page(Self.malicious()).utf8))

        let manifest: JSONValue = .object([
            "pages": .array(pages), "find": .array(find), "scopes": scopes,
            "rich": .object([
                "pricing": .string(pricing.rawValue),
                "timeline": .string(ViewerBundleTests.node(canvas, "Timeline").rawValue),
                "channels": .string(ViewerBundleTests.node(canvas, "Channels").rawValue),
                "risks": .string(ViewerBundleTests.node(canvas, "Risks").rawValue),
                "root": .string(canvas.root.rawValue),
            ]),
        ])
        try Self.write("manifest.json", CanonicalJSON.data(manifest))
    }

    /// Every trick the viewer must defuse: scripts, handlers, foreignObject, external
    /// references, javascript: links, HTML in text, an SVG "image", an HTML attachment.
    static func malicious() -> JSONValue {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 400 300" width="400" height="300" onload="window.__pwned=1">
            <script>window.__pwned=2</script>
            <style>@import url(https://evil.example/x.css); rect{fill:red}</style>
            <rect width="400" height="300" fill="#FFFFFF"/>
            <rect x="10" y="10" width="100" height="40" fill="url(https://evil.example/p.svg#g)" onclick="window.__pwned=3" data-nexus-id="t1"/>
            <image href="https://evil.example/track.png" x="0" y="0" width="10" height="10"/>
            <image xlink:href="javascript:window.__pwned=4" width="10" height="10"/>
            <image data-nexus-asset="img" x="20" y="20" width="10" height="10"/>
            <use href="https://evil.example/sprite.svg#a"/>
            <foreignObject width="100" height="100"><iframe xmlns="http://www.w3.org/1999/xhtml" src="https://evil.example/"></iframe></foreignObject>
            <a href="javascript:window.__pwned=5"><text x="20" y="80">click</text></a>
            <animate attributeName="href" to="javascript:window.__pwned=6"/>
            <set attributeName="onmouseover" to="window.__pwned=7"/>
            <circle cx="200" cy="150" r="40" fill="#4466FF" style="background:url(https://evil.example/s.png)"/>
            <path d="M0 0 L10 10" filter="url(https://evil.example/f.svg#f)" stroke="\\75 rl(https://evil.example/)"/>
            </svg>
            """
        let html = "<img src=x onerror=\"window.__pwned=8\">"
        let layout: JSONValue = .object([
            "svg": .string(svg), "viewBox": .array([0, 0, 400, 300].map { .number($0) }),
            "topics": .object([
                "t1": .object(["frame": .array([10, 10, 100, 40].map { .number($0) }), "depth": .number(0)])
            ]),
        ])
        let topic: JSONValue = .object([
            "text": .string(html), "label": .string(html), "note": .string("<script>window.__pwned=9</script>"),
            "link": .object(["href": .string("javascript:window.__pwned=10"), "kind": .string("web")]),
            "comments": .array([
                .object([
                    "author": .string("<b onmouseover=\"window.__pwned=11\">Eve</b>"), "date": .string("2026-10-28"),
                    "text": .string(html),
                ])
            ]),
            "attachments": .array([.object(["name": .string("<svg onload=alert(1)>.html"), "asset": .string("evil")])]),
            "labels": .array([.string(html)]),
            "fields": .array([.object(["key": .string(html), "value": .string(html)])]),
        ])
        let svgImage =
            "<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"window.__pwned=12\"><script>window.__pwned=13</script></svg>"
        return .object([
            "format": .string("opennexus-viewer"), "version": .number(1),
            "title": .string("</title><script>window.__pwned=14</script>"), "lang": .string("en"),
            "strings": .object(["search": .string(html), "outline": .string(html)]),
            "canvases": .array([
                .object([
                    "id": .string("c1"), "title": .string(html), "type": .string("mindmap"), "typeName": .string(html),
                    "theme": .object([
                        "canvas": .string("#FFFFFF"), "ink": .string("#1D1D1F"), "ink2": .string("#5B5B66"),
                        "accent": .string("#6E56CF"), "dark": .bool(false),
                    ]),
                    "layouts": .object(["saved": layout]),
                    "outline": .array([.object(["id": .string("t1")])]),
                    "topics": .object(["t1": topic]),
                ])
            ]),
            "assets": .object([
                "evil": .object([
                    "type": .string("text/html"), "size": .number(40),
                    "data": .string(Data("<script>window.__pwned=15</script>".utf8).base64EncodedString()),
                ]),
                "img": .object([
                    "type": .string("image/svg+xml"), "size": .number(Double(svgImage.utf8.count)),
                    "data": .string(Data(svgImage.utf8).base64EncodedString()),
                ]),
            ]),
        ])
    }
}
