import Foundation

/// Localisation scaffolding (M10). User-facing strings that come from data (command
/// titles, Settings rows) are looked up here at display time, in the String Catalog
/// `Resources/Localizable.xcstrings` (kept complete by `LocalizationTests`; regenerate
/// with `NEXUS_WRITE_CATALOG=1 swift test --filter writeStringCatalog`). SwiftUI literals
/// localise themselves.
///
/// Pseudo-localisation (`-NexusPseudoLanguage YES`, or `Loc.pseudo = true` in tests)
/// accents every looked-up string and makes it about 40% longer, to find truncation
/// before a real translation does.
public enum Loc {
    nonisolated(unsafe) public static var pseudo = UserDefaults.standard.bool(forKey: "NexusPseudoLanguage")

    public static func t(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let v = Bundle.module.localizedString(forKey: s, value: s, table: nil)
        return pseudo ? pseudolocalize(v) : v
    }

    static let accents: [Character: Character] = [
        "a": "á", "e": "é", "i": "í", "o": "ö", "u": "ü", "c": "ç", "n": "ñ", "s": "š", "y": "ý", "z": "ž",
        "A": "Å", "E": "É", "I": "Î", "O": "Ø", "U": "Û", "C": "Ç", "N": "Ñ", "S": "Š", "Y": "Ý", "Z": "Ž",
    ]

    /// "Add Child Topic" → "⟦Ådd Çhíld Töpíç ······⟧". Keys, glyphs and placeholders stay.
    public static func pseudolocalize(_ s: String) -> String {
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
