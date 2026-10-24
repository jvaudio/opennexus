import AppKit
import Carbon.HIToolbox
import NexusCanvas
import NexusCore
import NexusKeys
import ServiceManagement
import SwiftUI

/// Quick Capture (✦N anywhere, Settings › Integrations): a global hot key, a glass panel
/// that never activates the app, and, with Start at login, a menu bar item.
@MainActor
final class QuickCapture: NSObject, NSMenuDelegate {
    static let shared = QuickCapture()
    let prefs = Preferences.shared
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: CapturePanel?
    private var model: QuickCaptureModel?
    private var statusItem: NSStatusItem?

    /// (Re)applies the settings: the hot key follows Settings › Shortcuts › Quick Capture.
    func start() {
        registerHotKey()
        let atLogin = prefs.bool("integrations.captureAtLogin")
        if atLogin != (SMAppService.mainApp.status == .enabled) {
            if atLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
        if atLogin { showStatusItem() } else { hideStatusItem() }
    }

    /// The chord bound to Quick Capture (✦N unless remapped), as a Carbon hot key. Carbon
    /// hot keys need no Accessibility or Input Monitoring permission.
    func registerHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        var custom = prefs.data("shortcuts.custom").flatMap(KeyCustomization.decode) ?? KeyCustomization()
        custom.profile = prefs.string("shortcuts.profile")
        let registry = custom.apply(to: .standard)
        guard let chord = registry.bindings(for: .quickCapture, custom: custom.custom).first, let code = chord.keyCode
        else { return }
        var mods: UInt32 = 0
        if chord.modifiers.contains(.command) { mods |= UInt32(cmdKey) }
        if chord.modifiers.contains(.option) { mods |= UInt32(optionKey) }
        if chord.modifiers.contains(.control) { mods |= UInt32(controlKey) }
        if chord.modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { QuickCapture.shared.toggle() } }
                    return noErr
                }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4F4E_5843), id: 1)  // "ONXC"
        RegisterEventHotKey(UInt32(code), mods, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        let recents = NSDocumentController.shared.recentDocumentURLs.filter { $0 != Inbox.url }
        let m = QuickCaptureModel(
            targets: CaptureTargets(recents: recents, preferLast: prefs.string("integrations.captureTarget") == "last"))
        m.onSave = { text, target in
            guard
                let r = CaptureComposer.compose(
                    text, multiline: Preferences.shared.string("integrations.captureMultiline"))
            else { return }
            Integrations.shared.add(r, to: target.url ?? Inbox.url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { QuickCapture.shared.close() }
            }
        }
        m.onClose = { QuickCapture.shared.close() }
        model = m
        let p = panel ?? CapturePanel()
        p.contentView = NSHostingView(rootView: QuickCaptureView(model: m).padding(24))
        p.title = Loc.t("Quick Capture")
        p.contentView?.setAccessibilityLabel(Loc.t("Quick Capture"))
        p.setContentSize(p.contentView!.fittingSize)
        // Upper third of the screen the pointer is on, like Spotlight.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(CGPoint(x: f.midX - p.frame.width / 2, y: f.minY + f.height * 0.68))
        }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        model = nil
    }

    // MARK: Menu bar (Start at login)

    func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The Aperture template image, 18 pt, black and alpha only (brand/BRAND.md §5).
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "OpenNexus"
        item.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func hideStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Rebuilt each time it opens, so recent maps are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let capture = menu.addItem(
            withTitle: Loc.t("Quick Capture"), action: #selector(menuCapture), keyEquivalent: "n")
        capture.keyEquivalentModifierMask = [.command, .option, .control, .shift]
        capture.target = self
        menu.addItem(withTitle: Loc.t("Open Inbox Map"), action: #selector(menuInbox), keyEquivalent: "").target = self
        let recents = NSDocumentController.shared.recentDocumentURLs.prefix(5)
        if !recents.isEmpty {
            menu.addItem(.separator())
            for u in recents {
                let i = menu.addItem(
                    withTitle: u.deletingPathExtension().lastPathComponent, action: #selector(menuOpen(_:)),
                    keyEquivalent: "")
                i.representedObject = u
                i.target = self
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: Loc.t("Open OpenNexus"), action: #selector(menuActivate), keyEquivalent: "").target =
            self
        menu.addItem(withTitle: Loc.t("Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
    }

    @objc func menuCapture() { show() }
    @objc func menuInbox() {
        NSApp.activate()
        Integrations.shared.openInbox()
    }
    @objc func menuOpen(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        NSApp.activate()
        Integrations.shared.open(u, canvas: nil, node: nil)
    }
    @objc func menuActivate() {
        NSApp.activate()
        if NSDocumentController.shared.documents.isEmpty { HomeWindow.shared.show() }
    }
    @objc func menuSettings() {
        NSApp.activate()
        AppPreferences.shared.showSettings(pane: "integrations")
    }

    /// True when macOS opened the app at login (it then stays in the menu bar, windowless).
    static var launchedAtLogin: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return e.eventID == kAEOpenApplication
            && e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// A floating panel that takes typing without bringing OpenNexus to the front.
final class CapturePanel: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 140), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }

    /// Clicking elsewhere closes it, like Spotlight.
    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { QuickCapture.shared.close() }
    }
}
