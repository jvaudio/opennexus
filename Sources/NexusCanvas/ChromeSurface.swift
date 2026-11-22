import SwiftUI

/// The chrome's floating surfaces (hint bar, panels, palette, Present's strip, AI panel,
/// tour, Quick Capture): Liquid Glass or a material, or an opaque surface when Settings
/// turns glass off (Appearance › Liquid Glass chrome) or Reduce Transparency is on, in
/// Settings or, when Settings says System, in the system. Artboard 03: "Reduce
/// Transparency swaps all glass for opaque surface." The window's own bars follow the same
/// settings (the app's `applyWindowPreferences`).
@MainActor
public enum ChromeSurface {
    public static func glass(_ prefs: Preferences, systemReduces: Bool) -> Bool {
        guard prefs.bool("appearance.glass") else { return false }
        switch prefs.string("accessibility.reduceTransparency") {
        case "on": return false
        case "off": return true
        default: return !systemReduces
        }
    }
}

private struct ChromeGlass<S: Shape>: ViewModifier {
    var shape: S
    /// A material instead of Liquid Glass, for the surfaces that used one.
    var material: Bool
    var prefs: Preferences = .shared
    @Environment(\.accessibilityReduceTransparency) private var systemReduces

    func body(content: Content) -> some View {
        let _ = prefs.revision
        if !ChromeSurface.glass(prefs, systemReduces: systemReduces) {
            content
                .background(Color.windowBackground, in: shape)
                .overlay(shape.stroke(.separator))
        } else if material {
            content.background(.regularMaterial, in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// Liquid Glass in `shape`, or an opaque surface (see `ChromeSurface`).
    func chromeGlass(in shape: some Shape) -> some View {
        modifier(ChromeGlass(shape: shape, material: false))
    }

    /// The regular material in `shape`, or an opaque surface (see `ChromeSurface`).
    func chromeMaterial(in shape: some Shape = Rectangle()) -> some View {
        modifier(ChromeGlass(shape: shape, material: true))
    }
}
