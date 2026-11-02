#if os(iOS)
import SwiftUI
import UIKit
import VisionKit

/// The VisionKit document camera (M47b): the pages scanned become one PDF, which image to
/// map reads as it reads any PDF, a page per canvas. Offered only where the camera is
/// supported (not in the Simulator).
struct DocumentScanner: UIViewControllerRepresentable {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    let done: (Data?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let camera = VNDocumentCameraViewController()
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ camera: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: (Data?) -> Void
        init(done: @escaping (Data?) -> Void) { self.done = done }

        func documentCameraViewController(
            _ camera: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
        ) {
            done(Self.pdf(scan))
        }

        func documentCameraViewControllerDidCancel(_ camera: VNDocumentCameraViewController) { done(nil) }

        func documentCameraViewController(_ camera: VNDocumentCameraViewController, didFailWithError error: any Error) {
            done(nil)
        }

        /// Each page at its own size, in scan order.
        static func pdf(_ scan: VNDocumentCameraScan) -> Data? {
            pdf((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        static func pdf(_ pages: [UIImage]) -> Data? {
            guard let first = pages.first else { return nil }
            return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size)).pdfData { context in
                for page in pages {
                    let r = CGRect(origin: .zero, size: page.size)
                    context.beginPage(withBounds: r, pageInfo: [:])
                    page.draw(in: r)
                }
            }
        }
    }
}
#endif
