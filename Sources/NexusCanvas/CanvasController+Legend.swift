import CoreGraphics
import Foundation
import NexusCore
import NexusKeys
import NexusScene

/// Moving the legend from the keyboard (M21, D203). Select Legend (View menu, palette, a
/// click, or VoiceOver) gives it the keyboard: arrows nudge it, ⇧ moves it further, ↩ opens
/// Edit Legend… and Esc hands the keyboard back to the topics. Each press is one undo step,
/// like Move Up and the Gantt's day moves.
@MainActor
extension CanvasController {
    /// Points per arrow press, and with ⇧.
    public static let legendStep: Double = 10
    public static let legendFarStep: Double = 50

    /// The legend is selected and can take keys (Select mode, on the canvas, not presenting).
    var legendActive: Bool {
        legendSelected && mode == .select && present == nil && scene.legend != nil && viewMode != .gantt
            && !outlineFocused
    }

    var legendHandlers: [CommandID: (CanvasController) -> Void] {
        [
            .selectLegend: { $0.selectLegend() },
            .resetLegendPosition: { $0.moveLegend(to: nil) },
            .legendLeft: { $0.nudgeLegend(dx: -1, dy: 0) },
            .legendRight: { $0.nudgeLegend(dx: 1, dy: 0) },
            .legendUp: { $0.nudgeLegend(dx: 0, dy: -1) },
            .legendDown: { $0.nudgeLegend(dx: 0, dy: 1) },
            .legendLeftFar: { $0.nudgeLegend(dx: -1, dy: 0, far: true) },
            .legendRightFar: { $0.nudgeLegend(dx: 1, dy: 0, far: true) },
            .legendUpFar: { $0.nudgeLegend(dx: 0, dy: -1, far: true) },
            .legendDownFar: { $0.nudgeLegend(dx: 0, dy: 1, far: true) },
            .legendEdit: { $0.editLegend() },
            .legendDone: { $0.deselectLegend() },
        ]
    }

    /// Hidden from the palette (and disabled in menus) when there's nothing to act on.
    func canPerformLegend(_ id: CommandID) -> Bool {
        switch id {
        case .selectLegend: scene.legend != nil && present == nil
        case .resetLegendPosition: canvas.legend?.position != nil
        default: legendActive
        }
    }

    /// Select Legend: the legend takes the arrow keys until Esc or another selection.
    public func selectLegend() {
        guard scene.legend != nil else {
            showToast(Loc.t("Show the legend first · ⌥⌘L"))
            return
        }
        if mode == .edit { commitEdit() }
        selectedElement = nil
        legendSelected = true
        onSceneChange?(false)
    }

    public func deselectLegend() {
        guard legendSelected else { return }
        legendSelected = false
        onSceneChange?(false)
    }

    /// One step (or a far step) in a direction, as one undo step. An automatically placed
    /// legend starts from where it's drawn.
    public func nudgeLegend(dx: Double, dy: Double, far: Bool = false) {
        guard canvas.legend != nil, let l = scene.legend else { return }
        let step = far ? Self.legendFarStep : Self.legendStep
        let o = l.rect.origin
        moveLegend(to: CanvasPoint(x: o.x + dx * step, y: o.y + dy * step))
    }
}

@MainActor
extension CanvasController {
    /// View › Legend: shows or hides the legend, making one the first time.
    public func toggleLegend() {
        let show = !(canvas.legend?.visible ?? false)
        perform(show ? Loc.t("Show Legend") : Loc.t("Hide Legend")) { e in
            e.updateMeta { c in
                if c.legend == nil { c.legend = Legend() } else { c.legend?.visible = show }
            }
        }
        showToast(show ? Loc.t("Legend shown · ⌥⌘L hides it") : Loc.t("Legend hidden"))
    }

    public func setLegendVisible(_ on: Bool) {
        guard (canvas.legend?.visible ?? false) != on else { return }
        toggleLegend()
    }

    /// A marker's description; empty restores the marker's own name.
    public func setLegendDescription(_ text: String, for marker: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = canvas.legend?.markers[marker] ?? ""
        guard t != current, !(t.isEmpty && current.isEmpty) else { return }
        perform(Loc.t("Legend Description")) { e in
            e.updateMeta { c in
                var l = c.legend ?? Legend()
                l.markers[marker] = t.isEmpty ? nil : t
                c.legend = l
            }
        }
    }

    /// Where the legend's top-left corner goes (nil: back beside the map).
    public func moveLegend(to p: CanvasPoint?) {
        guard canvas.legend != nil, canvas.legend?.position != p else { return }
        perform(Loc.t("Move Legend")) { e in e.updateMeta { $0.legend?.position = p } }
    }

    /// Edit Legend…: the legend's descriptions and visibility.
    public func editLegend() {
        if mode == .edit { commitEdit() }
        onRequest?(.legend)
    }
}
