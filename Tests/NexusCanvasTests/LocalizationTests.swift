import AppKit
import Foundation
import NexusCore
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusKeys

/// M10: localisation scaffolding. The String Catalog holds every data-driven string
/// (commands, Settings), and pseudo-localisation shows where text would truncate.
@MainActor
@Suite(.serialized) struct LocalizationTests {
    static let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/NexusCanvas/Resources/Localizable.xcstrings")

    /// Every string the app shows from the registry and the Settings schema, with a
    /// comment saying where it appears.
    static func sourceStrings() -> [String: String] {
        var out: [String: String] = [:]
        for d in CommandRegistry.standard.commands {
            out[d.title] = "Command title (menus, palette, cheat sheet, Settings › Shortcuts)"
            if !d.note.isEmpty { out[d.note] = out[d.note] ?? "Command note (palette subtitle)" }
            out[d.category.rawValue] = out[d.category.rawValue] ?? "Command category"
        }
        for (title, _) in CheatSheetView.groups { out[title] = out[title] ?? "Cheat sheet column" }
        for p in SettingsSchema.panes {
            out[p.title] = out[p.title] ?? "Settings pane"
            out[p.subtitle] = out[p.subtitle] ?? "Settings pane subtitle"
            for s in p.sections {
                if !s.title.isEmpty { out[s.title] = out[s.title] ?? "Settings section" }
                if let f = s.footnote { out[f] = out[f] ?? "Settings footnote" }
                for r in s.rows {
                    if !r.title.isEmpty { out[r.title] = out[r.title] ?? "Settings row" }
                    if let d = r.detail { out[d] = out[d] ?? "Settings row detail" }
                    if let l = r.locked { out[l] = out[l] ?? "Why a Settings row is locked" }
                    switch r.kind {
                    case .segmented(let o), .menu(let o):
                        for x in o { out[x.label] = out[x.label] ?? "Settings option" }
                    case .info(let v): out[v] = out[v] ?? "Settings value"
                    default: break
                    }
                }
            }
        }
        // Names that live in NexusCore's data and are looked up where they're shown.
        for d in DiagramDescriptor.all {
            out[d.name] = out[d.name] ?? "Diagram type"
            out[d.summary] = out[d.summary] ?? "Diagram type summary (starter picker)"
            for i in DiagramCatalog.nodeTypes(for: d.type) { out[i.name] = out[i.name] ?? "Node type (\(d.name))" }
        }
        for c in StarterCategory.allCases { out[c.title] = out[c.title] ?? "Starter category (starter picker)" }
        for s in StarterLibrary.all {
            out[s.name] = out[s.name] ?? "Starter name (Home's template shelf, starter picker)"
            out[s.summary] = out[s.summary] ?? "Starter summary (Home's template shelf, starter picker)"
            out[s.kicker] = out[s.kicker] ?? "Starter kicker, small capitals over its name"
        }
        for i in DiagramCatalog.icons { out[i.name] = out[i.name] ?? "Icon name" }
        for c in Stride.allCases { out[c.name] = out[c.name] ?? "STRIDE category" }
        for r in Stride.risks + Stride.statuses { out[r] = out[r] ?? "Threat risk or status" }
        for (literal, file) in literals() { out[literal] = out[literal] ?? "UI text (\(file))" }
        for k in formatKeys() { out[k.key] = out[k.key] ?? k.comment }
        for (key, comment) in messageKeys() { out[key] = out[key] ?? comment }
        out[""] = nil
        return out
    }

    /// Literal SwiftUI strings in the chrome (`Text("…")`, `Button("…")`, `.help("…")`…).
    /// They resolve against the app's main bundle, which gets this catalog's compiled
    /// strings at build time (the app target's "Localized strings" phase). Text with
    /// values in it goes through `Loc.f` and `Loc.n` instead (`formatKeys`).
    static func literals() -> [(String, String)] {
        var out: [(String, String)] = []
        for (name, text) in sources() {
            for m in text.matches(of: uiLiteral) {
                let s = String(m.output.1)
                guard s.contains(where: \.isLetter), !s.contains("\\(") else { continue }
                out.append((unescape(m.output.1), name))
            }
        }
        return out
    }

