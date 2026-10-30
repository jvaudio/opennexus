#if os(iOS)
import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import NexusTheme
import QuickLook
import SwiftUI
import UIKit

/// An open document on the iPad (M47b): the canvas tabs, the toolbar (view mode, Format
/// inspector, share, collaborate, AI, Settings), the canvas with its floating chrome and
/// the AI panel beside it, and the request popovers. ZEN and Present hide the chrome;
/// presenting with a second display shows the presenter view here.
///
/// At compact width (the iPhone, M47c) the Outline comes first with a toggle to the
/// canvas, the title is a menu of the canvases, a bottom toolbar adds topics and holds
/// Style and More, and what floats beside the canvas on the iPad comes up as sheets.
public struct TouchDocumentScreen: View {
    @Bindable var model: TouchDocumentModel
    let library: TouchLibrary
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var display = ExternalDisplay.shared
    @State private var password = ""
    @State private var remember = true
    @State private var passwordFailed = false

    public init(model: TouchDocumentModel, library: TouchLibrary = .shared) {
        self.model = model
        self.library = library
    }

    var controller: CanvasController { model.controller }
    var compact: Bool { sizeClass == .compact }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.immersive && !compact {
                    CanvasTabStrip(model: model)
                    Divider()
                }
                content
            }
            .toolbar(model.immersive ? .hidden : .visible, for: .navigationBar)
            .toolbar(compact && !model.immersive ? .visible : .hidden, for: .bottomBar)
            .toolbar {
                if compact {
                    compactToolbar
                } else {
                    toolbar
                }
            }
            .navigationTitle(model.title)
            // The iPhone's title is the canvases' menu, the canvas's name under it: the
            // system's title, which follows Dynamic Type as text in the bar can't (D415).
            .navigationSubtitle(compact && controller.store.model.canvasOrder.count > 1 ? model.canvasName : "")
            .toolbarTitleMenu {
                if compact { CanvasTitleMenu(model: model) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .inspector(isPresented: $model.inspectorVisible) {
                FormatPanel(controller: controller)
                    .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
                    .presentationDetents([.medium, .large])
                    .accessibilityLabel(Loc.t("Format panel"))
            }
        }
        .onChange(of: compact, initial: true) { _, on in model.setCompact(on) }
        .sheet(item: Binding(get: { compact ? model.request : nil }, set: { if $0 == nil { model.closeRequest() } })) {
            r in
            CanvasRequestView(controller: controller, request: r.request) { model.closeRequest() }
                .presentationDetents([.medium, .large])
                .environment(\.colorScheme, controller.theme.isDark ? .dark : .light)
        }
        .sheet(isPresented: compactPanel) {
            CanvasTrailingPanel(controller: controller)
                .presentationDetents([.medium, .large])
        }
        .statusBarHidden(model.immersive)
        .persistentSystemOverlays(model.immersive ? .hidden : .automatic)
        .fullScreenCover(item: $model.settingsPane) { req in
            SettingsSheet(request: req, library: library) { model.settingsPane = nil }
        }
        .sheet(isPresented: $model.choosingStarter) { starterSheet }
        .fullScreenCover(isPresented: $model.scanning) {
            DocumentScanner { pdf in
                model.scanning = false
                if let pdf { controller.importImage(pdf, name: Loc.t("Scan") + ".pdf") }
            }
            .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { model.quickLook.map(PreviewItem.init) }, set: { model.quickLook = $0?.url })) {
            QuickLookView(url: $0.url).ignoresSafeArea()
        }
        .sheet(
            isPresented: Binding(
                get: { model.presenterVisible && !display.connected }, set: { model.presenterVisible = $0 })
        ) {
            PresenterView(controller: controller)
        }
        .alert(
            Loc.t("Rename Canvas"),
            isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
        ) {
            TextField(Loc.t("Canvas name"), text: $model.renameText)
            Button(Loc.t("Rename")) { model.rename() }
            Button(Loc.t("Cancel"), role: .cancel) { model.renaming = nil }
        }
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { model.confirmingDelete != nil }, set: { if !$0 { model.confirmingDelete = nil } })
        ) {
            Button(Loc.t("Delete"), role: .destructive) { model.confirmDelete() }
            Button(Loc.t("Cancel"), role: .cancel) { model.confirmingDelete = nil }
        } message: {
            Text("You can undo this.")
        }
        .alert(passwordTitle, isPresented: $model.needsPassword) {
            SecureField(Loc.t("Password"), text: $password)
            Button(Loc.t("Open")) {
                passwordFailed = !model.unlock(password, remember: remember)
                password = ""
                if passwordFailed { DispatchQueue.main.async { model.needsPassword = true } }
            }
            Button(Loc.t("Close Document"), role: .cancel) { model.close() }
        } message: {
            Text(verbatim: passwordMessage)
        }
        .alert(
            Loc.t("Couldn’t save"),
            isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button(Loc.t("OK"), role: .cancel) { model.error = nil }
        } message: {
            Text(verbatim: model.error ?? "")
        }
        .onChange(of: model.printing?.id) { _, _ in
            if let job = model.printing { print(job) }
        }
        .onChange(of: model.presenting) { _, on in
            display.presenting = on ? model : (display.presenting === model ? nil : display.presenting)
        }
        .onChange(of: display.connected) { _, connected in
            if model.presenting { model.presenterVisible = connected }
        }
    }

    // MARK: Content

    /// Canvas, Outline, Split or Gantt; while presenting on another display, the presenter
    /// view takes the canvas's place here.
    @ViewBuilder var content: some View {
        if model.presenting && display.connected {
            PresenterView(controller: controller)
        } else {
            HStack(spacing: 0) {
                if model.viewMode == .split || model.viewMode == .outline {
                    ViewHost(view: model.outlineView)
                        .frame(maxWidth: model.viewMode == .split ? 420 : .infinity)
                        .accessibilityLabel(Loc.t("Outline"))
                    if model.viewMode == .split { Divider() }
                }
                if model.viewMode == .gantt {
                    ViewHost(view: model.ganttView)
                }
                if model.viewMode == .canvas || model.viewMode == .split {
                    canvas
                }
                if !compact { CanvasTrailingPanel(controller: controller) }
            }
        }
    }

    var canvas: some View {
        ZStack {
            CanvasSlot(model: model, place: .main)
                .ignoresSafeArea(.container, edges: model.immersive ? .all : [])
            CanvasOverlayStack(controller: controller)
        }
        .popover(
            item: Binding(get: { compact ? nil : model.request }, set: { model.request = $0 }),
            attachmentAnchor: .rect(.rect(model.request?.anchor ?? .zero)),
            arrowEdge: .leading
        ) { r in
            CanvasRequestView(controller: controller, request: r.request) { model.closeRequest() }
                .frame(width: r.size.width, height: r.size.height)
                .presentationCompactAdaptation(.popover)
        }
    }

    var starterSheet: some View {
        let gallery = StarterGallery(purpose: .canvas)
        gallery.onCancel = { model.choosingStarter = false }
        gallery.onChoose = { starter in
            model.choosingStarter = false
            controller.addCanvas(from: starter)
        }
        return StarterGalleryView(model: gallery).frame(minWidth: compact ? nil : 700, minHeight: compact ? nil : 560)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.close()
            } label: {
                Label(Loc.t("Documents"), systemImage: "chevron.backward")
            }
            .accessibilityIdentifier("close-document")
        }
        ToolbarItem(placement: .principal) {
            Picker(Loc.t("View"), selection: Binding(get: { model.viewMode }, set: { model.setViewMode($0) })) {
                Label(Loc.t("Canvas"), systemImage: "point.3.connected.trianglepath.dotted").tag(CanvasViewMode.canvas)
                Label(Loc.t("Outline"), systemImage: "list.bullet.indent").tag(CanvasViewMode.outline)
                Label(Loc.t("Split"), systemImage: "rectangle.split.2x1").tag(CanvasViewMode.split)
                Label(Loc.t("Gantt"), systemImage: "chart.bar.xaxis").tag(CanvasViewMode.gantt)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .frame(width: 240)
            .accessibilityIdentifier("view-mode")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.runWindowCommand(.collaborate)
            } label: {
                Label(Loc.t("Collaborate"), systemImage: "person.2")
            }
            Menu {
                ShareMenuItems(model: model)
            } label: {
                Label(Loc.t("Share"), systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("share-menu")
            Button {
                controller.toggleAIPanel()
            } label: {
                Label("AI", systemImage: "sparkles")
            }
            .accessibilityIdentifier("ai-panel")
            Button {
                model.inspectorVisible.toggle()
            } label: {
                Label(Loc.t("Format"), systemImage: "paintbrush")
            }
            .accessibilityIdentifier("inspector")
            Button {
                model.settingsPane = .init(pane: "general")
            } label: {
                Label(Loc.t("Settings"), systemImage: "gearshape")
            }
            .accessibilityIdentifier("settings")
        }
    }

    // MARK: Compact (the iPhone)

    /// The AI panel or the guide, which sit beside the canvas on the iPad.
    var compactPanel: Binding<Bool> {
        Binding(
            get: {
                compact && (controller.aiPanelVisible || controller.guideVisible) && !controller.zen
                    && controller.present == nil
            },
            set: { shown in
                if !shown {
                    controller.aiPanelVisible = false
                    controller.guideVisible = false
                }
            })
    }

    @ToolbarContentBuilder var compactToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.close()
            } label: {
                Label(Loc.t("Documents"), systemImage: "chevron.backward")
            }
            .accessibilityIdentifier("close-document")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Picker(Loc.t("View"), selection: Binding(get: { model.compactMode }, set: { model.setViewMode($0) })) {
                Label(Loc.t("Outline"), systemImage: "list.bullet.indent").tag(CanvasViewMode.outline)
                Label(Loc.t("Canvas"), systemImage: "point.3.connected.trianglepath.dotted").tag(CanvasViewMode.canvas)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .fixedSize()
            .accessibilityIdentifier("view-mode")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                model.addTopic(child: true)
            } label: {
                Label(Loc.t("Add Child"), systemImage: "arrow.turn.down.right")
            }
            .accessibilityIdentifier("add-child")
            Spacer()
            Button {
                model.addTopic(child: false)
            } label: {
                Label(Loc.t("Add Sibling"), systemImage: "arrow.down.to.line")
            }
            .accessibilityIdentifier("add-sibling")
            Spacer()
            Button {
                model.inspectorVisible.toggle()
            } label: {
                Label(Loc.t("Style"), systemImage: "paintbrush")
            }
            .accessibilityIdentifier("inspector")
            Spacer()
            Menu {
                CompactMoreMenu(model: model)
            } label: {
                Label(Loc.t("More"), systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("more-menu")
        }
    }

    // MARK: Prompts

    var deleteTitle: String {
        let t = model.confirmingDelete.flatMap { controller.store.model.canvases[$0]?.title } ?? ""
        return Loc.f("Delete “%@”?", t.isEmpty ? Loc.t("this canvas") : t)
    }

    var passwordTitle: String { Loc.f("“%@” is password-protected", model.title) }

    var passwordMessage: String {
        if passwordFailed { return Loc.t("That password didn’t open it. Try again.") }
        return model.document.passwordHint.map { Loc.f("Hint: %@", $0) } ?? Loc.t("Enter its password to open it.")
    }

    func print(_ job: TouchDocumentModel.PrintJob) {
        let p = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = job.name
        info.outputType = .general
        p.printInfo = info
        p.printingItem = job.data
        p.present(animated: true) { _, _, _ in
            MainActor.assumeIsolated { model.printing = nil }
        }
    }
}

