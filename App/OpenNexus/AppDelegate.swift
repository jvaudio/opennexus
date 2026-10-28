import AppKit
import NexusAI
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusKeys
import SwiftUI
import UniformTypeIdentifiers

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// ⌘, opens Settings (the AI pane in M6; the rest arrive in M8).
    @objc func showSettings(_ sender: Any?) {
        AppPreferences.shared.showSettings(pane: (sender as? String) ?? "general")
    }

    /// Help › OpenNexus Help opens the README on GitHub in the browser (D140).
    @objc func showOnlineHelp(_ sender: Any?) {
        NSWorkspace.shared.open(ProjectLinks.help)
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Opened by macOS at login (Settings › Quick Capture › Start at login): stay in the
    /// menu bar with no windows.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = QuickCapture.launchedAtLogin
        NSApp.mainMenu = MainMenu.build(registry: .standard, profile: .openNexus)
        AppPreferences.shared.start()
        Integrations.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !launchedAtLogin { Onboarding.launch() }
        Updates.shared.start()
    }

    /// Spotlight results open straight to the topic; Handoff for iCloud documents is
    /// handled by NSDocument (and lands on the topic through restoreUserActivityState).
    func application(
        _ application: NSApplication, continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        Integrations.shared.continueActivity(userActivity)
    }

    /// Settings › General › At launch: a new document only when that's the choice (Home
    /// and the first-run welcome handle the rest).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !launchedAtLogin && Onboarding.done && Preferences.shared.string("general.launch") == "new"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { HomeWindow.shared.show() }
        return false
    }

    @objc func showWelcome(_ sender: Any?) { Onboarding.showWelcome() }
    @objc func showHome(_ sender: Any?) { HomeWindow.shared.show() }
    /// File › New Document from Starter… (⇧⌘N on Home): Home's starter picker (M40).
    @objc func newDocumentChooseType(_ sender: Any?) { HomeWindow.shared.show(choosingStarter: true) }
    /// ⌘N: a new document with the default look (Settings › New documents).
    @objc func newDocument(_ sender: Any?) { NewDocument.make() }

    /// A recovery snapshot opened as an untitled copy (Settings › Files & Backup).
    @MainActor func openSnapshotCopy(_ url: URL, sideBySide: Bool) {
        let s = SnapshotStore.list(documentID: url.deletingLastPathComponent().lastPathComponent).first {
            $0.url == url
        }
        guard let s else { return }
        let key = AppPreferences.shared.frontDocument?.0.cryptoKey
        do {
            let doc = try NexusPackage.read(files: try SnapshotStore.read(s, key: key))
            let nx =
                try NSDocumentController.shared.makeUntitledDocument(ofType: "com.opennexus.document") as! NexusDocument
            nx.store.replace(with: doc)
            nx.markImported()
            NSDocumentController.shared.addDocument(nx)
            nx.makeWindowControllers()
            nx.showWindows()
            if sideBySide, let w = nx.windowControllers.first?.window, let screen = w.screen {
                let f = screen.visibleFrame
                w.setFrame(CGRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height), display: true)
                if let other = AppPreferences.shared.frontDocument?.1.window, other !== w {
                    other.setFrame(CGRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height), display: true)
                }
            }
        } catch {
            let a = NSAlert()
            a.messageText = Loc.t("Couldn’t open the snapshot")
            a.informativeText = String(describing: error)
            a.runModal()
        }
    }

    /// File › Import… (artboard 33): any supported format opens as a new document, followed
    /// by the import report.
    @objc func importDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = DocumentWindowController.importTypes
        panel.message =
            Loc.t(
                "Import .xmind, OPML, Markdown, Mermaid, PlantUML, draw.io, FreeMind, MindManager, MindNode, Word, text, or a picture or PDF to read as a map."
            )
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importFile(url) }
    }

    @MainActor func importFile(_ url: URL) {
        if ImageToMap.isImage(name: url.lastPathComponent) { return importImage(url) }
        do {
            let name = url.lastPathComponent
            var files: [String: Data]?
            var data: Data?
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = NexusPackage.flatten(try FileWrapper(url: url, options: .immediate))
            } else {
                data = try Data(contentsOf: url)
            }
            openImported(try Interchange.importFile(name: name, data: data, files: files))
        } catch {
            importFailed(url.lastPathComponent, error)
        }
    }

    /// Image to mind map (M12): Vision and, when it can run, Apple Intelligence work off the
    /// main thread; the new document opens when they finish. A PDF of several pages, or any
    /// import still running after half a second, shows its progress in a window with Cancel
    /// (D238, D272).
    @MainActor func importImage(_ url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return importFailed(url.lastPathComponent, error)
        }
        let refine = Preferences.shared.bool(ImageToMap.refineKey)
        let progress = ImageImportProgress(name: url.lastPathComponent)
        progress.onShow = { [weak self, weak progress] in
            if let progress { self?.showImportProgress(progress) }
        }
        progress.start(data, refine: refine) { [weak self] outcome in
            guard let self else { return }
            self.importWindows.removeValue(forKey: progress.id)?.close()
            switch outcome {
            case .imported(let im): self.openImported(im)
            case .failed(let error): self.importFailed(url.lastPathComponent, error)
            case .cancelled: break
            }
        }
    }

    /// Image imports showing their progress, by id.
    private var importWindows: [UUID: NSWindow] = [:]

    @MainActor func showImportProgress(_ progress: ImageImportProgress) {
        let w = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 140), styleMask: [.titled],
            backing: .buffered, defer: false)
        w.title = Loc.t("Import")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ImageImportView(progress: progress))
        w.setContentSize(w.contentView?.fittingSize ?? w.frame.size)
        w.center()
        // Several PDFs imported at once cascade.
        let step = CGFloat(importWindows.count) * 24
        w.setFrameTopLeftPoint(CGPoint(x: w.frame.minX + step, y: w.frame.maxY - step))
        w.makeKeyAndOrderFront(nil)
        importWindows[progress.id] = w
    }

    @MainActor func openImported(_ imported: Imported) {
        do {
            let doc = try NSDocumentController.shared.makeUntitledDocument(ofType: "com.opennexus.document")
            guard let nx = doc as? NexusDocument else { return }
            nx.store.replace(with: imported.document)
            nx.markImported()
            NSDocumentController.shared.addDocument(nx)
            nx.makeWindowControllers()
            nx.showWindows()
            if let wc = nx.windowControllers.first as? DocumentWindowController {
                wc.controller.switchCanvas(to: imported.document.canvasOrder.first!)
                wc.controller.showImportReport(imported.report)
            }
        } catch {
            importFailed(imported.report.source, error)
        }
    }

    @MainActor func importFailed(_ name: String, _ error: any Error) {
        let alert = NSAlert()
        alert.messageText = Loc.f("Couldn’t import “%@”", name)
        alert.informativeText = String(describing: error)
        alert.runModal()
    }
}

