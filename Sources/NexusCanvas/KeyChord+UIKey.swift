#if os(iOS)
import NexusKeys
import UIKit

extension KeyChord {
    /// Maps a hardware key press to a chord, as `KeyChord(event:)` does on the Mac.
    public init?(key: UIKey) {
        var mods: Modifiers = []
        let f = key.modifierFlags
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.alternate) { mods.insert(.option) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.command) { mods.insert(.command) }
        self.init(hidUsage: key.keyCode.rawValue, modifiers: mods, characters: key.charactersIgnoringModifiers)
    }
}
#endif
