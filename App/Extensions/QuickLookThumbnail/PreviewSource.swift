import AppKit
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange

/// What Quick Look shows for a map: `preview.png` if the package has one, otherwise a
/// fresh rendering; a lock card for encrypted packages.
enum PreviewSource {
    static func document(at url: URL) -> DocumentModel? {
        if url.pathExtension.lowercased() == "nexusjson" {
            return (try? Data(contentsOf: url)).flatMap { try? DocumentJSON.parse($0, name: url.lastPathComponent) }
        }
        return try? NexusPackage.read(from: url)
    }

    static func isEncrypted(_ url: URL) -> Bool {
        guard let w = try? FileWrapper(url: url, options: [.immediate]), w.isDirectory else { return false }
        return PackageCrypto.isEncrypted(NexusPackage.flatten(w))
    }

    static func png(for url: URL) -> Data? {
        if let data = try? Data(contentsOf: url.appending(path: NexusPackage.previewName)) { return data }
        if isEncrypted(url) { return lockCard() }
        guard let doc = document(at: url) else { return nil }
        let render = { MainActor.assumeIsolated { HeadlessExport.previewPNG(doc) } }
        return Thread.isMainThread ? render() : DispatchQueue.main.sync(execute: render)
    }

    static func image(for url: URL) -> NSImage? { png(for: url).flatMap(NSImage.init(data:)) }

    /// A plain card with a lock: the title isn't secret, the content is.
    static func lockCard() -> Data? {
        let size = CGSize(width: 800, height: 500)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 24, yRadius: 24).fill()
            let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 120, weight: .regular))
            symbol?.draw(in: CGRect(x: r.midX - 60, y: r.midY - 40, width: 120, height: 150))
            let text = NSAttributedString(
                string: "Password-protected",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            text.draw(at: CGPoint(x: r.midX - text.size().width / 2, y: r.midY - 110))
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
