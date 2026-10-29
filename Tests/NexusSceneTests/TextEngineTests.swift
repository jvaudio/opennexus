import AppKit
import CoreText
import Foundation
import NexusCanvas
import NexusTheme
import Testing

@testable import NexusScene

/// The CoreText engine against the Mac's TextKit engine (M47a, A6). TextKit is what the
/// Mac and the iPad measure and draw with; CoreText is the fallback anywhere else, so
/// their agreement is measured and recorded rather than required to be total.
@MainActor
@Suite struct TextEngineTests {
    static let titles: [String] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Titles.json")
        return (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
    }()

    /// The spike's 375 styles: five sizes, weights and families, three wrap widths, every
    /// fourth one italic.
    static let styles: [NodeTextStyle] = {
        var out: [NodeTextStyle] = []
        let weights: [NodeTypography.Weight] = [.regular, .medium, .semibold, .bold, .heavy]
        for size in [12.0, 14, 16, 20, 26] {
            for w in weights {
                for family in ["system", "serif", "rounded", "mono", "hand"] {
                    for maxWidth in [140.0, 220, 320] {
                        var s = NodeTextStyle(typography: .for(.main), monospaced: false)
                        s.fontSize = size
                        s.weight = w
                        s.family = family
                        s.maxWidth = maxWidth
                        s.lineHeight = (size * 1.3).rounded()
                        s.italic = out.count % 4 == 1
                        out.append(s)
                    }
                }
            }
        }
        return out
    }()

    @Test func coreTextAgreesWithTextKitOverTheCorpus() {
        #expect(Self.titles.count == 599)
        #expect(Self.styles.count == 375)
        var same = 0
        var total = 0
        for (i, style) in Self.styles.enumerated() {
            for (j, text) in Self.titles.enumerated() where (i + j) % 9 == 0 {
                total += 1
                let tk = NodeMeasurer.measure(text, style: style, marks: [], engine: AppKitGraphics.shared)
                let ct = NodeMeasurer.measure(text, style: style, marks: [], engine: CoreTextGraphics.shared)
                if tk == ct { same += 1 }
            }
        }
        let share = Double(same) / Double(total)
        print(
            "NexusSceneTests: CoreText measures \(same) of \(total) topics as TextKit does (\(String(format: "%.1f", share * 100))%)"
        )
        #expect(share > 0.93)
    }

    /// One line's width and TextKit's line box (empty text has no attributes to measure).
    @Test func singleLinesMeasureAlike() {
        for text in Self.titles.prefix(200) where !text.isEmpty && !text.contains("\n") {
            for f in [Fonts.system(14), Fonts.system(20, .bold, design: .serif), Fonts.mono(12)] {
                let s = StyledText(text, font: f)
                let tk = AppKitGraphics.shared.size(s)
                let ct = CoreTextGraphics.shared.size(s)
                #expect(abs(tk.width - ct.width) < 0.01, "«\(text)»")
                #expect(abs(tk.height - ct.height) < 0.01, "«\(text)»")
            }
        }
        let mixed = NSMutableAttributedString(string: "Hg", attributes: [TextKey.font: Fonts.system(14)])
        mixed.addAttribute(TextKey.font, value: Fonts.system(30), range: NSRange(location: 1, length: 1))
        let raised = StyledText("Hg", TextAttributes(font: Fonts.system(14), baselineOffset: 4))
        let fixed = StyledText("Hg", TextAttributes(font: Fonts.system(14), paragraph: TextParagraph(lineHeight: 30)))
        for s in [mixed, raised, fixed] {
            #expect(AppKitGraphics.shared.size(s).height == CoreTextGraphics.shared.size(s).height, "\(s)")
        }
    }

    // MARK: Drawing

    /// Where the ink lands, in bitmap rows and columns, when `draw` draws into a 240×120
    /// context, flipped (y down, as layers are) or not.
    static func ink(flipped: Bool, _ draw: (CGContext) -> Void) -> CGRect {
        let w = 240
        let h = 120
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if flipped {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        draw(ctx)
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var box = CGRect.null
        for y in 0..<h {
            for x in 0..<w where p[(y * w + x) * 4 + 3] > 96 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box
    }

    static let sample = StyledText(
        "Hg Ålpha", TextAttributes(font: Fonts.system(24), color: .fixed(CGColor(gray: 0, alpha: 1))))

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        !a.isNull && abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.maxX - b.maxX) <= 1
            && abs(a.maxY - b.maxY) <= 1
    }

    @Test(arguments: [false, true]) func drawAtAPointLandsWhereTextKitsDoes(flipped: Bool) {
        let at = CGPoint(x: 20, y: 40)
        let tk = Self.ink(flipped: flipped) {
            AppKitGraphics.shared.draw(Self.sample, at: at, in: $0, flipped: flipped)
        }
        let ct = Self.ink(flipped: flipped) {
            CoreTextGraphics.shared.draw(Self.sample, at: at, in: $0, flipped: flipped)
        }
        #expect(Self.close(tk, ct), "TextKit \(tk), CoreText \(ct)")
    }

    @Test(arguments: [false, true]) func drawInARectLandsWhereTextKitsDoes(flipped: Bool) {
        let rect = CGRect(x: 20, y: 30, width: 200, height: 60)
        let tk = Self.ink(flipped: flipped) {
            AppKitGraphics.shared.draw(Self.sample, in: rect, context: $0, flipped: flipped)
        }
        let ct = Self.ink(flipped: flipped) {
            CoreTextGraphics.shared.draw(Self.sample, in: rect, context: $0, flipped: flipped)
        }
        #expect(Self.close(tk, ct), "TextKit \(tk), CoreText \(ct)")
    }

    @Test func coreTextResolvesTheMacsLightSystemColours() {
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for c in [SystemColor.label, .secondaryLabel] {
                let mac = AppKitGraphics.shared.color(c).converted(
                    to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
                let ct = CoreTextGraphics.shared.color(c)
                #expect(
                    mac.components!.map { ($0 * 255).rounded() } == ct.components!.map { ($0 * 255).rounded() }, "\(c)")
            }
        }
    }
}
