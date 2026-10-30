import NexusCore
import NexusScene
import SwiftUI

/// The canvas's floating chrome as one SwiftUI stack (M47b): what `CanvasHostView` pins over
/// the Mac's canvas, placed the same way, for a host that lays out in SwiftUI (the iPad).
/// Each overlay sizes to its content, so empty space lets touches through to the canvas.
/// The chrome follows the canvas theme (light on a light map, dark on a dark one).
public struct CanvasOverlayStack: View {
    let controller: CanvasController
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// On the iPhone, sheets and bars as wide as the screen keep a margin from its edges.
    var edge: CGFloat { sizeClass == .compact ? 10 : 0 }
    #else
    let edge: CGFloat = 0
    #endif

    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        ZStack {
            if controller.present != nil {
                PresentOverlayView(controller: controller).named(Loc.t("Presentation"))
            }
            NavigationPanelView(controller: controller).named(Loc.t("Navigation"))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Group {
                FocusBreadcrumbView(controller: controller).named(Loc.t("Focus breadcrumb"))
                DFDPanelView(controller: controller).named(Loc.t("Data flow levels"))
                IconLibraryView(controller: controller).named(Loc.t("Icon library"))
            }
            .padding(16).pinned(.topLeading)
            Group {
                FilterBarView(controller: controller).named(Loc.t("Filter")).padding(.top, 16)
                LevelBreadcrumbView(controller: controller).named(Loc.t("Level breadcrumb")).padding(.top, 14)
                ThreatSuggestionCard(controller: controller).named(Loc.t("Threat suggestions")).padding(.top, 16)
                ToastView(controller: controller).named(Loc.t("Notification")).padding(.top, 20)
                PaletteView(controller: controller).named(Loc.t("Command palette")).padding(.top, 70)
                JumpView(controller: controller).named(Loc.t("Quick jump")).padding(.top, 70)
            }
            .padding(.horizontal, edge)
            .pinned(.top)
            Group {
                TourOverlay(controller: controller, part: .pill).named(Loc.t("Tutorial paused"))
                    .padding(.top, 20).padding(.trailing, 20)
            }
            .pinned(.topTrailing)
            Group {
                MapShotHintHost(controller: controller).named(Loc.t("Map Shot hint")).padding(.leading, 24)
                    .padding(.top, 20)
            }
            .pinned(.topLeading)
            Group {
                CanvasStatusBar(controller: controller).named(Loc.t("Mode and keys")).padding(16)
                ViolationCardView(controller: controller).named(Loc.t("Data flow rule check")).padding(.leading, 16)
                    .padding(.bottom, 64)
            }
            .pinned(.bottomLeading)
            Group {
                CountsControl(controller: controller).named(Loc.t("Zoom and topic count")).padding(16)
                ZenCountView(controller: controller).named(Loc.t("Focus timer")).padding(.trailing, 24)
                    .padding(.bottom, 20)
            }
            .pinned(.bottomTrailing)
            Group {
                ThreatTableView(controller: controller).named(Loc.t("Threat table")).padding(.horizontal, 16)
                    .padding(.bottom, 60)
                MapShotBar(controller: controller).named(Loc.t("Map Shot")).padding(.bottom, 40)
                TourOverlay(controller: controller, part: .bar).named(Loc.t("Tutorial")).padding(.bottom, 70)
                TipView(controller: controller).named(Loc.t("Tip")).padding(.bottom, 72)
            }
            .pinned(.bottom)
            Group {
                CheatSheetView(controller: controller).named(Loc.t("Shortcut cheat sheet"))
                ConvertSheetView(controller: controller).named(Loc.t("Convert diagram type"))
                AISheetView(controller: controller).named("AI")
                TourOverlay(controller: controller, part: .finish).named(Loc.t("Tutorial finished"))
                fileSheets
            }
            .padding(.horizontal, edge)
        }
        .environment(\.colorScheme, controller.theme.isDark ? .dark : .light)
    }

    /// Files, sharing, sync and collaboration (M7, M44–M46): centred, one at a time.
    @ViewBuilder var fileSheets: some View {
        ExportSheetView(controller: controller).named(Loc.t("Export"))
        PrintSheetView(controller: controller).named(Loc.t("Print"))
        MergeSheetView(controller: controller).named(Loc.t("Merge documents"))
        PasswordSheetView(controller: controller).named(Loc.t("Password"))
        ImportReportView(controller: controller).named(Loc.t("Import report"))
        SnapshotsSheetView(controller: controller).named(Loc.t("Recovery snapshots"))
        TaskEditorSheetView(controller: controller).named(Loc.t("Task"))
        ShareSheetView(controller: controller).named(Loc.t("Share Link"))
        ShareNoticeView(controller: controller).named(Loc.t("Share Link"))
        ManageLinksView(controller: controller).named(Loc.t("Share Links"))
        ResolveConflictsView(controller: controller).named(Loc.t("Resolve Conflicts"))
        SyncHistoryView(controller: controller).named(Loc.t("Sync History"))
        ConflictCopiesNotice(controller: controller).named(Loc.t("Merge Conflicting Copies"))
        CollabSheetView(controller: controller).named(Loc.t("Collaborate"))
        JoinSheetView(controller: controller).named(Loc.t("Join Session"))
        CollabNoticeView(controller: controller).named(Loc.t("Collaborate"))
    }
}

