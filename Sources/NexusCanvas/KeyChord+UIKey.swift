#if os(iOS)
import NexusKeys
import UIKit

extension KeyChord {
    /// Maps a hardware key press to a chord, as `KeyChord(event:)` does on the Mac.
    @MainActor public init?(key: UIKey) {
        var mods: Modifiers = []
        let f = key.modifierFlags
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.alternate) { mods.insert(.option) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.command) { mods.insert(.command) }
        // The system sends ⌘. as Esc on the "." key: its characters say Esc (D406).
        if key.charactersIgnoringModifiers == UIKeyCommand.inputEscape || key.characters == UIKeyCommand.inputEscape {
            self.init([], .escape)
            return
        }
        self.init(hidUsage: key.keyCode.rawValue, modifiers: mods, characters: key.charactersIgnoringModifiers)
    }
}
#endif
