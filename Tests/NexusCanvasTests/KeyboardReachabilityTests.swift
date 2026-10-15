import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

/// M10: full keyboard reachability. Every command has a key, a menu item, or a row in
/// the command palette (⇧⌘P) that runs it; panels are reached with F6.
@MainActor
@Suite struct KeyboardReachabilityTests {
    @Test func everyCommandHasAKeyMenuOrPaletteRow() {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.select(h.canvas.nodes.first { $0.value.text == "Pricing" }!.key)
        h.controller.openPalette()
        let palette = Set(h.controller.paletteRows.map(\.id))
        var unreachable: [String] = []
        for d in CommandRegistry.standard.commands {
            let keyed = !d.keys.isEmpty || d.hyper != nil
            let menu = d.menu != .none
            let modal = d.scope == .editor || d.scope == .connect || d.scope == .find
            if !keyed && !menu && !modal && !palette.contains(d.id.rawValue) { unreachable.append(d.title) }
            // Mode commands (Edit, Connect, Find) are keyed inside their mode.
            if modal && !keyed { unreachable.append("\(d.title) (\(d.scope.rawValue))") }
        }
        #expect(unreachable.isEmpty, "no key, menu item or palette row: \(unreachable)")
    }

    @Test func panelsAreAKeyAway() throws {
        let next = try #require(CommandRegistry.standard[.nextPanel])
        let prev = try #require(CommandRegistry.standard[.previousPanel])
        #expect(next.keys == [KeyChord("f6")!] && prev.keys == [KeyChord("shift+f6")!])
        #expect(next.menu == .view && next.scope == .global)
        #expect(CommandRegistry.standard.conflicts(custom: [:]).isEmpty)
    }
}
