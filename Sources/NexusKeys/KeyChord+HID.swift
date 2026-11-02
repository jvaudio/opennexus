import Foundation

extension KeyChord {
    /// Maps a key press to a chord from its USB HID usage (keyboard page 7, what UIKit's
    /// `UIKey.keyCode` reports), the way `KeyChord(event:)` maps a Mac key code: special
    /// keys come from the usage; letters and punctuation from the layout's unshifted
    /// `characters`, falling back to the US ANSI position for non-ASCII layouts.
    public init?(hidUsage: Int, modifiers: Modifiers, characters: String?) {
        if let special = Self.hidSpecialKeys[hidUsage] {
            self.init(modifiers, special)
            return
        }
        if let base = characters?.lowercased(), base.count == 1, let c = base.first, c.isASCII, !c.isWhitespace {
            self.init(modifiers, .character(c))
            return
        }
        if let c = Self.hidANSI[hidUsage] {
            self.init(modifiers, .character(c))
            return
        }
        return nil
    }

    /// Usage → key for the keys that aren't characters (keypad Enter is Return).
    public static let hidSpecialKeys: [Int: Key] = {
        var keys: [Int: Key] = [
            0x2B: .tab, 0x28: .return, 0x58: .return, 0x29: .escape, 0x2C: .space, 0x2A: .delete,
            0x4C: .forwardDelete, 0x52: .up, 0x51: .down, 0x50: .left, 0x4F: .right, 0x4A: .home, 0x4D: .end,
            0x4B: .pageUp, 0x4E: .pageDown,
        ]
        for n in 1...12 { keys[0x39 + n] = .function(n) }
        return keys
    }()

    /// Usage → the US ANSI key cap, unshifted.
    public static let hidANSI: [Int: Character] = {
        var keys: [Int: Character] = [
            0x27: "0", 0x2E: "=", 0x2D: "-", 0x2F: "[", 0x30: "]", 0x34: "'", 0x33: ";", 0x31: "\\", 0x36: ",",
            0x38: "/", 0x37: ".", 0x35: "`",
        ]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { keys[0x04 + i] = c }
        for (i, c) in "123456789".enumerated() { keys[0x1E + i] = c }
        return keys
    }()
}
