import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusLayout

/// A roadmap with branches of different sizes, one event without details and topics
/// two levels under an event (M32).
func roadmapCanvas(_ s: LayoutStructure) -> Canvas {
    var c = Canvas(id: "c1", title: "Roadmap", rootText: "Product roadmap")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let tree: [(String, [(String, [String])])] = [
            ("Q1 · Discover", [("Research", []), ("Interviews", ["Users", "Partners"]), ("Prototype", [])]),
            ("Q2 · Beta", [("Private beta", []), ("Feedback", [])]),
            ("Q3 · Launch", [("Launch event", ["Press kit", "Webinar"]), ("Pricing", [])]),
            ("Q4 · Scale", [("Hiring", [])]),
            ("2027", []),
            ("Q1 2027 · Platform", [("Plugin API", []), ("Marketplace", [])]),
        ]
        for (event, details) in tree {
            let id = try! e.addChild(of: e.canvas.root, text: event)
            for (d, more) in details {
                let did = try! e.addChild(of: id, text: d)
                for m in more { try! e.addChild(of: did, text: m) }
            }
        }
    }
    c.layout.structure = s
    c.type = .timeline
    return c
}

/// A mind map with an alternating timeline on each side of the central topic.
func mixedCanvas() -> Canvas {
    var c = Canvas(id: "c1", title: "Company", rootText: "Company")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        for (branch, events) in [
            ("Roadmap", ["2026", "2027", "2028"]), ("Team", ["Hiring"]), ("History", ["2023", "2024", "2025"]),
        ] {
            let b = try! e.addChild(of: e.canvas.root, text: branch)
            if branch != "Team" { e.update(b) { $0.structure = .timelineAlternating } }
            for (i, ev) in events.enumerated() {
                let id = try! e.addChild(of: b, text: ev)
                for d in 0..<(i + 1) { try! e.addChild(of: id, text: "\(ev) item \(d + 1)") }
            }
        }
    }
    return c
}

