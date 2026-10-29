import CoreText
import Foundation

/// System font weights, as AppKit and UIKit name them.
public enum FontWeight: Int, Hashable, Sendable, CaseIterable {
    case regular, medium, semibold, bold, heavy
}

/// The system font's designs.
public enum FontDesign: Hashable, Sendable {
    case `default`, serif, rounded, monospaced
}

/// Fonts built with CoreText. The system faces come from the same UI font descriptors
/// AppKit's `systemFont(ofSize:weight:)`, `monospacedSystemFont` and `withDesign` build
/// (and UIKit's), so they're the same fonts: same face, axes and metrics (NexusSceneTests).
public enum Fonts {
    private static let usageKey = "NSCTFontUIUsageAttribute"

    /// The system font at a weight and design.
    public static func system(_ size: CGFloat, _ weight: FontWeight = .regular, design: FontDesign = .default) -> CTFont
    {
        let names = ["Regular", "Medium", "Semibold", "Bold", "Heavy"]
        let usage: String =
            switch design {
            case .default:
                ["CTFontRegularUsage", "CTFontMediumUsage", "CTFontDemiUsage", "CTFontBoldUsage", "CTFontHeavyUsage"][
                    weight.rawValue]
            case .serif: "CTFontSystemUISerif" + names[weight.rawValue]
            case .rounded: "CTFontSystemUIRounded" + names[weight.rawValue]
            case .monospaced: "CTFontSystemUIMonospaced" + names[weight.rawValue]
            }
        let d = CTFontDescriptorCreateWithAttributes(
            [usageKey as CFString: usage, kCTFontSizeAttribute: size] as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }

    /// The monospaced system font.
    public static func mono(_ size: CGFloat, _ weight: FontWeight = .regular) -> CTFont {
        system(size, weight, design: .monospaced)
    }

    /// A font by PostScript name, if it's installed.
    public static func named(_ name: String, size: CGFloat) -> CTFont? {
        let f = CTFontCreateWithName(name as CFString, size, nil)
        return CTFontCopyPostScriptName(f) as String == name ? f : nil
    }

    /// The member of a family closest to a weight on `NSFontManager`'s 0–15 scale (5 is
    /// regular, 9 bold), from the platform. Nil if the family isn't installed.
    public static func family(_ family: String, weight: Int, size: CGFloat) -> CTFont? {
        Graphics.platform.font(family: family, weight: weight, size: size)
    }

    /// The font with a trait added (bold or italic); the font itself when the family has
    /// no such face (as `NSFontManager.convert(_:toHaveTrait:)` does). From the platform.
    public static func adding(_ trait: CTFontSymbolicTraits, to f: CTFont) -> CTFont {
        Graphics.platform.font(f, adding: trait)
    }

    /// CoreText's pick of a family member, which agrees with NSFontManager's for 96% of the
    /// Mac's family × weight pairs (it differs on condensed-only families and on how close
    /// weights tie).
    static func coreTextFamily(_ family: String, weight: Int, size: CGFloat) -> CTFont? {
        let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        guard
            let members = CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor],
            !members.isEmpty
        else { return nil }
        var best: (CTFontDescriptor, Int, Int)?
        for d in members {
            let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let symbolic = (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0
            if symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0 { continue }
            if symbolic & CTFontSymbolicTraits.traitCondensed.rawValue != 0 { continue }
            if symbolic & CTFontSymbolicTraits.traitExpanded.rawValue != 0 { continue }
            let w = managerWeight((traits[kCTFontWeightTrait] as? Double) ?? 0)
            let distance = abs(w - weight)
            // Ties go to the lighter face, as NSFontManager's do.
            if best == nil || distance < best!.1 || (distance == best!.1 && w < best!.2) { best = (d, distance, w) }
        }
        guard let d = best?.0 else { return nil }
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }

    /// CoreText's normalised weight (-1…1) on NSFontManager's 0–15 scale.
    static func managerWeight(_ w: Double) -> Int {
        switch w {
        case ..<(-0.7): 2
        case ..<(-0.5): 3
        case ..<(-0.2): 4
        case ..<0.1: 5
        case ..<0.27: 6
        case ..<0.35: 8
        case ..<0.5: 9
        case ..<0.6: 10
        default: 12
        }
    }

    /// The font, falling back to a family for scripts it lacks (Chinese, Japanese, Korean).
    public static func cascading(_ f: CTFont, to family: String) -> CTFont {
        let fallback = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let d = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(f), [kCTFontCascadeListAttribute: [fallback]] as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, CTFontGetSize(f), nil)
    }

    /// Ascender (positive), descender (negative) and leading, as AppKit reports them.
    public static func metrics(_ f: CTFont) -> (ascender: CGFloat, descender: CGFloat, leading: CGFloat) {
        (CTFontGetAscent(f), -CTFontGetDescent(f), CTFontGetLeading(f))
    }

    /// TextKit's default line height for the font (`NSLayoutManager.defaultLineHeight`):
    /// its ascent, descent and leading, each rounded.
    public static func lineHeight(_ f: CTFont) -> CGFloat {
        CTFontGetAscent(f).rounded() + CTFontGetDescent(f).rounded() + CTFontGetLeading(f).rounded()
    }
}