    nonisolated(unsafe) static let uiLiteral =
        /(?:Text|Button|Label|Toggle|TextField|Picker|Menu|Section|\.help|\.accessibilityLabel|\.accessibilityHint|\.accessibilityValue|\.navigationTitle|LabeledContent|TableColumn|\.alert|\.confirmationDialog)\(\s*"((?:[^"\\]|\\.)*)"/

    /// Text handed to a toast, an alert, a panel, the tour coach or AppKit chrome (menus,
    /// accessibility labels, tooltips) must already be localised.
    nonisolated(unsafe) static let messageLiteral =
        /(?:(?:showToast|showInfo|showDropHint|\.wrong|setAccessibilityLabel)\(|(?:addButton|addItem)\(withTitle:|NSMenu(?:Item)?\(title:|\.toolTip =|(?:messageText|informativeText|\.prompt|\.message|self\.error) =)\s*"((?:[^"\\]|\\.)*)"/

    /// Undo action names: `perform("Add Child Topic")`, looked up when the undo menu shows them.
    nonisolated(unsafe) static let undoName =
        /(?:perform|commitDocument|patch)\(\s*(?:actionName:\s*)?"((?:[^"\\]|\\.)*)"/

    /// A `Loc.f` or `Loc.n` key; `one` is the English singular of a count phrase.
    struct FormatKey: Hashable {
        var key: String
        var one: String?
        var file: String
        var comment: String {
            one == nil ? "Text with values filled in (\(file))" : "Count phrase with plural variants (\(file))"
        }
    }

    static func sources() -> [(name: String, text: String)] {
        let repo = catalogURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var out: [(String, String)] = []
        for dir in ["Sources/NexusCanvas", "Sources/NexusCore", "App/OpenNexus"] {
            let urls =
                (try? FileManager.default.contentsOfDirectory(
                    at: repo.appending(path: dir), includingPropertiesForKeys: nil)) ?? []
            for f in urls where f.pathExtension == "swift" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                out.append((f.lastPathComponent, code.joined(separator: "\n")))
            }
        }
        return out
    }

    static func unescape(_ s: Substring) -> String {
        String(s).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Every `Loc.f("…"` and `Loc.n("…", "…"` in the chrome.
    static func formatKeys() -> [FormatKey] {
        var out: [FormatKey] = []
        for (name, text) in sources() {
            for m in text.matches(of: /(?:Loc|CoreText)\.f\(\s*"((?:[^"\\]|\\.)*)"/) {
                out.append(FormatKey(key: unescape(m.output.1), file: name))
            }
            for m in text.matches(of: /(?:Loc|CoreText)\.n\(\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"/) {
                out.append(FormatKey(key: unescape(m.output.2), one: unescape(m.output.1), file: name))
            }
        }
        return out
    }

    /// `Loc.t("…")` keys and undo action names.
    static func messageKeys() -> [(String, String)] {
        var out: [(String, String)] = []
        for (name, text) in sources() {
            for m in text.matches(of: /(?:Loc|CoreText)\.t\(\s*"((?:[^"\\]|\\.)*)"/) {
                out.append((unescape(m.output.1), "UI text (\(name))"))
            }
            for m in text.matches(of: undoName) where !m.output.1.contains("\\(") {
                out.append((unescape(m.output.1), "Undo action name (\(name))"))
            }
        }
        return out
    }

    static func catalogKeys() throws -> Set<String> {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        return Set((json?["strings"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    @Test func catalogCoversEveryDataDrivenString() throws {
        let missing = Set(Self.sourceStrings().keys).subtracting(try Self.catalogKeys())
        #expect(
            missing.isEmpty,
            "\(missing.count) strings missing from Localizable.xcstrings (NEXUS_WRITE_CATALOG=1 swift test --filter writeStringCatalog): \(missing.sorted().prefix(5))"
        )
    }

    @Test func lookupsFallBackToEnglishAndPseudoLanguageLengthens() {
        #expect(Loc.t("Add Child Topic") == "Add Child Topic")
        Loc.pseudo = true
        defer { Loc.pseudo = false }
        let p = Loc.t("Add Child Topic")
        #expect(p.hasPrefix("⟦Ådd Çhíld Töpíç") && p.count >= Int(Double("Add Child Topic".count) * 1.4))
        #expect(Loc.pseudolocalize("%d topics").contains("%d"), "placeholders survive")
    }

    @Test func countPhrasesUseTheCatalogsPluralVariants() {
        #expect(Loc.n("%lld topic", "%lld topics", 1) == "1 topic")
        #expect(Loc.n("%lld topic", "%lld topics", 2) == "2 topics")
        #expect(Loc.n("%lld topic", "%lld topics", 0) == "0 topics")
        #expect(Loc.n("%lld unknown thing", "%lld unknown things", 1) == "1 unknown thing", "falls back to English")
        let dict = Bundle.module.url(forResource: "Localizable", withExtension: "stringsdict")  // NexusCanvas's
            .flatMap { NSDictionary(contentsOf: $0) }
        #expect(dict?["%lld topics"] != nil, "the plural variants compile into the bundle's stringsdict")
    }

    /// SwiftUI would look an interpolated literal up by a format key that no catalog
    /// holds, a hand-written `n == 1 ? "topic" : "topics"` only knows English, and a
    /// toast or alert shows its `String` as given.
    @Test func chromeTextWithValuesGoesThroughLoc() {
        var found: [String] = []
        for (name, text) in Self.sources() {
            for m in text.matches(of: Self.uiLiteral) where m.output.1.contains("\\(") {
                if Self.outsideInterpolations(m.output.1).contains(where: \.isLetter) {
                    found.append("\(name): \(m.output.0)")
                }
            }
            for m in text.matches(of: /\\\([^"\n]*== 1 \? "/) { found.append("\(name): \(m.output)") }
            for m in text.matches(of: Self.messageLiteral) { found.append("\(name): \(m.output.0)") }
            for m in text.matches(of: Self.undoName) where m.output.1.contains("\\(") {
                found.append("\(name): \(m.output.0)")
            }
        }
        #expect(found.isEmpty, "use Loc.f / Loc.n: \(found.prefix(5))")
    }

    /// "Slide \(i) of \(n)" → "Slide  of ". An interpolation cut short by a nested
    /// literal drops the rest.
    static func outsideInterpolations(_ s: Substring) -> String {
        var out = ""
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("\\(") {
                depth += 1
                i = s.index(i, offsetBy: 2)
                continue
            }
            if depth > 0 {
                if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1 }
            } else {
                out.append(s[i])
            }
            i = s.index(after: i)
        }
        return out
    }

    @Test func pluralKeysHaveOneCountAndBothEnglishForms() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalogURL)) as? [String: Any]
        let strings = json?["strings"] as? [String: [String: Any]] ?? [:]
        for k in Self.formatKeys() {
            guard let one = k.one else { continue }
            #expect(k.key.ranges(of: "%").count == 1 && k.key.contains("%lld"), "\(k.key): exactly one %lld")
            #expect(one.ranges(of: "%").count == 1 && one.contains("%lld"), "\(one): exactly one %lld")
            let plural =
                ((strings[k.key]?["localizations"] as? [String: Any])?["en"] as? [String: Any]).flatMap {
                    ($0["variations"] as? [String: Any])?["plural"] as? [String: [String: [String: String]]]
                }
            #expect(plural?["one"]?["stringUnit"]?["value"] == one, "\(k.key) (\(k.file))")
            #expect(plural?["other"]?["stringUnit"]?["value"] == k.key, "\(k.key) (\(k.file))")
        }
    }

    /// Keeps existing translations; adds new strings; drops ones no longer used.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_WRITE_CATALOG"] != nil))
    func writeStringCatalog() throws {
        let old = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalogURL)) as? [String: Any]) ?? [:]
        let oldStrings = old["strings"] as? [String: [String: Any]] ?? [:]
        var strings: [String: Any] = [:]
        let plurals = Dictionary(
            Self.formatKeys().compactMap { k in k.one.map { (k.key, $0) } }, uniquingKeysWith: { a, _ in a })
        for (key, comment) in Self.sourceStrings() {
            var entry = oldStrings[key] ?? [:]
            entry["comment"] = comment
            entry["extractionState"] = "migrated"  // data-driven: no generated Swift symbols
            if let one = plurals[key] {
                var localizations = entry["localizations"] as? [String: Any] ?? [:]
                func unit(_ v: String) -> [String: Any] { ["stringUnit": ["state": "translated", "value": v]] }
                localizations["en"] = ["variations": ["plural": ["one": unit(one), "other": unit(key)]]]
                entry["localizations"] = localizations
            }
            strings[key] = entry
        }
        let catalog: [String: Any] = ["sourceLanguage": "en", "strings": strings, "version": "1.0"]
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.catalogURL)
    }

    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// For review: Settings and the palette in the pseudo-language.
    @Test(.enabled(if: dir != nil)) func pseudoLanguageSnapshots() async throws {
        Loc.pseudo = true
        defer { Loc.pseudo = false }
        for pane in ["general", "editing", "accessibility"] {
            let w = NSWindow(
                contentRect: CGRect(x: 40, y: 40, width: 1440, height: 900), styleMask: [.titled], backing: .buffered,
                defer: false)
            w.appearance = NSAppearance(named: .aqua)
            w.contentView = NSHostingView(rootView: SettingsView(prefs: .isolated(), availability: .ready, pane: pane))
            w.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(700))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = [
                "-x", "-o", "-l", "\(w.windowNumber)", Self.dir!.appendingPathComponent("m10-pseudo-\(pane).png").path,
            ]
            try? p.run()
            p.waitUntilExit()
            w.orderOut(nil)
        }
    }
}
