import AppKit
import NexusCanvas
import NexusCore
import NexusKeys
import NexusTheme
import SwiftUI

/// The document window (P0 / S3): unified toolbar, canvas tabs, and the canvas.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, RegistryCommandTarget,
    NSMenuItemValidation
{
    let document_: NexusDocument
    let controller: CanvasController
    let host: CanvasHostView

    init(document: NexusDocument) {
        document_ = document
        controller = CanvasController(store: document.store)
        host = CanvasHostView(controller: controller)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("OpenNexusDocument")
        super.init(window: window)
        window.delegate = self

        let tabs = NSHostingView(rootView: CanvasTabsView(store: document.store, controller: controller))
        tabs.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(tabs)
        content.addSubview(host)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 40),
            host.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        let toolbar = NSToolbar(identifier: "DocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.viewSwitcher]
        window.toolbar = toolbar

        document.store.addObserver(self) { [weak self] _ in self?.updateSubtitle() }
        updateSubtitle()
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

    func updateSubtitle() {
        let n = controller.canvas.nodes.count
        let edited = document_.isDocumentEdited
        window?.subtitle =
            "\(n) topic\(n == 1 ? "" : "s") · \(edited && document_.fileURL == nil ? "edited" : "autosaved")"
    }

    // MARK: Commands handled at window level

    @objc func performRegistryCommand(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let id = CommandID(rawValue: raw)
        if id == .newCanvas { addCanvas() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performRegistryCommand(_:)), let raw = item.representedObject as? String {
            return CommandID(rawValue: raw) == .newCanvas
        }
        return true
    }

    func addCanvas() {
        let store = document_.store
        let id = store.model.makeCanvasID()
        let canvas = NexusCore.Canvas(id: id, title: "Map \(store.model.canvases.count + 1)")
        insertCanvas(canvas, at: store.model.canvasOrder.count)
        controller.switchCanvas(to: id)
        controller.beginEditing(replacingWith: "")
    }

    private func insertCanvas(_ canvas: NexusCore.Canvas, at index: Int) {
        let store = document_.store
        store.updateDocument {
            $0.canvases[canvas.id] = canvas
            $0.canvasOrder.insert(canvas.id, at: min(index, $0.canvasOrder.count))
        }
        document_.undoManager?.registerUndo(withTarget: self) { wc in
            MainActor.assumeIsolated { wc.removeCanvas(canvas.id) }
        }
        document_.undoManager?.setActionName("New Canvas")
    }

    private func removeCanvas(_ id: CanvasID) {
        let store = document_.store
        guard let canvas = store.model.canvases[id], store.model.canvases.count > 1,
            let index = store.model.canvasOrder.firstIndex(of: id)
        else { return }
        if controller.canvasID == id {
            controller.switchCanvas(to: store.model.canvasOrder.first { $0 != id }!)
        }
        store.updateDocument {
            $0.canvases[id] = nil
            $0.canvasOrder.removeAll { $0 == id }
        }
        document_.undoManager?.registerUndo(withTarget: self) { wc in
            MainActor.assumeIsolated { wc.insertCanvas(canvas, at: index) }
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .viewSwitcher, .flexibleSpace, .diagramType, .theme, .aiStatus, .share]
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
            // Outline and Split arrive in M5.
            for (i, sub) in group.subitems.enumerated() where i > 0 { sub.isEnabled = false }
            return group
        case .diagramType:
            return hosted(id, label: "Diagram type", DiagramTypeButton(controller: controller))
        case .theme:
            return hosted(id, label: "Theme", ThemeButton(controller: controller))
        case .aiStatus:
            return hosted(id, label: "AI", AIStatusChip())
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
}

// MARK: Toolbar content

/// "Mind Map ⌥⌘T". M1 switches between the hierarchical structures; M4 adds the
/// converter with live previews.
struct DiagramTypeButton: View {
    var controller: CanvasController

    var body: some View {
        let structure = controller.canvas.layout.structure
        Menu {
            ForEach(Array(CanvasController.structureCycle.prefix(2).enumerated()), id: \.offset) { i, s in
                Button(name(s)) {
                    controller.select(controller.canvas.root)
                    controller.setStructure(s)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.option, .command])
            }
        } label: {
            HStack(spacing: 8) {
                Text(name(structure))
                Text("⌥⌘T").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    func name(_ s: LayoutStructure) -> String {
        switch s.family {
        case "logic": "Logic Chart"
        case "org": "Org Chart"
        default: controller.canvas.type.displayName
        }
    }
}

struct ThemeButton: View {
    var controller: CanvasController

    var body: some View {
        Menu(controller.theme.name) {
            ForEach(Theme.all) { t in
                Button(t.name) { controller.setTheme(t.id) }
            }
        }
        .fixedSize()
    }
}

/// "On-device · Apple": which local model is active. Nothing leaves the Mac.
struct AIStatusChip: View {
    /// Aurora ink, light and dark designed together.
    static let ink = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.56, green: 0.91, blue: 0.88, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.43, blue: 0.42, alpha: 1)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Tokens.Signal.auroraLight.swiftUIColor).frame(width: 7, height: 7)
            Text("On-device · Apple").foregroundStyle(Color(nsColor: Self.ink))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Tokens.Signal.auroraLight.swiftUIColor.opacity(0.1), in: Capsule())
        .accessibilityLabel("AI: on-device, Apple. Nothing leaves this Mac.")
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
