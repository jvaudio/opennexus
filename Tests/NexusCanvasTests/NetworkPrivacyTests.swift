import Foundation
import Testing

/// README §12: "Network traffic with default settings: none". OpenNexus has no network
/// code and no network entitlement, so the sandbox blocks any connection outright.
@Suite struct NetworkPrivacyTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func files(under dir: String, ext: Set<String>) -> [URL] {
        let root = repo.appending(path: dir)
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { ext.contains($0.pathExtension) }
    }

    @Test func noNetworkingAPIsAnywhere() throws {
        let banned = [
            "URLSession", "NWConnection", "NWListener", "NWBrowser", "import Network", "URLRequest", "WKWebView",
            "CFSocket", "CFStream", "getaddrinfo", "XMLHttpRequest", "fetch(", "PrivateCloudCompute",
        ]
        var hits: [String] = []
        for f in NetworkPrivacyTests.files(under: "Sources", ext: ["swift"])
            + NetworkPrivacyTests.files(under: "App", ext: ["swift", "js"])
        {
            let text = try String(contentsOf: f, encoding: .utf8)
            for b in banned where text.contains(b) { hits.append("\(f.lastPathComponent): \(b)") }
        }
        #expect(hits.isEmpty, "networking code: \(hits)")
    }

    @Test func noTargetHasANetworkEntitlement() throws {
        let ents = NetworkPrivacyTests.files(under: "App/Support", ext: ["entitlements"])
        #expect(ents.count >= 7, "the app, five extensions and the CLI")
        for f in ents {
            let text = try String(contentsOf: f, encoding: .utf8)
            #expect(!text.contains("com.apple.security.network"), "\(f.lastPathComponent) asks for the network")
            if !f.lastPathComponent.hasPrefix("nexus") {
                #expect(text.contains("com.apple.security.app-sandbox"), "\(f.lastPathComponent) isn't sandboxed")
            }
        }
    }

    /// Diagnostics are opt-in and never sent: the rows that would use the network are locked off.
    @Test func analyticsAndUpdatesAreOff() throws {
        let schema = try String(
            contentsOf: NetworkPrivacyTests.repo.appending(path: "Sources/NexusCanvas/SettingsSchema.swift"),
            encoding: .utf8)
        for key in ["general.updatesCheck", "privacy.usageStats", "privacy.linkPreviews"] {
            #expect(schema.contains("\"\(key)\""), "\(key)")
        }
    }
}
