import CoreText
import Foundation
import Testing

@testable import NexusScene

/// `StyledText` and how the CoreText engine reads it (M47a).
@Suite struct StyledTextTests {
    static let black = CGColor(gray: 0, alpha: 1)

    @Test func attributesUseTheSharedKeys() {
        let f = Fonts.system(13)
        let s = StyledText(
            "Hi",
            TextAttributes(
                font: f, color: .system(.label), paragraph: .centered, baselineOffset: 2, kern: 0.5, underline: true,
                strikethrough: true))
        let a = s.attributes(at: 0, effectiveRange: nil)
        #expect(CFEqual(a[TextKey.font] as CFTypeRef, f))
        #expect(a[TextKey.color] as? String == "label")
        #expect(a[TextKey.paragraph] as? TextParagraph == .centered)
        #expect(a[TextKey.baselineOffset] as? Double == 2)
        #expect(a[TextKey.kern] as? Double == 0.5)
        #expect(a[TextKey.underline] as? Int == 1)
        #expect(a[TextKey.strikethrough] as? Int == 1)
        #expect(TextKey.font.rawValue == "NSFont" && TextKey.link.rawValue == "NSLink", "AppKit's own names")
    }

    @Test func plainTextLeavesOutWhatIsntSet() {
        let a = StyledText("Hi", TextAttributes(font: Fonts.system(13))).attributes(at: 0, effectiveRange: nil)
        #expect(a.count == 1)
    }

    @Test func coloursRoundTrip() {
        if case .system(let c) = TextColorValue(attribute: "secondaryLabel") {
            #expect(c == .secondaryLabel)
        } else {
            Issue.record("a system colour reads back")
        }
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        if case .fixed(let c) = TextColorValue(attribute: red) {
            #expect(c == red)
        } else {
            Issue.record("a fixed colour reads back")
        }
        #expect(TextColorValue(attribute: "nonsense") == nil)
        #expect(TextColorValue(attribute: nil) == nil)
        #expect(TextColorValue.fixed(red).cgColor == red)
    }

    @Test func paragraphsCompareByValue() {
        let a = TextParagraph(alignment: .right, lineBreak: .truncateTail, lineHeight: 18)
        let b = TextParagraph(alignment: .right, lineBreak: .truncateTail, lineHeight: 18)
        #expect(a == b && a.hash == b.hash)
        #expect(a != TextParagraph(alignment: .right, lineBreak: .truncateTail, lineHeight: 19))
        let s1 = StyledText("x", TextAttributes(font: Fonts.system(12), paragraph: a))
        let s2 = StyledText("x", TextAttributes(font: Fonts.system(12), paragraph: b))
        #expect(s1 == s2, "styled texts with equal paragraphs are equal")
    }

    @Test func coreTextGetsItsOwnAttributes() {
        let p = TextParagraph(alignment: .center, lineBreak: .wordWrap, lineHeight: 20)
        let s = NSMutableAttributedString(
            string: "ab",
            attributes: TextAttributes(
                font: Fonts.system(14), color: .fixed(Self.black), paragraph: p,
                baselineOffset: 3
            ).values)
        s.addAttribute(TextKey.color, value: "label", range: NSRange(location: 1, length: 1))
        let ct = CoreTextGraphics.shared.coreTextString(s)
        let a = ct.attributes(at: 0, effectiveRange: nil)
        #expect(a[TextKey.color] == nil && a[TextKey.paragraph] == nil)
        let fg = a[NSAttributedString.Key(kCTForegroundColorAttributeName as String)]
        #expect(fg.map { CFEqual($0 as CFTypeRef, Self.black) } == true)
        #expect(a[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] as? Double == 3)
        let style = a[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)].map { $0 as! CTParagraphStyle }
        var align = CTTextAlignment.left
        var lh: CGFloat = 0
        #expect(
            style.map {
                CTParagraphStyleGetValueForSpecifier($0, .alignment, MemoryLayout<CTTextAlignment>.size, &align)
            } == true)
        #expect(
            style.map { CTParagraphStyleGetValueForSpecifier($0, .maximumLineHeight, MemoryLayout<CGFloat>.size, &lh) }
                == true)
        #expect(align == .center && lh == 20)
        // A system colour resolves through the engine.
        let second = ct.attributes(at: 1, effectiveRange: nil)[
            NSAttributedString.Key(kCTForegroundColorAttributeName as String)]
        #expect(second.map { CFEqual($0 as CFTypeRef, CoreTextGraphics.shared.color(.label)) } == true)
    }

    @Test func textWithoutAFontOrColourGetsTheDefaults() {
        let ct = CoreTextGraphics.shared.coreTextString(NSAttributedString(string: "a"))
        let a = ct.attributes(at: 0, effectiveRange: nil)
        #expect(a[TextKey.font].map { CTFontCopyPostScriptName($0 as! CTFont) as String } == "Helvetica")
        #expect(a[TextKey.font].map { CTFontGetSize($0 as! CTFont) } == 12)
        #expect(a[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] as? Bool == true)
    }

    @Test func fixedLineHeightsStackLines() {
        let p = TextParagraph(lineHeight: 22)
        let s = StyledText("one two three four five six", TextAttributes(font: Fonts.system(14), paragraph: p))
        let r = CoreTextGraphics.shared.boundingRect(
            s, size: CGSize(width: 60, height: 1e6), options: [.lineFragmentOrigin])
        #expect(r.height.truncatingRemainder(dividingBy: 22) == 0 && r.height >= 44)
        #expect(r.width <= 60, "widths are clipped to the wrap width")
    }

    @Test func widthsIncludeTrailingSpaces() {
        let f = Fonts.system(14)
        #expect("a  ".width(in: f) > "a".width(in: f))
    }
}
