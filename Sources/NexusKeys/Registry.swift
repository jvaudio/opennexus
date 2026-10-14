import Foundation

/// A named set of binding overrides on top of the defaults.
public struct KeyProfile: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// Replaces a command's default keys. An empty array unbinds it.
    public var overrides: [CommandID: [KeyChord]]
    /// Extra bindings added alongside the defaults (aliases).
    public var additions: [CommandID: [KeyChord]]
    /// Use Hyper bindings as the primary binding for OpenNexus-only commands.
    public var hyperFirst: Bool
    /// Whether typing a printable key over a selected node replaces its text.
    public var typingReplacesSelection: Bool

    public init(
        id: String, name: String, overrides: [CommandID: [KeyChord]] = [:],
        additions: [CommandID: [KeyChord]] = [:], hyperFirst: Bool = false,
        typingReplacesSelection: Bool = true
    ) {
        self.id = id
        self.name = name
        self.overrides = overrides
        self.additions = additions
        self.hyperFirst = hyperFirst
        self.typingReplacesSelection = typingReplacesSelection
    }
}

/// A conflict: two commands whose scopes overlap share a chord.
public struct KeyConflict: Hashable, Sendable, CustomStringConvertible {
    public var chord: KeyChord
    public var first: CommandID
    public var second: CommandID
    public var description: String { "\(chord.glyphs): \(first) ↔ \(second)" }
}

/// The single source of truth for commands. Menus, the command palette, the ⌘-hold
/// cheat sheet, Settings › Shortcuts and App Intents are all generated from it.
public struct CommandRegistry: Sendable {
    public private(set) var commands: [CommandDescriptor]
    private var index: [CommandID: Int]

    public init(_ commands: [CommandDescriptor]) {
        self.commands = commands
        self.index = Dictionary(commands.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public static let standard = CommandRegistry(DefaultCommands.all)

    public subscript(id: CommandID) -> CommandDescriptor? {
        index[id].map { commands[$0] }
    }

    public var ids: [CommandID] { commands.map(\.id) }

    /// Resolved bindings for a command under a profile and the user's customisations.
    public func bindings(
        for id: CommandID, profile: KeyProfile = .openNexus,
        custom: [CommandID: [KeyChord]] = [:]
    ) -> [KeyChord] {
        guard let c = self[id] else { return [] }
        if let user = custom[id] { return user }
        var keys = profile.overrides[id] ?? c.keys
        keys += profile.additions[id] ?? []
        if let h = c.hyper {
            if profile.hyperFirst && !c.isXmindDefault { keys.insert(h, at: 0) } else { keys.append(h) }
        }
        var seen = Set<KeyChord>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// The binding shown in menus and the palette (first one).
    public func primaryBinding(
        for id: CommandID, profile: KeyProfile = .openNexus,
        custom: [CommandID: [KeyChord]] = [:]
    ) -> KeyChord? {
        bindings(for: id, profile: profile, custom: custom).first
    }

    /// Finds the command a chord triggers in a scope (global commands always apply).
    public func command(
        for chord: KeyChord, in scope: Scope, profile: KeyProfile = .openNexus,
        custom: [CommandID: [KeyChord]] = [:]
    ) -> CommandID? {
        let table = lookupTable(profile: profile, custom: custom)
        return table[scope]?[chord] ?? table[.global]?[chord]
    }

    /// chord → command per scope. Build once per profile change and cache it.
    public func lookupTable(
        profile: KeyProfile = .openNexus,
        custom: [CommandID: [KeyChord]] = [:]
    ) -> [Scope: [KeyChord: CommandID]] {
        var table: [Scope: [KeyChord: CommandID]] = [:]
        for c in commands {
            for chord in bindings(for: c.id, profile: profile, custom: custom) where table[c.scope]?[chord] == nil {
                table[c.scope, default: [:]][chord] = c.id
            }
        }
        return table
    }

    /// Every pair of commands with overlapping scopes that share a chord.
    public func conflicts(
        profile: KeyProfile = .openNexus,
        custom: [CommandID: [KeyChord]] = [:]
    ) -> [KeyConflict] {
        var out: [KeyConflict] = []
        var owners: [KeyChord: [(CommandID, Scope)]] = [:]
        for c in commands {
            for chord in bindings(for: c.id, profile: profile, custom: custom) {
                for (other, scope) in owners[chord] ?? [] where scope.overlaps(c.scope) {
                    out.append(KeyConflict(chord: chord, first: other, second: c.id))
                }
                owners[chord, default: []].append((c.id, c.scope))
            }
        }
        return out
    }

    /// Who already uses this chord in an overlapping scope (for the shortcut recorder).
    public func owner(
        of chord: KeyChord, scope: Scope, excluding: CommandID? = nil, profile: KeyProfile = .openNexus,
        custom: [CommandID: [KeyChord]] = [:]
    ) -> CommandID? {
        commands.first { c in
            c.id != excluding && c.scope.overlaps(scope)
                && bindings(for: c.id, profile: profile, custom: custom).contains(chord)
        }?.id
    }
}

/// Shortcuts macOS reserves system-wide. Defaults must never use them.
public enum SystemShortcuts {
    public static let reserved: [KeyChord: String] = [
        KeyChord([.command], .character("q")): "Quit",
        KeyChord([.command], .character("h")): "Hide",
        KeyChord([.command, .option], .character("h")): "Hide Others",
        KeyChord([.command], .character("m")): "Minimize",
        KeyChord([.command], .character("w")): "Close Window",
        KeyChord([.command], .character("`")): "Cycle Windows",
        KeyChord([.command], .tab): "App Switcher",
        KeyChord([.command], .space): "Spotlight",
        KeyChord([.command, .option], .space): "Finder Search",
        KeyChord([.control], .space): "Input Sources",
        KeyChord([.control, .option], .space): "Next Input Source",
        KeyChord([.control], .up): "Mission Control",
        KeyChord([.control], .down): "App Windows",
        KeyChord([.control], .left): "Move Space Left",
        KeyChord([.control], .right): "Move Space Right",
        KeyChord([.command, .shift], .character("3")): "Screenshot",
        KeyChord([.command, .shift], .character("4")): "Screenshot Selection",
        KeyChord([.command, .shift], .character("5")): "Screenshot Toolbar",
        KeyChord([.command, .option], .escape): "Force Quit",
        KeyChord([.command, .control], .character("q")): "Lock Screen",
        KeyChord([.command, .control], .character("f")): "Full Screen",
        KeyChord([.command, .control], .space): "Emoji & Symbols",
        KeyChord([.command], .character(",")): "Settings",
        KeyChord([.command, .option], .character("d")): "Dock",
    ]
}