/// The menu bar, generated from the command registry so every command (and its
/// current key) is listed once, and macOS Help search finds them all.
enum MainMenu {
    /// The user's shortcut changes (Settings › Shortcuts), shown on menu items.
    nonisolated(unsafe) static var custom: [CommandID: [KeyChord]] = [:]

    static func build(registry: CommandRegistry, profile: KeyProfile, custom: [CommandID: [KeyChord]] = [:]) -> NSMenu {
        Self.custom = custom
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(registry, profile)))
        main.addItem(submenu(editMenu(registry, profile)))
        for placement in [MenuPlacement.insert, .topic, .format, .view, .ai] {
            let m = NSMenu(title: placement.rawValue)
            addRegistryItems(registry, profile, placement, to: m)
            if placement == .view {
                m.addItem(.separator())
                m.addItem(
                    item(
                        Loc.t("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])
                )
            }
            main.addItem(submenu(m))
        }
        let window = NSMenu(title: Loc.t("Window"))
        window.addItem(item(Loc.t("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(Loc.t("Zoom"), #selector(NSWindow.performZoom(_:)), ""))
        window.addItem(.separator())
        window.addItem(item(Loc.t("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), ""))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: Loc.t("Help"))
        help.addItem(item(Loc.t("OpenNexus Help"), #selector(AppDelegate.showOnlineHelp(_:)), "?"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String,
        _ mods: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: Loc.t("OpenNexus"))
        m.addItem(item(Loc.t("About OpenNexus"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        let updates = item(Loc.t("Check for Updates…"), #selector(Updates.checkForUpdates(_:)), "")
        updates.target = Updates.shared
        m.addItem(updates)
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        m.addItem(.separator())
        let services = NSMenu(title: Loc.t("Services"))
        m.addItem(submenu(services))
        NSApp.servicesMenu = services
        m.addItem(.separator())
        m.addItem(item(Loc.t("Hide OpenNexus"), #selector(NSApplication.hide(_:)), "h"))
        m.addItem(
            item(Loc.t("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item(Loc.t("Show All"), #selector(NSApplication.unhideAllApplications(_:)), ""))
        m.addItem(.separator())
        m.addItem(item(Loc.t("Quit OpenNexus"), #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu(_ r: CommandRegistry, _ p: KeyProfile) -> NSMenu {
        let m = NSMenu(title: Loc.t("File"))
        m.addItem(item(Loc.t("New"), #selector(AppDelegate.newDocument(_:)), "n"))
        m.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: Loc.t("Open Recent"))
        recent.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recent.addItem(item(Loc.t("Clear Menu"), #selector(NSDocumentController.clearRecentDocuments(_:)), ""))
        m.addItem(submenu(recent))
        m.addItem(.separator())
        m.addItem(item(Loc.t("Close"), #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(item("Save…", #selector(NSDocument.save(_:)), "s"))
        m.addItem(item(Loc.t("Duplicate"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        m.addItem(item("Rename…", #selector(NSDocument.rename(_:)), ""))
        m.addItem(item(Loc.t("Move To…"), #selector(NSDocument.move(_:)), ""))
        m.addItem(item(Loc.t("Revert To Last Saved"), #selector(NSDocument.revertToSaved(_:)), ""))
        m.addItem(item(Loc.t("Browse All Versions…"), #selector(NSDocument.browseVersions(_:)), ""))
        m.addItem(.separator())
        addRegistryItems(r, p, .file, to: m)
        return m
    }

    private static func editMenu(_ r: CommandRegistry, _ p: KeyProfile) -> NSMenu {
        let m = NSMenu(title: Loc.t("Edit"))
        addRegistryItems(r, p, .edit, to: m, only: [.undo, .redo])
        m.addItem(.separator())
        m.addItem(item(Loc.t("Cut"), #selector(NSText.cut(_:)), "x"))
        m.addItem(item(Loc.t("Copy"), #selector(NSText.copy(_:)), "c"))
        m.addItem(item(Loc.t("Paste"), #selector(NSText.paste(_:)), "v"))
        m.addItem(.separator())
        addRegistryItems(r, p, .edit, to: m, excluding: [.undo, .redo, .cut, .copy, .paste])
        return m
    }

    /// Commands grouped by category with separators; numbered families go in submenus.
    static func addRegistryItems(
        _ r: CommandRegistry, _ p: KeyProfile, _ placement: MenuPlacement, to menu: NSMenu,
        only: Set<CommandID>? = nil, excluding: Set<CommandID> = []
    ) {
        let commands = r.commands.filter {
            $0.menu == placement && (only?.contains($0.id) ?? true) && !excluding.contains($0.id)
        }
        let families: [(prefix: String, title: String)] = [
            ("structure.", Loc.t("Branch Structure")), ("marker.priority", Loc.t("Priority")),
            ("style.quick", Loc.t("Quick Style")),
            ("view.navigationTab", Loc.t("Navigation Panel")),
        ]
        var lastCategory: CommandCategory?
        var familyMenus: [String: NSMenu] = [:]
        for c in commands {
            let mi = registryItem(c, r, p)
            if let fam = families.first(where: { c.id.rawValue.hasPrefix($0.prefix) }) {
                if let sub = familyMenus[fam.prefix] {
                    sub.addItem(mi)
                } else {
                    let sub = NSMenu(title: fam.title)
                    sub.addItem(mi)
                    familyMenus[fam.prefix] = sub
                    if let last = lastCategory, last != c.category { menu.addItem(.separator()) }
                    menu.addItem(submenu(sub))
                    lastCategory = c.category
                }
                continue
            }
            if let last = lastCategory, last != c.category { menu.addItem(.separator()) }
            lastCategory = c.category
            menu.addItem(mi)
        }
    }

    static func registryItem(_ c: CommandDescriptor, _ r: CommandRegistry, _ p: KeyProfile) -> NSMenuItem {
        let action: Selector =
            c.standardAction.map(NSSelectorFromString)
            ?? #selector(RegistryCommandTarget.performRegistryCommand(_:))
        let mi = NSMenuItem(title: Loc.t(c.title), action: action, keyEquivalent: "")
        mi.representedObject = c.id.rawValue
        if let chord = r.primaryBinding(for: c.id, profile: p, custom: custom) {
            mi.keyEquivalent = chord.key.keyEquivalent
            mi.keyEquivalentModifierMask = chord.menuModifierMask
        }
        if !c.note.isEmpty { mi.toolTip = c.note }
        return mi
    }
}
