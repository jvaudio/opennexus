import AppKit
import NexusCanvas
import NexusCore
import NexusKeys
import NexusTheme
import SwiftUI
import UniformTypeIdentifiers

/// The document window (P0 / S3): unified toolbar, canvas tabs, and the canvas.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, RegistryCommandTarget,
    NSMenuItemValidation
{
    let document_: NexusDocument
    let controller: CanvasController
    let host: CanvasHostView

    let panel: NSHostingView<FormatPanel>
    private var panelDivider: NSView?
    private var canvasConstraints: (alone: NSLayoutConstraint, withPanel: NSLayoutConstraint)?
    /// Outline (⌘2) and Split (⌘3), M5.
    let outline: OutlineView
    private var modeConstraints: [CanvasViewMode: [NSLayoutConstraint]] = [:]
    var tabsView: NSView?
    private var tabsHeight: NSLayoutConstraint?
    private var presenterWindow: NSWindow?
    private var chromeBeforeImmersion: (panel: Bool, fullScreen: Bool, mode: CanvasViewMode)?

    init(document: NexusDocument) {
        document_ = document
        controller = CanvasController(store: document.store)
        host = CanvasHostView(controller: controller)
        panel = NSHostingView(rootView: FormatPanel(controller: controller))
        outline = OutlineView(controller: controller)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        window.tabbingMode = Preferences.shared.string("general.openIn") == "windows" ? .disallowed : .preferred
        window.setFrameAutosaveName("OpenNexusDocument")
        super.init(window: window)
        window.delegate = self
        wireDiagramHooks()

        let tabs = NSHostingView(rootView: CanvasTabsView(store: document.store, controller: controller))
        tabs.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(tabs)
        content.addSubview(host)
        outline.translatesAutoresizingMaskIntoConstraints = false
        outline.isHidden = true
        content.addSubview(outline)
        tabsView = tabs
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = !UserDefaults.standard.bool(forKey: "formatPanelVisible")
        content.addSubview(panel)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)
        panelDivider = divider
        divider.isHidden = panel.isHidden
        let canvasTrailing = host.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        let canvasToPanel = host.trailingAnchor.constraint(equalTo: divider.leadingAnchor)
        canvasConstraints = (canvasTrailing, canvasToPanel)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outline.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            outline.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
            panel.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panel.widthAnchor.constraint(equalToConstant: 330),
        ])
        (panel.isHidden ? canvasTrailing : canvasToPanel).isActive = true
        let th = tabs.heightAnchor.constraint(equalToConstant: 40)
        th.isActive = true
        tabsHeight = th
        modeConstraints = [
            .canvas: [
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                outline.widthAnchor.constraint(equalToConstant: 0),
            ],
            .outline: [
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                outline.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ],
            .split: [
                outline.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.39),
                host.leadingAnchor.constraint(equalTo: outline.trailingAnchor, constant: 1),
            ],
        ]
        NSLayoutConstraint.activate(modeConstraints[.canvas]!)
        window.contentView = content

        let toolbar = NSToolbar(identifier: "DocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.viewSwitcher]
        window.toolbar = toolbar

        document.store.addObserver(self) { [weak self] _ in self?.updateSubtitle() }
        updateSubtitle()
        applyWindowPreferences()
        // Settings › Editing › Default zoom.
        if let z = controller.defaultZoom, document.isFreshBlank || document.fileURL == nil {
            DispatchQueue.main.async { [weak self] in self?.host.canvasView.setZoom(z) }
        }
        window.center()
        window.makeFirstResponder(host.canvasView)

        if document.isFreshBlank {
            DispatchQueue.main.async { [controller] in
                controller.beginEditing(replacingWith: "")
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        displayName.hasSuffix(".nexus") ? displayName : displayName + ".nexus"
    }

    /// "16 topics · autosaved" (macOS adds its own "Edited" to the title for unsaved documents).
    func updateSubtitle() {
        let n = controller.canvas.nodes.count
        let topics = "\(n) topic\(n == 1 ? "" : "s")"
        window?.subtitle = document_.fileURL == nil ? topics : "\(topics) · autosaved"
    }

    // MARK: Commands handled at window level

    /// Canvas ⌘1, Outline ⌘2, Split ⌘3: selection is shared, so both panes stay linked.
    func applyViewMode(_ mode: CanvasViewMode) {
        for (_, cs) in modeConstraints { NSLayoutConstraint.deactivate(cs) }
        NSLayoutConstraint.activate(modeConstraints[mode] ?? [])
        outline.isHidden = mode == .canvas
        host.isHidden = mode == .outline
        window?.subtitle = mode == .split ? "Split view" : mode == .outline ? "Outline" : window?.subtitle ?? ""
        if mode == .canvas { updateSubtitle() }
        (window?.toolbar?.items.first { $0.itemIdentifier == .viewSwitcher } as? NSToolbarItemGroup)?.selectedIndex =
            mode == .canvas ? 0 : mode == .outline ? 1 : 2
        window?.layoutIfNeeded()
        if mode == .canvas { window?.makeFirstResponder(host.canvasView) } else { outline.focus() }
    }

    @objc func switchViewMode(_ sender: NSToolbarItemGroup) {
        controller.viewMode = [.canvas, .outline, .split][max(0, min(2, sender.selectedIndex))]
    }

    /// ZEN and Present hide every toolbar and panel (and go full screen).
    func setImmersive(_ on: Bool) {
        guard let window else { return }
        if on {
            if chromeBeforeImmersion == nil {
                chromeBeforeImmersion = (!panel.isHidden, window.styleMask.contains(.fullScreen), controller.viewMode)
            }
            if !panel.isHidden { toggleFormatPanel() }
            if controller.viewMode != .canvas { controller.viewMode = .canvas }
            window.toolbar?.isVisible = false
            tabsHeight?.constant = 0
            tabsView?.isHidden = true
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        } else if let before = chromeBeforeImmersion {
            chromeBeforeImmersion = nil
            window.toolbar?.isVisible = true
            tabsHeight?.constant = 40
            tabsView?.isHidden = false
            if before.panel && panel.isHidden { toggleFormatPanel() }
            if !before.fullScreen && window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            controller.viewMode = before.mode
        }
        window.makeFirstResponder(host.canvasView)
    }

    /// Presenter view: on a second display when there is one.
    func showPresenter(_ on: Bool, force: Bool = false) {
        if !on {
            presenterWindow?.orderOut(nil)
            presenterWindow = nil
            return
        }
        guard presenterWindow == nil, force || NSScreen.screens.count > 1,
            let other = NSScreen.screens.first(where: { $0 != window?.screen }) ?? NSScreen.main
        else { return }
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        w.title = "Presenter View"
        w.contentView = NSHostingView(rootView: PresenterView(controller: controller))
        w.setFrameOrigin(CGPoint(x: other.visibleFrame.midX - 360, y: other.visibleFrame.midY - 260))
        w.level = force ? .floating : .normal
        w.orderFront(nil)
        presenterWindow = w
    }

    /// Export: PDF · PowerPoint · Keynote · Video (artboard 32).
    func exportSlides(_ format: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        let base = controller.canvas.title.isEmpty ? "Slides" : controller.canvas.title
        switch format {
        case "PDF":
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(base).pdf"
        case "Video":
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "\(base).mp4"
        default:
            panel.allowedContentTypes = [UTType(filenameExtension: "pptx") ?? .data]
            panel.nameFieldStringValue = "\(base).pptx"
        }
        let model = document_.store.model
        let canvasID = controller.canvasID
        let titles = controller.slides.filter { !$0.skipped }.map(\.title)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                let images = SlideExporter.renderSlides(model, canvas: canvasID)
                switch format {
                case "PDF": try? SlideExporter.pdf(images).write(to: url, options: .atomic)
                case "Video":
                    Task { @MainActor in
                        do {
                            try await SlideExporter.video(images, to: url)
                            self?.controller.showToast("Video exported")
                        } catch {
                            self?.controller.showToast("Video export failed: \(error.localizedDescription)")
                        }
                    }
                    return
                default: try? SlideExporter.pptx(images, titles: titles).write(to: url, options: .atomic)
                }
                self?.controller.showToast("Exported \(images.count) slides")
            }
        }
    }

    /// DFD drill-down inserts its level canvas undoably; CSV exports go through a save panel.
    private func wireDiagramHooks() {
        controller.onViewMode = { [weak self] m in self?.applyViewMode(m) }
        controller.onOpenAISettings = { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
        controller.externalCommands.insert(.inspector)
        controller.onZen = { [weak self] on in self?.setImmersive(on) }
        host.onPresentChange = { [weak self] on in
            self?.setImmersive(on)
            self?.showPresenter(on)
        }
        controller.onExportSlides = { [weak self] f in self?.exportSlides(f) }
        controller.onTogglePresenter = { [weak self] in
            guard let self else { return }
            self.showPresenter(self.presenterWindow == nil, force: true)
        }
        controller.externalCommands = Self.windowCommands
        controller.onExternalCommand = { [weak self] id in self?.runWindowCommand(id) }
        wireFileHooks()
        controller.onSaveText = { [weak self] name, text in
            guard let window = self?.window else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? text.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }

    @objc func performRegistryCommand(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        runWindowCommand(CommandID(rawValue: raw))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performRegistryCommand(_:)), let raw = item.representedObject as? String {
            let id = CommandID(rawValue: raw)
            if id == .inspector {
                item.state = panel.isHidden ? .off : .on
                // ⌘I is Italic while editing text; the menu item steps aside.
                return controller.mode != .edit
            }
            if id == .pasteCanvas { return controller.canPasteCanvas }
            if id == .setPassword { item.title = document_.cryptoKey == nil ? "Set Password…" : "Change Password…" }
            return Self.windowCommands.contains(id)
        }
        return true
    }

    /// ⌘I: the Format panel slides in on the right only when asked (calm chrome).
    @objc func toggleFormatPanel() {
        let show = panel.isHidden
        panel.isHidden = !show
        panelDivider?.isHidden = !show
        canvasConstraints?.alone.isActive = !show
        canvasConstraints?.withPanel.isActive = show
        UserDefaults.standard.set(show, forKey: "formatPanelVisible")
        window?.makeFirstResponder(host.canvasView)
    }

    func addCanvas() {
        let store = document_.store
        let id = store.model.makeCanvasID()
        store.commitDocument("New Canvas", focus: id) { d in
            var c = NexusCore.Canvas(id: id, title: "Map \(d.canvases.count + 1)")
            CanvasController.applyDefaults(&c, prefs: .shared)
            d.canvases[id] = c
            d.canvasOrder.append(id)
        }
        controller.switchCanvas(to: id)
        controller.beginEditing(replacingWith: "")
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .viewSwitcher, .flexibleSpace, .diagramType, .theme, .aiStatus, .share, .inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case .viewSwitcher:
            let group = NSToolbarItemGroup(
                itemIdentifier: id, titles: ["Canvas", "Outline", "Split"], selectionMode: .selectOne,
                labels: ["Canvas", "Outline", "Split"], target: nil, action: nil)
            group.selectedIndex = 0
            group.target = self
            group.action = #selector(switchViewMode(_:))
            return group
        case .diagramType:
            return hosted(id, label: "Diagram type", DiagramTypeButton(controller: controller))
        case .theme:
            return hosted(id, label: "Theme", ThemeButton(controller: controller))
        case .aiStatus:
            return hosted(id, label: "AI", AIStatusChip(controller: controller))
        case .inspector:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Format"
            item.toolTip = "Format panel (⌘I)"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Format panel")
            item.target = self
            item.action = #selector(toggleFormatPanel)
            return item
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"
            return item
        default:
            return nil
        }
    }

    private func hosted(_ id: NSToolbarItem.Identifier, label: String, _ view: some View) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.view = NSHostingView(rootView: view)
        return item
    }
}

