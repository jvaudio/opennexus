import Foundation
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange

/// Reading and writing maps on disk for the CLI and the MCP server. Every access is
/// coordinated (`NSFileCoordinator`), so a document open in OpenNexus notices the
/// change at once and takes it as one undoable edit.
public enum MapFiles {
    public static let extensions = ["nexus", "nexusjson"]

    public static func isMap(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    public struct FileError: Error, CustomStringConvertible {
        public var description: String
        public init(_ d: String) { description = d }
    }

    public static func read(_ url: URL) throws -> DocumentModel {
        var result: Result<DocumentModel, any Error> = .failure(FileError("Couldn't read \(url.lastPathComponent)."))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result {
                if u.pathExtension.lowercased() == "nexusjson" {
                    return try DocumentJSON.parse(Data(contentsOf: u), name: u.lastPathComponent)
                }
                return try NexusPackage.read(from: u)
            }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// Writes `doc`, replacing the file. Packages get a fresh `preview.png` (never for
    /// encrypted documents, which agents can't open anyway).
    @MainActor
    public static func write(_ doc: DocumentModel, to url: URL) throws {
        let isJSON = url.pathExtension.lowercased() == "nexusjson"
        let wrapper: FileWrapper
        if isJSON {
            wrapper = FileWrapper(
                regularFileWithContents: Data(DocumentJSON.export(doc, pretty: true, assets: true).utf8))
        } else {
            var files = NexusPackage.files(for: doc)
            if let png = HeadlessExport.previewPNG(doc) { files[NexusPackage.previewName] = png }
            wrapper = NexusPackage.directoryWrapper(from: files)
        }
        var failure: (any Error)?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try wrapper.write(to: u, options: [.atomic], originalContentsURL: nil) } catch { failure = error }
        }
        if let coordError { throw coordError }
        if let failure { throw failure }
    }

    /// Writes exported bytes (coordinated too: the target may be open elsewhere).
    public static func write(_ data: Data, to url: URL) throws {
        var failure: (any Error)?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { failure = error }
        }
        if let coordError { throw coordError }
        if let failure { throw failure }
    }
}

/// The folders an agent may use (Settings › Integrations › Allowed folders). Paths are
/// resolved (symlinks, `..`, `~`) before they're compared, component by component, so
/// `/Maps-private` is not inside `/Maps` and a link out of a folder doesn't escape it.
public struct FolderScope: Sendable {
    public let roots: [URL]

    public init(_ paths: [String]) {
        roots = paths.filter { !$0.isEmpty }.map {
            Self.resolve(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
        }
    }

    /// Resolves through the deepest existing ancestor, so not-yet-created outputs work.
    static func resolve(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        var existing = std
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for r in rest { out.append(path: r) }
        return out.standardizedFileURL
    }

    public func contains(_ url: URL) -> Bool {
        let t = Self.resolve(url).pathComponents
        return roots.contains { r in
            let rc = r.pathComponents
            return t.count >= rc.count && Array(t.prefix(rc.count)) == rc
        }
    }

    /// A path from an agent: absolute, `~`, or relative to the first allowed folder.
    public func url(for path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return roots.first.map { $0.appending(path: expanded) }
    }

    /// Every map in the allowed folders (packages aren't descended into), newest first.
    public func maps(limit: Int = 500) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard
                let e = fm.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for case let u as URL in e {
                if MapFiles.isMap(u) {
                    out.append(u)
                    e.skipDescendants()
                    if out.count >= limit { break }
                }
            }
        }
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return out.sorted { date($0) > date($1) }
    }
}