// MARK: Compact menus

/// The title's menu on the iPhone: the document's canvases, then the tab menu's actions.
struct CanvasTitleMenu: View {
    let model: TouchDocumentModel
    var controller: CanvasController { model.controller }

    var body: some View {
        Section(Loc.t("Canvases")) {
            ForEach(controller.store.model.orderedCanvases, id: \.id) { c in
                Button {
                    model.switchCanvas(to: c.id)
                } label: {
                    if c.id == controller.canvasID {
                        Label(TouchDocumentModel.name(of: c), systemImage: "checkmark")
                    } else {
                        Text(verbatim: TouchDocumentModel.name(of: c))
                    }
                }
            }
        }
        CanvasTabActions(model: model, target: controller.canvasID)
    }
}

/// The bottom toolbar's More on the iPhone: what the iPad's toolbar, share menu and the
/// canvas's modes offer.
struct CompactMoreMenu: View {
    let model: TouchDocumentModel
    var controller: CanvasController { model.controller }

    var body: some View {
        Section {
            Button(Loc.t("Comments"), systemImage: "text.bubble") { model.run(.comment) }
            Button(Loc.t("Note"), systemImage: "note.text") { model.run(.note) }
            Button("AI", systemImage: "sparkles") { controller.toggleAIPanel() }
        }
        Section {
            Button(Loc.t("Present"), systemImage: "play.rectangle") { model.run(.present) }
            Button(Loc.t("Focus"), systemImage: "scope") { model.run(.focusBranch) }
            Button(Loc.t("ZEN"), systemImage: "rectangle.dashed") { model.run(.zen) }
            Button(Loc.t("Find"), systemImage: "magnifyingglass") { model.run(.find) }
            Button(Loc.t("Filter"), systemImage: "line.3.horizontal.decrease") { model.run(.filterBar) }
            Button(Loc.t("Gantt"), systemImage: "chart.bar.xaxis") { model.setViewMode(.gantt) }
            Button(Loc.t("Fit to Screen"), systemImage: "arrow.up.left.and.arrow.down.right") {
                model.run(.fitToWindow)
            }
        }
        Section {
            Button(Loc.t("Collaborate"), systemImage: "person.2") { model.runWindowCommand(.collaborate) }
            Menu(Loc.t("Share"), systemImage: "square.and.arrow.up") { ShareMenuItems(model: model) }
            Button(Loc.t("Settings"), systemImage: "gearshape") { model.settingsPane = .init(pane: "general") }
        }
    }
}

