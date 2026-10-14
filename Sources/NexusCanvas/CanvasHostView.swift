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
        // Technical-canvas panels (M4). Each sizes to its content, so it's empty when hidden.
        let dfd = NSHostingView(rootView: DFDPanelView(controller: controller))
        let crumb = NSHostingView(rootView: LevelBreadcrumbView(controller: controller))
        let violation = NSHostingView(rootView: ViolationCardView(controller: controller))
        let threatCard = NSHostingView(rootView: ThreatSuggestionCard(controller: controller))
        let table = NSHostingView(rootView: ThreatTableView(controller: controller))
        let icons = NSHostingView(rootView: IconLibraryView(controller: controller))
        let convert = NSHostingView(rootView: ConvertSheetView(controller: controller))
        let all: [NSView] = [status, toast, dfd, crumb, violation, threatCard, table, icons, convert, cheat]
        for h in all {
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
        }
        status.sizingOptions = [.intrinsicContentSize]
        cheat.sizingOptions = [.intrinsicContentSize]
        toast.sizingOptions = [.intrinsicContentSize]
        dfd.sizingOptions = [.intrinsicContentSize]
        crumb.sizingOptions = [.intrinsicContentSize]
        violation.sizingOptions = [.intrinsicContentSize]
        threatCard.sizingOptions = [.intrinsicContentSize]
        table.sizingOptions = [.intrinsicContentSize]
        icons.sizingOptions = [.intrinsicContentSize]
        convert.sizingOptions = [.intrinsicContentSize]
        NSLayoutConstraint.activate([
            dfd.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dfd.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            icons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icons.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            crumb.centerXAnchor.constraint(equalTo: centerXAnchor),
            crumb.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            violation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            violation.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -64),
            threatCard.centerXAnchor.constraint(equalTo: centerXAnchor),
            threatCard.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            table.centerXAnchor.constraint(equalTo: centerXAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -60),
            table.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            convert.centerXAnchor.constraint(equalTo: centerXAnchor),
            convert.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

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
