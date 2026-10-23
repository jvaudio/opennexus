import AppKit
import NexusCore
import NexusKeys

/// A view that shows context menus built from `CanvasMenuEntry`: the canvas, the outline
/// and the Gantt (M17, M26). Commands go through `performRegistryCommand`, so window
/// commands continue up the responder chain; other items through `performMenuAction`.
@MainActor @objc protocol ContextMenuTarget: RegistryCommandTarget {
    func performMenuAction(_ sender: Any?)
}

@MainActor
enum ContextMenus {
    /// Every `ContextMenuTarget` answers these (the canvas's methods name them).
    static let commandSelector = #selector(CanvasView.performRegistryCommand(_:))
    static let actionSelector = #selector(CanvasView.performMenuAction(_:))

    /// Entries as an `NSMenu` whose items target `target` (D173, D174).
    static func make(_ entries: [CanvasMenuEntry], title: String = "", target: any ContextMenuTarget) -> NSMenu {
        let menu = NSMenu(title: title)
        for e in entries {
            switch e {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = make(children, title: title, target: target)
                menu.addItem(item)
            case .item(let i):
                let item: NSMenuItem
                if case .command(let id) = i.action {
                    item = NSMenuItem(
                        title: i.title, action: commandSelector,
                        keyEquivalent: "")
                    item.representedObject = id.rawValue
                } else {
                    item = NSMenuItem(
                        title: i.title, action: actionSelector, keyEquivalent: "")
                    item.representedObject = MenuActionBox(i.action)
                }
                item.target = target
                if let chord = i.key {
                    item.keyEquivalent = chord.key.keyEquivalent
                    item.keyEquivalentModifierMask = chord.menuModifierMask
                }
                item.state = i.checked ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Whether the item being run was chosen with the mouse (it counts towards a key tip,
    /// Settings › General).
    static var chosenWithMouse: Bool {
        guard let t = NSApp.currentEvent?.type else { return false }
        return [.leftMouseUp, .leftMouseDown, .rightMouseUp, .otherMouseUp].contains(t)
    }

    /// Runs a registry item from a row menu (outline, Gantt): here if the controller
    /// handles it, else up the responder chain from `responder`.
    static func performCommand(_ sender: Any?, controller: CanvasController, from responder: NSResponder) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let id = CommandID(rawValue: raw)
        if chosenWithMouse { controller.noteMouseUse(id) }
        if controller.perform(id) { return }
        nextHandler(after: responder)?.performRegistryCommand(sender)
    }

    /// Runs an item that isn't a plain command.
    static func performAction(_ sender: Any?, controller: CanvasController) {
        guard let box = (sender as? NSMenuItem)?.representedObject as? MenuActionBox else { return }
        if let id = box.action.command, chosenWithMouse { controller.noteMouseUse(id) }
        controller.runMenuAction(box.action)
    }

    /// Validates a row menu's item: what the controller can run, else what the window does
    /// (Format Panel, which also sets its checkmark there).
    static func validate(_ item: NSMenuItem, controller: CanvasController, from responder: NSResponder) -> Bool {
        if item.action == commandSelector,
            let raw = item.representedObject as? String
        {
            if controller.canPerform(CommandID(rawValue: raw)) { return true }
            return (nextHandler(after: responder) as? any NSMenuItemValidation)?.validateMenuItem(item) ?? false
        }
        return controller.mode != .connect
    }

    /// The next registry target up the responder chain (the document window).
    static func nextHandler(after responder: NSResponder) -> (any RegistryCommandTarget)? {
        var r = responder.nextResponder
        while let cur = r {
            if let t = cur as? any RegistryCommandTarget { return t }
            r = cur.nextResponder
        }
        return nil
    }
}

/// A row VoiceOver reads in the outline or the Gantt; Show Menu (VO-Shift-M) opens the
/// row's context menu (D226).
@MainActor
final class MenuRowElement: NSAccessibilityElement {
    nonisolated(unsafe) var showMenu: (@MainActor @Sendable () -> Bool)?

    override func accessibilityPerformShowMenu() -> Bool {
        let show = showMenu
        return onMain { show?() ?? false }
    }
}
