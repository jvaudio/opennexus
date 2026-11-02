import CoreGraphics
import CoreText
import Foundation
import NexusTheme
import Testing

@testable import NexusScene

/// MathJax in JavaScriptCore (M48): the engine, its SVG read into shapes, and text that
/// holds formulas laid out.
@Suite struct MathEngineTests {
    @Test func typesetsAFormula() throws {
        let r = MathEngine.shared.typeset("\\frac{a}{b} + \\ce{H2O}", display: true)
        let g = try #require(r.glyphs, "\(r)")
        #expect(g.width > 1 && g.ascent > 0.5 && g.depth > 0.3)
        #expect(!g.pieces.isEmpty)
        #expect(MathEngine.shared.version == "4.1.3")
    }

    @Test func reportsErrors() {
        #expect(MathEngine.shared.typeset("\\frac{", display: false) == .error("Missing close brace"))
        #expect(MathEngine.shared.typeset("\\nosuch", display: false) == .error("Undefined control sequence \\nosuch"))
    }

    /// A definition lasts for its own formula, as in KaTeX: one formula's `\def` mustn't
    /// change the next.
    @Test func definitionsStayWithTheirFormula() throws {
        let engine = MathEngine()
        #expect(engine.typeset("\\def\\half{\\frac12}\\half", display: false).glyphs != nil)
        #expect(engine.typeset("\\half", display: false) == .error("Undefined control sequence \\half"))
        #expect(engine.typeset("\\newcommand{\\R}{X}\\R", display: false).glyphs != nil)
        // KaTeX's own \R (ℝ) is back for the next formula.
        let r = try #require(engine.typeset("\\R", display: false).glyphs)
        let x = try #require(engine.typeset("X", display: false).glyphs)
        #expect(r != x)
        #expect(engine.typeset("\\def\\begin{matrix}", display: false).glyphs != nil)
        #expect(engine.typeset("\\begin{matrix}a\\end{matrix}", display: false).glyphs != nil)
    }

    /// Settings › About › Acknowledgements: MathJax's notice and licence travel with the app.
    @Test func acknowledgementsCarryMathJaxsNotice() {
        let text = Acknowledgements.text
        #expect(text.contains("MathJax 4.1.3") && text.contains("The MathJax Consortium"))
        #expect(text.contains("Apache License"))
    }

    @Test func cachesResults() throws {
        let engine = MathEngine()
        let key = MathEngine.Key("x^2", display: false)
        #expect(engine.cached(key) == nil)
        let first = engine.typeset(key)
        #expect(engine.cached(key) == first)
        #expect(engine.result("x^2", display: false) == first)
        engine.clearCache()
        #expect(engine.cached(key) == nil)
        // Display and inline are different results.
        #expect(engine.typeset("\\sum_i", display: true) != engine.typeset("\\sum_i", display: false))
    }

