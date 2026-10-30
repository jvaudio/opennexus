import CoreGraphics
import NexusScene
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
}

extension ChromeText {
    /// Settings › Accessibility › Follow system text size in chrome: the system's preferred
    /// body size relative to its default (13 pt on the Mac, 17 pt on the iPad).
    @MainActor
    public static func apply(followSystem: Bool) {
        #if os(macOS)
        let ratio = NSFont.preferredFont(forTextStyle: .body).pointSize / 13
        #else
        let ratio = UIFont.preferredFont(forTextStyle: .body).pointSize / 17
        #endif
        let s = followSystem ? min(max(ratio, range.lowerBound), range.upperBound) : 1
        if shared.scale != s { shared.scale = s }
    }
}

extension Font {
    /// The system font at `size` × the chrome text scale. On the iPad it's the body text
    /// style scaled to `size` at the default text size, so it follows Dynamic Type as the
    /// system's own text does (M47b, D400).
    public static func chrome(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        #if os(macOS)
        .system(size: (size * ChromeText.shared.scale).rounded(.toNearestOrEven), weight: weight, design: design)
        #else
        .system(.body, design: design, weight: weight).scaled(by: size / 17)
        #endif
    }
}

#if os(macOS)
extension NSFont {
    /// AppKit chrome (tab bar, status chip) at `size` × the chrome text scale.
    public static func chrome(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * ChromeText.shared.scale, weight: weight)
    }
}
#endif

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

extension View {
    /// A sheet's width: fixed on the Mac; on the iPad, at most that, so a sheet wider than
    /// the screen fits it (M47b, D396).
    public func sheetWidth(_ w: CGFloat) -> some View {
        #if os(macOS)
        frame(width: w)
        #else
        frame(maxWidth: w)
        #endif
    }

    /// A window's smallest size on the Mac; the iPad's screen sets its own (M47b, D396).
    public func windowMinSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }

    /// A button label's area to touch: at least 44 × 44 points on the iPad, around what's
    /// drawn (M47b, D401); the Mac's pointer needs nothing added.
    public func touchTarget() -> some View {
        #if os(macOS)
        self
        #else
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #endif
    }

    /// A drawing made of text views, read as one picture on the iPad, so its labels aren't
    /// read, or audited, as text (M47b, D408).
    public func illustration(_ label: String) -> some View {
        #if os(macOS)
        self
        #else
        // Hidden outright: the audit still reaches the children of an element that ignores them.
        accessibilityHidden(true).overlay {
            Color.clear.accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(.isImage)
        }
        #endif
    }
}

/// The chrome's secondary and tertiary text. On the Mac, the system's `.secondary` and
/// `.tertiary`; on the iPad, greys darker than the system's (lighter in Dark Mode), so
/// small text keeps 4.5:1 against the chrome's backgrounds, which the accessibility audit
/// checks (M47b, D402).
public struct ChromeTextStyle: ShapeStyle {
    let level: Int

    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        #if os(macOS)
        level == 2 ? HierarchicalShapeStyle.tertiary : .secondary
        #else
        Color(uiColor: level == 2 ? .chromeTertiary : .chromeSecondary)
        #endif
    }
}

extension ShapeStyle where Self == ChromeTextStyle {
    public static var chromeSecondary: ChromeTextStyle { ChromeTextStyle(level: 1) }
    public static var chromeTertiary: ChromeTextStyle { ChromeTextStyle(level: 2) }
}

extension Color {
    /// Green and teal for small status text (ready, on-device, a default badge): the
    /// system's on the Mac; on the iPad, darker in light mode so they keep 4.5:1 on the
    /// chrome's backgrounds, which the audit checks (D408).
    public static var statusGreen: Color {
        #if os(macOS)
        .green
        #else
        Color(uiColor: .statusGreen)
        #endif
    }
    public static var statusTeal: Color {
        #if os(macOS)
        .teal
        #else
        Color(uiColor: .statusTeal)
        #endif
    }
    /// The fill behind a badge's white text (Watermark's "Never"): the system's green on the
    /// Mac; on the iPad, light mode's status green in both modes, under which white text
    /// keeps 5.6:1 (D408).
    public static var badgeGreen: Color {
        #if os(macOS)
        .green
        #else
        Color(red: 0, green: 0.47, blue: 0.2)
        #endif
    }
}

#if os(iOS)
extension UIColor {
    /// 5.6:1 on white, 5:1 on the grouped background.
    static let statusGreen = UIColor {
        $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0, green: 0.47, blue: 0.2, alpha: 1)
    }
    /// 5.9:1 on white, 5.1:1 on its badge's tint.
    static let statusTeal = UIColor {
        $0.userInterfaceStyle == .dark ? .systemTeal : UIColor(red: 0, green: 0.44, blue: 0.43, alpha: 1)
    }
    /// 6.4:1 on white, 5.8:1 on the grouped background; 8:1 on Dark Mode's.
    static let chromeSecondary = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.70, alpha: 1) : UIColor(white: 0.36, alpha: 1)
    }
    /// 5:1 on white; 4.8:1 on Dark Mode's raised background.
    static let chromeTertiary = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.60, alpha: 1) : UIColor(white: 0.43, alpha: 1)
    }
}
#endif

/// Reduce Motion for the SwiftUI chrome (toasts, the mode chip, the tour coach, panels):
/// Settings › Accessibility › Reduce motion, or the system setting when it says System.
/// The canvas has its own path (`CanvasController.reduceMotionPreference`).
@MainActor
public enum UIMotion {
    public static var reduce: Bool {
        switch Preferences.shared.string("accessibility.reduceMotion") {
        case "on": true
        case "off": false
        default: systemReduceMotion
        }
    }

    static var systemReduceMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// `animation`, or none when motion is reduced (changes then happen at once).
    public static func animation(_ a: Animation) -> Animation? { reduce ? nil : a }
}

extension View {
    /// A tap target that assistive apps can press too: a button role and a default action
    /// (M10 audit: "Action is missing" for bare tap gestures).
    public func accessibleTap(perform action: @escaping () -> Void) -> some View {
        onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { action() }
    }
}

/// A pop-up menu whose title is its accessibility label. The title view inside a SwiftUI
/// menu is otherwise exposed as a separate element with no action (M10 audit).
public struct LabeledMenu<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            Text(title).accessibilityHidden(true)
        }
        .accessibilityLabel(title)
    }
}
