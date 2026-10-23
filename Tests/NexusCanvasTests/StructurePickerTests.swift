import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// The Format panel's structure picker names each structure from the structure it
/// applies (M17's known gap: its names were in another order, so "Brace Map" applied an
/// org chart and "Matrix" a tree table).
@MainActor
@Suite(.serialized) struct StructurePickerTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    @Test func everyChoiceAppliesTheStructureItNames() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        let options = StyleTab.structureOptions(current: .mindmapBalanced)
        #expect(
            options.map(\.1) == [
                "Mind Map", "Logic Chart", "Org Chart", "Timeline", "Fishbone", "Matrix", "Brace Map", "Tree Table",
                "Tree Chart", "Timeline (alternating)",
            ])
        for (s, name) in options {
            h.controller.setStructure(s)
            #expect(h.canvas.nodes[pricing]?.structure == s, "\(name)")
            if CanvasController.structureCycle.contains(s) {
                #expect(CanvasController.diagramType(for: s).displayName == name, "\(name) names its own family")
            }
        }
    }

    @Test func aStructureOutsideTheNineIsShownAsItself() {
        let options = StyleTab.structureOptions(current: .logicLeft)
        #expect(options.first?.0 == .logicLeft && options.first?.1 == "Logic Chart (left)")
        let offered = CanvasController.structureCycle.count + CanvasController.structureExtras.count
        #expect(options.count == offered + 1)
        #expect(Set(options.map(\.1)).count == options.count, "no two choices share a name")
        // One of the nine, or an extra (D249), isn't repeated.
        #expect(StyleTab.structureOptions(current: .orgDown).count == offered)
        #expect(StyleTab.structureOptions(current: .timelineAlternating).count == offered)
    }

    @Test func theRightClickMenuUsesTheSameNames() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.controller.prepareContextMenu(.topic(pricing))
        let titles = Set(h.controller.contextMenu(for: .topic(pricing)).flatMap(\.items).map(\.title))
        for s in CanvasController.structureCycle {
            #expect(titles.contains(CanvasController.structureName(s)), "\(s.rawValue)")
        }
    }
}
