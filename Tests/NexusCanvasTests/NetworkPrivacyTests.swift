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

    /// Software updates (D275) are opt-in, done by Sparkle's own services, and signed: the
    /// app still has no network entitlement, nothing turns checks on by default, the feed
    /// is HTTPS on GitHub, and updates must carry the EdDSA signature.
    @Test func updatesAreOptInAndSigned() throws {
        let support = NetworkPrivacyTests.repo.appending(path: "App/Support")
        let data = try Data(contentsOf: support.appending(path: "Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["SUEnableDownloaderService"] as? Bool == true, "the Downloader service does the fetching")
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        #expect(info["SUEnableAutomaticChecks"] == nil, "Sparkle asks before its first check")
        #expect(info["SUAutomaticallyUpdate"] == nil && info["SUAllowsAutomaticUpdates"] as? Bool != false)
        let feed = try #require(info["SUFeedURL"] as? String)
        #expect(feed.hasPrefix("https://") && feed.contains("jvaudio/opennexus"))
        #expect(((info["SUPublicEDKey"] as? String) ?? "").count == 44, "an Ed25519 public key")
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        let ents = try String(contentsOf: support.appending(path: "OpenNexus.entitlements"), encoding: .utf8)
        #expect(ents.contains("-spks") && ents.contains("-spki"), "Sparkle's installer services")
        #expect(!ents.contains("com.apple.security.network"))
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
