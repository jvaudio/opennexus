import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// The minimap is for moving around a canvas: it stays hidden on slides, where it covered
/// Present's strip (found in M35's snapshots), and comes back afterwards.
@MainActor
@Suite(.serialized) struct MinimapTests {
    @Test func theMinimapStaysHiddenWhilePresenting() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.prefs.set("appearance.minimap", "always")
        let m = try #require(h.host.canvasView.minimap)
        m.refresh(panning: true)
        #expect(!m.isHidden, "shown on the canvas")
        h.controller.startPresent()
        m.refresh(panning: true)
        #expect(m.isHidden, "hidden on slides")
        h.controller.endPresent()
        m.refresh(panning: true)
        #expect(!m.isHidden, "back after presenting")
    }
}
