import Testing

@testable import NexusKeys

@Suite struct HIDUsageTests {
    @Test func specialKeysComeFromTheUsage() {
        #expect(KeyChord(hidUsage: 0x28, modifiers: [], characters: "\r") == KeyChord("return"))
        #expect(KeyChord(hidUsage: 0x58, modifiers: [], characters: "\r") == KeyChord("return"), "keypad Enter")
        #expect(KeyChord(hidUsage: 0x2C, modifiers: .option, characters: " ") == KeyChord("opt+space"))
        #expect(KeyChord(hidUsage: 0x52, modifiers: [.option, .command], characters: nil) == KeyChord("opt+cmd+up"))
        #expect(KeyChord(hidUsage: 0x45, modifiers: [], characters: nil) == KeyChord([], .function(12)))
    }

    @Test func charactersFollowTheLayout() {
        // AZERTY: the key in QWERTY's Q position types A.
        #expect(KeyChord(hidUsage: 0x14, modifiers: .command, characters: "a") == KeyChord("cmd+a"))
        // Shift doesn't change the key: ⇧⌘L arrives as "L".
        #expect(KeyChord(hidUsage: 0x0F, modifiers: [.shift, .command], characters: "L") == KeyChord("shift+cmd+l"))
    }

    @Test func nonLatinLayoutsFallBackToTheANSIPosition() {
        #expect(KeyChord(hidUsage: 0x0F, modifiers: .command, characters: "д") == KeyChord("cmd+l"))
        #expect(KeyChord(hidUsage: 0x38, modifiers: .command, characters: nil) == KeyChord("cmd+/"))
        #expect(KeyChord(hidUsage: 0xE3, modifiers: .command, characters: nil) == nil, "a modifier alone")
    }

    @Test func tablesCoverTheKeyboard() {
        #expect(KeyChord.hidANSI.count == 47)
        #expect(Set(KeyChord.hidANSI.values).count == 47)
        #expect(KeyChord.hidSpecialKeys.count == 27)
        #expect(Set(KeyChord.hidANSI.keys).isDisjoint(with: KeyChord.hidSpecialKeys.keys))
    }
}
