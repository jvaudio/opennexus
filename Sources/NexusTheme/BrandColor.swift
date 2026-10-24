import Foundation

/// The Aperture brand colours (brand/BRAND.md §2), the same values as the app catalog's
/// `Colors/Brand*.colorset`s: one light and one dark value each. The app-icon palette, used
/// on the Iris tile, is `appIcon`.
public struct BrandColor: Hashable, Sendable {
    public let light: RGBA
    public let dark: RGBA

    public init(light: String, dark: String) {
        self.light = RGBA(hex: light)
        self.dark = RGBA(hex: dark)
    }

    public func resolved(dark isDark: Bool) -> RGBA { isDark ? dark : light }

    /// The ring: Iris (Select and Edit).
    public static let ring = BrandColor(light: "#5850EC", dark: "#8F89FF")
    /// The root node.
    public static let root = BrandColor(light: "#17171C", dark: "#F5F5F7")
    /// The upper branch and node: Aurora (on-device AI).
    public static let upper = BrandColor(light: "#0F9F9A", dark: "#3FD3C9")
    /// The lower branch and node: Amber (Connect).
    public static let lower = BrandColor(light: "#E0A100", dark: "#F2B135")
    /// The wordmark's "Open" and "Nexus".
    public static let wordOpen = BrandColor(light: "#6B6B76", dark: "#8A8A96")
    public static let wordNexus = BrandColor(light: "#17171C", dark: "#F5F5F7")
    /// The app icon's Iris tile, top and bottom of its 155° gradient.
    public static let iconTop = BrandColor(light: "#6E67F6", dark: "#6E67F6")
    public static let iconBottom = BrandColor(light: "#4C43DB", dark: "#4C43DB")

    /// The mark's colours on the Iris tile (the app icon).
    public enum AppIcon {
        public static let ring = RGBA(hex: "#FFFFFF")
        public static let root = RGBA(hex: "#FFFFFF")
        public static let upper = RGBA(hex: "#8CF0E6")
        public static let lower = RGBA(hex: "#FFD27A")
    }

    /// The dark appearance's graphite tile, top to bottom.
    public static let darkTile = (top: RGBA(hex: "#2A2B33"), bottom: RGBA(hex: "#121317"))

    /// Every catalog colour by its colour-set name (`Colors/<name>.colorset`).
    public static let catalog: [String: BrandColor] = [
        "BrandRing": ring, "BrandRoot": root, "BrandUpper": upper, "BrandLower": lower,
        "BrandWordOpen": wordOpen, "BrandWordNexus": wordNexus, "BrandIconTop": iconTop,
        "BrandIconBottom": iconBottom,
    ]
}
