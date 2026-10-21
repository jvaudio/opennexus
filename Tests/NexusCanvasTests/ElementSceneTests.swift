import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusKeys

/// M3 geometry: elements follow the topics they belong to.
@MainActor
@Suite(.serialized) struct ElementSceneTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID {
        h.canvas.nodes.first { $0.value.text == text }!.key
    }

    func branchRect(_ h: CanvasHarness, _ id: NodeID) -> CGRect {
        h.canvas.subtree(id).compactMap { h.controller.scene.nodes[$0]?.frame.rect }.reduce(CGRect.null) {
            $0.union($1)
        }
    }

    @Test func boundaryEnclosesItsBranches() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        let risks = node(h, "Risks")
        h.controller.perform("Boundary") { _ = try $0.addBoundary(around: [pricing, risks]) }
        let b = try! #require(h.controller.scene.boundaries.first)
        #expect(b.rect.contains(branchRect(h, pricing)))
        #expect(b.rect.contains(branchRect(h, risks)))
        // Adding a child grows the boundary with the branch.
        h.controller.perform("Add") { try $0.addChild(of: pricing, text: "Enterprise") }
        let grown = h.controller.scene.boundaries[0].rect
        #expect(grown.contains(branchRect(h, pricing)))
    }

    @Test func summaryBracketSpansItsRange() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let kids = h.canvas.nodes[node(h, "Pricing")]!.children
        let topic = try #require(h.controller.perform("Summary") { try $0.addSummary(over: [kids[0], kids[2]]) })
        let s = try #require(h.controller.scene.summaries.first)
        let range = kids.map { branchRect(h, $0) }.reduce(CGRect.null) { $0.union($1) }
        #expect(s.bracket.minY <= range.minY + 0.5 && s.bracket.maxY >= range.maxY - 0.5)
        let t = try #require(h.controller.scene.nodes[topic]).frame.rect
        // The summary topic sits beyond the bracket, away from the range.
        if s.bracket.midX > range.midX {
            #expect(t.minX >= s.bracket.maxX - 0.5)
        } else {
            #expect(t.maxX <= s.bracket.minX + 0.5)
        }
        #expect(!t.intersects(range))
    }

    @Test func calloutStaysAttachedToItsHost() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let host = node(h, "Channels")
        let topic = try #require(h.controller.perform("Callout") { try $0.addCallout(on: host, text: "Ask Sam") })
        func gap() -> CGFloat {
            let a = h.controller.scene.nodes[host]!.frame.rect
            let b = h.controller.scene.nodes[topic]!.frame.rect
            let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
            let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
            return hypot(dx, dy)
        }
        #expect(gap() < 60)
        #expect(!h.controller.scene.nodes[host]!.frame.rect.intersects(h.controller.scene.nodes[topic]!.frame.rect))
        h.press("opt+cmd+2")
        #expect(gap() < 60)
    }

    @Test func zoneMovesItsMembers() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let zone = try #require(h.controller.perform("Zone") { $0.addZone(origin: CanvasPoint(x: 900, y: -400)) })
        let pro = node(h, "Pro")
        h.controller.perform("Detach") { try $0.detach(pro, at: CanvasPoint(x: 1000, y: -300)) }
        h.controller.perform("Drag") { try $0.moveFloating(pro, to: CanvasPoint(x: 1000, y: -300)) }
        #expect(h.canvas.zones[0].members == [pro])
        let before = h.controller.scene.nodes[pro]!.frame.rect
        h.controller.moveZone(zone, by: CGSize(width: 40, height: 30))
        let after = h.controller.scene.nodes[pro]!.frame.rect
        #expect(abs(after.minX - before.minX - 40) < 0.6 && abs(after.minY - before.minY - 30) < 0.6)
        #expect(h.controller.scene.zones[0].rect.contains(after))
        h.controller.updateZone(zone) { $0.collapsed = true }
        #expect(h.controller.scene.zones[0].hidden == 1)
        #expect(h.controller.scene.nodes[pro] == nil)
    }

    /// D170: a relationship ends on a zone's rectangle, follows the zone, survives save
    /// and load, exports, and goes when the zone is removed.
    @Test func relationshipToAZone() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let zone = try #require(
            h.controller.perform("Zone") { $0.addZone(title: "Ideas", origin: CanvasPoint(x: 900, y: -400)) })
        let pro = node(h, "Pro")
        let risks = node(h, "Risks")
        h.controller.perform("Detach") { try $0.detach(pro, at: CanvasPoint(x: 1000, y: -300)) }
        h.controller.perform("Drag") { try $0.moveFloating(pro, to: CanvasPoint(x: 1000, y: -300)) }
        #expect(h.canvas.zones[0].members == [pro])
        h.controller.perform("Connect") { e in
            e.connect(.topic(risks), to: .zone(zone), label: "parked")
            e.connect(.topic(pro), to: .zone(zone))
        }
        #expect(h.canvas.validate().isEmpty)
        let scene = h.controller.scene
        #expect(scene.relationships.map(\.relationship.to) == [.zone(zone), .zone(zone)])
        func onEdge(_ p: CGPoint, _ r: CGRect) -> Bool {
            let x = abs(p.x - r.minX) < 0.6 || abs(p.x - r.maxX) < 0.6
            let y = abs(p.y - r.minY) < 0.6 || abs(p.y - r.maxY) < 0.6
            let r = r.insetBy(dx: -0.6, dy: -0.6)
            return (x && p.y >= r.minY && p.y <= r.maxY) || (y && p.x >= r.minX && p.x <= r.maxX)
        }
        // From outside: the end sits on the zone's frame (plus the usual 6 pt gap).
        let zr = try #require(scene.rect(of: .zone(zone)))
        let a = try #require(scene.rect(of: .topic(risks)))
        let outside = RelationshipGeometry.make(h.canvas.relationships[0], from: a, to: zr)
        #expect(onEdge(outside.end, zr.insetBy(dx: -6, dy: -6)))
        // From a member: a short line to the zone's nearest edge.
        let p = try #require(scene.rect(of: .topic(pro)))
        let inside = RelationshipGeometry.make(h.canvas.relationships[1], from: p, to: zr)
        #expect(onEdge(inside.end, zr) && !p.contains(inside.start) && zr.contains(inside.start))

        // The anchor follows the zone.
        h.controller.moveZone(zone, by: CGSize(width: 40, height: 30))
        let moved = try #require(h.controller.scene.rect(of: .zone(zone)))
        #expect(abs(moved.minX - zr.minX - 40) < 0.6 && abs(moved.minY - zr.minY - 30) < 0.6)

        // Save and load.
        let decoded = try Canvas(json: h.canvas.json, path: "c")
        #expect(decoded.relationships == h.canvas.relationships)

        // Zone export keeps member → zone, not the one from outside (D155).
        var o = ImageExporter.Options()
        o.scope = .zone
        o.zone = zone
        let isolated = ImageExporter.controller(h.store.model, canvas: h.canvas.id, o).scene
        #expect(isolated.relationships.map(\.relationship.from) == [.topic(pro)])
        let svg = SVGExporter.export(h.store.model, canvas: h.canvas.id, ImageExporter.Options())
        #expect(try XMLDocument(data: Data(svg.utf8)).rootElement() != nil)
        #expect(svg.contains("data-nexus-to=\"\(zone)\" data-nexus-to-kind=\"zone\""))
        #expect(svg.components(separatedBy: "class=\"relationship\"").count == 3)

        // Removing the zone removes its relationships; one undo brings both back.
        h.controller.perform("Remove") { $0.removeElement(.zone(zone)) }
        #expect(h.canvas.relationships.isEmpty && h.canvas.validate().isEmpty)
        h.undo.undo(h.store)
        #expect(h.canvas.relationships.count == 2)
    }

    @Test func relationshipSceneFollowsColourModes() {
        let h = CanvasHarness(model: launchPlanDocument())
        let a = node(h, "Channels")
        let b = node(h, "Risks")
        h.controller.perform("Connect") { $0.connect(a, to: b) }
        let r = h.canvas.relationships[0].id
        h.controller.updateRelationship(r) { $0.color = "source" }
        #expect(h.controller.scene.relationships[0].color == h.controller.scene.nodes[a]!.branchColor)
        h.controller.updateRelationship(r) { $0.color = "#FF0000" }
        #expect(h.controller.scene.relationships[0].color.hex == "#FF0000")
    }

    /// Rich text: ⌘B in the real editor becomes a mark, survives commit and a package round trip.
    @Test func richTextMarksSurviveEditAndSave() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Annual discount")
        h.controller.select(pricing)
        h.press("space")
        #expect(h.controller.mode == .edit)
        let editor = h.host.canvasView.editor
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        h.press("cmd+b")
        h.press("return")
        #expect(h.controller.mode == .select)
        let marks = h.canvas.nodes[pricing]!.marks
        #expect(marks == [TextMark(start: 0, length: 3, bold: true)])
        #expect(h.controller.scene.nodes[pricing]!.marks == marks)
        let files = NexusPackage.files(for: h.store.model)
        let reread = try NexusPackage.read(files: files)
        #expect(reread.canvases[h.canvas.id]?.nodes[pricing]?.marks == marks)
        // Undo removes the mark in one step.
        #expect(h.undo.undo(h.store))
        #expect(h.canvas.nodes[pricing]!.marks.isEmpty)
        // ⌘B on an already-bold main topic is refused rather than silently lost.
        let main = node(h, "Pricing")
        h.controller.select(main)
        h.press("space")
        h.host.canvasView.editor.setSelectedRange(NSRange(location: 0, length: 3))
        h.press("cmd+b")
        h.press("return")
        #expect(h.canvas.nodes[main]!.marks.isEmpty)
    }

    /// Editing a relationship label leaves the source topic drawn as-is and grows the chip.
    @Test func labelEditKeepsSourceTopic() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let channels = node(h, "Channels")
        h.controller.select(channels)
        h.press("shift+cmd+l")
        h.type("tim")
        h.press("return")
        #expect(h.controller.edit?.element != nil)
        h.type("drives")
        #expect(h.controller.scene.nodes[channels]?.displayText == "Channels")
        #expect(h.controller.scene.relationships.first?.relationship.label == "drives")
        h.press("return")
        #expect(h.canvas.relationships.first?.label == "drives")
        #expect(h.canvas.nodes[channels]?.text == "Channels")
    }

    @Test func elementKeysSelectEditAndDelete() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        h.press("shift+cmd+b")
        let b = try #require(h.canvas.boundaries.first)
        #expect(b.nodes == [pricing])
        h.controller.selectElement(.boundary(b.id))
        h.press("delete")
        #expect(h.canvas.boundaries.isEmpty)
        #expect(h.canvas.nodes[pricing] != nil)
    }

    /// Visual review: every M3 element on one board, plus the FMT-2 panel per element.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func elementsBoardSnapshot() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        let h = CanvasHarness(model: launchPlanDocument(), width: 1600, height: 1000)
        let pricing = node(h, "Pricing")
        let kids = h.canvas.nodes[pricing]!.children
        let channels = node(h, "Channels")
        let timeline = node(h, "Timeline")
        let risks = node(h, "Risks")
        h.controller.perform("Elements") { e in
            let b = try e.addBoundary(around: [pricing], title: "prod-us-east")
            e.updateBoundary(b) { $0.meaning = "vpc" }
            let t = try e.addBoundary(around: [risks], title: "")
            e.updateBoundary(t) {
                $0.meaning = "trust"
                $0.trust = "low"
                $0.hatch = true
            }
            let s = try e.addSummary(over: [kids[0], kids[2]], text: "3 plans")
            _ = s
            _ = try e.addCallout(on: risks, text: "Legal review due before beta · Nov 3")
            e.connect(channels, to: timeline)
            let r = e.canvas.relationships[0].id
            e.updateRelationship(r) { $0.label = "drives" }
            let z = e.addZone(title: "Parking lot", origin: CanvasPoint(x: 700, y: -420), width: 360, height: 220)
            for (i, text) in ["Team dinner", "Swag budget", "Guest speaker"].enumerated() {
                _ = e.addFloating(at: CanvasPoint(x: 760 + Double(i % 2) * 150, y: -360 + Double(i) * 60), text: text)
            }
            _ = z
            let z2 = e.addZone(title: "Logistics", origin: CanvasPoint(x: 1150, y: -420), width: 300, height: 200)
            e.updateZone(z2) { $0.collapsed = true }
            e.update(kids[1]) { $0.todo = Todo(done: true) }
            e.update(node(h, "Developers")) {
                $0.marks = [TextMark(start: 0, length: 4, bold: true)]
                $0.labels = ["Q4", "Finance"]
                $0.note = Note(text: "Rollout notes")
                $0.link = "https://example.com"
            }
        }
        for f in h.canvas.floating {
            if let p = h.canvas.nodes[f]?.position {
                try? h.controller.perform("Adopt") { try $0.moveFloating(f, to: p) }
            }
        }
        h.controller.select(channels)
        h.controller.toggleMarker("priority-1")
        h.controller.setSticker("emoji:🚀", on: timeline)
        h.host.canvasView.fitToWindow()
        h.controller.selectElement(.relationship(h.canvas.relationships[0].id))
        h.snapshot(to: dir.appendingPathComponent("m3-elements.png"))
        h.window.orderOut(nil)
        let refs: [(String, ElementRef)] = [
            ("relationship", .relationship(h.canvas.relationships[0].id)),
            ("boundary", .boundary(h.canvas.boundaries[1].id)), ("summary", .summary(h.canvas.summaries[0].id)),
            ("zone", .zone(h.canvas.zones[0].id)),
        ]
        UserDefaults.standard.set("style", forKey: "format.tab")
        for (name, ref) in refs {
            h.controller.selectElement(ref)
            let panel = NSHostingView(rootView: FormatPanel(controller: h.controller))
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 330, height: 900), styleMask: [.borderless], backing: .buffered,
                defer: false)
            w.contentView = panel
            w.appearance = NSAppearance(named: .aqua)
            w.setFrameOrigin(NSPoint(x: 900, y: 0))
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = [
                "-x", "-o", "-l", "\(w.windowNumber)", dir.appendingPathComponent("m3-panel-\(name).png").path,
            ]
            try p.run()
            p.waitUntilExit()
            w.orderOut(nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func connectSnapshot() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        let h = CanvasHarness(model: launchPlanDocument(), width: 1200, height: 760)
        h.controller.select(node(h, "Channels"))
        h.host.canvasView.fitToWindow()
        h.press("shift+cmd+l")
        h.snapshot(to: dir.appendingPathComponent("m3-connect-hints.png"))
        h.type("tim")
        h.snapshot(to: dir.appendingPathComponent("m3-connect-filter.png"))
        h.press("return")
        h.type("drives")
        h.snapshot(to: dir.appendingPathComponent("m3-connect-label.png"))
        h.window.orderOut(nil)
    }
}