    /// The apps' path: a formula is requested once, typeset in the background, and the
    /// generation moves on when it lands.
    @Test func typesetsInTheBackground() async throws {
        let engine = MathEngine()
        let key = MathEngine.Key("\\sqrt{2}", display: false)
        let before = engine.generation
        engine.request(key)
        engine.request(key)
        // The notice comes on the main thread, which other suites' tests keep busy: wait long.
        for _ in 0..<3000 where engine.generation == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.generation == before + 1)
        #expect(engine.cached(key)?.glyphs != nil)
    }

    @Test func waitingTypesetsOnTheMainThread() async {
        await MainActor.run {
            let was = MathEngine.defersOnMainThread
            MathEngine.defersOnMainThread = true
            defer { MathEngine.defersOnMainThread = was }
            #expect(MathEngine.defers)
            #expect(MathEngine.waiting { MathEngine.defers } == false)
            #expect(MathEngine.defers)
        }
    }

    // MARK: The SVG reader

    @Test func readsTransformsAndColours() throws {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -1000 2000 1500"><g fill="currentColor" stroke="currentColor" stroke-width="0" transform="scale(1,-1)">\
            <g transform="translate(500,0)"><rect x="0" y="0" width="100" height="200"/></g>\
            <g fill="red" stroke="red"><rect x="1000" y="0" width="100" height="100"/></g>\
            <path d="M0 0L10 0L10 10Z" fill="none" stroke-width="20"/></g></svg>
            """
        let g = try #require(MathSVGReader.read(svg))
        #expect(g.width == 2 && g.ascent == 1 && g.depth == 0.5)
        #expect(g.pieces.count == 3)
        // Ems, y down from the baseline: the rect stands on it.
        let first = g.pieces[0].path.boundingBoxOfPath
        #expect(abs(first.minX - 0.5) < 1e-9 && abs(first.minY + 0.2) < 1e-9 && abs(first.height - 0.2) < 1e-9)
        #expect(g.pieces[0].color == nil)
        #expect(g.pieces[1].color == RGBA(r: 1, g: 0, b: 0, a: 1))
        // The path is stroked, not filled.
        #expect(g.pieces[2].stroke.map { abs($0 - 0.02) < 1e-9 } == true)
    }

    /// Table rules take their width from MathJax's style sheet: 70 units, unfilled.
    @Test func drawsTableRules() throws {
        let g = try #require(
            MathEngine.shared.typeset("\\begin{array}{c|c} a & b \\\\ \\hline c & d \\end{array}", display: true).glyphs
        )
        let rules = g.pieces.filter { $0.stroke != nil }
        #expect(rules.count == 2)
        #expect(rules.allSatisfy { abs($0.stroke! - 0.07) < 1e-9 })
        let boxes = rules.map { $0.path.boundingBoxOfPath }
        #expect(boxes.contains { $0.width == 0 && $0.height > 1 })  // the column's
        #expect(boxes.contains { $0.height == 0 && abs($0.width - g.width) < 1e-9 })  // \hline
    }

    @Test func dashesAndRoundStrokesBecomeOutlines() throws {
        let dashed = try #require(
            MathEngine.shared.typeset("\\begin{array}{c:c} a & b \\\\ \\hdashline c & d \\end{array}", display: true)
                .glyphs)
        // Both rules dashed: drawn as filled outlines, in several pieces each.
        #expect(dashed.pieces.allSatisfy { $0.stroke == nil })
        let wide = dashed.pieces.map { $0.path.boundingBoxOfPath }.filter { abs($0.width - dashed.width) < 0.1 }
        #expect(!wide.isEmpty)
        // \phase's angle sets its width in a style attribute, with round caps.
        let phase = try #require(MathEngine.shared.typeset("\\phase{x}", display: false).glyphs)
        let x = try #require(MathEngine.shared.typeset("x", display: false).glyphs)
        #expect(phase.pieces.count == x.pieces.count + 1)
        let angle = try #require(phase.pieces.last)
        #expect(angle.stroke == nil && angle.path.boundingBoxOfPath.width > 0.3)
        // \angl's lines carry their width as attributes, scaled with the subscript.
        let actuarial = try #require(MathEngine.shared.typeset("a_{\\angl n}", display: false).glyphs)
        let lines = actuarial.pieces.compactMap(\.stroke)
        #expect(lines.count == 2 && lines.allSatisfy { abs($0 - 0.067 * 0.707) < 1e-6 })
    }

    /// Characters MathJax's font lacks come back as `<text>`, drawn from the system's fonts.
    @Test func textFallbackDrawsSystemGlyphs() throws {
        let g = try #require(MathEngine.shared.typeset("\\text{漢字}", display: false).glyphs)
        #expect(g.width > 1.5)
        let box = g.pieces.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        #expect(box.width > 1.5 && box.height > 0.5)
    }

    @Test func reflectboxMirrors() throws {
        let plain = try #require(MathEngine.shared.typeset("\\text{R}", display: false).glyphs)
        let mirrored = try #require(MathEngine.shared.typeset("\\reflectbox{R}", display: false).glyphs)
        let a = plain.pieces.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        let b = mirrored.pieces.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        #expect(abs(a.width - b.width) < 1e-6)
        #expect(plain.pieces.map { MathGlyphs.d($0.path) } != mirrored.pieces.map { MathGlyphs.d($0.path) })
    }

    // MARK: Layout

    static var font: CTFont { Fonts.system(14) }
    static func text(_ s: String, width: CGFloat? = nil, centred: Bool = false) -> MathLayout {
        let a = TextAttributes(
            font: font, color: .fixed(CGColor(gray: 0, alpha: 1)),
            paragraph: TextParagraph(alignment: centred ? .center : .left, lineHeight: 20))
        return MathLayout(MathText.styled(s, a), width: width)
    }

    @Test func formulasSitOnTheBaseline() throws {
        let plain = Self.text("Area here")
        let maths = Self.text("Area $x$ here")
        #expect(maths.formulas.count == 1)
        #expect(maths.lines.count == 1)
        let f = try #require(maths.formulas.first)
        #expect(f.origin.y == maths.lines[0].baseline)
        // A small formula keeps the paragraph's line height.
        #expect(maths.size.height == plain.size.height)
        #expect(maths.size.width > plain.size.width)
        // The formula's em matches the words' x-height.
        let x = CTFontGetXHeight(Self.font)
        #expect(abs(f.run.fontSize * MathText.mathXHeight - x) < 0.5)
    }

    @Test func tallFormulasGrowTheirLine() throws {
        let plain = Self.text("Ratio here")
        let tall = Self.text("Ratio $\\frac{\\frac{a}{b}}{\\frac{c}{d}}$ here")
        let f = try #require(tall.formulas.first)
        #expect(tall.size.height > plain.size.height)
        #expect(tall.lines[0].baseline >= f.run.ascent)
        #expect(tall.size.height >= f.run.ascent + f.run.depth)
    }

    @Test func displayFormulasGetACentredLine() throws {
        let layout = Self.text("Before $$x^2 + y^2$$ after", width: 300)
        #expect(layout.lines.count == 3)
        let f = try #require(layout.formulas.first)
        #expect(f.run.display)
        #expect(abs(f.origin.x - (300 - f.run.width) / 2) < 1)
        #expect(layout.lines[0].x == 0)
    }

    @Test func wrapsLikeText() throws {
        let one = Self.text("Words then $a+b$ then more words and $c$ again")
        let wrapped = Self.text("Words then $a+b$ then more words and $c$ again", width: 90)
        #expect(one.lines.count == 1)
        #expect(wrapped.lines.count > 2)
        #expect(wrapped.formulas.count == 2)
        #expect(wrapped.lines.allSatisfy { $0.width <= 90 + 0.5 })
    }

    @Test func escapesAndErrorsShowAsText() {
        let s = MathText.styled(
            "Pay \\$5 or $\\frac{$", TextAttributes(font: Self.font), errorColor: .fixed(CGColor(gray: 0.5, alpha: 1)))
        #expect(s.string == "Pay $5 or $\\frac{$")
        #expect(!MathText.contains(s))
        #expect(MathText.error(in: s) == "Missing close brace")
    }
}
