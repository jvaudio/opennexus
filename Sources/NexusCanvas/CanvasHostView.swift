import AppKit
import SwiftUI

/// The canvas plus its floating chrome: state pill and hints (bottom-left), toast (top
/// centre) and the ⌘-hold cheat sheet (centre). Overlays are sized to their content so
/// the canvas keeps every pixel it can for the mouse.
public final class CanvasHostView: NSView {
    public let canvasView: CanvasView
    private var presentHost: NSView?
    private var overlays: [NSView] = []

    /// Overlays follow the canvas theme (light chrome on a light map, dark on a dark one),
    /// not the system appearance.
    private func syncAppearance(_ controller: CanvasController) {
        let dark = withObservationTracking {
            controller.theme.isDark
        } onChange: { [weak self, weak controller] in
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                self.syncAppearance(controller)
            }
        }
        let a = NSAppearance(named: dark ? .darkAqua : .aqua)
        for v in overlays + subviews.filter({ $0 is NSHostingView<CanvasStatusBar> }) { v.appearance = a }
    }
    /// The window shows or hides its chrome and the presenter view.
    public var onPresentChange: ((Bool) -> Void)?

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
        // Views and navigation (M5).
        let nav = NSHostingView(rootView: NavigationPanelView(controller: controller))
        let filter = NSHostingView(rootView: FilterBarView(controller: controller))
        let focus = NSHostingView(rootView: FocusBreadcrumbView(controller: controller))
        let counts = NSHostingView(rootView: CountsControl(controller: controller))
        let zenCount = NSHostingView(rootView: ZenCountView(controller: controller))
        let palette = NSHostingView(rootView: PaletteView(controller: controller))
        let jump = NSHostingView(rootView: JumpView(controller: controller))
        let present = NSHostingView(rootView: PresentOverlayView(controller: controller))
        present.isHidden = true
        // Pinned to all edges: its (often empty) content must not size the host.
        present.sizingOptions = []
        presentHost = present
        let all: [NSView] = [
            present, status, toast, dfd, crumb, violation, threatCard, table, icons, nav, filter, focus, counts,
            zenCount, convert, palette, jump, cheat,
        ]
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
        filter.sizingOptions = [.intrinsicContentSize]
        focus.sizingOptions = [.intrinsicContentSize]
        counts.sizingOptions = [.intrinsicContentSize]
        zenCount.sizingOptions = [.intrinsicContentSize]
        palette.sizingOptions = [.intrinsicContentSize]
        jump.sizingOptions = [.intrinsicContentSize]
        nav.sizingOptions = [.intrinsicContentSize]
        NSLayoutConstraint.activate([
            present.leadingAnchor.constraint(equalTo: leadingAnchor),
            present.trailingAnchor.constraint(equalTo: trailingAnchor),
            present.topAnchor.constraint(equalTo: topAnchor),
            present.bottomAnchor.constraint(equalTo: bottomAnchor),
            nav.leadingAnchor.constraint(equalTo: leadingAnchor),
            nav.topAnchor.constraint(equalTo: topAnchor),
            nav.bottomAnchor.constraint(equalTo: bottomAnchor),
            filter.centerXAnchor.constraint(equalTo: centerXAnchor),
            filter.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            focus.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            focus.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            counts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            counts.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            zenCount.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            zenCount.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            palette.centerXAnchor.constraint(equalTo: centerXAnchor),
            palette.topAnchor.constraint(equalTo: topAnchor, constant: 70),
            jump.centerXAnchor.constraint(equalTo: centerXAnchor),
            jump.topAnchor.constraint(equalTo: topAnchor, constant: 70),
        ])
        overlays = all.filter { $0 !== status }
        syncAppearance(controller)
        controller.onPresent = { [weak self, weak controller] on in
            self?.presentHost?.isHidden = !on
            self?.onPresentChange?(on)
            if !on { controller?.refreshView() }
        }
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
