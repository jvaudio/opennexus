import Foundation
import NexusCore

/// Reads and writes the `.nexus` directory package:
///
/// ```
/// MyMap.nexus/
/// ├── manifest.json        format, schemaVersion, app, canvases (tab order), encrypted
/// ├── canvases/c1.json     one canonical JSON file per canvas
/// ├── theme.json           document theme, custom colour themes, quick styles
/// ├── assets/              images, audio, stickers (content-hashed names)
/// ├── preview.png          Quick Look's rendered first canvas (written by the app; never
/// │                        for encrypted documents; ignored by Git and by reading)
/// ├── snapshots/           recovery snapshots (ignored by Git)
/// └── .gitignore           generated: `snapshots/` and `preview.png`
/// ```
public enum NexusPackage {
    public static let fileExtension = "nexus"
    public static let typeIdentifier = "com.opennexus.document"
    public static let appVersion = "1.0"
    /// Quick Look's rendered snapshot inside the package.
    public static let previewName = "preview.png"

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case missingFile(String)
        case notOpenNexus(String)
        case newerSchema(Int)
        case invalid(String)
        /// Password-protected; the hint, if any, is readable.
        case encrypted(String?)

        public var description: String {
            switch self {
            case .encrypted(let h): "This document is password-protected" + (h.map { " (hint: \($0))" } ?? "") + "."
            case .missingFile(let f): "The package is missing \(f)."
            case .notOpenNexus(let f): "This is not an OpenNexus file (format “\(f)”)."
            case .newerSchema(let v): "This file was made by a newer OpenNexus (schema \(v))."
            case .invalid(let m): m
            }
        }
    }

    // MARK: Files

    /// The package as relative path → bytes. Pure, so tests can diff it directly.
    public static func files(for doc: DocumentModel) -> [String: Data] {
        var files: [String: Data] = [:]
        var manifest = ObjectWriter(extra: doc.manifestExtra)
        manifest.set("format", DocumentModel.formatName)
        manifest.set("schemaVersion", .number(Double(DocumentModel.schemaVersion)))
        manifest.set("app", appVersion)
        manifest.set("canvases", doc.canvasOrder.map(\.rawValue), omitEmpty: false)
        manifest.set("encrypted", .bool(doc.encrypted))
        files["manifest.json"] = CanonicalJSON.data(manifest.value)
        for canvas in doc.orderedCanvases {
            files["canvases/\(canvas.id.rawValue).json"] = CanonicalJSON.data(canvas.json)
        }
        files["theme.json"] = CanonicalJSON.data(doc.theme)
        if !doc.chats.isEmpty {
            files["ai/chats.json"] = CanonicalJSON.data(.object(["chats": .array(doc.chats.map(\.json))]))
        }
        for (name, data) in doc.assets {
            files["assets/\(name)"] = data
        }
        files[".gitignore"] = Data("snapshots/\npreview.png\n".utf8)
        return files
    }

    public static func read(files: [String: Data]) throws -> DocumentModel {
        if PackageCrypto.isEncrypted(files) { throw ReadError.encrypted(PackageCrypto.info(files)?.hint) }
        guard let manifestData = files["manifest.json"] else { throw ReadError.missingFile("manifest.json") }
        let manifestJSON = try parse(manifestData, "manifest.json")
        var m = try ObjectReader(manifestJSON, path: "manifest")
        let format = try m.optionalString("format") ?? ""
        guard format == DocumentModel.formatName else { throw ReadError.notOpenNexus(format) }
        let version = Int(try m.optionalDouble("schemaVersion") ?? 1)
        guard version <= DocumentModel.schemaVersion else { throw ReadError.newerSchema(version) }
        _ = try m.optionalString("app")
        let encrypted = try m.bool("encrypted", default: false)
        let order = try m.strings("canvases").map { CanvasID($0) }

        var canvases: [Canvas] = []
        for id in order {
            let path = "canvases/\(id.rawValue).json"
            guard let data = files[path] else { throw ReadError.missingFile(path) }
            let canvas = try Canvas(json: try parse(data, path), path: id.rawValue)
            guard canvas.id == id else { throw ReadError.invalid("\(path) has id \(canvas.id)") }
            canvases.append(canvas)
        }
        guard !canvases.isEmpty else { throw ReadError.invalid("The document has no canvases.") }

        var doc = DocumentModel(canvases: canvases)
        doc.encrypted = encrypted
        doc.manifestExtra = m.leftovers
        if let t = files["theme.json"] { doc.theme = try parse(t, "theme.json") }
        if let c = files["ai/chats.json"] {
            var r = try ObjectReader(try parse(c, "ai/chats.json"), path: "chats")
            doc.chats = try r.array("chats").enumerated().map { try AIChat(json: $1, path: "chats[\($0)]") }
        }
        for (path, data) in files where path.hasPrefix("assets/") && path.count > "assets/".count {
            doc.assets[String(path.dropFirst("assets/".count))] = data
        }
        return doc
    }

    private static func parse(_ data: Data, _ name: String) throws -> JSONValue {
        do {
            return try CanonicalJSON.parse(data)
        } catch {
            throw ReadError.invalid("\(name) is not valid JSON.")
        }
    }

    // MARK: File wrappers and URLs

    public static func fileWrapper(for doc: DocumentModel) -> FileWrapper {
        directoryWrapper(from: files(for: doc))
    }

    public static func read(from wrapper: FileWrapper) throws -> DocumentModel {
        try read(files: flatten(wrapper))
    }

    public static func write(_ doc: DocumentModel, to url: URL) throws {
        let wrapper = fileWrapper(for: doc)
        try wrapper.write(to: url, options: [.atomic], originalContentsURL: nil)
    }

    public static func read(from url: URL) throws -> DocumentModel {
        let wrapper = try FileWrapper(url: url, options: [.immediate])
        return try read(from: wrapper)
    }

    public static func directoryWrapper(from files: [String: Data]) -> FileWrapper {
        final class Dir {
            var files: [String: Data] = [:]
            var dirs: [String: Dir] = [:]
        }
        let root = Dir()
        for (path, data) in files {
            var parts = path.split(separator: "/").map(String.init)
            let name = parts.removeLast()
            var cur = root
            for p in parts {
                if cur.dirs[p] == nil { cur.dirs[p] = Dir() }
                cur = cur.dirs[p]!
            }
            cur.files[name] = data
        }
        func wrap(_ d: Dir) -> FileWrapper {
            var children: [String: FileWrapper] = [:]
            for (n, data) in d.files {
                let w = FileWrapper(regularFileWithContents: data)
                w.preferredFilename = n
                children[n] = w
            }
            for (n, sub) in d.dirs {
                let w = wrap(sub)
                w.preferredFilename = n
                children[n] = w
            }
            return FileWrapper(directoryWithFileWrappers: children)
        }
        return wrap(root)
    }

    public static func flatten(_ wrapper: FileWrapper, prefix: String = "") -> [String: Data] {
        var out: [String: Data] = [:]
        for (name, child) in wrapper.fileWrappers ?? [:] {
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if child.isDirectory {
                // Recovery snapshots are not part of the document model.
                if path == "snapshots" { continue }
                out.merge(flatten(child, prefix: path)) { a, _ in a }
            } else if let data = child.regularFileContents {
                out[path] = data
            }
        }
        return out
    }
}
