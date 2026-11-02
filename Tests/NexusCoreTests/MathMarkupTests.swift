import Foundation
import NexusCore
import Testing

/// Where formulas sit in text (M48): Pandoc's rules for `$…$` and `$$…$$`.
@Suite struct MathMarkupTests {
    func sources(_ text: String) -> [String] {
        MathMarkup.scan(text).formulas.map { ($0.display ? "$$" : "$") + $0.source }
    }

    @Test func inlineFollowsPandocsRules() {
        #expect(sources("Area $\\pi r^2$ here") == ["$\\pi r^2"])
        #expect(sources("$a$ and $b$") == ["$a", "$b"])
        // Prices stay text: a space after the opening dollar, before the closing one, or a
        // digit after it.
        #expect(sources("Costs $5 and $10") == [])
        #expect(sources("$ x$") == [])
        #expect(sources("$x $") == [])
        #expect(sources("$x$5") == [])
        #expect(sources("$x$, then") == ["$x"])
        #expect(sources("one $ alone") == [])
        #expect(sources("$$") == [])
    }

    @Test func displayAndEscapes() {
        #expect(sources("Before $$\\int_0^1 x\\,dx$$ after") == ["$$\\int_0^1 x\\,dx"])
        #expect(sources("$$ x^2 $$") == ["$$x^2"])
        #expect(sources("$$ $$") == [])
        // A `\$` is a dollar sign and never opens or closes a formula.
        let s = MathMarkup.scan("Pay \\$5 for $x\\$y$")
        #expect(s.escapes == [4])
        #expect(s.formulas.map(\.source) == ["x\\$y"])
        #expect(s.formulas.first?.range == NSRange(location: 12, length: 6))
        #expect(!MathMarkup.mayContain("No maths here"))
    }

    @Test func plainTextAndWholeDisplay() {
        #expect(MathMarkup.plain("Area $\\pi r^2$, \\$5") == "Area \\pi r^2, $5")
        #expect(MathMarkup.plain("Nothing") == "Nothing")
        #expect(MathMarkup.wholeDisplay("  $$E = mc^2$$ ") == "E = mc^2")
        #expect(MathMarkup.wholeDisplay("$$a$$ and more") == nil)
        #expect(MathMarkup.wholeDisplay("$a$") == nil)
    }

    @Test func surrogatePairsKeepTheirOffsets() {
        // Ranges are UTF-16, as NSString and the text system count.
        let s = MathMarkup.scan("🙂 $x$")
        #expect(s.formulas.first?.range == NSRange(location: 3, length: 3))
    }
}
