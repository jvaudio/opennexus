import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

/// The P0 sample map ("Launch plan").
func launchPlanDocument() -> DocumentModel {
    var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let tree: [(String, [String])] = [
            ("Positioning", ["Developers", "Teams"]), ("Pricing", ["Free tier", "Pro", "Annual discount"]),
            ("Channels", ["Product Hunt", "Newsletter"]), ("Timeline", ["Beta · Nov", "GA · Jan"]),
            ("Risks", ["Competitor response"]),
        ]
        for (m, subs) in tree {
            let id = try! e.addChild(of: e.canvas.root, text: m)
            for s in subs { try! e.addChild(of: id, text: s) }
        }
    }
    return DocumentModel(canvases: [c])
}

@MainActor
@Suite(.serialized) struct ConnectTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID {
        h.canvas.nodes.first { $0.value.text == text }!.key
    }

    /// F2 hint path: ⇧⌘L, type the target's hint, ↩ draws the edge, label in Edit.
    @Test func hintPath() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let channels = node(h, "Channels")
        let timeline = node(h, "Timeline")
        h.controller.select(channels)
        h.press("shift+cmd+l")
        #expect(h.controller.mode == .connect)
        let state = try #require(h.controller.connect)
        #expect(state.source == .topic(channels))
        // Nearest first, unique, prefix-free.
        let hints = state.candidates.map(\.hint)
        #expect(Set(hints).count == hints.count)
        #expect(state.candidates.first?.hint == "A")
        let hint = try #require(state.candidates.first { $0.node == timeline }?.hint)
        h.type(hint.lowercased())
        #expect(h.controller.connect?.target?.node == timeline)
        h.press("return")
        #expect(h.controller.mode == .edit)
        #expect(h.controller.edit?.element != nil)
        let rel = try #require(h.canvas.relationships.first)
        #expect(rel.from == .topic(channels) && rel.to == .topic(timeline))
        h.type("drives")
        h.press("return")
        #expect(h.controller.mode == .select)
        #expect(h.canvas.relationships.first?.label == "drives")
        // One undo step for the edge, one for its label.
        h.undo.undo(h.store)
        #expect(h.canvas.relationships.first?.label == "")
        h.undo.undo(h.store)
        #expect(h.canvas.relationships.isEmpty)
    }

    /// F2 text path: typing that matches no hint filters by topic text.
    @Test func textFilterPath() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.select(node(h, "Risks"))
        h.press("shift+cmd+l")
        h.type("newsl")
        let c = try #require(h.controller.connect)
        #expect(!c.matchedHints)
        #expect(c.matches.map(\.node) == [node(h, "Newsletter")])
        h.press("return")
        #expect(h.canvas.relationships.first?.to == .topic(node(h, "Newsletter")))
        h.press("esc")  // commits the (empty) label
        #expect(h.controller.mode == .select)
        #expect(h.canvas.relationships.count == 1)
    }

    @Test func arrowsMoveTheHighlight() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.select(node(h, "Pricing"))
        h.press("shift+cmd+l")
        let first = h.controller.connect?.target?.node
        h.press("down")
        let second = h.controller.connect?.target?.node
        #expect(first != second)
        h.press("up")
        #expect(h.controller.connect?.target?.node == first)
        h.press("return")
        #expect(h.canvas.relationships.first?.to.topic == first)
    }

    /// Esc at any point: nothing changed.
    @Test func escapeLeavesModelUnchanged() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let before = h.canvas
        let undoDepth = h.undo.stack.undoStack.count
        h.controller.select(node(h, "Pricing"))
        h.press("shift+cmd+l")
        h.type("ti")
        h.press("down")
        h.press("delete")
        h.press("esc")
        #expect(h.controller.mode == .select)
        #expect(h.controller.connect == nil)
        #expect(h.canvas == before)
        #expect(h.undo.stack.undoStack.count == undoDepth)
    }

    /// No match: ↩ creates the topic and connects to it.
    @Test func createNewNode() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.select(node(h, "Pricing"))
        h.press("shift+cmd+l")
        h.type("Billing team")
        #expect(h.controller.connect?.offersCreate == true)
        h.press("return")
        let created = node(h, "Billing team")
        #expect(h.canvas.parent(of: created) == h.canvas.root)
        #expect(h.canvas.relationships.first?.to == .topic(created))
        h.press("return")
        h.undo.undo(h.store)
        h.undo.undo(h.store)
        #expect(h.canvas.nodes.values.contains { $0.text == "Billing team" } == false)
    }

    /// D171: zones are hint targets, their titles filter, and a selected zone is the source.
    @Test func connectToAndFromAZone() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let zone = try #require(
            h.controller.perform("Zone") { $0.addZone(title: "Parking lot", origin: CanvasPoint(x: 700, y: -360)) })
        let risks = node(h, "Risks")
        h.controller.select(risks)
        h.press("shift+cmd+l")
        let state = try #require(h.controller.connect)
        let hint = try #require(state.candidates.first { $0.end == .zone(zone) }?.hint)
        h.type(hint.lowercased())
        #expect(h.controller.connect?.target?.end == .zone(zone))
        h.press("return")
        #expect(h.controller.mode == .edit)
        h.type("parked")
        h.press("return")
        let rel = try #require(h.canvas.relationships.first)
        #expect(rel.from == .topic(risks) && rel.to == .zone(zone) && rel.label == "parked")
        #expect(h.controller.scene.relationships.count == 1)

        // Typing the zone's title finds it.
        h.controller.select(node(h, "Pricing"))
        h.press("shift+cmd+l")
        h.type("parking")
        #expect(h.controller.connect?.matches.map(\.end) == [.zone(zone)])
        h.press("esc")

        // From the zone: back to a topic.
        h.controller.selectElement(.zone(zone))
        h.press("shift+cmd+l")
        #expect(h.controller.connect?.source == .zone(zone))
        #expect(h.controller.connect?.candidates.contains { $0.end == .zone(zone) } == false)
        h.type("newsl")
        h.press("return")
        let back = try #require(h.canvas.relationships.last)
        #expect(back.from == .zone(zone) && back.to == .topic(node(h, "Newsletter")))
        h.press("esc")
        #expect(h.canvas.relationships.count == 2)
        h.undo.undo(h.store)
        #expect(h.canvas.relationships.count == 1)
    }

    /// D184: boundaries and summary brackets are Connect targets and sources; a callout's
    /// bubble is a topic target. VoiceOver names each kind of end.
    @Test func connectToBoundariesSummariesAndCallouts() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let channels = node(h, "Channels")
        let risks = node(h, "Risks")
        let kids = h.canvas.nodes[node(h, "Pricing")]!.children
        let boundary = try #require(
            h.controller.perform("Boundary") { try $0.addBoundary(around: [channels], title: "Reach") })
        h.controller.perform("Summary") { _ = try $0.addSummary(over: Array(kids.prefix(2)), text: "Paid plans") }
        let summary = h.canvas.summaries[0].id
        let callout = try #require(h.controller.perform("Callout") { try $0.addCallout(on: risks, text: "Ask legal") })

        // A hint reaches the boundary.
        h.controller.select(risks)
        h.press("shift+cmd+l")
        let state = try #require(h.controller.connect)
        let ends = Set(state.candidates.map(\.end))
        #expect(ends.isSuperset(of: [.boundary(boundary), .summary(summary), .topic(callout)]))
        let hint = try #require(state.candidates.first { $0.end == .boundary(boundary) }?.hint)
        h.type(hint.lowercased())
        #expect(h.controller.connect?.target?.end == .boundary(boundary))
        h.press("return")
        h.type("watches")
        h.press("return")
        let rel = try #require(h.canvas.relationships.last)
        #expect(rel.from == .topic(risks) && rel.to == .boundary(boundary) && rel.label == "watches")

        // Titles filter: "Boundary: Reach", "Summary: Paid plans".
        h.controller.select(node(h, "Timeline"))
        h.press("shift+cmd+l")
        h.type("reach")
        #expect(h.controller.connect?.matches.map(\.end) == [.boundary(boundary)])
        h.press("esc")
        h.press("shift+cmd+l")
        h.type("paid plans")
        #expect(h.controller.connect?.matches.map(\.end) == [.summary(summary), .topic(h.canvas.summaries[0].topic)])
        h.press("esc")

        // From the summary's bracket to the callout's bubble.
        h.controller.selectElement(.summary(summary))
        h.press("shift+cmd+l")
        #expect(h.controller.connect?.source == .summary(summary))
        h.type("ask legal")
        h.press("return")
        let back = try #require(h.canvas.relationships.last)
        #expect(back.from == .summary(summary) && back.to == .topic(callout))
        h.press("esc")

        // From a selected boundary.
        h.controller.selectElement(.boundary(boundary))
        h.press("shift+cmd+l")
        #expect(h.controller.connect?.source == .boundary(boundary))
        h.press("esc")
        #expect(h.canvas.relationships.count == 2 && h.canvas.validate().isEmpty)

        // VoiceOver reads the ends by kind.
        let edges = h.host.canvasView.accessibilityTree.edgeItems().map(\.text)
        #expect(edges.contains("Risks to boundary Reach, watches. Relationship."))
        #expect(edges.contains("summary Paid plans to callout Ask legal. Relationship."))
        h.undo.undo(h.store)
        #expect(h.canvas.relationships.count == 1)
    }

    @Test func hintsArePrefixFreeAtScale() {
        for n in [1, 5, 26, 27, 60, 200, 676] {
            let hs = ConnectState.hints(count: n)
            #expect(hs.count == n, "\(n)")
            #expect(Set(hs).count == n)
            for a in hs {
                for b in hs where a != b { #expect(!b.hasPrefix(a), "\(a) prefixes \(b)") }
            }
        }
    }
}