extension NSToolbarItem.Identifier {
    static let viewSwitcher = Self("viewSwitcher")
    static let diagramType = Self("diagramType")
    static let theme = Self("theme")
    static let aiStatus = Self("aiStatus")
    static let share = Self("share")
    static let inspector = Self("inspector")
}

// MARK: Toolbar content

/// "Mind Map ⌥⌘T". M1 switches between the hierarchical structures; M4 adds the
/// converter with live previews.
struct DiagramTypeButton: View {
    var controller: CanvasController

    var body: some View {
        Button {
            controller.openConvert()
        } label: {
            HStack(spacing: 8) {
                Text(controller.canvas.type.displayName)
                Text("⌥⌘T").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help("Convert diagram type (⌥⌘T)")
    }
}

struct ThemeButton: View {
    var controller: CanvasController

    var body: some View {
        Menu(controller.theme.name) {
            ForEach(Theme.builtIn) { t in
                Button(t.name) { controller.setTheme(t.id) }
            }
            let custom = controller.library.themes
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { t in Button(t.name) { controller.setTheme(t.id) } }
            }
        }
        .fixedSize()
    }
}

/// "On-device · Apple": which local model is active. Nothing leaves the Mac.
struct AIStatusChip: View {
    var controller: CanvasController
    /// Aurora ink, light and dark designed together.
    static let ink = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.56, green: 0.91, blue: 0.88, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.43, blue: 0.42, alpha: 1)
    }

    var body: some View {
        let a = controller.aiAvailability
        Button {
            if a.canRun { controller.toggleAIPanel() } else { controller.requestGhosts() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(a.canRun ? Tokens.Signal.auroraLight.swiftUIColor : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(a.chip).foregroundStyle(a.canRun ? Color(nsColor: Self.ink) : .secondary)
            }
        }
        .buttonStyle(.plain)
        .opacity(Preferences.shared.bool(AISettingsKeys.statusChip) ? 1 : 0)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Tokens.Signal.auroraLight.swiftUIColor.opacity(0.1), in: Capsule())
        .accessibilityLabel("AI: \(controller.aiAvailability.chip). Nothing leaves this Mac.")
    }
}

