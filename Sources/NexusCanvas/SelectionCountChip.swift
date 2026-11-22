import NexusScene
import NexusTheme
import SwiftUI

/// "Multi-selected · count chip" (artboard 11): how many topics are selected, white on an
/// Iris capsule. The canvas shows it at the primary topic's top-right corner while more
/// than one topic is selected, and keeps it with that topic as the camera moves.
public struct SelectionCountChip: View {
    let controller: CanvasController

    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        let count = controller.selection.nodes.count
        let ring = controller.theme.ring
        Text(verbatim: count.formatted())
            .font(.chrome(10.5, weight: .semibold, design: .monospaced))
            // White on Iris; ink on a paler ring (dark themes, Blueprint's white), whichever
            // contrasts more: they cross at a luminance of about 0.18.
            .foregroundStyle(Contrast.relativeLuminance(ring) > 0.18 ? Color(white: 0.09) : .white)
            .frame(height: 15)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(cgColor: controller.theme.ring.cgColor)))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Loc.f("%lld topics selected", count))
    }
}

#if os(macOS)
import AppKit

/// A hosting view that draws but never takes the mouse: the count chip sits over the
/// canvas without catching clicks meant for the topic under it.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
