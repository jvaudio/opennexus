import Foundation
import NexusCore

// Shared by the app, its extensions (Quick Look, Spotlight, Share, Widgets) and the
// `nexus` CLI. Everything here is plain data on disk: no IPC, no network.

/// What Spotlight learns about a document: its title, and the text of every topic, note
/// and label (README §6).
public struct SpotlightText: Equatable, Sendable {
    public struct Topic: Equatable, Sendable {
        public var canvas: CanvasID
        public var node: NodeID
        public var text: String
        /// "Canvas title › Parent › …" for the result's subtitle.
        public var breadcrumb: String
        public var note: String?
        public var labels: [String]
    }

    public var title: String
    public var topics: [Topic]

    /// Everything as one string, for a file's `textContent`.
    public var content: String {
        topics.flatMap { [$0.text] + $0.labels + ($0.note.map { [$0] } ?? []) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public var keywords: [String] { Array(Set(topics.flatMap(\.labels))).sorted() }

    public init(_ doc: DocumentModel, fileName: String) {
        title = (fileName as NSString).deletingPathExtension
        var out: [Topic] = []
        for c in doc.orderedCanvases {
            let parents = c.parentMap()
            func crumb(_ id: NodeID) -> String {
                var path: [String] = []
                var cur = parents[id]
                while let p = cur, p != c.root {
                    path.insert(c.nodes[p]?.text ?? "", at: 0)
                    cur = parents[p]
                }
                return ([c.title] + path).filter { !$0.isEmpty }.joined(separator: " › ")
            }
            for top in [c.root] + c.floating {
                c.walk(from: top) { id, n, _ in
                    guard !n.text.isEmpty else { return }
                    out.append(
                        Topic(
                            canvas: c.id, node: id, text: n.text, breadcrumb: crumb(id),
                            note: n.note.map(\.text).flatMap { $0.isEmpty ? nil : $0 }, labels: n.labels))
                }
            }
        }
        topics = out
    }
}

/// The App Group shared by the app, its extensions and the CLI:
/// `<TeamID>.com.opennexus`. Team-prefixed groups need no provisioning profile on macOS.
public enum AppGroup {
    public static let suffix = "com.opennexus"
    /// Info.plist key holding the expanded `$(TeamIdentifierPrefix)com.opennexus`.
    public static let infoKey = "OpenNexusAppGroup"

    /// The group identifier for this process, from its Info.plist (app and extensions).
    public static var identifier: String? {
        // Unsigned builds expand to just the suffix: no group, so the fallbacks apply.
        guard let id = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String, id.hasSuffix(".\(suffix)"),
            !id.hasPrefix(".")
        else { return nil }
        return id
    }

    /// The shared container, or nil in an unsigned build.
    public static var container: URL? {
        guard let id = identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// A group container path for a team, without asking the system (the CLI's view).
    public static func container(team: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Group Containers/\(team).\(suffix)")
    }
}

/// Something sent to OpenNexus from outside the app: Share, the Safari clipper, Services.
public struct Capture: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, link, page, image }
    public var id: String
    public var kind: Kind
    public var text: String
    public var title: String?
    public var url: String?
    /// The page's readable text, for the clipper's summary.
    public var pageText: String?
    /// PNG or JPEG bytes for an image.
    public var image: Data?
    /// The chosen map: nil for the inbox, otherwise a token from the widget snapshot's
    /// recent maps (never a path).
    public var target: String?
    public var date: Date

    public init(
        kind: Kind, text: String, title: String? = nil, url: String? = nil, pageText: String? = nil,
        image: Data? = nil, target: String? = nil, date: Date = Date()
    ) {
        self.id = UUID().uuidString
        self.kind = kind
        self.text = text
        self.title = title
        self.url = url
        self.pageText = pageText
        self.image = image
        self.target = target
        self.date = date
    }
}

/// Captures waiting for the app, one JSON file each in `Captures/` (written atomically,
/// so a half-written capture is never read).
public enum CaptureQueue {
    public static func directory(in container: URL) -> URL { container.appending(path: "Captures") }

    public static func enqueue(_ c: Capture, in container: URL) throws {
        let dir = directory(in: container)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(c).write(to: dir.appending(path: "\(c.id).json"), options: .atomic)
    }

    /// Reads and removes every waiting capture, oldest first.
    public static func drain(in container: URL) -> [Capture] {
        let dir = directory(in: container)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [Capture] = []
        for u in urls where u.pathExtension == "json" {
            if let data = try? Data(contentsOf: u), let c = try? dec.decode(Capture.self, from: data) { out.append(c) }
            try? FileManager.default.removeItem(at: u)
        }
        return out.sorted { $0.date < $1.date }
    }
}

/// What the widgets show, written by the app to `Widgets/` with a thumbnail per map.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Map: Codable, Equatable, Sendable {
        /// An opaque token the app maps back to a bookmark (`opennexus://open/<token>`).
        public var token: String
        public var title: String
        public var detail: String
        /// File name of the thumbnail in `Widgets/`.
        public var thumbnail: String?
        public init(token: String, title: String, detail: String, thumbnail: String?) {
            self.token = token
            self.title = title
            self.detail = detail
            self.thumbnail = thumbnail
        }
    }

    public var inbox: [String]
    public var inboxCount: Int
    public var recents: [Map]
    public var updated: Date

    public init(inbox: [String], inboxCount: Int, recents: [Map], updated: Date = Date()) {
        self.inbox = inbox
        self.inboxCount = inboxCount
        self.recents = recents
        self.updated = updated
    }

    public static func directory(in container: URL) -> URL { container.appending(path: "Widgets") }

    public func write(to container: URL) throws {
        let dir = Self.directory(in: container)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: dir.appending(path: "snapshot.json"), options: .atomic)
    }

    public static func read(from container: URL) -> WidgetSnapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: directory(in: container).appending(path: "snapshot.json")) else {
            return nil
        }
        return try? dec.decode(WidgetSnapshot.self, from: d)
    }
}

/// Settings › Integrations › Agents, as the `nexus mcp` server reads it. The app writes
/// it whenever those settings change; it lives in the App Group, which other apps
/// (including an agent's shell) can't modify without the user's consent.
public struct AgentPolicy: Codable, Equatable, Sendable {
    public enum Access: String, Codable, Sendable, CaseIterable { case allow, ask, block }

    public var enabled: Bool
    public var folders: [String]
    public var read: Access
    public var edit: Access
    public var files: Access

    public init(
        enabled: Bool = false, folders: [String] = [], read: Access = .allow, edit: Access = .ask,
        files: Access = .ask
    ) {
        self.enabled = enabled
        self.folders = folders
        self.read = read
        self.edit = edit
        self.files = files
    }

    public static let fileName = "agent.json"

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> AgentPolicy {
        try JSONDecoder().decode(AgentPolicy.self, from: Data(contentsOf: url))
    }
}

/// Settings the extensions need (they can't read the app's preferences): written by the
/// app to the App Group whenever they change.
public struct ExtensionSettings: Codable, Equatable, Sendable {
    public var share: Bool
    public var clipper: Bool
    public init(share: Bool = true, clipper: Bool = true) {
        self.share = share
        self.clipper = clipper
    }

    public static let fileName = "extensions.json"

    public func write(to container: URL) throws {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: container.appending(path: Self.fileName), options: .atomic)
    }

    public static func read(from container: URL) -> ExtensionSettings {
        (try? Data(contentsOf: container.appending(path: fileName))).flatMap {
            try? JSONDecoder().decode(ExtensionSettings.self, from: $0)
        } ?? ExtensionSettings()
    }
}
