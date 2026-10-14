import AppKit
import NexusTheme

/// `/math`: a LaTeX subset rendered in the node (artboard 12): Greek letters, operators,
/// super- and subscripts, \frac, \sqrt, \mathbb, function names. Variables set italic,
/// digits and operators upright, like TeX.
enum MathText {
    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "sum": "Σ", "prod": "∏", "int": "∫", "oint": "∮",
        "infty": "∞", "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤",
        "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "iff": "⇔",
        "mapsto": "↦", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩",
        "emptyset": "∅", "forall": "∀", "exists": "∃", "partial": "∂", "nabla": "∇", "ldots": "…", "cdots": "⋯",
        "dots": "…", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "neg": "¬", "wedge": "∧", "vee": "∨", "circ": "∘", "star": "⋆", "ast": "∗", "prime": "′", "degree": "°",
        "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}", ",": "\u{2009}", ";": "\u{2005}", "!": "",
        "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "_": "_", "#": "#",
    ]
    static let functions: Set<String> = [
        "sin", "cos", "tan", "log", "ln", "exp", "lim", "max", "min", "sup", "inf", "det", "arg", "deg", "gcd",
        "Pr", "mod",
    ]
    static let blackboard: [Character: String] = ["N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ"]

    static func render(_ source: String, size: CGFloat, color: NSColor, paragraph: NSParagraphStyle)
        -> NSAttributedString
    {
        var p = Parser(chars: Array(source), i: 0)
        let out = NSMutableAttributedString()
        p.parse(into: out, size: size, offset: 0, color: color, until: nil)
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func font(_ size: CGFloat, italic: Bool) -> NSFont {
        let base =
            NSFont(name: italic ? "STIXTwoText-Italic" : "STIXTwoText", size: size)
            ?? NSFont(name: italic ? "TimesNewRomanPS-ItalicMT" : "TimesNewRomanPSMT", size: size)
            ?? .systemFont(ofSize: size)
        return base
    }

    struct Parser {
        var chars: [Character]
        var i: Int

        mutating func parse(
            into out: NSMutableAttributedString, size: CGFloat, offset: CGFloat, color: NSColor, until end: Character?
        ) {
            func emit(_ s: String, italic: Bool, sz: CGFloat = size, off: CGFloat = offset) {
                out.append(
                    NSAttributedString(
                        string: s,
                        attributes: [
                            .font: MathText.font(sz, italic: italic), .foregroundColor: color, .baselineOffset: off,
                        ]))
            }
            while i < chars.count {
                let c = chars[i]
                if let end, c == end {
                    i += 1
                    return
                }
                switch c {
                case "\\":
                    i += 1
                    var name = ""
                    if i < chars.count, !chars[i].isLetter {
                        name = String(chars[i])
                        i += 1
                    } else {
                        while i < chars.count, chars[i].isLetter {
                            name.append(chars[i])
                            i += 1
                        }
                    }
                    switch name {
                    case "frac":
                        // Inline: numerator over a fraction slash over denominator, set smaller.
                        let num = group(size: size * 0.78, offset: offset + size * 0.28, color: color)
                        out.append(num)
                        emit("⁄", italic: false)
                        out.append(group(size: size * 0.78, offset: offset - size * 0.12, color: color))
                    case "sqrt":
                        emit("√", italic: false)
                        // The radicand carries a vinculum: combining overlines (U+0305).
                        let inner = group(size: size, offset: offset, color: color)
                        let m = NSMutableAttributedString()
                        inner.enumerateAttributes(in: NSRange(location: 0, length: inner.length)) { attrs, r, _ in
                            let piece = (inner.string as NSString).substring(with: r)
                            let barred = piece.map { "\($0)\u{0305}" }.joined()
                            m.append(NSAttributedString(string: barred, attributes: attrs))
                        }
                        out.append(m)
                    case "mathbb":
                        let g = rawGroup()
                        emit(String(g.map { blackboard[$0] ?? String($0) }.joined()), italic: false)
                    case "mathrm", "text", "operatorname":
                        emit(rawGroup(), italic: false)
                    case "left", "right", "big", "Big", "bigl", "bigr", "displaystyle":
                        continue
                    default:
                        if MathText.functions.contains(name) {
                            emit(name, italic: false)
                        } else if let s = MathText.symbols[name] {
                            emit(
                                s,
                                italic: name.first?.isLowercase == true && name.count > 1 && s.count == 1
                                    && "αβγδεζηθικλμνξπρστυφχψω".contains(s))
                        } else {
                            emit("\\" + name, italic: false)
                        }
                    }
                case "^", "_":
                    i += 1
                    let up = c == "^"
                    out.append(
                        group(
                            size: size * 0.7, offset: offset + (up ? size * 0.42 : -size * 0.22), color: color))
                case "{":
                    i += 1
                    parse(into: out, size: size, offset: offset, color: color, until: "}")
                case "}":
                    i += 1
                case " ":
                    i += 1
                default:
                    i += 1
                    if c.isLetter {
                        emit(String(c), italic: true)
                    } else if "=+<>−-".contains(c) {
                        emit(c == "-" ? " − " : " \(c) ", italic: false)
                    } else {
                        emit(String(c), italic: false)
                    }
                }
            }
        }

        /// The next `{…}` group (or single token), rendered.
        mutating func group(size: CGFloat, offset: CGFloat, color: NSColor) -> NSAttributedString {
            let out = NSMutableAttributedString()
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { return out }
            if chars[i] == "{" {
                i += 1
                parse(into: out, size: size, offset: offset, color: color, until: "}")
            } else if chars[i] == "\\" {
                var sub = Parser(chars: chars, i: i)
                let start = i
                // One command.
                sub.i += 1
                if sub.i < chars.count, chars[sub.i].isLetter {
                    while sub.i < chars.count, chars[sub.i].isLetter { sub.i += 1 }
                } else {
                    sub.i += 1
                }
                var one = Parser(chars: Array(chars[start..<sub.i]), i: 0)
                one.parse(into: out, size: size, offset: offset, color: color, until: nil)
                i = sub.i
            } else {
                var one = Parser(chars: [chars[i]], i: 0)
                one.parse(into: out, size: size, offset: offset, color: color, until: nil)
                i += 1
            }
            return out
        }

        mutating func rawGroup() -> String {
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { return "" }
            if chars[i] != "{" {
                defer { i += 1 }
                return String(chars[i])
            }
            i += 1
            var s = ""
            var depth = 1
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                s.append(c)
            }
            return s
        }
    }
}

