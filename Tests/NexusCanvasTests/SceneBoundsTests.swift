import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusScene

/// What Fit to Window, export, the minimap and thumbnails frame (`Scene.bounds`): every
/// relationship as the canvas draws it, its label included.
@MainActor
@Suite(.serialized) struct SceneBoundsTests {
    /// Each relationship's line and label chip as drawn on the canvas.
    static func drawn(_ h: CanvasHarness) -> [(id: String, line: CGRect, label: CGRect?)] {
        h.controller.scene.relationships.compactMap { r in
            guard let l = h.host.canvasView.elements.relLayers[r.relationship.id], let path = l.line.path else {
                return nil
            }
            return (r.relationship.id, path.boundingBoxOfPath, r.relationship.label.isEmpty ? nil : l.labelRect)
        }
    }

    /// A curve bent past every topic, and its label, are inside the bounds, the PNG export
    /// and the SVG's view box.
    @Test func aBentCurveAndItsLabelAreInside() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let node = { (t: String) in h.canvas.nodes.first { $0.value.text == t }!.key }
        var id = ""
        h.controller.perform("Connect") { id = $0.connect(node("Pricing"), to: node("Risks"), label: "Watch margins") }
        h.controller.updateRelationship(id) { $0.bend = CanvasPoint(x: 0, y: -900) }
        let scene = h.controller.scene
        let (_, line, label) = try #require(Self.drawn(h).first { $0.id == id })
        let topics = scene.nodes.values.reduce(CGRect.null) { $0.union($1.frame.rect) }
        #expect(line.minY < topics.minY - 200, "the curve leaves the topics")
        let labelRect = try #require(label)
        #expect(scene.bounds.contains(line) && scene.bounds.contains(labelRect))
        let png = ImageExporter.contentRect(h.store.model, canvas: h.canvas.id, ImageExporter.Options())
        #expect(png.contains(line) && png.contains(labelRect))
        let svg = SVGExporter.viewBox(scene, ImageExporter.Options())
        #expect(svg.contains(line) && svg.contains(labelRect))
    }

    /// In all 100 starters, every relationship and label the canvas draws is inside the
    /// bounds, and the SVG draws each line where the canvas does.
    @Test func everyStartersRelationshipsAreInside() throws {
        var checked = 0
        for s in StarterLibrary.templates {
            let h = CanvasHarness(model: s.document(), width: 880, height: 560)
            let b = h.controller.scene.bounds
            let svg = SVGExporter.export(h.store.model, canvas: h.canvas.id, ImageExporter.Options())
            for (id, line, label) in Self.drawn(h) {
                #expect(b.contains(line.insetBy(dx: 0.5, dy: 0.5)), "\(s.id) \(id): line \(line) outside \(b)")
                if let label { #expect(b.contains(label), "\(s.id) \(id): label \(label) outside \(b)") }
                let path = try #require(h.host.canvasView.elements.relLayers[id]?.line.path)
                #expect(svg.contains("d=\"\(SVGExporter.d(path))\""), "\(s.id) \(id): the SVG draws it elsewhere")
                // The box the bounds use to skip routing holds the curve.
                let scene = h.controller.scene
                let r = try #require(scene.relationships.first { $0.relationship.id == id })
                if r.points == nil, let from = scene.rect(of: r.relationship.from),
                    let to = scene.rect(of: r.relationship.to),
                    let reach = RelationshipGeometry.reach(
                        r.relationship, from: from, to: to, t: Scene.labelAt(r.relationship))
                {
                    #expect(reach.line.insetBy(dx: -0.5, dy: -0.5).contains(line), "\(s.id) \(id): reach \(reach)")
                    if let label {
                        #expect(
                            reach.anchor.insetBy(dx: -label.width / 2 - 54.5, dy: -label.height / 2 - 54.5).contains(
                                label), "\(s.id) \(id): label reach \(reach)")
                    }
                }
                checked += 1
            }
        }
        #expect(checked > 100)
    }

    /// The minimap reads the bounds once per scene. On 1,011 topics with 100 labelled
    /// curves across the map, they cost under half what laying the curves out does: only
    /// curves that can reach past the topics are routed.
    @Test func boundsCostLessThanLayingOutTheRelationships() {
        let h = CanvasHarness(model: bigDocument(mains: 10, subs: 10, leaves: 9))
        let leaves = h.canvas.nodes.keys.filter { h.canvas.nodes[$0]!.children.isEmpty }.sorted()
        h.controller.perform("Connect") { e in
            for i in 0..<100 { e.connect(leaves[i * 7], to: leaves[(i * 7 + 400) % leaves.count], label: "Link \(i)") }
        }
        let scene = h.controller.scene
        let elements = h.host.canvasView.elements
        #expect(scene.relationships.count == 100 && elements.relLayers.count == 100)
        let clock = ContinuousClock()
        var bounds: [Duration] = []
        var layout: [Duration] = []
        for _ in 0..<9 {
            bounds.append(clock.measure { _ = scene.bounds })
            layout.append(
                clock.measure {
                    elements.updateGeometry(selected: nil, connect: nil, frame: { scene.nodes[$0]?.frame.rect })
                })
        }
        print("1,011 topics, 100 relationships: bounds \(ms(median(bounds))) ms, layout \(ms(median(layout))) ms")
        #expect(median(bounds) * 2 < median(layout))
    }
}
