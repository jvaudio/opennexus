import AppKit
import Foundation
import NexusCore
import NexusTheme
import Testing

@testable import NexusCanvas

/// M31 on the canvas: a canvas's element defaults draw and seed new elements (D245), and
/// progress markers in eighths draw as pies beside the quarter glyphs (D247).
@MainActor
@Suite(.serialized) struct XmindGapsCanvasTests {
    static func document(defaults: ElementStyles) -> DocumentModel {
        var c = Canvas(id: "c1", title: "Plan", rootText: "Plan")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let a = try! e.addChild(of: e.canvas.root, text: "Alpha")
            let b = try! e.addChild(of: e.canvas.root, text: "Beta")
            _ = try! e.addChild(of: a, text: "A1")
            _ = try! e.addChild(of: a, text: "A2")
            _ = try! e.addBoundary(around: [a])
            _ = e.connect(a, to: b)
            e.updateMeta { $0.style.elements = defaults }
        }
        return DocumentModel(canvases: [c])
    }

    static let defaults = ElementStyles(
        boundary: .init(color: "#FF0000", fillOpacity: 0.1, dash: "dashed", width: 3, shape: "wave"),
        summary: .init(color: "#0000FF", width: 4, bracket: "round"),
        relationship: .init(color: "#00AA00", line: "straight", dash: "solid", width: 3))

    func node(_ h: CanvasHarness, _ text: String) -> NodeID {
        h.canvas.nodes.first { $0.value.text == text }!.key
    }

    @Test func elementsWithoutAColourDrawInTheCanvasDefault() throws {
        let h = CanvasHarness(model: Self.document(defaults: Self.defaults))
        let b = try #require(h.controller.scene.boundaries.first)
        #expect(b.boundary.color == nil && b.color == RGBA(hex: "#FF0000"))
        let r = try #require(h.controller.scene.relationships.first)
        #expect(r.relationship.color == "theme" && r.color == RGBA(hex: "#00AA00"))
        let kids = h.canvas.nodes[node(h, "Alpha")]!.children
        h.controller.perform("Summary") { _ = try $0.addSummary(over: kids) }
        let s = try #require(h.controller.scene.summaries.first)
        #expect(s.color == RGBA(hex: "#0000FF") && s.summary.width == 4 && s.summary.bracket == "round")
        // Its own colour still wins.
        h.controller.perform("Colour") { $0.updateBoundary(b.boundary.id) { $0.color = "#123456" } }
        #expect(h.controller.scene.boundaries.first?.color == RGBA(hex: "#123456"))
        // Without defaults, the theme's colours as before.
        let plain = CanvasHarness(model: Self.document(defaults: ElementStyles()))
        #expect(plain.controller.scene.boundaries.first?.color == plain.controller.theme.ring)
        #expect(plain.controller.scene.relationships.first?.color == plain.controller.theme.relationship)
    }

    @Test func newElementsAndResetUseTheCanvasDefaults() throws {
        let h = CanvasHarness(model: Self.document(defaults: Self.defaults))
        let beta = node(h, "Beta")
        let id = try #require(h.controller.perform("Boundary") { try $0.addBoundary(around: [beta]) })
        let b = try #require(h.canvas.boundaries.first { $0.id == id })
        #expect(b.color == nil && b.dash == "dashed" && b.width == 3 && b.shape == "wave" && b.fillOpacity == 0.1)
        let rid = try #require(h.controller.perform("Connect") { $0.connect(beta, to: h.canvas.root) })
        let r = try #require(h.canvas.relationships.first { $0.id == rid })
        #expect(r.line == "straight" && r.dash == "solid" && r.width == 3 && r.color == "theme")
        h.controller.perform("Restyle") { e in
            e.updateBoundary(id) {
                $0.shape = "rectangle"
                $0.width = 1
            }
        }
        h.controller.resetElementStyle(.boundary(id))
        #expect(h.canvas.boundaries.first { $0.id == id }?.shape == "wave")
        #expect(h.canvas.boundaries.first { $0.id == id }?.width == 3)
    }

    // MARK: Eighths (D247)

    @Test func eighthsAreMarkersOfTheirOwn() {
        let progress = MarkerLibrary.groups.first { $0.id == "progress" }!.markers
        #expect(
            progress.map(\.id) == [
                "progress-0", "progress-13", "progress-25", "progress-38", "progress-50", "progress-63",
                "progress-75", "progress-88", "progress-100",
            ])
        #expect(progress.compactMap(\.pie) == [0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875])
        #expect(progress.filter { $0.pie == nil }.map(\.glyph) == ["○", "✓"])
        #expect(progress.map(\.glyph).contains("◑"), "quarters keep their glyphs where only text fits")
        #expect(MarkerLibrary.name("progress-13") == "One eighth done")
        #expect(MarkerLibrary.name("progress-88") == "Seven eighths done")
        // Picking one replaces another progress marker, as in its group.
        #expect(MarkerLibrary.group(of: "progress-63") == MarkerLibrary.group(of: "progress-25"))
    }

    @Test func eighthsDrawAsPies() throws {
        var c = Canvas(id: "c1", title: "P", rootText: "P")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let a = try! e.addChild(of: e.canvas.root, text: "Three eighths")
            e.update(a) { $0.markers = ["progress-38"] }
            e.updateMeta { $0.legend = Legend() }
        }
        let doc = DocumentModel(canvases: [c])
        let h = CanvasHarness(model: doc)
        let a = try #require(h.controller.scene.nodes[node(h, "Three eighths")])
        #expect(a.otherMarkers == ["progress-38"])
        #expect(h.controller.scene.legend?.rows.first?.text == "Three eighths done")
        var o = ImageExporter.Options()
        o.scale = 1
        let svg = SVGExporter.export(doc, canvas: "c1", o)
        // On the topic and in the legend: a ring and a wedge, not a text glyph.
        #expect(svg.components(separatedBy: "fill=\"none\" stroke=\"#FFFFFF\"").count == 3)
        #expect(!svg.contains(">⅜<"))
        // The wedge ends 135° clockwise from twelve o'clock.
        let img = try #require(ImageExporter.image(doc, canvas: "c1", o))
        #expect(img.width > 0)
        let pie = NSImage(size: CGSize(width: 36, height: 36), flipped: true) { r in
            LegendLayer.drawMarker("progress-38", in: r)
            return true
        }
        let tiff = try #require(pie.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        func white(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9
        }
        let px = rep.pixelsWide / 36
        // Inside the ring: filled to the right of twelve o'clock, open to the left.
        #expect(white(20 * px, 14 * px) && !white(14 * px, 14 * px))
    }
}
