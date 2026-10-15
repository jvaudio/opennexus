import Foundation

/// User-facing text made in NexusCore: rule checks, repairs and refusals. The keys live
/// in NexusCanvas's String Catalog, which the app copies into its main bundle (D133), so
/// they are looked up there. The CLI, the extensions and the tests have no catalog in
/// their main bundle and get the English back. Same shapes as `Loc` (D138): `t` for
/// plain text, `f` for a printf-style key, `n` for a count phrase with plural variants.
public enum CoreText {
    public static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    public static func f(_ key: String, _ args: any CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: args)
    }

    public static func n(_ one: String, _ other: String, _ count: Int) -> String {
        let missing = "\u{1}"
        var format = Bundle.main.localizedString(forKey: other, value: missing, table: nil)
        if format == missing { format = count == 1 ? one : other }
        return String(format: format, locale: .current, count)
    }
}
