import Foundation
import Testing

@testable import NexusTheme

@Suite struct ContrastTests {
    @Test func wcagReferenceValues() {
        #expect(abs(Contrast.ratio(.black, .white) - 21) < 0.01)
        #expect(abs(Contrast.ratio(.white, .white) - 1) < 0.01)
        // #767676 on white is the classic 4.54:1 AA threshold colour.
        #expect(abs(Contrast.ratio(RGBA(hex: "#767676"), .white) - 4.54) < 0.01)
        #expect(Contrast.passes(RGBA(hex: "#767676"), .white, level: .aa))
        #expect(!Contrast.passes(RGBA(hex: "#777777").mix(.white, 0.05), .white, level: .aa))
    }

    @Test func hexRoundTrip() {
        #expect(RGBA(hex: "#5850EC").hex == "#5850EC")
        #expect(RGBA(hex: "#5850EC80").hex == "#5850EC80")
    }

    @Test func translucentBackgroundsComposite() {
        // Classic sub-topic tint over the canvas.
        let t = Theme.classic
        let ratio = Contrast.ratio(t.sub.foreground, t.sub.background, backdrop: t.canvas)
        #expect(ratio > 10)
    }
}

@Suite struct TokenTests {
    /// The Swift tokens must agree with the handoff's design-tokens.json.
    @Test func tokensMatchHandoffJSON() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Handoff/docs/design-tokens.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let signal = json["signal"] as! [String: [String: String]]
        #expect(RGBA(hex: signal["iris"]!["light"]!) == Tokens.Signal.irisLight)
        #expect(RGBA(hex: signal["iris"]!["dark"]!) == Tokens.Signal.irisDark)
        #expect(RGBA(hex: signal["amber"]!["light"]!) == Tokens.Signal.amber)
        #expect(RGBA(hex: signal["aurora"]!["light"]!) == Tokens.Signal.auroraLight)
        #expect(RGBA(hex: signal["aurora"]!["dark"]!) == Tokens.Signal.auroraDark)
        let neutral = json["neutral"] as! [String: [String: String]]
        #expect(RGBA(hex: neutral["light"]!["canvas"]!) == Tokens.neutralsLight.canvas)
        #expect(RGBA(hex: neutral["dark"]!["ink"]!) == Tokens.neutralsDark.ink)
        let palette = json["branchPalette"] as! [String: String]
        let order = ["iris", "coral", "teal", "gold", "rose", "sky", "lime", "violet"]
        #expect(order.map { RGBA(hex: palette[$0]!) } == Tokens.classicPalette)
        let motion = (json["motion"] as! [String: Any])["curves"] as! [String: [String: Any]]
        #expect(motion["snap"]!["response"] as! Double == Motion.snap.response)
        #expect(motion["settle"]!["dampingFraction"] as! Double == Motion.settle.dampingFraction)
        let radius = json["radius"] as! [String: Double]
        #expect(radius["node"] == Tokens.Radius.node)
        #expect(radius["root"] == Tokens.Radius.root)
    }

    @Test func branchColourWrapsAndShifts() {
        let t = Theme.classic
        #expect(t.branchColor(index: 0) == Tokens.classicPalette[0])
        #expect(t.branchColor(index: 8) == Tokens.classicPalette[0])
        #expect(t.branchColor(index: 0, shift: 1) == Tokens.classicPalette[1])
    }
}
