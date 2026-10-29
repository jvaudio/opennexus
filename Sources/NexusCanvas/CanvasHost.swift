import Foundation

/// A pasteboard type by its uniform type identifier, with the names `NSPasteboard` uses.
public struct PasteboardType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let string = PasteboardType("public.utf8-plain-text")
    public static let png = PasteboardType("public.png")
    public static let tiff = PasteboardType("public.tiff")
    public static let heic = PasteboardType("public.heic")
    public static let pdf = PasteboardType("com.adobe.pdf")
    /// A copied branch or zone, as the canonical JSON of its fragment.
    public static let nexusFragment = PasteboardType("org.opennexus.fragment")
    /// A whole canvas (Copy Canvas).
    public static let nexusCanvas = PasteboardType("org.opennexus.canvas")
    /// Which open document a fragment was copied from (zone paste, D196).
    public static let nexusFragmentSource = PasteboardType("org.opennexus.fragment.source")
}

/// The clipboard as the controller uses it, in `NSPasteboard`'s terms.
@MainActor
public protocol CanvasPasteboard: AnyObject {
    func clearContents()
    func setString(_ string: String, forType type: PasteboardType)
    func setData(_ data: Data, forType type: PasteboardType)
    func string(forType type: PasteboardType) -> String?
    func data(forType type: PasteboardType) -> Data?
    /// Copied files.
    func fileURLs() -> [URL]
}

/// What the controller asks of its platform (M47a). The Mac's host wraps `NSPasteboard`,
/// `NSApp` and `NSWorkspace`; tests and tools use `MemoryCanvasHost`.
@MainActor
public protocol CanvasHost: AnyObject {
    var pasteboard: any CanvasPasteboard { get set }
    /// The system appearance is dark.
    var systemIsDark: Bool { get }
    /// The system asks for more contrast (Increase Contrast).
    var increaseContrast: Bool { get }
    /// The person's full name, else their account name.
    var userName: String { get }
    /// This computer's or device's name, as the person named it.
    var deviceName: String { get }
    /// Has VoiceOver read `text` out, when it's running.
    func announce(_ text: String)
}

/// A pasteboard in memory: one item, as `clearContents()` then `set…` builds it.
@MainActor
public final class MemoryPasteboard: CanvasPasteboard {
    public var items: [PasteboardType: Data] = [:]
    public var files: [URL] = []

    public init() {}

    public func clearContents() {
        items = [:]
        files = []
    }
    public func setString(_ string: String, forType type: PasteboardType) { items[type] = Data(string.utf8) }
    public func setData(_ data: Data, forType type: PasteboardType) { items[type] = data }
    public func string(forType type: PasteboardType) -> String? {
        items[type].map { String(decoding: $0, as: UTF8.self) }
    }
    public func data(forType type: PasteboardType) -> Data? { items[type] }
    public func fileURLs() -> [URL] { files }
}

/// A host with nothing behind it: a memory pasteboard, light appearance, fixed names, and
/// announcements kept in a list.
@MainActor
public final class MemoryCanvasHost: CanvasHost {
    public var pasteboard: any CanvasPasteboard = MemoryPasteboard()
    public var systemIsDark = false
    public var increaseContrast = false
    public var userName = "Test User"
    public var deviceName = "Test Device"
    public private(set) var announcements: [String] = []

    public init() {}

    public func announce(_ text: String) { announcements.append(text) }
}

/// The platform's own host: the Mac's, or a memory one where there's none yet.
@MainActor
public enum CanvasHosts {
    public static func platform() -> any CanvasHost {
        #if os(macOS)
        MacCanvasHost()
        #else
        MemoryCanvasHost()
        #endif
    }
}