/// `/code`: a monospaced block with keyword, string, number, comment and type colours.
enum CodeText {
    static let keywords: Set<String> = [
        // Swift, JS/TS, Python, Go, Rust, C-family, SQL (common subset).
        "func", "let", "var", "if", "else", "for", "in", "while", "return", "import", "struct", "class", "enum",
        "case", "switch", "default", "break", "continue", "guard", "throw", "throws", "try", "catch", "async",
        "await", "public", "private", "static", "self", "nil", "true", "false", "function", "const", "new",
        "this", "null", "undefined", "def", "lambda", "None", "True", "False", "and", "or", "not", "elif",
        "pass", "with", "as", "from", "yield", "fn", "mut", "impl", "pub", "use", "match", "go", "package",
        "type", "interface", "map", "chan", "defer", "SELECT", "FROM", "WHERE", "JOIN", "INSERT", "UPDATE",
        "DELETE", "VALUES", "INTO", "ORDER", "BY", "GROUP", "LIMIT", "AND", "OR",
    ]
    static let keyword = NSColor(red: 0.42, green: 0.71, blue: 1.0, alpha: 1)
    static let string = NSColor(red: 0.65, green: 0.84, blue: 0.65, alpha: 1)
    static let number = NSColor(red: 0.95, green: 0.77, blue: 0.43, alpha: 1)
    static let comment = NSColor(red: 0.55, green: 0.55, blue: 0.62, alpha: 1)
    static let typeName = NSColor(red: 0.88, green: 0.63, blue: 1.0, alpha: 1)

    static func render(_ source: String, size: CGFloat, color: NSColor, paragraph: NSParagraphStyle)
        -> NSAttributedString
    {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let p = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        p.alignment = .left
        let out = NSMutableAttributedString(
            string: source, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        let ns = source as NSString
        func paint(_ pattern: String, _ c: NSColor, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                out.addAttribute(.foregroundColor, value: c, range: m.range)
            }
        }
        paint("\\b[A-Z][A-Za-z0-9_]*\\b", typeName)
        paint("\\b[0-9]+(\\.[0-9]+)?\\b", number)
        let words = try? NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*\\b")
        for m in words?.matches(in: source, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if keywords.contains(ns.substring(with: m.range)) {
                out.addAttribute(.foregroundColor, value: keyword, range: m.range)
            }
        }
        paint("\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*'", string)
        paint("//[^\\n]*|#[^\\n]*|--[^\\n]*", comment)
        return out
    }
}
