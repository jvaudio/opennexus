import Testing

@testable import NexusKeys

@Suite struct KeyRegistryTests {
    let registry = CommandRegistry.standard

    /// No two commands with overlapping scopes may share a chord, in any profile.
    @Test(arguments: KeyProfile.all)
    func noConflictsPerScope(profile: KeyProfile) {
        let conflicts = registry.conflicts(profile: profile)
        #expect(conflicts.isEmpty, "\(profile.name): \(conflicts)")
    }

    @Test func commandIDsAreUnique() {
        #expect(Set(registry.ids).count == registry.ids.count)
    }

    @Test(arguments: KeyProfile.all)
    func defaultsAvoidMacOSShortcuts(profile: KeyProfile) {
        for c in registry.commands {
            for chord in registry.bindings(for: c.id, profile: profile) {
                #expect(
                    SystemShortcuts.reserved[chord] == nil,
                    "\(c.id) uses \(chord) (\(SystemShortcuts.reserved[chord] ?? ""))")
            }
        }
    }

    @Test func xmindKeysUnchanged() {
        func key(_ id: CommandID) -> String? { registry.primaryBinding(for: id)?.glyphs }
        #expect(key(.addChild) == "⇥")
        #expect(key(.addSiblingAfter) == "↩")
        #expect(key(.addSiblingBefore) == "⇧↩")
        #expect(key(.addParent) == "⌘↩")
        #expect(key(.addFloating) == "⌥⌘↩")
        #expect(key(.fold) == "⌘/")
        #expect(key(.connect) == "⇧⌘L")
        #expect(key(.label) == "⇧⌘T")
        #expect(key(.aiGhosts) == "⌥Space")
        #expect(key(.convert) == "⌥⌘T")
        #expect(key(.cycleNodeStyle) == "⌥⌘S")
        #expect(key(.navigationTab(1)) == "⌃⌘1")
        #expect(key(.newCanvasFromTopic) == "⌥⌘N")
    }

    @Test func hyperBindingsMatchBrief() {
        let expected: [(CommandID, String)] = [
            (.connect, "✦C"), (.label, "✦L"), (.aiGhosts, "✦Space"), (.aiPrompt, "✦A"), (.aiPanel, "✦J"),
            (.convert, "✦T"), (.structure(1), "✦1"), (.present, "✦P"), (.focusBranch, "✦F"), (.palette, "✦K"),
            (.quickCapture, "✦N"),
        ]
        for (id, glyph) in expected {
            #expect(registry[id]?.hyper?.glyphs == glyph, "\(id)")
        }
    }

    @Test func hyperFirstPromotesHyper() {
        #expect(registry.primaryBinding(for: .connect, profile: .hyperFirst)?.glyphs == "✦C")
        #expect(registry.primaryBinding(for: .connect, profile: .openNexus)?.glyphs == "⇧⌘L")
    }

    @Test func lookupResolvesScopes() {
        let tab = KeyChord([], .tab)
        #expect(registry.command(for: tab, in: .canvas) == .addChild)
        #expect(registry.command(for: tab, in: .editor) == .commitAndAddChild)
        #expect(registry.command(for: KeyChord([.command], .character("f")), in: .editor) == .find)
        #expect(registry.command(for: KeyChord([.command], .character("k")), in: .canvas) == .palette)
        #expect(registry.command(for: KeyChord([.command], .character("k")), in: .editor) == .editorLink)
    }

    @Test func conflictDetectionFindsClashes() {
        let custom: [CommandID: [KeyChord]] = [.quickJump: [KeyChord("shift+cmd+k")!]]
        let conflicts = registry.conflicts(custom: custom)
        #expect(conflicts.contains { Set([$0.first, $0.second]) == Set([.quickJump, .hyperlink]) })
        #expect(registry.owner(of: KeyChord("shift+cmd+k")!, scope: .global, excluding: .quickJump) == .hyperlink)
    }

    @Test func chordParsingAndGlyphs() {
        #expect(KeyChord("cmd+shift+l")?.glyphs == "⇧⌘L")
        #expect(KeyChord("ctrl+opt+shift+cmd+c")?.glyphs == "✦C")
        #expect(KeyChord("opt+cmd+up")?.glyphs == "⌥⌘↑")
        #expect(KeyChord("ctrl+shift+return")?.glyphs == "⌃⇧↩")
        #expect(KeyChord("cmd+shift+l")?.spec == "shift+cmd+l")
        #expect(KeyChord("nonsense+key") == nil)
        for c in registry.commands {
            for chord in c.keys + [c.hyper].compactMap({ $0 }) {
                #expect(KeyChord(chord.spec) == chord, "\(chord.spec) does not round-trip")
            }
        }
    }

    @Test func vimProfileTurnsOffTypingReplaces() {
        #expect(!KeyProfile.vim.typingReplacesSelection)
        #expect(registry.command(for: KeyChord("j")!, in: .canvas, profile: .vim) == .selectDown)
        #expect(registry.command(for: KeyChord("j")!, in: .canvas, profile: .openNexus) == nil)
    }
}
