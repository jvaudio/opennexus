import CoreGraphics
import CoreText
import Foundation
import NexusCore
import NexusTheme

extension TextKey {
    /// A typeset formula, on the U+FFFC that stands for it: a `MathRun`.
    public static let math = NSAttributedString.Key("OpenNexusMath")
    /// Over the source of a formula MathJax couldn't typeset: its message (a `String`).
    public static let mathError = NSAttributedString.Key("OpenNexusMathError")
}

/// A formula placed in styled text: its glyphs at a size. Two runs are equal when they
/// show the same source the same way, so redrawing a topic doesn't depend on which object
/// carries it. The glyphs aren't compared: a source and mode always typeset the same, and
/// comparing paths point by point made every topic that moved cost a millisecond more.
public final class MathRun: NSObject, @unchecked Sendable {
    public let glyphs: MathGlyphs
    public let source: String
    public let display: Bool
    /// The em, in points.
    public let fontSize: CGFloat

    public init(glyphs: MathGlyphs, source: String, display: Bool, fontSize: CGFloat) {
        self.glyphs = glyphs
        self.source = source
        self.display = display
        self.fontSize = fontSize
    }

    public var width: CGFloat { glyphs.width * fontSize }
    public var ascent: CGFloat { glyphs.ascent * fontSize }
    public var depth: CGFloat { glyphs.depth * fontSize }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? MathRun else { return false }
        return o.source == source && o.display == display && o.fontSize == fontSize
    }

    public override var hash: Int {
        var h = Hasher()
        h.combine(source)
        h.combine(display)
        h.combine(fontSize)
        return h.finalize()
    }
}

extension MathMarkup {
    /// The formulas a topic or note will ask the engine for.
    public static func keys(_ text: String) -> [MathEngine.Key] {
        scan(text).formulas.map { MathEngine.Key($0.source, display: $0.display) }
    }
}

/// Formulas in styled text (M48): the U+FFFC that stands for each, sized to the text.
public enum MathText {
    /// MathJax's font's x-height, in ems.
    static let mathXHeight: CGFloat = 0.442

    /// The formula's em for text in `font`: x-heights match, as MathJax matches them in a
    /// browser, so letters in a formula are the size of the words around them.
    public static func fontSize(for font: CTFont) -> CGFloat {
        let size = CTFontGetSize(font)
        let x = CTFontGetXHeight(font)
        guard x > 0 else { return size * 1.2 }
        return size * min(1.4, max(0.9, x / size / mathXHeight))
    }

    /// The formula's character: `attrs` (the text's style there) plus the run.
    static func run(_ r: MathRun, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var a = attrs
        a[TextKey.math] = r
        a[TextKey.baselineOffset] = nil
        return NSAttributedString(string: "\u{FFFC}", attributes: a)
    }

    /// A topic in `/math`: the whole text is one display formula.
    static func block(
        _ source: String, base: [NSAttributedString.Key: Any], font: CTFont, errorColor: TextColorValue
    ) -> NSAttributedString {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        switch MathEngine.shared.result(trimmed, display: true) {
        case .glyphs(let g)?:
            return run(MathRun(glyphs: g, source: trimmed, display: true, fontSize: fontSize(for: font)), base)
        case .error(let message)?:
            var a = base
            a[TextKey.color] = errorColor.attribute
            a[TextKey.mathError] = message
            return NSAttributedString(string: source, attributes: a)
        case nil:
            return NSAttributedString(string: source, attributes: base)
        }
    }

