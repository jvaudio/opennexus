import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    /// Raycast-style Hyper: all four modifiers at once, shown as ✦.
    public static let hyper: Modifiers = [.control, .option, .shift, .command]

    /// Apple's display order: ⌃⌥⇧⌘. Hyper shows as ✦.
    public var glyphs: String {
        if self == .hyper { return "✦" }
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A physical key, independent of modifiers. Characters are the unshifted US
/// ANSI key caps (`l`, `1`, `/`, `]`), matching how shortcuts are written.
public enum Key: Hashable, Sendable {
    case character(Character)
    case tab, `return`, escape, space, delete, forwardDelete
    case up, down, left, right, home, end, pageUp, pageDown
    case function(Int)

    public var glyph: String {
        switch self {
        case .character(let c): String(c).uppercased()
        case .tab: "⇥"
        case .return: "↩"
        case .escape: "esc"
        case .space: "Space"
        case .delete: "⌫"
        case .forwardDelete: "⌦"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .function(let n): "F\(n)"
        }
    }

    /// The menu key-equivalent string AppKit expects.
    public var keyEquivalent: String {
        switch self {
        case .character(let c): String(c)
        case .tab: "\t"
        case .return: "\r"
        case .escape: "\u{1B}"
        case .space: " "
        case .delete: "\u{08}"
        case .forwardDelete: "\u{7F}"
        case .up: "\u{F700}"
        case .down: "\u{F701}"
        case .left: "\u{F702}"
        case .right: "\u{F703}"
        case .home: "\u{F729}"
        case .end: "\u{F72B}"
        case .pageUp: "\u{F72C}"
        case .pageDown: "\u{F72D}"
        case .function(let n): String(UnicodeScalar(0xF703 + n).map(Character.init) ?? " ")
        }
    }
}

public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var modifiers: Modifiers
    public var key: Key

    public init(_ modifiers: Modifiers = [], _ key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    public var isHyper: Bool { modifiers == .hyper }

    /// `⇧⌘L`, `⌥Space`, `✦C`.
    public var glyphs: String {
        let m = modifiers.glyphs
        if isHyper { return m + key.glyph }
        if case .space = key, !m.isEmpty { return m + "Space" }
        return m + key.glyph
    }

    public var description: String { glyphs }

    /// Parses `"cmd+shift+l"`, `"opt+space"`, `"hyper+c"`, `"ctrl+1"`, `"tab"`.
    public init?(_ spec: String) {
        var mods: Modifiers = []
        var key: Key?
        for raw in spec.lowercased().split(separator: "+") {
            let p = String(raw)
            switch p {
            case "cmd", "command": mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            case "hyper": mods.formUnion(.hyper)
            case "tab": key = .tab
            case "return", "enter": key = .return
            case "esc", "escape": key = .escape
            case "space": key = .space
            case "delete", "backspace": key = .delete
            case "fwddelete": key = .forwardDelete
            case "up": key = .up
            case "down": key = .down
            case "left": key = .left
            case "right": key = .right
            case "home": key = .home
            case "end": key = .end
            case "plus": key = .character("=")
            default:
                if p.count == 1, let c = p.first {
                    key = .character(c)
                } else if p.hasPrefix("f"), let n = Int(p.dropFirst()) {
                    key = .function(n)
                } else {
                    return nil
                }
            }
        }
        guard let key else { return nil }
        self.init(mods, key)
    }
}

extension KeyChord: Codable {
    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = KeyChord(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad chord \(s)"))
        }
        self = c
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(spec)
    }

    /// The parseable text form (`cmd+shift+l`).
    public var spec: String {
        var parts: [String] = []
        if modifiers == .hyper {
            parts.append("hyper")
        } else {
            if modifiers.contains(.control) { parts.append("ctrl") }
            if modifiers.contains(.option) { parts.append("opt") }
            if modifiers.contains(.shift) { parts.append("shift") }
            if modifiers.contains(.command) { parts.append("cmd") }
        }
        switch key {
        case .character(let c): parts.append(String(c))
        case .tab: parts.append("tab")
        case .return: parts.append("return")
        case .escape: parts.append("esc")
        case .space: parts.append("space")
        case .delete: parts.append("delete")
        case .forwardDelete: parts.append("fwddelete")
        case .up: parts.append("up")
        case .down: parts.append("down")
        case .left: parts.append("left")
        case .right: parts.append("right")
        case .home: parts.append("home")
        case .end: parts.append("end")
        case .pageUp: parts.append("pageup")
        case .pageDown: parts.append("pagedown")
        case .function(let n): parts.append("f\(n)")
        }
        return parts.joined(separator: "+")
    }
}