/// Xmind's horizontal timeline as a structure of its own (D248, D249).
@MainActor
@Suite(.serialized) struct TimelineAlternatingTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    @Test func eventsAlternateAboveAndBelowOnTheCanvas() throws {
        let h = CanvasHarness(model: DocumentModel(canvases: [roadmapCanvas(.timelineAlternating)]))
        let scene = h.controller.scene
        let root = try #require(scene.nodes[h.canvas.root]).frame
        let events = h.canvas.nodes[h.canvas.root]!.children
        var above = 0
        var below = 0
        for (i, e) in events.enumerated() {
            let f = try #require(scene.nodes[e]).frame
            #expect(abs(f.center.y - root.center.y) < 0.5, "events ride the axis")
            for d in h.canvas.subtree(e) where d != e {
                let r = try #require(scene.nodes[d]).frame.rect
                if i % 2 == 0 {
                    #expect(r.maxY < f.rect.minY, "event \(i)'s branch is above")
                    above += 1
                } else {
                    #expect(r.minY > f.rect.maxY, "event \(i)'s branch is below")
                    below += 1
                }
                #expect(r.minX > f.center.x, "the branch grows away from the root")
            }
        }
        #expect(above > 0 && below > 0)
        // Every topic is drawn, with a line to its parent, and no two overlap.
        let rects = scene.nodes.values.map(\.frame.rect)
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] { #expect(!a.insetBy(dx: 1, dy: 1).intersects(b.insetBy(dx: 1, dy: 1))) }
        }
        #expect(scene.edges.count == h.canvas.nodes.count - 1)
        let interviews = node(h, "Interviews")
        #expect(scene.edges.first { $0.child == interviews }?.family == "timelineUp")
        #expect(scene.edges.first { $0.child == node(h, "Users") }?.family == "logic")
        #expect(scene.edges.first { $0.child == node(h, "Private beta") }?.family == "timelineDown")
    }

    @Test func onEitherSideOfAMindMapItGrowsAwayFromTheCentre() throws {
        let h = CanvasHarness(model: DocumentModel(canvases: [mixedCanvas()]))
        let scene = h.controller.scene
        let root = try #require(scene.nodes[h.canvas.root]).frame.rect
        for (name, left) in [("Roadmap", false), ("History", true)] {
            let b = node(h, name)
            for (i, e) in h.canvas.nodes[b]!.children.enumerated() {
                let f = try #require(scene.nodes[e]).frame
                for d in h.canvas.subtree(e) where d != e {
                    let r = try #require(scene.nodes[d]).frame.rect
                    #expect(left ? r.maxX < f.center.x : r.minX > f.center.x, "\(name): away from the centre")
                    #expect(i % 2 == 0 ? r.maxY < f.rect.minY : r.minY > f.rect.maxY, "\(name) \(i) alternates")
                    #expect(left ? r.maxX < root.minX : r.minX > root.maxX)
                }
            }
        }
        let rects = scene.nodes.values.map(\.frame.rect)
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] { #expect(!a.insetBy(dx: 1, dy: 1).intersects(b.insetBy(dx: 1, dy: 1))) }
        }
    }

    @Test func hitTestingAndDropTargetsUseTheLaidOutTopics() {
        let h = CanvasHarness(model: DocumentModel(canvases: [roadmapCanvas(.timelineAlternating)]))
        let v = h.host.canvasView
        for (id, n) in h.controller.scene.nodes {
            let r = v.camera.toView(n.frame.rect)
            #expect(v.node(at: CGPoint(x: r.midX, y: r.midY)) == id, "\(h.canvas.nodes[id]?.text ?? "")")
        }
        // Moving a topic onto another event's branch keeps the structure's rules.
        let pricing = node(h, "Pricing")
        let q2 = node(h, "Q2 · Beta")
        h.controller.restructure("Move") { try $0.move(pricing, toParent: q2, at: 0) }
        let scene = h.controller.scene
        let f = scene.nodes[q2]!.frame.rect
        #expect(scene.nodes[pricing]!.frame.rect.minY > f.maxY, "now in Q2's branch, below the axis")
    }

    @Test func itIsOfferedInThePickerAndTheMenu() throws {
        #expect(CanvasController.structureName(.timelineAlternating) == "Timeline (alternating)")
        #expect(StyleTab.structureOptions(current: .logicRight).map(\.0).contains(.timelineAlternating))
        #expect(StyleTab.structureOptions(current: .timelineAlternating).first?.0 == .mindmapBalanced)
        #expect(LayoutStructure.timelineAlternating.isSelfContained)
        #expect(CanvasController.diagramType(for: .timelineAlternating) == .timeline)

        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        h.controller.prepareContextMenu(.topic(pricing))
        let entries = h.controller.contextMenu(for: .topic(pricing))
        let structure = try #require(
            entries.compactMap { e -> [CanvasMenuEntry]? in
                if case .submenu(let t, let items) = e, t == "Structure" { return items }
                return nil
            }.first)
        let item = try #require(structure.flatMap(\.items).first { $0.title == "Timeline (alternating)" })
        #expect(item.action == .structure(.timelineAlternating))
        #expect(h.controller.runMenuAction(item.action))
        #expect(h.canvas.nodes[pricing]?.structure == .timelineAlternating)
        h.controller.prepareContextMenu(.topic(pricing))
        let checked = h.controller.contextMenu(for: .topic(pricing)).flatMap(\.items)
            .first { $0.title == "Timeline (alternating)" }
        #expect(checked?.checked == true)
        // VoiceOver's actions leave the Structure submenu to ⌥⌘1–9 and the Format panel.
        let names = h.host.canvasView.accessibilityTree.menuActions(.topic(pricing)).map(\.name)
        #expect(!names.contains("Timeline (alternating)"))
    }

    /// Visual check (env-gated): `NEXUS_SNAPSHOT_DIR=/tmp/m32 swift test --filter TimelineAlternatingTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func snapshots() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mixed = mixedCanvas()
        var folded = roadmapCanvas(.timelineAlternating)
        for k in folded.nodes.keys where ["Q3 · Launch", "Q2 · Beta"].contains(folded.nodes[k]!.text) {
            folded.nodes[k]!.folded = true
        }
        var shots: [(String, Canvas)] = [
            ("alternating", roadmapCanvas(.timelineAlternating)), ("horizontal", roadmapCanvas(.timelineHorizontal)),
            ("alternating-mixed", mixed), ("alternating-folded", folded),
        ]
        // Fold controls (D250): two folded branches, and the "−" on a third.
        for s in [LayoutStructure.timelineHorizontal, .orgDown, .treeIndented, .fishboneLeft, .timelineAlternating] {
            var c = roadmapCanvas(s)
            for k in c.nodes.keys where ["Q2 · Beta", "Launch event"].contains(c.nodes[k]!.text) {
                c.nodes[k]!.folded = true
            }
            shots.append(("fold-\(s.rawValue)", c))
        }
        for (name, c) in shots {
            let h = CanvasHarness(model: DocumentModel(canvases: [c]), width: 1400, height: 800)
            h.host.canvasView.fitToWindow()
            if name.hasPrefix("fold-") {
                let v = h.host.canvasView
                let r = v.camera.toView(h.controller.scene.nodes[node(h, "Q1 · Discover")]!.frame.rect)
                v.updateFoldHover(CGPoint(x: r.midX, y: r.midY))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try #require(h.renderOffscreen(scale: 1))
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("m32-\(name).png"))
            h.window.orderOut(nil)
        }
    }
}
