import AppKit
import Observation
import SwiftUI

/// Dynamic Type for the chrome (M10): Settings, Home, onboarding, sheets, popovers,
/// panels, the status bar and Quick Capture use `Font.chrome(…)`, which scales by
/// `ChromeText.shared.scale`. Reading it inside a view's body registers the view for
/// observation, so every open window re-renders when the size changes. Canvas text has
/// its own setting (Canvas text never smaller than).
@Observable
public final class ChromeText: @unchecked Sendable {
    public static let shared = ChromeText()

    /// 1 at the system's default size (13 pt body text). Clamped so layouts hold.
    public var scale: CGFloat = 1

    public static let range: ClosedRange<CGFloat> = 0.85...1.6

    /// Settings › Accessibility › Follow system text size in chrome: the system's preferred
    /// body size relative to the 13 pt default.
    @MainActor
    public static func apply(followSystem: Bool) {
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        let s = followSystem ? min(max(body / 13, range.lowerBound), range.upperBound) : 1
        if shared.scale != s { shared.scale = s }
    }
}

extension Font {
    /// The system font at `size` × the chrome text scale.
    public static func chrome(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: (size * ChromeText.shared.scale).rounded(.toNearestOrEven), weight: weight, design: design)
    }
}

extension NSFont {
    /// AppKit chrome (tab bar, status chip) at `size` × the chrome text scale.
    public static func chrome(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * ChromeText.shared.scale, weight: weight)
    }
}

/// System controls (menus, pop-up buttons, search fields) follow the chrome text size
/// through their control size.
struct ChromeControls: ViewModifier {
    func body(content: Content) -> some View {
        let s = ChromeText.shared.scale
        content.controlSize(s >= 1.45 ? .extraLarge : s >= 1.2 ? .large : .regular)
    }
}

extension View {
    public func chromeControls() -> some View { modifier(ChromeControls()) }
}

extension CGFloat {
    /// A chrome width (sidebars, popovers) that grows with the text, up to 1.3×.
    public static func chromeWidth(_ w: CGFloat) -> CGFloat { w * Swift.min(ChromeText.shared.scale, 1.3) }
}

/// Reduce Motion for the SwiftUI chrome (toasts, the mode chip, the tour coach, panels):
/// Settings › Accessibility › Reduce motion, or the system setting when it says System.
/// The canvas has its own path (`CanvasController.reduceMotionPreference`).
@MainActor
public enum UIMotion {
    public static var reduce: Bool {
        switch Preferences.shared.string("accessibility.reduceMotion") {
        case "on": true
        case "off": false
        default: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    /// `animation`, or none when motion is reduced (changes then happen at once).
    public static func animation(_ a: Animation) -> Animation? { reduce ? nil : a }
}
