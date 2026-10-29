import AppKit
import CoreText
import NexusCanvas
import NexusTheme
import Testing

@testable import NexusScene

/// Fonts built with CoreText are AppKit's own (M47a, A6).
@Suite struct FontTests {
    static let sizes: [CGFloat] = [12, 14, 16, 20, 26]
    static let families = ["system", "serif", "rounded", "mono", "hand"]

    static func appKitWeight(_ w: FontWeight) -> NSFont.Weight {
        switch w {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    /// What the Mac built before M47a: `systemFont`, `monospacedSystemFont`, `withDesign`,
    /// Noteworthy by name and NSFontManager's italic.
    static func appKit(_ family: String, _ size: CGFloat, _ w: FontWeight, italic: Bool) -> CTFont {
        var f: NSFont
        switch family {
        case "mono": f = .monospacedSystemFont(ofSize: size, weight: appKitWeight(w))
        case "serif", "rounded":
            let base = NSFont.systemFont(ofSize: size, weight: appKitWeight(w))
            let design: NSFontDescriptor.SystemDesign = family == "serif" ? .serif : .rounded
            f = base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case "hand":
            f = NSFont(
                name: w.rawValue >= FontWeight.semibold.rawValue ? "Noteworthy-Bold" : "Noteworthy-Light", size: size)!
        default: f = .systemFont(ofSize: size, weight: appKitWeight(w))
        }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f as CTFont
    }

    /// The same face from NexusScene, on CoreText alone.
    static func coreText(_ family: String, _ size: CGFloat, _ w: FontWeight, italic: Bool) -> CTFont {
        var f: CTFont =
            switch family {
            case "mono": Fonts.mono(size, w)
            case "serif": Fonts.system(size, w, design: .serif)
            case "rounded": Fonts.system(size, w, design: .rounded)
            case "hand":
                Fonts.named(
                    w.rawValue >= FontWeight.semibold.rawValue ? "Noteworthy-Bold" : "Noteworthy-Light", size: size)!
            default: Fonts.system(size, w)
            }
        if italic { f = CoreTextGraphics.shared.font(f, adding: .traitItalic) }
        return f
    }

    static func describe(_ f: CTFont) -> String {
        let v = (CTFontCopyVariation(f) as? [NSNumber: NSNumber] ?? [:]).sorted { $0.key.intValue < $1.key.intValue }
        return
            "\(CTFontCopyPostScriptName(f)) \(CTFontGetSize(f)) \(v) a=\(CTFontGetAscent(f)) d=\(CTFontGetDescent(f)) l=\(CTFontGetLeading(f))"
    }

    @Test func everyStyleBuildsAppKitsFace() {
        var checked = 0
        for size in Self.sizes {
            for w in FontWeight.allCases {
                for family in Self.families {
                    for italic in [false, true] {
                        let a = Self.appKit(family, size, w, italic: italic)
                        let b = Self.coreText(family, size, w, italic: italic)
                        #expect(Self.describe(a) == Self.describe(b), "\(family) \(size) \(w) italic=\(italic)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 250)
    }

    @Test func lineHeightIsTextKits() {
        let layout = NSLayoutManager()
        for size in stride(from: 8.0, through: 72, by: 1) {
            for w in [FontWeight.regular, .semibold, .heavy] {
                for f in [Fonts.system(size, w), Fonts.mono(size, w), Fonts.system(size, w, design: .serif)] {
                    #expect(Fonts.lineHeight(f) == layout.defaultLineHeight(for: f as NSFont), "\(Self.describe(f))")
                }
            }
        }
    }

    @Test func metricsAreAppKits() {
        for f in [Fonts.system(14), Fonts.mono(11, .bold), Fonts.system(20, .heavy, design: .rounded)] {
            let ns = f as NSFont
            let m = Fonts.metrics(f)
            #expect(m.ascender == ns.ascender)
            #expect(m.descender == ns.descender)
            #expect(m.leading == ns.leading)
        }
    }

    /// The CoreText engine's family match is a fallback; the Mac asks NSFontManager. How
    /// often they agree over the installed families is recorded in M47a.md.
    @Test func familyMatchMostlyAgreesWithNSFontManager() {
        var same = 0
        var total = 0
        for family in NSFontManager.shared.availableFontFamilies {
            for weight in [5, 6, 8, 9, 11] {
                guard let a = NSFontManager.shared.font(withFamily: family, traits: [], weight: weight, size: 14) else {
                    continue
                }
                total += 1
                if let b = Fonts.coreTextFamily(family, weight: weight, size: 14),
                    CTFontCopyPostScriptName(b) == CTFontCopyPostScriptName(a as CTFont)
                {
                    same += 1
                }
            }
        }
        print("NexusSceneTests: CoreText's family match agrees with NSFontManager on \(same) of \(total)")
        #expect(total > 0)
        #expect(Double(same) / Double(total) > 0.9)
    }

    @Test func cascadeKeepsTheFaceAndAddsTheFallback() {
        let f = Fonts.cascading(Fonts.system(14), to: "PingFang SC")
        #expect(CTFontCopyPostScriptName(f) == CTFontCopyPostScriptName(Fonts.system(14)))
        let list =
            CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(f), kCTFontCascadeListAttribute)
            as? [CTFontDescriptor]
        #expect(
            list?.first.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
                == "PingFang SC")
    }

    @Test func topicFontsAreTheSystemFaces() {
        var style = NodeTextStyle(typography: .for(.main), monospaced: false)
        #expect(CTFontCopyPostScriptName(style.font) == CTFontCopyPostScriptName(Fonts.system(15, .medium)))
        style.family = "serif"
        style.fontSize = 17
        #expect(
            CTFontCopyPostScriptName(style.font) == CTFontCopyPostScriptName(Fonts.system(17, .medium, design: .serif)))
    }
}
