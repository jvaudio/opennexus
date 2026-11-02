import Foundation
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene

/// The user's own starters (M50): one `.nexusstarter` file each in `Starters/` in the App
/// Group, so `nexus` and the MCP server list them too; in the app's own container when
/// there's no group (an unsigned build). The files are what Export Starter… writes.
public final class MyStarters: @unchecked Sendable {
    public static let fileExtension = "nexusstarter"
    public static let packExtension = "nexusstarters"

    /// Nil when there's nowhere to keep them.
    public let folder: URL?
    private let lock = NSLock()
    private var loaded: [Starter]?

    public init(folder: URL?) { self.folder = folder }

    /// The app's: the App Group's `Starters/`, else Application Support's.
    public static let shared = MyStarters(folder: defaultFolder)

    static var defaultFolder: URL? {
        if let group = AppGroup.container { return group.appending(path: "Starters") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "OpenNexus/Starters")
    }

    /// Every starter in the folder, by name. A file that doesn't read is left out.
    public var all: [Starter] {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let read = Self.read(folder)
        loaded = read
        return read
    }

    /// Reads the folder again (after another process installed one).
    public func reload() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    public func starter(_ id: String) -> Starter? { all.first { $0.id == id } }

    /// Where a starter's file is.
    public func url(of id: String) -> URL? { folder?.appending(path: "\(id).\(Self.fileExtension)") }

