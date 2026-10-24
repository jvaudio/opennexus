import Foundation
import Testing

@testable import NexusTheme

/// `BrandColor` holds the same values as the kit's colour sets (brand/xcode/Colors) and
/// the app catalog's copies of them, so code and assets can't drift apart.
@Suite struct BrandColorTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// "#RRGGBB" for each appearance of a colour set.
    static func colorset(_ url: URL) throws -> (light: String, dark: String) {
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url.appending(path: "Contents.json")))
                as? [String: Any])
        var light = "", dark = ""
        for c in json["colors"] as? [[String: Any]] ?? [] {
            let comps = (c["color"] as? [String: Any])?["components"] as? [String: String] ?? [:]
            let hex =
                "#"
                + ["red", "green", "blue"].map { (comps[$0] ?? "").replacingOccurrences(of: "0x", with: "") }
                .joined()
            if c["appearances"] == nil { light = hex.uppercased() } else { dark = hex.uppercased() }
        }
        return (light, dark)
    }

    @Test(arguments: ["brand/xcode/Colors", "App/OpenNexus/Assets.xcassets/Colors"])
    func matchesTheColourSets(_ folder: String) throws {
        let dir = Self.repo.appending(path: folder)
        let sets = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".colorset") }
        #expect(Set(sets.map { String($0.dropLast(".colorset".count)) }) == Set(BrandColor.catalog.keys))
        for name in sets {
            let key = String(name.dropLast(".colorset".count))
            let (light, dark) = try Self.colorset(dir.appending(path: name))
            let c = try #require(BrandColor.catalog[key])
            #expect(c.light.hex == light && c.dark.hex == dark, "\(folder)/\(name)")
        }
    }
}
