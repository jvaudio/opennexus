import CoreGraphics
import Foundation

/// An sRGB colour with alpha. Themes are data, so colours are plain values.
public struct RGBA: Hashable, Sendable, CustomStringConvertible {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    public init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        if s.count == 8 {
            self.init(
                r: Double((v >> 24) & 255) / 255, g: Double((v >> 16) & 255) / 255,
                b: Double((v >> 8) & 255) / 255, a: Double(v & 255) / 255)
        } else {
            self.init(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255)
        }
    }

    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    public static let white = RGBA(hex: "#FFFFFF")
    public static let black = RGBA(hex: "#000000")

    public func alpha(_ a: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }

    public var hex: String {
        let c = { (v: Double) in String(format: "%02X", Int((v * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b) + (a < 1 ? c(a) : "")
    }

    public var description: String { hex }

    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// This colour drawn over an opaque background.
    public func composited(over bg: RGBA) -> RGBA {
        RGBA(r: r * a + bg.r * (1 - a), g: g * a + bg.g * (1 - a), b: b * a + bg.b * (1 - a), a: 1)
    }

    /// Linear interpolation, used by the morph animations.
    public func mix(_ other: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }
}

extension RGBA: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(hex: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    /// Parses `#RRGGBB`, `#RRGGBBAA`, or nil for anything else.
    public init?(hexString s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#"), t.count == 7 || t.count == 9,
            t.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return nil }
        self.init(hex: t)
    }
}

/// WCAG 2.x contrast.
public enum Contrast {
    public static func relativeLuminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// Contrast ratio between text and its background, compositing translucent
    /// colours over `backdrop` first.
    public static func ratio(_ fg: RGBA, _ bg: RGBA, backdrop: RGBA = .white) -> Double {
        let b = bg.composited(over: backdrop)
        let f = fg.composited(over: b)
        let l1 = relativeLuminance(f)
        let l2 = relativeLuminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    public enum Level: Sendable {
        case aa, aaa
        /// Minimum ratio for normal-size text.
        public var minimum: Double { self == .aa ? 4.5 : 7 }
    }

    public static func passes(_ fg: RGBA, _ bg: RGBA, backdrop: RGBA = .white, level: Level) -> Bool {
        ratio(fg, bg, backdrop: backdrop) >= level.minimum
    }

    /// The colour closest to `fg` that reaches `target` against `bg` (auto contrast:
    /// "text colour auto-adapts to background"). Tones toward ink or white, whichever
    /// direction gains contrast, in small steps.
    public static func adjusted(_ fg: RGBA, on bg: RGBA, backdrop: RGBA = .white, target: Double = 4.5) -> RGBA {
        let b = bg.composited(over: backdrop)
        let f = fg.composited(over: b)
        if ratio(f, b) >= target { return fg.a < 1 ? f : fg }
        let ink = RGBA(hex: "#111114")
        let darkFirst = relativeLuminance(b) > 0.25
        for toward in darkFirst ? [ink, .white] : [.white, ink] {
            var t = 0.05
            while t <= 1.0001 {
                let c = f.mix(toward, t)
                if ratio(c, b) >= target { return c }
                t += 0.05
            }
        }
        return ratio(ink, b) >= ratio(.white, b) ? ink : .white
    }
}