/// The iPad's share menu (and the iPhone's More › Share).
struct ShareMenuItems: View {
    let model: TouchDocumentModel

    var body: some View {
        Button(Loc.t("Export…")) { model.runWindowCommand(.export) }
        Button(Loc.t("Share Link…")) { model.runWindowCommand(.shareLink) }
        Button(Loc.t("Print…")) { model.runWindowCommand(.printDocument) }
        Divider()
        Button(Loc.t("Import…")) { model.runWindowCommand(.importFile) }
        if DocumentScanner.isSupported {
            Button(Loc.t("Scan Document…")) { model.scanning = true }
        }
        Button(Loc.t("Merge Documents…")) { model.runWindowCommand(.mergeDocuments) }
        Button(Loc.t("Recovery Snapshots…")) { model.runWindowCommand(.recoverySnapshots) }
        Button(model.document.isEncrypted ? Loc.t("Change Password…") : Loc.t("Set Password…")) {
            model.runWindowCommand(.setPassword)
        }
        Divider()
        Button(Loc.t("Resolve Conflicts…")) { model.runWindowCommand(.resolveConflicts) }
        Button(Loc.t("Sync History…")) { model.runWindowCommand(.syncHistory) }
        Button(Loc.t("Join Session…")) { model.runWindowCommand(.joinSession) }
    }
}

