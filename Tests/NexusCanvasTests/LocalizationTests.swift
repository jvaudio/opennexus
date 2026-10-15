import AppKit
import Foundation
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
        for (literal, file) in literals() { out[literal] = out[literal] ?? "UI text (\(file))" }
        out[""] = nil
        return out
    }

    /// Literal SwiftUI strings in the chrome (`Text("…")`, `Button("…")`, `.help("…")`…).
    /// They resolve against the app's main bundle, which gets this catalog's compiled
    /// strings at build time (the app target's "Localized strings" phase). Interpolated
    /// literals become format keys that Xcode's extraction owns; they're skipped here.
    static func literals() -> [(String, String)] {
        let repo = catalogURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var out: [(String, String)] = []
        let pattern =
            /(?:Text|Button|Label|Toggle|TextField|Picker|Menu|Section|\.help|\.accessibilityLabel|\.accessibilityHint|\.navigationTitle)\("((?:[^"\\]|\\.)*)"/
        for dir in ["Sources/NexusCanvas", "App/OpenNexus"] {
            let urls =
                (try? FileManager.default.contentsOfDirectory(
                    at: repo.appending(path: dir), includingPropertiesForKeys: nil)) ?? []
            for f in urls where f.pathExtension == "swift" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for m in text.matches(of: pattern) {
                    let s = String(m.output.1)
                    guard s.contains(where: \.isLetter), !s.contains("\\(") else { continue }
                    out.append(
                        (
                            s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n"),
                            f.lastPathComponent
                        ))
                }
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

    /// Keeps existing translations; adds new strings; drops ones no longer used.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_WRITE_CATALOG"] != nil))
    func writeStringCatalog() throws {
        let old = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalogURL)) as? [String: Any]) ?? [:]
        let oldStrings = old["strings"] as? [String: [String: Any]] ?? [:]
        var strings: [String: Any] = [:]
        for (key, comment) in Self.sourceStrings() {
            var entry = oldStrings[key] ?? [:]
            entry["comment"] = comment
            entry["extractionState"] = "migrated"  // data-driven: no generated Swift symbols
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
