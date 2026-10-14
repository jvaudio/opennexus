import CoreSpotlight
import NexusCore
import NexusFormat

/// Spotlight's importer for `.nexus` files on disk (README §6): topic text, notes and
/// labels, so plain Spotlight and Finder search find maps that were never opened.
/// Encrypted packages contribute only their name.
final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        let doc: DocumentModel
        do {
            doc = try NexusPackage.read(from: contentURL)
        } catch NexusPackage.ReadError.encrypted {
            attributes.kind = "OpenNexus Document (encrypted)"
            return
        }
        let text = SpotlightText(doc, fileName: contentURL.lastPathComponent)
        attributes.title = doc.orderedCanvases.first.flatMap { $0.nodes[$0.root]?.text } ?? text.title
        attributes.textContent = text.content
        attributes.keywords = text.keywords
        attributes.kind = "OpenNexus Document"
        attributes.contentDescription =
            "\(doc.orderedCanvases.map(\.title).filter { !$0.isEmpty }.joined(separator: " · ")) · \(doc.topicCount) topics"
    }
}