// MARK: Canvas tabs

/// The canvas tabs (artboard 50) on the iPad: tap to switch, long-press for the tab's
/// menu, + for New Canvas.
struct CanvasTabStrip: View {
    let model: TouchDocumentModel
    var controller: CanvasController { model.controller }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(controller.store.model.orderedCanvases, id: \.id) { c in
                    tab(c)
                }
                Button {
                    model.addCanvas()
                } label: {
                    Image(systemName: "plus").frame(width: 32, height: 32)
                }
                .accessibilityLabel(Loc.t("New Canvas"))
                .accessibilityIdentifier("new-canvas")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 44)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Loc.t("Canvas tabs"))
    }

    func tab(_ c: NexusCore.Canvas) -> some View {
        let selected = c.id == controller.canvasID
        let name = TouchDocumentModel.name(of: c)
        return Button {
            controller.switchCanvas(to: c.id)
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(cgColor: RGBA(hex: DiagramDescriptor[c.type].tint).cgColor))
                    .frame(width: 10, height: 10)
                Text(verbatim: name).lineLimit(1)
                    .font(.chrome(13, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Color.textBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { CanvasTabActions(model: model, target: c.id) }
    }
}

/// A tab's menu: what the Mac's tab menu offers, less Move to New Window (D399).
struct CanvasTabActions: View {
    let model: TouchDocumentModel
    let target: CanvasID
    var controller: CanvasController { model.controller }

    var body: some View {
        Button(Loc.t("New Canvas")) { model.addCanvas() }
        Button(Loc.t("New Canvas from Selected Topic")) { on { controller.newCanvasFromTopic() } }
        Button(Loc.t("Duplicate Canvas")) { on { controller.duplicateCanvas() } }
        Button(Loc.t("Rename…")) { on { model.runWindowCommand(.renameCanvas) } }
        Divider()
        Button(Loc.t("Copy Canvas")) { on { controller.copyCanvas() } }
        Button(Loc.t("Paste Canvas")) { on { controller.pasteCanvas() } }.disabled(!controller.canPasteCanvas)
        Divider()
        Button(Loc.t("Save Canvas as Document…")) { on { controller.saveCanvasAsDocument() } }
        Divider()
        Button(Loc.t("Delete Canvas…"), role: .destructive) { on { model.runWindowCommand(.deleteCanvas) } }
    }

    /// Acts on the tab that was pressed.
    func on(_ body: () -> Void) {
        controller.switchCanvas(to: target)
        body()
    }
}

// MARK: Hosting UIKit views

/// Where the canvas shows: here, or on the external display while presenting there (D398).
public enum CanvasPlace: Sendable { case main, external }

extension TouchDocumentModel {
    var canvasPlace: CanvasPlace { presenting && ExternalDisplay.shared.connected ? .external : .main }
}

/// Hosts the document's one canvas view. The view moves between this screen and the
/// external display (a view lives in one window), so each slot takes it when it's its turn.
struct CanvasSlot: UIViewRepresentable {
    let model: TouchDocumentModel
    let place: CanvasPlace

    func makeUIView(context: Context) -> SlotView { SlotView() }

    func updateUIView(_ slot: SlotView, context: Context) {
        let canvas = model.canvasView
        guard model.canvasPlace == place, canvas.superview !== slot else { return }
        canvas.removeFromSuperview()
        canvas.frame = slot.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        slot.addSubview(canvas)
        DispatchQueue.main.async { canvas.takeKeyboard() }
    }

    final class SlotView: UIView {}
}

/// Hosts the outline or the Gantt.
struct ViewHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: Sheets

/// Settings on the iPad: the Mac's panes over the whole screen. A sheet would show the
/// window behind at its sides and cut its rows off at its rounded bottom (D407).
struct SettingsSheet: View {
    let request: TouchDocumentModel.SettingsRequest
    let library: TouchLibrary
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SettingsView(
                availability: library.aiAvailability(), pane: request.pane, record: request.record,
                onAction: library.settingsAction
            )
            .navigationTitle(Loc.t("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The system's checkmark: a bar button's title stops growing at the larger
                // text sizes, which the audit reports (D408).
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: done) { Label(Loc.t("Done"), systemImage: "checkmark") }.labelStyle(.iconOnly)
                }
            }
        }
    }
}

struct PreviewItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Quick Look for attachments.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
