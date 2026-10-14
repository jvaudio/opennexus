import AppKit
import NexusCore
import NexusFormat
import NexusInterchange

// The parts of M9's macOS integration that are logic rather than system glue, kept here
// so they're tested headless: the agent policy from Settings, code links, and Quick
// Capture's parsing and inbox writes.

/// Settings › Integrations › Allowed folders (one path per line).
@MainActor
public enum AgentFolders {
    public static let key = "integrations.folderList"

    public static func list(_ prefs: Preferences) -> [String] {
        prefs.string(key).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public static func set(_ paths: [String], _ prefs: Preferences) {
        var seen = Set<String>()
        prefs.set(key, paths.filter { seen.insert($0).inserted }.joined(separator: "\n"))
    }

    /// What `nexus mcp` reads (D116).
    public static func policy(_ prefs: Preferences) -> AgentPolicy {
        func access(_ k: String) -> AgentPolicy.Access { AgentPolicy.Access(rawValue: prefs.string(k)) ?? .ask }
        return AgentPolicy(
            enabled: prefs.bool("integrations.mcp"), folders: list(prefs), read: access("integrations.mcpRead"),
            edit: access("integrations.mcpEdit"), files: access("integrations.mcpFiles"))
    }
}

/// Settings › Integrations › Open code links in: a link to a source file (`file:///…/x.swift`,
/// optionally `#L42` or `:42`) opens in the chosen editor, at the line where it can.
@MainActor
public enum CodeLinks {
    public static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "java",
        "kt",
        "kts", "cs", "php", "scala", "sh", "zsh", "bash", "sql", "json", "yaml", "yml", "toml", "md", "html", "css",
        "scss", "vue", "svelte", "lua", "dart", "ex", "exs", "erl", "hs", "ml", "zig", "proto", "graphql", "tf",
        "gradle", "cmake", "mk", "xcconfig", "plist", "pbxproj", "metal",
    ]

    public struct Target: Equatable {
        public var file: URL
        public var line: Int?
    }

    /// A code file and line, or nil for anything else (web links open normally).
    public static func target(_ url: URL) -> Target? {
        guard url.isFileURL else { return nil }
        var path = url.path
        var line: Int?
        if let frag = url.fragment, frag.hasPrefix("L"), let n = Int(frag.dropFirst()) { line = n }
        if let r = path.range(of: #":(\d+)$"#, options: .regularExpression) {
            line = Int(path[r].dropFirst())
            path.removeSubrange(r)
        }
        let file = URL(fileURLWithPath: path)
        guard codeExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        return Target(file: file, line: line)
    }

    static let bundleIDs = [
        "xcode": "com.apple.dt.Xcode", "vscode": "com.microsoft.VSCode", "cursor": "com.todesktop.230313mzl4w4u92",
        "zed": "dev.zed.Zed",
    ]

    /// The URL to open: editors with a file-and-line URL scheme get one.
    public static func editorURL(_ t: Target, editor: String) -> URL? {
        let scheme = ["vscode": "vscode", "cursor": "cursor", "zed": "zed"][editor]
        guard let scheme else { return nil }
        var s =
            "\(scheme)://file\(t.file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? t.file.path)"
        if let l = t.line { s += ":\(l)" }
        return URL(string: s)
    }

    /// Opens `url`, routing code files to the chosen editor. Everything else goes to the
    /// system as before.
    public static func open(_ url: URL, prefs: Preferences, workspace: NSWorkspace = .shared) {
        let editor = prefs.string("integrations.codeLinks")
        guard let t = target(url), editor != "default" else {
            workspace.open(url)
            return
        }
        if let u = editorURL(t, editor: editor), workspace.urlForApplication(toOpen: u) != nil {
            workspace.open(u)
            return
        }
        if let id = bundleIDs[editor], let app = workspace.urlForApplication(withBundleIdentifier: id) {
            workspace.open([t.file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(t.file)
        }
    }
}

/// Quick Capture, Services and Share: turning what arrives into topics.
public enum CaptureComposer {
    public enum Result: Equatable {
        /// Topics to add to the target map, each with optional children.
        case items([Item])
        /// A new map (Settings › Multi-line text becomes: A new map).
        case map(DocumentModel)
    }

    public struct Item: Equatable, Sendable {
        public var text: String
        public var note: String?
        public var link: String?
        public var children: [String]
        public var image: AssetRef?
        public init(
            text: String, note: String? = nil, link: String? = nil, children: [String] = [], image: AssetRef? = nil
        ) {
            self.text = text
            self.note = note
            self.link = link
            self.children = children
            self.image = image
        }
    }

    /// One line is one topic. Several lines are topics (indentation keeps the hierarchy
    /// under each top line) or a new map, per Settings.
    public static func compose(_ text: String, multiline: String = "items", title: String = "Capture") -> Result? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !lines.isEmpty else { return nil }
        if lines.count == 1 { return .items([Item(text: Self.clean(lines[0]))]) }
        let tree = IndentedText.parse(lines.joined(separator: "\n"), title: title)
        if multiline == "map" {
            var report = ImportReport(source: title, format: "Text")
            let canvases = CanvasBuilder.build([tree], report: &report)
            return .map(DocumentModel(canvases: canvases))
        }
        // Indented text parses under a made-up root when there are several top lines.
        let tops = tree.synthesizedRoot ? tree.root.children : [tree.root]
        return .items(tops.map { t in Item(text: Self.clean(t.text), children: Self.flatten(t)) })
    }

    static func flatten(_ t: ITopic) -> [String] {
        t.children.flatMap { [$0.text] + flatten($0) }
    }

    /// Bullets and checkboxes typed out of habit are dropped.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for p in ["- [ ] ", "- [x] ", "* ", "- ", "• ", "+ "] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
            break
        }
        return t
    }

    /// A clipped page: its title with key points under it, and the link.
    public static func clip(title: String, points: [String], url: String?) -> Item {
        Item(text: title.isEmpty ? (url ?? "Clipped page") : title, link: url, children: points.filter { !$0.isEmpty })
    }

    /// Adds items to a canvas (under the central topic) as one undo step.
    public static func patch(adding items: [Item], to canvas: Canvas, actionName: String = "Quick Capture") -> Patch? {
        guard !items.isEmpty else { return nil }
        var e = CanvasEditor(canvas)
        var last: NodeID?
        for item in items {
            guard let id = try? e.addChild(of: canvas.root, text: item.text) else { continue }
            e.update(id) { n in
                if let note = item.note, !note.isEmpty { n.note = Note(text: note) }
                if let link = item.link { n.link = link }
                if let image = item.image { n.image = image }
            }
            for c in item.children { _ = try? e.addChild(of: id, text: c) }
            last = id
        }
        return e.patch(actionName: actionName, selectionAfter: last.map { Selection($0) })
    }
}

/// The capture panel's target line: the Inbox, then recent maps (⇥ cycles, ⇧⇥ back).
public struct CaptureTargets: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var title: String
        /// nil for the Inbox.
        public var url: URL?
        public init(title: String, url: URL?) {
            self.title = title
            self.url = url
        }
    }

    public var targets: [Target]
    public var index = 0

    public init(recents: [URL], preferLast: Bool = false) {
        targets =
            [Target(title: "Inbox map", url: nil)]
            + recents.prefix(8).map { Target(title: $0.deletingPathExtension().lastPathComponent, url: $0) }
        if preferLast, targets.count > 1 { index = 1 }
    }

    public var current: Target { targets[index] }
    public mutating func next() { index = (index + 1) % targets.count }
    public mutating func previous() { index = (index - 1 + targets.count) % targets.count }
}
