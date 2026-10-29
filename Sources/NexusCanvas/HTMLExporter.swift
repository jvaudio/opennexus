import CryptoKit
import Foundation
import NexusCore
import NexusFormat

/// Interactive HTML (M43): one file that opens offline in any modern browser. It holds the
/// built viewer (`web/viewer-core`, copied into `Viewer/`), its stylesheet and the bundle;
/// a Content Security Policy allows only those two by hash, and images from `data:` and
/// `blob:`, so the page can make no request at all (D317).
@MainActor
public enum HTMLExporter {
    public static func export(_ model: DocumentModel, _ o: ViewerBundle.Options, prefs: Preferences = .isolated())
        -> String
    {
        page(ViewerBundle.build(model, o, prefs: prefs))
    }

    /// The page for a bundle.
    public static func page(_ bundle: JSONValue) -> String {
        var title = ""
        var lang = "en"
        var noScript = ""
        if case .object(let o) = bundle {
            if case .string(let t)? = o["title"] { title = t }
            if case .string(let l)? = o["lang"] { lang = l }
            if case .object(let s)? = o["strings"], case .string(let t)? = s["noScript"] { noScript = t }
        }
        // `<` only ever appears inside JSON strings, so < keeps `</script>` and `<!--`
        // out of the element without changing what JSON.parse reads.
        let data = CanonicalJSON.compact(bundle).replacingOccurrences(of: "<", with: "\\u003c")
        let csp = [
            "default-src 'none'", "script-src '\(hash(script))'", "style-src '\(hash(style))'",
            "img-src data: blob:", "base-uri 'none'", "form-action 'none'",
        ].joined(separator: "; ")
        return """
            <!doctype html>
            <html lang="\(escape(lang))">
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="no-referrer">
            <meta name="generator" content="OpenNexus">
            <title>\(escape(title))</title>
            <style>\(style)</style>
            </head>
            <body>
            <noscript>\(escape(noScript))</noscript>
            <div id="opennexus-viewer"></div>
            <script type="application/json" id="opennexus-bundle">\(data)</script>
            <script>\(script)</script>
            </body>
            </html>

            """
    }

    /// The built viewer (`scripts/build-viewer.sh` copies it here).
    static let script = resource("js")
    static let style = resource("css")

    static func resource(_ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: "opennexus-viewer", withExtension: ext, subdirectory: "Viewer"),
            let s = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        // The file ends in a newline; the hash covers exactly what sits between the tags.
        return s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    /// A CSP source for inline content: `sha256-<base64>`.
    static func hash(_ s: String) -> String {
        "sha256-" + Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
