import Foundation

/// A named set of branch colours (FMT-3 › Colour theme). Recolours only.
public struct ColorPalette: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var name: String
    public var colors: [RGBA]
    /// Root colour for custom colour themes (nil: keep the theme's root).
    public var root: RGBA?

    public init(id: String, name: String, colors: [RGBA], root: RGBA? = nil) {
        self.id = id
        self.name = name
        self.colors = colors
        self.root = root
    }

    private static func p(_ id: String, _ name: String, _ hex: [String]) -> ColorPalette {
        ColorPalette(id: id, name: name, colors: hex.map(RGBA.init(hex:)))
    }

    public static let classic = p(
        "classic", "Classic", ["#5850EC", "#E4572E", "#0F9F9A", "#E0A100", "#D6408B", "#1E8BE0"])
    public static let sunset = p(
        "sunset", "Sunset", ["#F94144", "#F3722C", "#F8961E", "#F9C74F", "#90BE6D", "#43AA8B"])
    public static let ocean = p("ocean", "Ocean", ["#03045E", "#0077B6", "#00B4D8", "#48CAE4", "#90E0EF", "#2A9D8F"])
    public static let pastel = p(
        "pastel", "Pastel", ["#F4A6A6", "#F6D6A8", "#A6D9C8", "#A8C8F0", "#B9B4F0", "#E8B4D8"])
    public static let earth = p("earth", "Earth", ["#8C5A3C", "#B5835A", "#3D6B5A", "#7A8B5B", "#B0413E", "#5C4B51"])
    public static let neon = p("neon", "Neon", ["#FF4FD8", "#3DF5FF", "#B6FF3D", "#FFE14D", "#8F89FF", "#FF7A45"])

    public static let builtIn: [ColorPalette] = [.classic, .sunset, .ocean, .pastel, .earth, .neon]

    /// "Generate from one accent": six hues spaced around the accent at its lightness.
    public static func generated(from accent: RGBA, id: String = "generated", name: String = "Generated")
        -> ColorPalette
    {
        let (h, s, l) = accent.hsl
        let colors = (0..<6).map { i in RGBA(h: (h + Double(i) / 6).truncatingRemainder(dividingBy: 1), s: s, l: l) }
        return ColorPalette(id: id, name: name, colors: colors)
    }
}

/// How palette colours are spread over branches.
public enum ColorThemeMode: String, Sendable, CaseIterable {
    /// Each main branch takes the next palette colour.
    case rainbow
    /// Every topic takes a colour by its position among siblings.
    case multi
    /// One colour everywhere.
    case mono
    /// Main branches blend from the first palette colour to the last.
    case gradient

    public var title: String { rawValue.capitalized }
}

extension RGBA {
    var hsl: (Double, Double, Double) {
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    init(h: Double, s: Double, l: Double, a: Double = 1) {
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        if s == 0 {
            self.init(r: l, g: l, b: l, a: a)
            return
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3), a: a)
    }
}
