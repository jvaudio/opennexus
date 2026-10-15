import Foundation

/// Localisation scaffolding (M10). User-facing strings that come from data (command
/// titles, Settings rows) are looked up here at display time, in the String Catalog
/// `Resources/Localizable.xcstrings` (kept complete by `LocalizationTests`; regenerate
/// with `NEXUS_WRITE_CATALOG=1 swift test --filter writeStringCatalog`). SwiftUI literals
/// localise themselves; text with values in it goes through `f`, and counts through `n`.
///
/// Pseudo-localisation (`-NexusPseudoLanguage YES`, or `Loc.pseudo = true` in tests)
/// accents every looked-up string and makes it about 40% longer, to find truncation
/// before a real translation does.
public enum Loc {
    nonisolated(unsafe) public static var pseudo = UserDefaults.standard.bool(forKey: "NexusPseudoLanguage")

    /// A string with no values in it: `Loc.t("Copied as Markdown")`. Keys passed as literals
    /// are scanned into the catalog; other strings (data, undo names) fall back to themselves.
    public static func t(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let v = Bundle.module.localizedString(forKey: s, value: s, table: nil)
        return pseudo ? pseudolocalize(v) : v
    }

    /// A format key filled in for the current locale: `Loc.f("Slide %lld of %lld", i, n)`.
    /// Pass a phrase from `n` as a `%@` argument when a sentence holds a count, so each
    /// key has at most one plural. Keys must be literals; the catalog generator scans them.
    public static func f(_ key: String, _ args: any CVarArg...) -> String {
        let format = Bundle.module.localizedString(forKey: key, value: key, table: nil)
        let v = String(format: format, locale: .current, arguments: args)
        return pseudo ? pseudolocalize(v) : v
    }

    /// A count phrase with plural variants: `Loc.n("%lld topic", "%lld topics", count)`.
    /// The plural form is the catalog key; the generator writes both forms as its English
    /// variants, which a translation replaces with its own plural categories.
    public static func n(_ one: String, _ other: String, _ count: Int) -> String {
        let missing = "\u{1}"
        var format = Bundle.module.localizedString(forKey: other, value: missing, table: nil)
        if format == missing { format = count == 1 ? one : other }
        let v = String(format: format, locale: .current, count)
        return pseudo ? pseudolocalize(v) : v
    }

    static let accents: [Character: Character] = [
        "a": "á", "e": "é", "i": "í", "o": "ö", "u": "ü", "c": "ç", "n": "ñ", "s": "š", "y": "ý", "z": "ž",
        "A": "Å", "E": "É", "I": "Î", "O": "Ø", "U": "Û", "C": "Ç", "N": "Ñ", "S": "Š", "Y": "Ý", "Z": "Ž",
    ]

    /// "Add Child Topic" → "⟦Ådd Çhíld Töpíç ······⟧". Keys, glyphs and placeholders stay.
    public static func pseudolocalize(_ s: String) -> String {
        guard !s.hasPrefix("⟦") else { return s }  // already looked up once
        var out = ""
        var inPlaceholder = false
        for ch in s {
            if ch == "%" || ch == "{" { inPlaceholder = true }
            out.append(inPlaceholder ? ch : (accents[ch] ?? ch))
            if inPlaceholder, ch.isLetter || ch == "}" { inPlaceholder = false }
        }
        let pad = String(repeating: "·", count: max(2, s.count * 2 / 5))
        return "⟦\(out) \(pad)⟧"
    }
}
