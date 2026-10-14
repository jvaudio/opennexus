import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys
@testable import NexusTheme

@MainActor
@Suite(.serialized) struct StylingCommandTests {
    func harness() -> CanvasHarness {
        CanvasHarness(model: nodeStyleSampleDocument(theme: "classic", style: "outline"))
    }

    func steps(_ h: CanvasHarness) -> Int { h.undo.stack.undoStack.count }

    @Test func cycleNodeStyleIsOneUndoStep() {
        let h = harness()
        let before = steps(h)
        h.press("opt+cmd+s")
        #expect(h.canvas.style.nodeStyle == "soft")
        #expect(h.controller.toast?.text == "Node style: Soft")
        for _ in 0..<8 { h.press("opt+cmd+s") }
        #expect(h.canvas.style.nodeStyle == "outline")
        #expect(steps(h) == before + 9)
        h.undo.undo(h.store)
        #expect(h.canvas.style.nodeStyle == "minimal")
    }

    @Test func copyPasteResetStyle() {
        let h = harness()
        let mains = h.canvas.nodes[h.canvas.root]!.children
        h.controller.select(mains[0])
        h.controller.updateSelectionStyle {
            $0.shape = "hexagon"; $0.fillColor = "#0F9F9A"
        }
        h.press("opt+cmd+c")
        h.controller.select(mains[1])
        h.press("opt+cmd+v")
        #expect(h.canvas.nodes[mains[1]]?.style?.shape == "hexagon")
        #expect(h.controller.scene.nodes[mains[1]]?.appearance.shape == "hexagon")
        h.press("opt+cmd+r")
        #expect(h.canvas.nodes[mains[1]]?.style == nil)
        h.undo.undo(h.store)
        #expect(h.canvas.nodes[mains[1]]?.style?.shape == "hexagon")
    }

    @Test func quickStylesByKey() {
        let h = harness()
        let mains = h.canvas.nodes[h.canvas.root]!.children
        h.controller.select(mains[0])
        h.press("ctrl+opt+1")
        #expect(h.canvas.nodes[mains[0]]?.quickStyle == "very-important")
        let a = h.controller.scene.nodes[mains[0]]!.appearance
        #expect(a.fill == .solid(RGBA(hex: "#C62F35")))
        h.press("ctrl+opt+5")
        #expect(h.canvas.nodes[mains[0]]?.quickStyle == "decision")
        #expect(h.controller.scene.nodes[mains[0]]!.appearance.shape == "diamond")
        h.press("ctrl+opt+4")  // Default clears it
        #expect(h.canvas.nodes[mains[0]]?.quickStyle == nil)
    }

    @Test func updateStyleScopes() {
        let h = harness()
        let c = h.canvas
        let positioning = c.nodes[c.root]!.children[0]
        let devs = c.nodes[positioning]!.children[0]
        h.controller.select(devs)
        h.controller.updateSelectionStyle { $0.textCase = "upper" }
        h.controller.updateStyle(.siblings)
        let teams = c.nodes[positioning]!.children[1]
        #expect(h.canvas.nodes[teams]?.style?.textCase == "upper")
        h.controller.updateStyle(.sameLevel)
        #expect(h.canvas.style.levels[2]?.textCase == "upper")
        #expect(h.canvas.nodes[teams]?.style == nil)
        let free = h.canvas.nodes[c.nodes[c.root]!.children[1]]!.children[0]
        #expect(h.controller.scene.nodes[free]?.displayText == "FREE")
    }

    @Test func numberingLabelsChildren() {
        let h = harness()
        let root = h.canvas.root
        h.controller.select(root)
        h.controller.updateSelectionStyle { $0.numbering = NumberingStyle(format: "decimal") }
        let pos = h.canvas.nodes[root]!.children[0]
        #expect(h.controller.scene.nodes[pos]?.displayText == "1 Positioning")
        h.controller.select(pos)
        h.controller.updateSelectionStyle { $0.numbering = NumberingStyle(format: "tiered", tiered: true) }
        let devs = h.canvas.nodes[pos]!.children[0]
        #expect(h.controller.scene.nodes[devs]?.displayText == "1.1 Devs")
        #expect(SceneBuilder.number(4, format: "roman") == "IV")
        #expect(SceneBuilder.number(28, format: "upper") == "AB")
        #expect(SceneBuilder.number(2, format: "circled") == "②")
        #expect(SceneBuilder.number(12, format: "cjk") == "十二")
    }

    @Test func libraryChangesAreUndoable() {
        let h = harness()
        let t = h.controller.saveCurrentAsTheme(named: "Studio Dusk")
        #expect(h.controller.library.themes.map(\.name) == ["Studio Dusk"])
        #expect(h.canvas.style.theme == t.id)
        h.undo.undo(h.store)  // theme switch
        h.undo.undo(h.store)  // library entry
        #expect(h.controller.library.themes.isEmpty)
        h.controller.saveAsQuickStyle(named: "Alarm")
        #expect(h.controller.styleEnvironment.quickStyles.contains { $0.name == "Alarm" })
    }

    @Test func skeletonAppliesThreeDialsInOneStep() {
        let h = harness()
        let before = steps(h)
        h.controller.applySkeleton(Skeleton.featured[2])
        #expect(h.canvas.layout.structure == .orgDown)
        #expect(h.canvas.style.lineShape == "elbow")
        #expect(steps(h) == before + 1)
    }

    @Test func mapSettingsTakeEffect() {
        let h = harness()
        let w0 = h.controller.scene.bounds.width
        h.controller.updateCanvasStyle { $0.compact = true }
        #expect(h.controller.scene.bounds.width < w0)
        h.controller.updateCanvasStyle { $0.background = "#121317" }
        #expect(h.controller.scene.canvasColor == RGBA(hex: "#121317"))
        h.controller.updateCanvasStyle { $0.pattern = "plain" }
        #expect(h.controller.scene.grid == .none)
        h.controller.updateCanvasStyle { $0.lineWidth = "bold" }
        #expect(h.controller.scene.edges.first!.width > 3)
        // Text stays readable on the dark override background.
        for n in h.controller.scene.nodes.values {
            #expect(Contrast.ratio(n.appearance.text, n.appearance.textBackground) >= 4.5)
        }
    }

    @Test func themeSwitchKeepsTextReadable() {
        let h = harness()
        for t in Theme.builtIn {
            h.controller.setTheme(t.id)
            for style in NodeStyle.allCases {
                h.controller.setNodeStyle(style)
                for n in h.controller.scene.nodes.values {
                    let r = Contrast.ratio(
                        n.appearance.text, n.appearance.textBackground, backdrop: h.controller.scene.canvasColor)
                    #expect(r >= t.contrastTarget - 0.01, "\(t.name)/\(style): \(n.displayText) \(r)")
                }
            }
        }
    }
}
