import AppKit
import Carbon.HIToolbox
import NexusKeys

extension KeyChord {
    /// Maps a key event to a chord. Special keys come from the key code; letters and
    /// punctuation come from the current layout's unshifted character, falling back to
    /// the US ANSI position for non-ASCII layouts.
    public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        var mods: Modifiers = []
        let f = event.modifierFlags
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.command) { mods.insert(.command) }
        if let special = Self.specialKeys[Int(event.keyCode)] {
            self.init(mods, special)
            return
        }
        if let base = event.characters(byApplyingModifiers: [])?.lowercased(), base.count == 1, let c = base.first,
            c.isASCII, !c.isWhitespace
        {
            self.init(mods, .character(c))
            return
        }
        if let c = Self.ansi[Int(event.keyCode)] {
            self.init(mods, .character(c))
            return
        }
        return nil
    }

    static let specialKeys: [Int: Key] = [
        kVK_Tab: .tab, kVK_Return: .return, kVK_ANSI_KeypadEnter: .return, kVK_Escape: .escape, kVK_Space: .space,
        kVK_Delete: .delete, kVK_ForwardDelete: .forwardDelete, kVK_UpArrow: .up, kVK_DownArrow: .down,
        kVK_LeftArrow: .left, kVK_RightArrow: .right, kVK_Home: .home, kVK_End: .end, kVK_PageUp: .pageUp,
        kVK_PageDown: .pageDown, kVK_F1: .function(1), kVK_F2: .function(2), kVK_F3: .function(3),
        kVK_F4: .function(4), kVK_F5: .function(5), kVK_F6: .function(6), kVK_F7: .function(7),
        kVK_F8: .function(8), kVK_F9: .function(9), kVK_F10: .function(10), kVK_F11: .function(11),
        kVK_F12: .function(12),
    ]

    static let ansi: [Int: Character] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
        kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
        kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`",
    ]

    /// The key code for a chord's key (US ANSI), used to synthesise events in tests.
    public var keyCode: UInt16? {
        if let k = Self.specialKeys.first(where: { $0.value == key })?.key { return UInt16(k) }
        if case .character(let c) = key, let k = Self.ansi.first(where: { $0.value == c })?.key { return UInt16(k) }
        return nil
    }

    public var eventModifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        if modifiers.contains(.command) { f.insert(.command) }
        return f
    }

    /// Modifier mask for an `NSMenuItem` key equivalent.
    public var menuModifierMask: NSEvent.ModifierFlags { eventModifierFlags }
}
