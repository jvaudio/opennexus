import AppKit
import NexusCanvas
import NexusKeys

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(registry: .standard, profile: .openNexus)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}

/// The menu bar, generated from the command registry so every command (and its
/// current key) is listed once, and macOS Help search finds them all.
enum MainMenu {
    static func build(registry: CommandRegistry, profile: KeyProfile) -> NSMenu {
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
                    item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command]))
            }
            main.addItem(submenu(m))
        }
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("OpenNexus Help", #selector(NSApplication.showHelp(_:)), "?"))
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
        let m = NSMenu(title: "OpenNexus")
        m.addItem(item("About OpenNexus", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        m.addItem(.separator())
        m.addItem(item("Settings…", nil, ","))
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        m.addItem(submenu(services))
        NSApp.servicesMenu = services
        m.addItem(.separator())
        m.addItem(item("Hide OpenNexus", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        m.addItem(.separator())
        m.addItem(item("Quit OpenNexus", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu(_ r: CommandRegistry, _ p: KeyProfile) -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        m.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), ""))
        m.addItem(submenu(recent))
        m.addItem(.separator())
        m.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(item("Save…", #selector(NSDocument.save(_:)), "s"))
        m.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        m.addItem(item("Rename…", #selector(NSDocument.rename(_:)), ""))
        m.addItem(item("Move To…", #selector(NSDocument.move(_:)), ""))
        m.addItem(item("Revert To Last Saved", #selector(NSDocument.revertToSaved(_:)), ""))
        m.addItem(item("Browse All Versions…", #selector(NSDocument.browseVersions(_:)), ""))
        m.addItem(.separator())
        addRegistryItems(r, p, .file, to: m)
        return m
    }

    private static func editMenu(_ r: CommandRegistry, _ p: KeyProfile) -> NSMenu {
        let m = NSMenu(title: "Edit")
        addRegistryItems(r, p, .edit, to: m, only: [.undo, .redo])
        m.addItem(.separator())
        m.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        m.addItem(.separator())
        addRegistryItems(r, p, .edit, to: m, excluding: [.undo, .redo])
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
            ("structure.", "Branch Structure"), ("marker.priority", "Priority"), ("style.quick", "Quick Style"),
            ("view.navigationTab", "Navigation Panel"),
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
        let mi = NSMenuItem(title: c.title, action: action, keyEquivalent: "")
        mi.representedObject = c.id.rawValue
        if let chord = r.primaryBinding(for: c.id, profile: p) {
            mi.keyEquivalent = chord.key.keyEquivalent
            mi.keyEquivalentModifierMask = chord.menuModifierMask
        }
        if !c.note.isEmpty { mi.toolTip = c.note }
        return mi
    }
}
