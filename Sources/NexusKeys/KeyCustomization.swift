import Foundation

/// The user's shortcut changes on top of a profile (Settings › Shortcuts, artboard 08):
/// replacement chords per command and narrowed scopes ("Scope to Edit"). Stored as JSON so
/// profiles can be exported and imported.
public struct KeyCustomization: Codable, Equatable, Sendable {
    public var profile: String = "opennexus"
    /// Command id → chord specs (`"shift+cmd+k"`). An empty list unbinds the command.
    public var chords: [String: [String]] = [:]
    /// Command id → scope, for bindings narrowed to avoid a conflict.
    public var scopes: [String: Scope] = [:]

    public init() {}

    public var custom: [CommandID: [KeyChord]] {
        Dictionary(
            uniqueKeysWithValues: chords.map { (CommandID(rawValue: $0.key), $0.value.compactMap(KeyChord.init)) })
    }

    public var keyProfile: KeyProfile { KeyProfile.all.first { $0.id == profile } ?? .openNexus }

    /// The registry with narrowed scopes applied.
    public func apply(to registry: CommandRegistry) -> CommandRegistry {
        guard !scopes.isEmpty else { return registry }
        return CommandRegistry(
            registry.commands.map { c in
                var c = c
                if let s = scopes[c.id.rawValue] { c.scope = s }
                return c
            })
    }

    public mutating func set(_ id: CommandID, _ chords: [KeyChord]) { self.chords[id.rawValue] = chords.map(\.spec) }

    public mutating func reset(_ id: CommandID) {
        chords[id.rawValue] = nil
        scopes[id.rawValue] = nil
    }

    public var json: Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> KeyCustomization? {
        try? JSONDecoder().decode(KeyCustomization.self, from: data)
    }

    // MARK: Recording a chord (with conflict resolution)

    public enum Resolution: Sendable, Equatable {
        /// The other command takes this command's old chord.
        case swap
        /// The other command loses the chord.
        case reassign
        /// This command's binding only applies in `scope`, where nothing else uses it.
        case scope(Scope)
    }

    /// Who would clash if `id` took `chord` as its standard binding.
    public func conflict(for id: CommandID, chord: KeyChord, registry: CommandRegistry) -> CommandID? {
        let reg = apply(to: registry)
        guard let scope = reg[id]?.scope else { return nil }
        return reg.owner(of: chord, scope: scope, excluding: id, profile: keyProfile, custom: custom)
    }

    /// Gives `id` the standard binding `chord`, resolving a clash if there is one. The
    /// command's Hyper binding (if any) is kept.
    public mutating func record(
        _ id: CommandID, chord: KeyChord, registry: CommandRegistry, resolution: Resolution? = nil
    ) {
        let reg = apply(to: registry)
        let old = reg.bindings(for: id, profile: keyProfile, custom: custom)
        let hyper = old.filter(\.isHyper)
        let previousStandard = old.first { !$0.isHyper }
        if let other = conflict(for: id, chord: chord, registry: registry), let resolution {
            let theirs = reg.bindings(for: other, profile: keyProfile, custom: custom)
            switch resolution {
            case .swap:
                set(
                    other,
                    theirs.map { $0 == chord ? (previousStandard ?? $0) : $0 }.filter {
                        $0 != chord || previousStandard == nil
                    })
            case .reassign:
                set(other, theirs.filter { $0 != chord })
            case .scope(let s):
                scopes[id.rawValue] = s
            }
        }
        set(id, [chord] + hyper)
    }

    /// The scope a narrowed binding should use to avoid `other`.
    public static func narrowing(_ mine: Scope, avoiding other: Scope) -> Scope? {
        let candidates: [Scope] = [.editor, .canvas, .outline, .connect]
        return candidates.first { !$0.overlaps(other) && (mine == .global || mine == $0) }
    }
}
