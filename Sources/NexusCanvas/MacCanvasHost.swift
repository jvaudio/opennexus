#if os(macOS)
import AppKit

/// The Mac's `CanvasHost`: the general pasteboard, NSApp's appearance, NSWorkspace's
/// accessibility settings and VoiceOver. Making one installs TextKit as the text engine.
@MainActor
public final class MacCanvasHost: CanvasHost {
    public var pasteboard: any CanvasPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        AppKitGraphics.install()
        self.pasteboard = MacPasteboard(pasteboard)
    }

    public var systemIsDark: Bool { NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    public var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    public var userName: String {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    public var deviceName: String { Host.current().localizedName ?? "Mac" }

    public func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = NSApp.keyWindow else { return }
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// An `NSPasteboard` as a `CanvasPasteboard`.
@MainActor
public final class MacPasteboard: CanvasPasteboard {
    public let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    public func clearContents() { pasteboard.clearContents() }
    public func setString(_ string: String, forType type: PasteboardType) {
        pasteboard.setString(string, forType: .init(type.rawValue))
    }
    public func setData(_ data: Data, forType type: PasteboardType) {
        pasteboard.setData(data, forType: .init(type.rawValue))
    }
    public func string(forType type: PasteboardType) -> String? { pasteboard.string(forType: .init(type.rawValue)) }
    public func data(forType type: PasteboardType) -> Data? { pasteboard.data(forType: .init(type.rawValue)) }
    public func fileURLs() -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

extension NSPasteboard.PasteboardType {
    /// The canvas's own pasteboard types, for AppKit's drag and drop.
    public static let nexusFragment = NSPasteboard.PasteboardType(PasteboardType.nexusFragment.rawValue)
    public static let nexusCanvas = NSPasteboard.PasteboardType(PasteboardType.nexusCanvas.rawValue)
    public static let nexusFragmentSource = NSPasteboard.PasteboardType(PasteboardType.nexusFragmentSource.rawValue)
}

extension CodeLinks {
    /// Opens `url`, routing code files to the chosen editor. Everything else goes to the
    /// system as before.
    public static func open(_ url: URL, prefs: Preferences, workspace: NSWorkspace = .shared) {
        let editor = prefs.string("integrations.codeLinks")
        guard let t = target(url), editor != "default" else {
            workspace.open(url)
            return
        }
        if let u = editorURL(t, editor: editor), workspace.urlForApplication(toOpen: u) != nil {
            workspace.open(u)
            return
        }
        if let id = bundleIDs[editor], let app = workspace.urlForApplication(withBundleIdentifier: id) {
            workspace.open([t.file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(t.file)
        }
    }
}
#endif
