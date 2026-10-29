import Foundation
import NexusCore
import NexusScene

@MainActor
extension CanvasController {
    /// What the renderer shows beyond the scene: selection, editing, Connect and Present,
    /// and the effects Settings turns on. Flow dots stop under Reduce Motion.
    func renderState(reduceMotion: Bool) -> SceneRenderer.State {
        var s = SceneRenderer.State()
        s.parents = canvas.parentMap()
        s.selected = Set(selection.nodes)
        s.primary = selection.primary
        s.editing = edit.flatMap { $0.element == nil ? $0.node : nil }
        s.editingElement = edit?.element
        s.selectedElement = selectedElement
        s.selectedZones = Set(selectedZones)
        s.connect = connect
        s.presenting = present != nil
        s.legendActive = legendActive
        s.ringWidth = ringWidth
        s.glowTrail = prefs.bool("appearance.glowTrail")
        s.flowDots = prefs.bool("appearance.flowDots") && !reduceMotion
        return s
    }
}