/// The AI panel, or the guide in its place (M41), beside the canvas: it takes its width
/// from the canvas and is zero wide when hidden, as on the Mac.
public struct CanvasTrailingPanel: View {
    let controller: CanvasController

    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        TrailingPanelView(controller: controller).named(Loc.t("AI panel"))
            .environment(\.colorScheme, controller.theme.isDark ? .dark : .light)
    }
}

extension View {
    /// A named group for assistive apps (M10 audit: unnamed overlays are "missing useful
    /// accessibility information").
    fileprivate func named(_ name: String) -> some View {
        accessibilityElement(children: .contain).accessibilityLabel(name)
    }

    /// Sized to its content, at `alignment` in the canvas.
    fileprivate func pinned(_ alignment: Alignment) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

/// A canvas request's content (note, comments, legend, link, labels, markers and stickers,
/// an audio recording) as the Mac's popovers show it, for a host that presents it itself
/// (the iPad). Image and attachment requests, and playing a recorded note, have no
/// content: the host picks, opens or plays the file.
public struct CanvasRequestView: View {
    let controller: CanvasController
    let request: CanvasRequest
    let close: () -> Void

    public init(controller: CanvasController, request: CanvasRequest, close: @escaping () -> Void) {
        self.controller = controller
        self.request = request
        self.close = close
    }

    /// The popover's size, or nil when the request has no content to show.
    @MainActor
    public static func size(_ r: CanvasRequest, controller: CanvasController) -> CGSize? {
        switch r {
        case .note: CGSize(width: 380, height: 320)
        case .comments: CGSize(width: 380, height: 440)
        case .legend: CGSize(width: 380, height: 460)
        case .link: CGSize(width: 380, height: 420)
        case .labels: CGSize(width: 320, height: 300)
        case .markers, .stickers: CGSize(width: 340, height: 420)
        case .audio(let id): controller.canvas.nodes[id]?.audio == nil ? CGSize(width: 300, height: 170) : nil
        case .image, .attachment: nil
        }
    }

    public var body: some View {
        switch request {
        case .note(let id): NotePopover(controller: controller, node: id, close: close)
        case .comments(let id): CommentsPopover(controller: controller, node: id, close: close)
        case .legend: LegendPopover(controller: controller, close: close)
        case .link(let id): LinkPopover(controller: controller, node: id, close: close)
        case .labels(let id): LabelPopover(controller: controller, node: id, close: close)
        case .markers(let id), .stickers(let id): MarkerPopover(controller: controller, node: id, close: close)
        case .audio(let id): AudioPopover(controller: controller, node: id, close: close)
        case .image, .attachment: EmptyView()
        }
    }
}
