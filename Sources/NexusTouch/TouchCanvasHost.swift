#if os(iOS)
import NexusCanvas
import NexusScene
import UIKit

/// The iPad's `CanvasHost` (M47b): the general pasteboard, the trait collection's
/// appearance and contrast, the device's name and VoiceOver. Making one installs UIKit's
/// text engine.
@MainActor
public final class TouchCanvasHost: CanvasHost {
    public var pasteboard: any CanvasPasteboard

    public init(pasteboard: UIPasteboard = .general) {
        UIKitGraphics.install()
        self.pasteboard = TouchPasteboard(pasteboard)
    }

    /// Makes `CanvasHosts.platform()` hand out iPad hosts (the app does this at launch).
    public static func install() {
        UIKitGraphics.install()
        CanvasHosts.factory = { TouchCanvasHost() }
    }

    var traits: UITraitCollection {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }?.traitCollection
            ?? scenes.first?.traitCollection ?? .current
    }

    public var systemIsDark: Bool { traits.userInterfaceStyle == .dark }
    public var increaseContrast: Bool { UIAccessibility.isDarkerSystemColorsEnabled }

    /// iOS keeps no account name an app can read, so the name people give in Settings ›
    /// Sharing stands in (the collaboration name falls back to this).
    public var userName: String {
        let full = NSFullUserName()
        return full.isEmpty || full == "Mobile User" ? UIDevice.current.name : full
    }

    public var deviceName: String { UIDevice.current.name }

    public func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// `UIPasteboard` as a `CanvasPasteboard`: like `NSPasteboard`, everything set after
/// `clearContents()` is one item with several types.
@MainActor
public final class TouchPasteboard: CanvasPasteboard {
    public let pasteboard: UIPasteboard

    public init(_ pasteboard: UIPasteboard) { self.pasteboard = pasteboard }

    public func clearContents() { pasteboard.items = [] }

    private func set(_ value: Any, _ type: PasteboardType) {
        var item = pasteboard.items.first ?? [:]
        item[type.rawValue] = value
        pasteboard.items = [item]
    }

    public func setString(_ string: String, forType type: PasteboardType) { set(string, type) }
    public func setData(_ data: Data, forType type: PasteboardType) { set(data, type) }

    public func string(forType type: PasteboardType) -> String? {
        if type == .string { return pasteboard.string }
        if let s = pasteboard.value(forPasteboardType: type.rawValue) as? String { return s }
        return pasteboard.data(forPasteboardType: type.rawValue).map { String(decoding: $0, as: UTF8.self) }
    }

    public func data(forType type: PasteboardType) -> Data? {
        if let d = pasteboard.data(forPasteboardType: type.rawValue) { return d }
        return (pasteboard.value(forPasteboardType: type.rawValue) as? String).map { Data($0.utf8) }
    }

    public func fileURLs() -> [URL] { pasteboard.urls?.filter(\.isFileURL) ?? [] }
}
#endif