    static func read(_ folder: URL?) -> [Starter] {
        guard let folder,
            let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [Starter] = []
        for url in urls where url.pathExtension == fileExtension {
            guard let data = try? Data(contentsOf: url),
                let s = try? StarterFile.read(data, name: url.lastPathComponent).first
            else { continue }
            out.append(s)
        }
        return out.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    /// Writes one starter's file, replacing any with its id. A file that wouldn't read back
    /// isn't written.
    func write(_ s: Starter) throws {
        guard let folder, let url = url(of: s.id) else {
            throw StarterFile.Refusal("There’s nowhere to keep starters.")
        }
        var s = s
        if s.summary.trimmingCharacters(in: .whitespaces).isEmpty { s.summary = DiagramDescriptor[s.type].name }
        let data = StarterFile.data(s)
        _ = try StarterFile.read(data, name: url.lastPathComponent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        reload()
    }

    /// An id no built-in or other starter of yours has: `base`, else `base-2`, `base-3`…
    public func freshID(_ base: String) -> String {
        let taken = Set(StarterLibrary.blanks.map(\.id) + StarterLibrary.templates.map(\.id) + all.map(\.id))
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// Save Canvas as Starter…: keeps it under a fresh id.
    @discardableResult
    public func save(_ s: Starter) throws -> Starter {
        var s = s
        s.id = freshID(s.id)
        s.mine = true
        try write(s)
        return s
    }

    /// Rename, Edit Details…, Move to: rewrites the file.
    public func update(_ id: String, _ body: (inout Starter) -> Void) throws {
        guard var s = starter(id) else { return }
        body(&s)
        s.id = id
        try write(s)
    }

    /// Delete: removes the file and returns the starter, for Undo (`restore`).
    @discardableResult
    public func remove(_ id: String) throws -> Starter? {
        guard let s = starter(id), let url = url(of: id) else { return nil }
        try FileManager.default.removeItem(at: url)
        reload()
        return s
    }

    public func restore(_ s: Starter) throws { try write(s) }

    // MARK: Installing

    /// What an install does with a starter whose id you already have.
    public enum Clash: Sendable { case replace, keepBoth }

    /// The incoming starters you already have one of (by id).
    public func clashes(_ incoming: [Starter]) -> [Starter] {
        let mine = Set(all.map(\.id))
        return incoming.filter { mine.contains($0.id) }
    }

    /// Installs starters read by `StarterFile.read`. One with a built-in's id gets a fresh
    /// one (a built-in can't be replaced); one you already have is replaced or kept beside
    /// yours, as `clash` says, never silently. Returns what was installed.
    @discardableResult
    public func install(_ incoming: [Starter], clash: Clash) throws -> [Starter] {
        let builtIn = Set(StarterLibrary.blanks.map(\.id) + StarterLibrary.templates.map(\.id))
        var out: [Starter] = []
        for var s in incoming {
            s.mine = true
            if builtIn.contains(s.id) {
                s.id = freshID(s.id)
            } else if starter(s.id) != nil, clash == .keepBoth {
                s.id = freshID(s.id)
                s.name = Self.copyName(s.name, taken: Set(all.map(\.name)))
            }
            try write(s)
            out.append(s)
        }
        return out
    }

    /// "Plan" → "Plan 2" (then 3…), as Finder names a copy.
    static func copyName(_ name: String, taken: Set<String>) -> String {
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}

/// Reading and writing `.nexusstarter` files and `.nexusstarters` packs (M50). Starters are
/// data: they're checked against `starter.schema.json` and read like a `.nexusjson`, and
/// nothing in them runs.
public enum StarterFile {
    /// Larger files are refused before they're read.
    public static let maxBytes = 25 * 1024 * 1024

    /// Why a file was refused, said to the user as it is.
    public struct Refusal: Error, LocalizedError, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// The starters in a file: one, or a pack's. Throws a `Refusal` saying what's wrong.
    public static func read(_ data: Data, name: String) throws -> [Starter] {
        guard data.count <= maxBytes else {
            throw Refusal(
                Loc.f(
                    "“%@” is too large to be a starter (%@; the limit is %@).", name,
                    ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)))
        }
        guard let json = try? CanonicalJSON.parse(data), case .object(let o) = json else {
            throw Refusal(Loc.f("“%@” isn’t a starter file: it isn’t JSON.", name))
        }
        let items: [JSONValue]
        if case .array(let a)? = o["starters"] {
            guard o.count == 1 else {
                throw Refusal(Loc.f("“%@” isn’t a starter pack: a pack holds only “starters”.", name))
            }
            guard !a.isEmpty else { throw Refusal(Loc.f("“%@” is an empty starter pack.", name)) }
            items = a
        } else {
            items = [json]
        }
        return try items.enumerated().map { i, v in
            let label = items.count > 1 ? "\(name) #\(i + 1)" : name
            if let issue = SchemaValidator.starter.validate(v).first {
                // An unknown field is most likely from a newer OpenNexus.
                let newer = issue.message.contains("not allowed") || issue.message.contains("additional")
                throw Refusal(
                    newer
                        ? Loc.f(
                            "“%@” isn’t a starter this version of OpenNexus can read (%@). It may come from a newer version.",
                            label, issue.description)
                        : Loc.f("“%@” isn’t a valid starter: %@.", label, issue.description))
            }
            do {
                var s = try Starter(json: CanonicalJSON.data(v))
                s.mine = true
                return s
            } catch {
                throw Refusal(Loc.f("“%@” isn’t a valid starter: %@.", label, "\(error)"))
            }
        }
    }

    /// One starter's file.
    public static func data(_ s: Starter) -> Data { CanonicalJSON.data(s.json) }

    /// A pack of several.
    public static func pack(_ starters: [Starter]) -> Data {
        CanonicalJSON.data(.object(["starters": .array(starters.map(\.json))]))
    }
}

extension Starter {
    /// Save Canvas as Starter… (M50): a starter of your own holding the canvas as it is, with
    /// its document's theme and the assets it uses.
    public static func saved(
        from canvas: Canvas, in doc: DocumentModel, name: String, collection: StarterCollection?, summary: String,
        aliases: [String]
    ) -> Starter {
        var c = canvas
        c.id = "c1"
        // The assets the canvas names (each asset's file name appears in its JSON).
        let text = String(decoding: CanonicalJSON.data(canvas.json), as: UTF8.self)
        let assets = doc.assets.filter { text.contains($0.key) }
        let d = DiagramDescriptor[canvas.type]
        var s = Starter(
            id: slug(name), name: name, summary: summary.isEmpty ? d.name : summary, kicker: d.name.uppercased(),
            category: d.category, shelf: nil, aliases: aliases, type: canvas.type, title: canvas.title, outline: [],
            relationships: [], order: 1, collection: collection)
        s.saved = DocumentModel(canvases: [c], theme: doc.theme, assets: assets)
        s.mine = true
        return s
    }

    /// An id from a name: letters and digits, words joined by hyphens ("my-plan").
    static func slug(_ name: String) -> String {
        let words = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let s = words.joined(separator: "-")
        guard let first = s.first, first.isLetter, !s.hasPrefix("blank") else {
            return "my-" + (s.isEmpty ? "starter" : s)
        }
        return s
    }
}
