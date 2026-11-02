import AppKit
import Carbon.HIToolbox
import NexusKeys
import Testing

@testable import NexusCanvas

/// The iPad's key mapping (USB HID usages) against the Mac's (virtual key codes).
@MainActor
struct KeyChordHIDTests {
    /// Each Mac virtual key code's USB HID usage (keyboard page 7).
    static let usages: [Int: Int] = {
        var u: [Int: Int] = [
            kVK_Tab: 0x2B, kVK_Return: 0x28, kVK_ANSI_KeypadEnter: 0x58, kVK_Escape: 0x29, kVK_Space: 0x2C,
            kVK_Delete: 0x2A, kVK_ForwardDelete: 0x4C, kVK_UpArrow: 0x52, kVK_DownArrow: 0x51, kVK_LeftArrow: 0x50,
            kVK_RightArrow: 0x4F, kVK_Home: 0x4A, kVK_End: 0x4D, kVK_PageUp: 0x4B, kVK_PageDown: 0x4E,
            kVK_ANSI_0: 0x27, kVK_ANSI_Equal: 0x2E, kVK_ANSI_Minus: 0x2D, kVK_ANSI_LeftBracket: 0x2F,
            kVK_ANSI_RightBracket: 0x30, kVK_ANSI_Quote: 0x34, kVK_ANSI_Semicolon: 0x33, kVK_ANSI_Backslash: 0x31,
            kVK_ANSI_Comma: 0x36, kVK_ANSI_Slash: 0x38, kVK_ANSI_Period: 0x37, kVK_ANSI_Grave: 0x35,
        ]
        let fs = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, k) in fs.enumerated() { u[k] = 0x3A + i }
        let letters = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
            kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ]
        for (i, k) in letters.enumerated() { u[k] = 0x04 + i }
        let digits = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        for (i, k) in digits.enumerated() { u[k] = 0x1E + i }
        return u
    }()

    /// Every key either mapping knows is known to both.
    @Test func bothMappingsKnowTheSameKeys() {
        let mac = Set(KeyChord.specialKeys.keys).union(KeyChord.ansi.keys)
        #expect(Set(Self.usages.keys) == mac)
        let hid = Set(KeyChord.hidSpecialKeys.keys).union(KeyChord.hidANSI.keys)
        #expect(Set(Self.usages.values) == hid)
    }

    @Test(arguments: [Modifiers(), .command, [.shift, .command], [.control, .option], .hyper])
    func usagesMapToTheEventsChords(modifiers: Modifiers) throws {
        for (code, usage) in Self.usages.sorted(by: { $0.key < $1.key }) {
            let chars = KeyChord.specialKeys[code]?.keyEquivalent ?? KeyChord.ansi[code].map(String.init) ?? ""
            let e = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: KeyChord(modifiers, .space).eventModifierFlags,
                    timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: false, keyCode: UInt16(code)))
            let mac = KeyChord(event: e)
            #expect(mac != nil)
            let base = e.characters(byApplyingModifiers: [])
            #expect(KeyChord(hidUsage: usage, modifiers: modifiers, characters: base) == mac, "key code \(code)")
            // A non-Latin layout: both fall back to the ANSI position.
            if KeyChord.ansi[code] != nil {
                #expect(
                    KeyChord(hidUsage: usage, modifiers: modifiers, characters: "ж")
                        == KeyChord(modifiers, .character(KeyChord.ansi[code]!)))
            }
        }
    }
}
