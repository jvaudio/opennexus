import AppKit
import SwiftUI

/// The canvas plus its floating chrome: state pill and hints (bottom-left), toast (top
/// centre) and the ⌘-hold cheat sheet (centre). Overlays are sized to their content so
/// the canvas keeps every pixel it can for the mouse.
public final class CanvasHostView: NSView {
    public let canvasView: CanvasView

    public init(controller: CanvasController) {
        canvasView = CanvasView(controller: controller)
        super.init(frame: .zero)
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvasView)

        let status = NSHostingView(rootView: CanvasStatusBar(controller: controller))
        let toast = NSHostingView(rootView: ToastView(controller: controller))
        let cheat = NSHostingView(rootView: CheatSheetView(controller: controller))
        for h in [status, toast, cheat] as [NSView] {
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
        }
        status.sizingOptions = [.intrinsicContentSize]
        cheat.sizingOptions = [.intrinsicContentSize]
        toast.sizingOptions = [.intrinsicContentSize]

        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomAnchor),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            toast.centerXAnchor.constraint(equalTo: centerXAnchor),
            toast.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            cheat.centerXAnchor.constraint(equalTo: centerXAnchor),
            cheat.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
