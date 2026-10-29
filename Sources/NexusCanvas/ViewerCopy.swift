import Foundation
import NexusCore
import NexusFormat
import NexusInterchange

/// A document's viewer copy (M43, D314): the bundle a browser, a share link or Obsidian
/// shows without OpenNexus. Packages carry it as `render/viewer.json` (Settings › Files &
/// Backup › Save a viewer copy, on); single-file documents as a `render` key (Also in
/// single-file documents, off). Never for encrypted documents. It names assets rather than
/// copying them, and reading ignores it: the canvases stay the truth.
@MainActor
public enum ViewerCopy {
    public static let path = "render/viewer.json"
    public static let jsonKey = "render"

    /// The last copy built, so an unchanged document (autosave, Save twice) isn't drawn again.
    private static var cache: (model: DocumentModel, bundle: JSONValue)?

    /// The bundle for `doc`, or nil when it's encrypted.
    public static func bundle(_ doc: DocumentModel) -> JSONValue? {
        guard !doc.encrypted else { return nil }
        if let cache, cache.model == doc { return cache.bundle }
        var o = ViewerBundle.Options()
        o.attachments = true
        o.embedAssets = false
        let b = ViewerBundle.build(doc, o)
        cache = (doc, b)
        return b
    }

    /// `render/viewer.json`'s bytes: one line of canonical JSON.
    public static func data(_ doc: DocumentModel) -> Data? {
        bundle(doc).map { Data((CanonicalJSON.compact($0) + "\n").utf8) }
    }

    /// Adds the copy to a package's files when `prefs` ask for it.
    public static func add(to files: inout [String: Data], _ doc: DocumentModel, prefs: Preferences) {
        guard prefs.bool("files.viewerCopy"), let d = data(doc) else { return }
        files[path] = d
    }

    /// A single-file document, with the `render` key when `prefs` ask for it.
    public static func json(_ doc: DocumentModel, pretty: Bool, prefs: Preferences) -> String {
        let plain = DocumentJSON.export(doc, pretty: pretty, assets: true)
        guard prefs.bool("files.viewerCopy"), prefs.bool("files.viewerCopyJSON"), let b = bundle(doc),
            case .object(var o)? = try? CanonicalJSON.parse(Data(plain.utf8))
        else { return plain }
        o[jsonKey] = b
        // Written as DocumentJSON writes the rest, so everything but `render` keeps its bytes.
        return pretty ? CanonicalJSON.string(.object(o)) : DocumentJSON.compact(.object(o)) + "\n"
    }
}
