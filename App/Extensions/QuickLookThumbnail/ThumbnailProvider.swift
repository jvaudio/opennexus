import AppKit
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import QuickLookThumbnailing

/// Finder thumbnails for `.nexus` and `.nexusjson` (artboard 33): the package's own
/// `preview.png` when it has one, otherwise the first canvas rendered here. Encrypted
/// documents show a lock, never their content.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        let url = request.fileURL
        let image = PreviewSource.image(for: url)
        let maxSize = request.maximumSize
        guard let image else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        let s = image.size
        let k = min(maxSize.width / max(s.width, 1), maxSize.height / max(s.height, 1), 1)
        let size = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        handler(
            QLThumbnailReply(contextSize: size) { () -> Bool in
                image.draw(in: CGRect(origin: .zero, size: size))
                return true
            }, nil)
    }
}
