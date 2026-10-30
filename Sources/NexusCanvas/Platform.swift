import NexusKeys
import NexusTheme
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The few AppKit/UIKit types the shared SwiftUI chrome needs (M47b). Mac code paths stay
// as they were; the iPad gets the UIKit equivalent.

#if os(macOS)
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#else
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif

extension Color {
    /// A color from the platform's own color type.
    public init(platform c: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: c)
        #else
        self.init(uiColor: c)
        #endif
    }

    /// The color's sRGB components (a picker's choice, a swatch), or nil when it has none.
    public var srgbComponents: (red: Double, green: Double, blue: Double, alpha: Double)? {
        #if os(macOS)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
        #else
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1), a)
        #endif
    }
}

extension PlatformImage {
    /// An image from a decoded `CGImage` at its pixel size.
    public static func from(_ cg: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        UIImage(cgImage: cg)
        #endif
    }
}

extension Image {
    /// A SwiftUI image from the platform's image type.
    public init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension View {
    /// Esc (⌘. too on the Mac): the Mac's `onExitCommand`; a hardware keyboard's Esc on
    /// the iPad.
    public func onEscape(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) {
            action()
            return .handled
        }
        #endif
    }
}

// MARK: System colors

extension Color {
    /// Text fields, cards and list rows.
    public static var textBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    /// Sheets and windows.
    public static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
    /// Grouped controls (Settings cards, the Format panel's wells).
    public static var controlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
    /// Behind a page (Home, the starter gallery).
    public static var underPageBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
    public static var separatorLine: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
    public static var secondaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .secondaryLabelColor)
        #else
        Color(uiColor: .secondaryLabel)
        #endif
    }
    /// The keyboard focus ring.
    public static var focusIndicator: Color {
        #if os(macOS)
        Color(nsColor: .keyboardFocusIndicatorColor)
        #else
        Color(uiColor: .tintColor)
        #endif
    }
}

// MARK: Opening things

/// Opening URLs, and asking for files or folders, on either platform (M47b). The Mac's
/// open panel runs as a sheet-less panel; the iPad's document picker is presented from the
/// frontmost view controller. Either way `done` gets the chosen URLs (empty on cancel), and
/// on the iPad the caller holds security-scoped access as the Mac's sandbox would grant it.
@MainActor
public enum PlatformOpen {
    public static func url(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Puts `text` on the clipboard.
    public static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// ⇧ is held (a ⇧-click adds a tag to the filter). The iPad has no global query, so a
    /// tap there never combines.
    public static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    #if os(iOS)
    /// The picker's delegate, kept alive until it answers.
    private static var pending: PickerDelegate?

    /// Files of `types` (or a folder when `types` is `[.folder]`).
    public static func choose(
        _ types: [UTType], multiple: Bool = false, done: @escaping @MainActor ([URL]) -> Void
    ) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = multiple
        let d = PickerDelegate { urls in
            pending = nil
            done(urls)
        }
        pending = d
        picker.delegate = d
        guard let top = topViewController() else { return done([]) }
        top.present(picker, animated: true)
    }

    /// Offers `file` to be saved where the person chooses (Files, iCloud Drive, a provider).
    public static func export(_ file: URL, done: @escaping @MainActor (URL?) -> Void = { _ in }) {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        let d = PickerDelegate { urls in
            pending = nil
            done(urls.first)
        }
        pending = d
        picker.delegate = d
        guard let top = topViewController() else { return done(nil) }
        top.present(picker, animated: true)
    }

    /// The view controller showing on top in the foreground scene.
    public static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
    #endif
}

#if os(iOS)
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    let done: @MainActor ([URL]) -> Void
    init(_ done: @escaping @MainActor ([URL]) -> Void) { self.done = done }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
}
#endif

// MARK: Fonts

public enum PlatformFonts {
    /// Installed font families (the Format panel's font menu).
    @MainActor
    public static var families: [String] {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies
        #else
        UIFont.familyNames.sorted()
        #endif
    }
}

// MARK: Control styles

extension View {
    /// A checkbox on the Mac, a switch on the iPad.
    public func checkboxToggle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }

    /// A text link on the Mac; on the iPad, the tint colour with a 44-point area to touch.
    public func linkButton() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(TouchLinkStyle())
        #endif
    }

    /// A menu drawn as its label alone.
    public func borderlessMenu() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        menuStyle(.button).buttonStyle(.borderless)
        #endif
    }
}

#if os(iOS)
/// A text link on the iPad: the tint colour, dimmed while pressed, with a 44-point area to
/// touch around the text (D401).
struct TouchLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .touchTarget()
    }
}
#endif

// MARK: Recording a key (Settings › Shortcuts on the iPad)

#if os(iOS)
/// Takes the hardware keyboard while it's shown and reports each chord.
public struct KeyCatcher: UIViewRepresentable {
    let onChord: @MainActor (KeyChord) -> Void

    public init(_ onChord: @escaping @MainActor (KeyChord) -> Void) { self.onChord = onChord }

    public func makeUIView(context: Context) -> CatcherView { CatcherView() }

    public func updateUIView(_ v: CatcherView, context: Context) {
        v.onChord = onChord
        DispatchQueue.main.async { _ = v.becomeFirstResponder() }
    }

    public final class CatcherView: UIView {
        var onChord: (@MainActor (KeyChord) -> Void)?
        public override var canBecomeFirstResponder: Bool { true }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { _ = becomeFirstResponder() }
        }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let key = presses.first?.key, let chord = KeyChord(key: key) else {
                return super.pressesBegan(presses, with: event)
            }
            onChord?(chord)
        }
    }
}
#endif
