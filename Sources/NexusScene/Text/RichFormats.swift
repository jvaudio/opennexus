import CoreText
import Foundation
import NexusTheme

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
    static let keyword = CGColor(srgbRed: 0.42, green: 0.71, blue: 1.0, alpha: 1)
    static let string = CGColor(srgbRed: 0.65, green: 0.84, blue: 0.65, alpha: 1)
    static let number = CGColor(srgbRed: 0.95, green: 0.77, blue: 0.43, alpha: 1)
    static let comment = CGColor(srgbRed: 0.55, green: 0.55, blue: 0.62, alpha: 1)
    static let typeName = CGColor(srgbRed: 0.88, green: 0.63, blue: 1.0, alpha: 1)

    static func render(_ source: String, size: CGFloat, color: TextColorValue, paragraph: TextParagraph)
        -> NSAttributedString
    {
        let font = Fonts.mono(size)
        let p = TextParagraph(alignment: .left, lineBreak: paragraph.lineBreak, lineHeight: paragraph.lineHeight)
        let out = NSMutableAttributedString(
            string: source, attributes: [TextKey.font: font, TextKey.color: color.attribute, TextKey.paragraph: p])
        let ns = source as NSString
        func paint(_ pattern: String, _ c: CGColor, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                out.addAttribute(TextKey.color, value: c, range: m.range)
            }
        }
        paint("\\b[A-Z][A-Za-z0-9_]*\\b", typeName)
        paint("\\b[0-9]+(\\.[0-9]+)?\\b", number)
        let words = try? NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*\\b")
        for m in words?.matches(in: source, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if keywords.contains(ns.substring(with: m.range)) {
                out.addAttribute(TextKey.color, value: keyword, range: m.range)
            }
        }
        paint("\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*'", string)
        paint("//[^\\n]*|#[^\\n]*|--[^\\n]*", comment)
        return out
    }
}