    /// Text with `$…$` and `$$…$$`: each formula ready replaces its source; one with an
    /// error keeps its source in the error colour; one still typesetting keeps its source.
    /// A display formula gets a centred line of its own.
    static func typeset(_ s: NSMutableAttributedString, font: CTFont, errorColor: TextColorValue) {
        let scan = MathMarkup.scan(s.string)
        guard !scan.formulas.isEmpty || !scan.escapes.isEmpty else { return }
        let size = fontSize(for: font)
        enum Edit {
            case formula(MathMarkup.Formula)
            case escape(Int)
            var location: Int {
                switch self {
                case .formula(let f): f.range.location
                case .escape(let i): i
                }
            }
        }
        let edits = (scan.formulas.map(Edit.formula) + scan.escapes.map(Edit.escape)).sorted {
            $0.location > $1.location
        }
        let ns = s.string as NSString
        for e in edits {
            switch e {
            case .escape(let i):
                s.replaceCharacters(in: NSRange(location: i, length: 1), with: "")
            case .formula(let f):
                let attrs = s.attributes(at: f.range.location, effectiveRange: nil)
                switch MathEngine.shared.result(f.source, display: f.display) {
                case .glyphs(let g)?:
                    var a = attrs
                    a[TextKey.math] = MathRun(glyphs: g, source: f.source, display: f.display, fontSize: size)
                    a[TextKey.baselineOffset] = nil
                    var before = false
                    var after = false
                    var range = f.range
                    if f.display {
                        // Its own line, centred: the spaces beside it go, and it breaks before
                        // and after unless the text does.
                        func space(_ i: Int) -> Bool { [32, 9].contains(ns.character(at: i)) }
                        var start = range.location
                        var end = range.location + range.length
                        while start > 0, space(start - 1) { start -= 1 }
                        while end < ns.length, space(end) { end += 1 }
                        range = NSRange(location: start, length: end - start)
                        before = start > 0 && ns.character(at: start - 1) != 10
                        after = end < ns.length && ns.character(at: end) != 10
                        if let p = attrs[TextKey.paragraph] as? TextParagraph {
                            a[TextKey.paragraph] = TextParagraph(
                                alignment: .center, lineBreak: p.lineBreak, lineHeight: p.lineHeight)
                        }
                    }
                    let out = NSMutableAttributedString(
                        string: (before ? "\n" : "") + "\u{FFFC}" + (after ? "\n" : ""), attributes: attrs)
                    out.setAttributes(a, range: NSRange(location: before ? 1 : 0, length: 1))
                    s.replaceCharacters(in: range, with: out)
                case .error(let message)?:
                    s.addAttribute(TextKey.color, value: errorColor.attribute, range: f.range)
                    s.addAttribute(TextKey.mathError, value: message, range: f.range)
                case nil:
                    break
                }
            }
        }
    }

    /// Plain text with its `$…$` and `$$…$$` typeset, as notes show them (M48).
    public static func styled(
        _ text: String, _ a: TextAttributes, errorColor: TextColorValue = .system(.red)
    ) -> StyledText {
        let s = NSMutableAttributedString(string: text, attributes: a.values)
        guard MathMarkup.mayContain(text), let font = a.values[TextKey.font] else { return s }
        typeset(s, font: font as! CTFont, errorColor: errorColor)
        return s
    }

    /// Every formula in a string: its run and where it is.
    public static func runs(in s: NSAttributedString) -> [(MathRun, NSRange)] {
        var out: [(MathRun, NSRange)] = []
        guard contains(s) else { return out }
        s.enumerateAttribute(TextKey.math, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let m = v as? MathRun { out.append((m, r)) }
        }
        return out
    }

    /// Whether styled text holds a typeset formula (and so is laid out by `MathLayout`).
    public static func contains(_ s: NSAttributedString) -> Bool {
        guard s.length > 0, (s.string as NSString).range(of: "\u{FFFC}").location != NSNotFound else { return false }
        var found = false
        s.enumerateAttribute(TextKey.math, in: NSRange(location: 0, length: s.length)) { v, _, stop in
            if v != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The first error message in styled text, if a formula failed.
    public static func error(in s: NSAttributedString) -> String? {
        var message: String?
        s.enumerateAttribute(TextKey.mathError, in: NSRange(location: 0, length: s.length)) { v, _, stop in
            if let m = v as? String {
                message = m
                stop.pointee = true
            }
        }
        return message
    }
}

extension SceneNode {
    /// The colour a formula with an error shows its source in (M48).
    public func mathErrorColor(theme: Theme, canvas: RGBA) -> RGBA {
        theme.formulaErrorColor(on: appearance.textBackground, canvas: canvas)
    }
}
