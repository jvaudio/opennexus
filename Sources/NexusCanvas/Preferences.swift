import Foundation
import Observation

/// App preferences (Settings, README §10). A thin observable layer over `UserDefaults`:
/// every row in `SettingsSchema` has a key and a default here, views observe `revision`,
/// and controllers listen for `Preferences.didChange` so changes take effect live.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences(defaults: .standard)
    public static let didChange = Notification.Name("OpenNexusPreferencesDidChange")

    @ObservationIgnored public let defaults: UserDefaults
    /// Bumps on every change (views read it to refresh).
    public private(set) var revision = 0

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// A private, empty store (tests).
    public static func isolated() -> Preferences {
        let name = "opennexus.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return Preferences(defaults: d)
    }

    func fallback(_ key: String) -> PrefValue? { SettingsSchema.defaults[key] }

    public func bool(_ key: String) -> Bool {
        _ = revision
        if let v = defaults.object(forKey: key) as? Bool { return v }
        if case .bool(let b)? = fallback(key) { return b }
        return false
    }

    public func string(_ key: String) -> String {
        _ = revision
        if let v = defaults.string(forKey: key) { return v }
        if case .string(let s)? = fallback(key) { return s }
        return ""
    }

    public func number(_ key: String) -> Double {
        _ = revision
        if let v = defaults.object(forKey: key) as? Double { return v }
        if let v = defaults.object(forKey: key) as? Int { return Double(v) }
        if case .number(let n)? = fallback(key) { return n }
        return 0
    }

    public func value(_ key: String) -> PrefValue? {
        switch fallback(key) {
        case .bool?: .bool(bool(key))
        case .string?: .string(string(key))
        case .number?: .number(number(key))
        case nil: nil
        }
    }

    public func set(_ key: String, _ value: PrefValue) {
        switch value {
        case .bool(let b): defaults.set(b, forKey: key)
        case .string(let s): defaults.set(s, forKey: key)
        case .number(let n): defaults.set(n, forKey: key)
        }
        changed(key)
    }

    public func set(_ key: String, _ b: Bool) { set(key, .bool(b)) }
    public func set(_ key: String, _ s: String) { set(key, .string(s)) }
    public func set(_ key: String, _ n: Double) { set(key, .number(n)) }

    /// Back to the schema default.
    public func reset(_ key: String) {
        defaults.removeObject(forKey: key)
        changed(key)
    }

    public func isDefault(_ key: String) -> Bool { defaults.object(forKey: key) == nil }

    /// Raw data values (shortcut overrides, bookmarks).
    public func data(_ key: String) -> Data? { defaults.data(forKey: key) }
    public func setData(_ key: String, _ d: Data?) {
        defaults.set(d, forKey: key)
        changed(key)
    }

    func changed(_ key: String) {
        revision += 1
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["key": key])
    }
}

public enum PrefValue: Hashable, Sendable {
    case bool(Bool)
    case string(String)
    case number(Double)
}
