import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene
import NexusTouch
import UIKit

/// What Quick Look shows for a map on the iPad (M47b): `preview.png` if the package has
/// one, otherwise a fresh rendering with UIKit's text; a lock card for encrypted packages.
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
        let render = {
            MainActor.assumeIsolated {
                UIKitGraphics.install()
                return HeadlessExport.previewPNG(doc)
            }
        }
        return Thread.isMainThread ? render() : DispatchQueue.main.sync(execute: render)
    }

    static func image(for url: URL) -> UIImage? { png(for: url).flatMap(UIImage.init(data:)) }

    /// A plain card with a lock: the title isn't secret, the content is.
    static func lockCard() -> Data? {
        let size = CGSize(width: 800, height: 500)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            let r = CGRect(origin: .zero, size: size)
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 24).fill()
            let symbol = UIImage(
                systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 120))?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: r.midX - 60, y: r.midY - 110, width: 120, height: 150))
            let text = NSAttributedString(
                string: "Password-protected",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.secondaryLabel,
                ])
            text.draw(at: CGPoint(x: r.midX - text.size().width / 2, y: r.midY + 70))
        }
    }
}