extension RGBA {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// Canvases as tabs along the top (Xmind sheets).
struct CanvasTabsView: View {
    var store: DocumentStore
    var controller: CanvasController

    var body: some View {
        let _ = store.revision
        HStack(spacing: 4) {
            ForEach(store.model.orderedCanvases, id: \.id) { c in
                let on = c.id == controller.canvasID
                Button {
                    controller.switchCanvas(to: c.id)
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(color(for: c.type)).frame(width: 9, height: 9)
                        Text(c.title.isEmpty ? (c.nodes[c.root]?.text ?? "Untitled") : c.title)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(on ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .contextMenu { CanvasTabMenu(controller: controller, target: c.id) }
                .overlay(alignment: .trailing) {
                    if on {
                        Menu {
                            CanvasTabMenu(controller: controller, target: c.id)
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .offset(x: 14)
                        .accessibilityLabel("Canvas menu")
                    }
                }
                .padding(.trailing, on ? 14 : 0)
            }
            Button {
                NSApp.sendAction(
                    #selector(DocumentWindowController.performRegistryCommand(_:)), to: nil,
                    from: Self.newCanvasItem)
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New Canvas (⌘T)")
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    static let newCanvasItem: NSMenuItem = {
        let item = NSMenuItem()
        item.representedObject = CommandID.newCanvas.rawValue
        return item
    }()

    func color(for type: DiagramType) -> Color {
        switch type {
        case .flowchart, .swimlane: RGBA(hex: "#9B51E0").swiftUIColor
        case .threatModel: RGBA(hex: "#D93A3F").swiftUIColor
        case .dfd: RGBA(hex: "#0F9F9A").swiftUIColor
        case .architecture: RGBA(hex: "#1E8BE0").swiftUIColor
        default: Tokens.Signal.irisLight.swiftUIColor
        }
    }
}
