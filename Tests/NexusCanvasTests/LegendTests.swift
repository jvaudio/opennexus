import AppKit
import Foundation
import NexusCore
import NexusKeys
import Testing

@testable import NexusCanvas

/// M14: the marker and label legend: toggled from the keyboard, drawn beside the map or
/// where it was dragged, in exports, and read by VoiceOver.
@MainActor
@Suite(.serialized) struct LegendTests {
    static func document(legend: Legend? = nil) -> DocumentModel {
        var c = Canvas(id: "c1", title: "Review", rootText: "Pricing")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in
            let a = try! e.addChild(of: e.canvas.root, text: "Annual tier")
            let b = try! e.addChild(of: e.canvas.root, text: "Pro")
            e.update(a) {
                $0.markers = ["flag-red", "priority-2"]
                $0.labels = ["Q4"]
            }
            e.update(b) {
                $0.markers = ["priority-1", "flag-red", "custom-thing"]
                $0.labels = ["Q4", "Margins"]
            }
            e.updateMeta { $0.legend = legend }
        }
        return DocumentModel(canvases: [c])
    }

    @Test func listsMarkersAndLabelsBesideTheMap() throws {
        let h = CanvasHarness(model: Self.document(legend: Legend(markers: ["flag-red": "Blocked"])))
        let l = try #require(h.controller.scene.legend)
        #expect(l.rows.map(\.text) == ["Priority 1", "Priority 2", "Blocked", "custom-thing", "Q4", "Margins"])
        #expect(l.rows.map(\.marker) == ["priority-1", "priority-2", "flag-red", "custom-thing", nil, nil])
        #expect(l.automatic)
        let topics = h.controller.scene.nodes.values.reduce(CGRect.null) { $0.union($1.frame.rect) }
        #expect(l.rect.minX == topics.maxX + 48 && l.rect.minY == topics.minY, "beside the map, top-aligned")
        #expect(h.controller.scene.bounds.contains(l.rect), "exports size themselves to include it")
        #expect(l.spoken.hasPrefix("Legend: Priority 1. Priority 2. Red flag, Blocked."))
        // Hidden: nothing drawn, descriptions kept.
        var doc = Self.document(legend: Legend(visible: false, markers: ["flag-red": "Blocked"]))
        let hidden = CanvasHarness(model: doc)
        #expect(hidden.controller.scene.legend == nil)
        doc = Self.document()
        #expect(CanvasHarness(model: doc).controller.scene.legend == nil, "no legend until one is shown")
    }

    @Test func toggleDescribeAndMoveAreOneUndoStepEach() throws {
        let h = CanvasHarness(model: Self.document())
        let depth = h.undo.stack.undoStack.count
        h.press("opt+cmd+l")
        #expect(h.canvas.legend == Legend() && h.controller.scene.legend != nil)
        h.controller.setLegendDescription("  Blocked ", for: "flag-red")
        #expect(h.canvas.legend?.markers == ["flag-red": "Blocked"])
        h.controller.moveLegend(to: CanvasPoint(x: -400, y: 120))
        #expect(h.controller.scene.legend?.rect.origin == CGPoint(x: -400, y: 120))
        #expect(h.controller.scene.legend?.automatic == false)
        h.press("opt+cmd+l")
        #expect(h.canvas.legend?.visible == false && h.controller.scene.legend == nil)
        #expect(h.canvas.legend?.markers == ["flag-red": "Blocked"], "hiding keeps the descriptions")
        #expect(h.undo.stack.undoStack.count == depth + 4)
        h.undo.undo(h.store)
        #expect(h.controller.scene.legend != nil)
        h.controller.setLegendDescription("", for: "flag-red")
        #expect(h.canvas.legend?.markers.isEmpty == true, "empty restores the marker's own name")
        // Edit Legend… asks for the editor; the commands live in View and the palette.
        var asked: [CanvasRequest] = []
        h.controller.onRequest = { asked.append($0) }
        #expect(h.controller.perform(.editLegend))
        #expect(asked == [.legend])
        #expect(CommandRegistry.standard[.toggleLegend]?.menu == .view)
        #expect(CommandRegistry.standard[.editLegend]?.menu == .view)
    }

    @Test func dragMovesItAsOneUndoStep() throws {
        let h = CanvasHarness(model: Self.document(legend: Legend()))
        let v = h.host.canvasView
        let l = try #require(h.controller.scene.legend)
        let start = v.camera.toView(CGPoint(x: l.rect.minX + 20, y: l.rect.minY + 12))
        let end = CGPoint(x: start.x + 80, y: start.y + 40)
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let depth = h.undo.stack.undoStack.count
        v.mouseDown(with: event(.leftMouseDown, start))
        v.mouseDragged(with: event(.leftMouseDragged, end))
        v.mouseUp(with: event(.leftMouseUp, end))
        let a = v.camera.toWorld(start)
        let b = v.camera.toWorld(end)
        let moved = try #require(h.canvas.legend?.position)
        #expect(abs(moved.x - CanvasPoint.round(l.rect.minX + b.x - a.x)) <= 0.5)
        #expect(abs(moved.y - CanvasPoint.round(l.rect.minY + b.y - a.y)) <= 0.5)
        #expect(h.undo.stack.undoStack.count == depth + 1)
        #expect(h.controller.selection.primary == h.canvas.root, "dragging the legend leaves the selection alone")
    }

    @Test func exportsDrawItOnlyForTheWholeCanvas() throws {
        let doc = Self.document(legend: Legend(markers: ["flag-red": "Blocked"]))
        var o = ImageExporter.Options()
        o.scale = 1
        let with = ImageExporter.contentRect(doc, canvas: "c1", o)
        let without = ImageExporter.contentRect(Self.document(), canvas: "c1", o)
        #expect(with.width > without.width + 100)
        let png = try #require(ImageExporter.image(doc, canvas: "c1", o))
        #expect(png.width == Int(with.width))
        let svg = SVGExporter.export(doc, canvas: "c1", o)
        #expect(svg.contains("class=\"legend\"") && svg.contains("Blocked") && svg.contains(">Margins<"))
        var branch = o
        branch.scope = .branch
        branch.selection = [doc.canvases["c1"]!.nodes.first { $0.value.text == "Pro" }!.key]
        #expect(!SVGExporter.export(doc, canvas: "c1", branch).contains("class=\"legend\""))
        let pdf = PrintLayout.singlePage(doc, canvas: "c1", o)
        #expect(pdf.count > 1000)
    }

    @Test func voiceOverReadsAndOpensIt() throws {
        let h = CanvasHarness(model: Self.document(legend: Legend()))
        let roots = h.host.canvasView.accessibilityTree.roots()
        let item = try #require(roots.last as? LegendItem)
        #expect(item.accessibilityLabel()?.hasPrefix("Legend: Priority 1") == true)
        #expect(item.accessibilityRoleDescription() == "legend")
        var asked: [CanvasRequest] = []
        h.controller.onRequest = { asked.append($0) }
        #expect(item.accessibilityPerformPress() && asked == [.legend])
        #expect(item.accessibilityCustomActions()?.map(\.name) == ["Edit Legend", "Hide Legend"])
    }

    /// Visual review: NEXUS_SNAPSHOT_DIR=… writes the canvas with a legend and comments.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil)) func snapshot() throws {
        var doc = Self.document(legend: Legend(markers: ["flag-red": "Blocked"]))
        let pro = doc.canvases["c1"]!.nodes.first { $0.value.text == "Pro" }!.key
        doc.canvases["c1"]!.nodes[pro]!.comments = [
            TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "One"),
            TopicComment(author: "Sam", date: "2026-10-20T14:04:00Z", text: "Two"),
        ]
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        var o = ImageExporter.Options()
        o.scale = 2
        let img = try #require(ImageExporter.image(doc, canvas: "c1", o))
        try ImageExporter.png(img).write(to: dir.appending(path: "m14-legend.png"))
        try Data(SVGExporter.export(doc, canvas: "c1", o).utf8).write(to: dir.appending(path: "m14-legend.svg"))
    }
}
