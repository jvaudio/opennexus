import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// M10: the VoiceOver canvas tree (README §11, §12).
@MainActor
@Suite(.serialized) struct VoiceOverTreeTests {
    func node(_ h: CanvasHarness, _ t: String) -> NodeID { h.canvas.nodes.first { $0.value.text == t }!.key }

    func topics(_ items: [Any]?) -> [TopicElement] { (items ?? []).compactMap { $0 as? TopicElement } }

    @Test func treeMirrorsTheMapAndReadsLikeTheREADME() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        let roots = topics(v.accessibilityChildren())
        #expect(roots.first?.id == h.canvas.root)
        #expect(roots.count == h.canvas.tops.count, "the central topic, then floating topics")
        let root = try #require(roots.first)
        #expect(root.accessibilityLabel()?.hasPrefix("Launch plan. Central topic, level 1 of 3") == true)
        // Children nest like the map, in order.
        let mains = topics(root.accessibilityChildren())
        #expect(mains.map(\.id) == h.canvas.nodes[h.canvas.root]!.children)
        let pricing = try #require(mains.first { $0.id == node(h, "Pricing") })
        #expect(pricing.accessibilityLabel()?.contains("Pricing. Main topic, level 2 of 3. 3 children") == true)
        #expect(pricing.accessibilityLabel()?.contains("Branch colour") == true)
        #expect((pricing.accessibilityParent() as? TopicElement)?.id == h.canvas.root)
        #expect(pricing.accessibilityRoleDescription() == "topic")
        // Folded: the children leave the tree and the label says so.
        h.controller.select(pricing.id)
        h.press("cmd+/")
        #expect(topics(pricing.accessibilityChildren()).isEmpty)
        #expect(pricing.accessibilityLabel()?.contains("3 children, collapsed") == true)
        // The same element is reused across edits (VoiceOver keeps its place).
        #expect(v.accessibilityTree.element(pricing.id) === pricing)
    }

    @Test func framesFollowTheCamera() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        let pro = try #require(v.accessibilityTree.element(node(h, "Pro")))
        let before = pro.accessibilityFrame()
        #expect(before.width > 20 && h.window.frame.contains(CGPoint(x: before.midX, y: before.midY)))
        var c = v.camera
        c.offset.x += 100
        v.setCamera(c, animated: false)
        #expect(abs(pro.accessibilityFrame().minX - before.minX - 100) < 0.5, "no rebuild needed to pan")
        // Hit-testing finds the topic under the VoiceOver cursor.
        let mid = CGPoint(x: pro.accessibilityFrame().midX, y: pro.accessibilityFrame().midY)
        #expect((v.accessibilityHitTest(mid) as? TopicElement)?.id == pro.id)
    }

    @Test func actionsRunTheSameUndoableCommands() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        let risks = try #require(v.accessibilityTree.element(node(h, "Risks")))
        #expect(risks.accessibilityPerformPress() && h.controller.selection.primary == risks.id)
        let names = risks.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(names == ["Edit", "Add child", "Add sibling", "Connect from here", "Comments", "Fold"])
        let before = h.canvas.nodes.count
        let depth = h.undo.stack.undoStack.count
        _ = risks.accessibilityCustomActions()?.first { $0.name == "Add child" }?.handler?()
        #expect(h.canvas.nodes.count == before + 1 && h.undo.stack.undoStack.count == depth + 1)
        h.press("esc")
        _ = risks.accessibilityCustomActions()?.first { $0.name == "Edit" }?.handler?()
        #expect(h.controller.mode == .edit)
    }

    @Test func rotorsWalkTopicsNotesEdgesAndBoundaries() throws {
        var doc = launchPlanDocument()
        let pricing = doc.canvases["c1"]!.nodes.first { $0.value.text == "Pricing" }!.key
        doc.canvases["c1"]!.nodes[pricing]!.note = Note(text: "Margins")
        var e = CanvasEditor(doc.canvases["c1"]!)
        _ = try e.addBoundary(around: [pricing], title: "Money")
        let channels = e.canvas.nodes.first { $0.value.text == "Channels" }!.key
        let timeline = e.canvas.nodes.first { $0.value.text == "Timeline" }!.key
        _ = e.connect(channels, to: timeline, label: "drives")
        doc.canvases["c1"] = e.canvas
        let h = CanvasHarness(model: doc)
        let v = h.host.canvasView
        let rotors = v.accessibilityCustomRotors()
        #expect(
            rotors.map(\.label) == [
                "Topics", "Notes", "Comments", "Edges", "Boundaries", "AI suggestions", "Connect targets",
            ])
        func walk(_ label: String) -> [String] {
            let r = rotors.first { $0.label == label }!
            var out: [String] = []
            var current: NSAccessibilityCustomRotor.ItemResult?
            for _ in 0..<50 {
                let p = NSAccessibilityCustomRotor.SearchParameters()
                p.searchDirection = .next
                p.currentItem = current
                guard let next = r.itemSearchDelegate?.rotor(r, resultFor: p) else { break }
                out.append(next.customLabel ?? "")
                current = next
            }
            return out
        }
        #expect(walk("Topics").count == h.controller.scene.nodes.count)
        #expect(walk("Topics").first?.hasPrefix("Launch plan.") == true)
        #expect(walk("Notes").count == h.canvas.nodes.values.filter { $0.note != nil }.count)
        #expect(walk("Edges").first?.contains("Channels to Timeline, drives") == true)
        #expect(walk("Boundaries") == ["Money. Boundary around 1 topic."])
        #expect(walk("Connect targets").isEmpty)
        // Connect mode: targets in hint order, each read with its hint letter.
        h.controller.select(node(h, "Channels"))
        h.press("shift+cmd+l")
        let targets = walk("Connect targets")
        #expect(targets.count == h.controller.connect?.candidates.count && targets.first?.hasPrefix("Hint A.") == true)
    }

    @Test func aiSuggestionsAreElementsUnderTheirTopic() async throws {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.ai = ScriptedEngine(defaultIdeas: [GhostIdea(text: "Churn"), GhostIdea(text: "Refunds")])
        let risks = node(h, "Risks")
        h.controller.select(risks)
        h.press("opt+space")
        for _ in 0..<100 where h.controller.ghosts?.loading != false { try await Task.sleep(for: .milliseconds(10)) }
        let el = try #require(h.host.canvasView.accessibilityTree.element(risks))
        let ghosts = topics(el.accessibilityChildren()).filter { $0.accessibilityRoleDescription() == "suggestion" }
        #expect(ghosts.count == 2 && ghosts[0].accessibilityLabel()?.hasPrefix("Suggested topic: Churn.") == true)
        #expect(ghosts[1].accessibilityPerformPress(), "pressing a suggestion accepts it")
        #expect(h.canvas.nodes.values.contains { $0.text == "Refunds" && $0.ai })
    }

    @Test func focusFollowsTheSelectionOnlyWhenAnAssistiveAppRuns() {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        v.assistiveAppOverride = true
        h.controller.select(node(h, "Pro"))
        #expect((v.accessibilityValue() as? String)?.hasPrefix("Pro. Subtopic") == true)
        #expect(v.accessibilityTree.element(node(h, "Pro"))?.isAccessibilityFocused() == true)
        #expect(v.accessibilityTree.element(node(h, "Pricing"))?.isAccessibilityFocused() == false)
    }

    /// The tree is built only on demand: a 5k map doesn't pay for it while nobody reads it.
    @Test func largeMapsCostNothingUntilRead() {
        let h = CanvasHarness(model: bigDocument(mains: 20, subs: 25, leaves: 9))
        let v = h.host.canvasView
        let d = ContinuousClock().measure {
            let roots = v.accessibilityChildren() ?? []
            let mains = (roots.first as? TopicElement)?.accessibilityChildren() ?? []
            #expect(mains.count == 20)
            _ = (mains.first as? TopicElement)?.accessibilityLabel()
        }
        #expect(ms(d) < 100, "first read \(ms(d)) ms")
    }
}
