import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

extension ContextMenuTests {
    /// M33's known gap: the Gantt let Note and Label through to the canvas, whose popovers
    /// opened on the hidden canvas. They hang from the task's row now, as outline rows do.
    @Test func ganttPopoversOpenOnTheRow() throws {
        let h = ganttHarness()
        let s = h.host.ganttView.surface
        let popovers = try #require(h.host.canvasView.popovers)
        var anchored: [(NSView, CGRect)] = []
        popovers.present = { _, rect, view in anchored.append((view, rect)) }
        s.reload()
        let L = try #require(s.layout)
        let row = try #require(L.rows.first { h.canvas.nodes[$0.id]?.todo != nil })
        h.controller.select(row.id)
        h.window.makeFirstResponder(s)
        #expect(h.controller.ganttFocused)
        h.press("shift+cmd+n")
        let (view, rect) = try #require(anchored.last)
        #expect(view === s, "on the Gantt, not the hidden canvas")
        #expect(rect.minY == row.frame.minY && rect.height == row.frame.height && rect.width == L.tableWidth)
    }
}
