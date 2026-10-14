import Foundation

public struct CommandID: RawRepresentable, Hashable, Sendable, Comparable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: CommandID, b: CommandID) -> Bool { a.rawValue < b.rawValue }
}

/// Where a binding is live. Commands in different scopes may share a key; `global`
/// commands conflict with every scope.
public enum Scope: String, Sendable, CaseIterable, Codable {
    /// Anywhere in a document window.
    case global
    /// Canvas in Select mode.
    case canvas
    /// A node's text editor (Edit mode).
    case editor
    /// Connect mode.
    case connect
    /// Outline view.
    case outline
    /// The find and replace bar.
    case find

    public var title: String {
        switch self {
        case .global: "Everywhere"
        case .canvas: "Select"
        case .editor: "Edit"
        case .connect: "Connect"
        case .outline: "Outline"
        case .find: "Find"
        }
    }

    public func overlaps(_ other: Scope) -> Bool {
        self == other || self == .global || other == .global
    }
}

public enum CommandCategory: String, Sendable, CaseIterable {
    case create = "Create"
    case edit = "Edit text"
    case navigate = "Navigate & select"
    case restructure = "Restructure"
    case elements = "Add elements"
    case style = "Style"
    case view = "View"
    case ai = "AI"
    case file = "File"
    case app = "App"
}

/// The top-level menu a command appears in. Menus are generated from the registry.
public enum MenuPlacement: String, Sendable, CaseIterable {
    case file = "File"
    case edit = "Edit"
    case insert = "Insert"
    case topic = "Topic"
    case format = "Format"
    case view = "View"
    case ai = "AI"
    case none
}

/// Everything about a command except how it runs. Handlers are bound by id in the
/// app layer, so the registry stays pure and testable.
public struct CommandDescriptor: Identifiable, Sendable {
    public var id: CommandID
    public var title: String
    public var category: CommandCategory
    public var scope: Scope
    /// Default bindings in the OpenNexus (Xmind-compatible) profile.
    public var keys: [KeyChord]
    /// The Hyper (✦) binding, if any.
    public var hyper: KeyChord?
    public var menu: MenuPlacement
    /// Ships with Xmind's binding (`XMIND` tag) rather than being an OpenNexus addition (`NEW`).
    public var isXmindDefault: Bool
    /// One-line hint shown in the cheat sheet and Settings › Shortcuts.
    public var note: String
    /// A standard AppKit action (`undo:`, `copy:`) to send instead of a custom handler.
    public var standardAction: String?

    public init(
        _ id: CommandID, _ title: String, _ category: CommandCategory, scope: Scope = .canvas,
        keys: [KeyChord] = [], hyper: KeyChord? = nil, menu: MenuPlacement = .none,
        xmind: Bool = false, note: String = "", standardAction: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.scope = scope
        self.keys = keys
        self.hyper = hyper
        self.menu = menu
        self.isXmindDefault = xmind
        self.note = note
        self.standardAction = standardAction
    }
}
