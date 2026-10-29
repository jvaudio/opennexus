import Foundation
import Testing

@testable import NexusCanvas

/// README §12: "Network traffic with default settings: none". The network rule (D313):
/// OpenNexus itself has no network code and no network entitlement, so the sandbox blocks
/// any connection outright. The one exception is `OpenNexusNet.xpc` (M44), which alone has
/// the entitlement and the request code, connects only to hosts each job allows, and does
/// nothing until Privacy & Data › Network is turned on.
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
        var service: [String] = []
        for f in NetworkPrivacyTests.files(under: "Sources", ext: ["swift"])
            + NetworkPrivacyTests.files(under: "App", ext: ["swift", "js"])
        {
            let text = try String(contentsOf: f, encoding: .utf8)
            // The network service's own code (M44) is the exception.
            if f.path.contains("/Sources/NexusNet/") {
                service += banned.filter { text.contains($0) }
                continue
            }
            for b in banned where text.contains(b) { hits.append("\(f.lastPathComponent): \(b)") }
        }
        #expect(hits.isEmpty, "networking code: \(hits)")
        #expect(service.contains("URLSession"), "the service's requests are where the test expects them")
    }

    /// Only the network service links the network code: not the app, its extensions or the CLI.
    @Test func onlyTheServiceLinksTheNetworkCode() throws {
        // In the package: its own product, and test targets; no other target depends on it.
        let package = try String(contentsOf: NetworkPrivacyTests.repo.appending(path: "Package.swift"), encoding: .utf8)
        // Each product and target declaration whole, however it's wrapped.
        let uses = package.components(separatedBy: "\n        .").filter { $0.contains("\"NexusNet\"") }.map {
            $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        // The product, the target, and three test targets (canvas, network, sync).
        #expect(uses.count == 5, "\(uses)")
        for u in uses {
            #expect(
                u.hasPrefix("library(name: \"NexusNetKit\"") || u.hasPrefix("target(name: \"NexusNet\"")
                    || (u.hasPrefix("testTarget(") && u.contains("Tests\"")), "\(u)")
        }
        // In the app's project: only the service target takes the product.
        let project = try String(
            contentsOf: NetworkPrivacyTests.repo.appending(path: "App/tools/make_project.py"), encoding: .utf8)
        #expect(project.components(separatedBy: "\"NexusNetKit\"").count == 2, "one target uses NexusNetKit")
        let service = try #require(project.range(of: "name=\"OpenNexusNet\""))
        #expect(project[service.lowerBound...].prefix(400).contains("packages=[\"NexusNetKit\"]"))
        // Nothing the app links imports it.
        for f in NetworkPrivacyTests.files(under: "Sources", ext: ["swift"])
            + NetworkPrivacyTests.files(under: "App/OpenNexus", ext: ["swift"])
            + NetworkPrivacyTests.files(under: "App/Extensions", ext: ["swift"])
        where !f.path.contains("/Sources/NexusNet/") {
            let text = try String(contentsOf: f, encoding: .utf8)
            #expect(!text.contains("import NexusNet"), "\(f.lastPathComponent) imports the network code")
        }
    }

    /// Every switch under Privacy & Data › Network is off on a fresh install.
    @Test @MainActor func theNetworkIsOffByDefault() {
        let rows = SettingsSchema.allRows.map(\.2).filter { $0.key.hasPrefix("network.") }
        #expect(!rows.isEmpty)
        for r in rows { #expect(r.defaultValue == .bool(false), "\(r.key)") }
        let prefs = Preferences.isolated()
        #expect(!prefs.bool("network.enabled") && !prefs.bool("network.sharing"))
    }

    /// The interactive viewer (M43) opens offline: neither its source nor the copy built into
    /// the app may reach the network (exported pages also forbid it by CSP; HTMLExportTests).
    @Test func theViewerMakesNoRequests() throws {
        let banned = [
            "fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "serviceWorker", "importScripts",
            "new Worker", "import(", "<link", "<iframe", "eval(", "new Function",
        ]
        let files =
            NetworkPrivacyTests.files(under: "Sources/NexusCanvas/Viewer", ext: ["js", "css"])
            + NetworkPrivacyTests.files(under: "web/viewer-core/src", ext: ["ts", "css"])
        #expect(files.count >= 9, "the built viewer and its sources")
        var hits: [String] = []
        for f in files {
            // SVG's and XLink's namespace names are URIs, not addresses anything loads.
            let text = try String(contentsOf: f, encoding: .utf8)
                .replacingOccurrences(of: "http://www.w3.org/2000/svg", with: "")
                .replacingOccurrences(of: "http://www.w3.org/1999/xlink", with: "")
            for b in banned where text.contains(b) { hits.append("\(f.lastPathComponent): \(b)") }
            if f.pathExtension == "css", text.contains("@import") || text.contains("url(") {
                hits.append("\(f.lastPathComponent): a stylesheet reference")
            }
            if text.range(of: #"(https?:)?//[A-Za-z0-9-]+\.[A-Za-z]"#, options: .regularExpression) != nil,
                f.pathExtension != "ts"
            {
                hits.append("\(f.lastPathComponent): an address")
            }
        }
        #expect(hits.isEmpty, "network code in the viewer: \(hits)")
    }

    @Test func onlyTheServiceHasANetworkEntitlement() throws {
        let ents = NetworkPrivacyTests.files(under: "App/Support", ext: ["entitlements"])
        #expect(ents.count >= 8, "the app, five extensions, the network service and the CLI")
        for f in ents {
            let text = try String(contentsOf: f, encoding: .utf8)
            if f.lastPathComponent == "OpenNexusNet.entitlements" {
                // Outgoing connections only.
                #expect(text.contains("<key>com.apple.security.network.client</key>"))
                #expect(!text.contains("com.apple.security.network.server"))
                #expect(!text.contains("com.apple.security.files") && !text.contains("application-groups"))
            } else {
                #expect(!text.contains("com.apple.security.network"), "\(f.lastPathComponent) asks for the network")
            }
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
