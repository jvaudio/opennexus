import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text in an image (PNG, JPEG, HEIC, TIFF, GIF, screenshots) or a PDF's first
/// page with Vision, on this Mac (D150). Synchronous, so the CLI and the merge sheet can
/// import images like any other file; the app calls it off the main thread.
public enum ImageText {
    /// The longest side a PDF page renders at before recognition.
    static let pdfSide: CGFloat = 2400

    public static func recognize(_ data: Data, name: String) throws -> RecognisedImage {
        let (image, pages) = try decode(data, name: name)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ImportError.invalid(name, "text recognition failed (\(error.localizedDescription))")
        }
        let w = Double(image.width)
        let h = Double(image.height)
        let boxes: [TextBox] = (request.results ?? []).compactMap { obs in
            guard let best = obs.topCandidates(1).first else { return nil }
            // Vision's boxes are normalised with the origin at the bottom left.
            let r = obs.boundingBox
            return TextBox(
                best.string, x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h,
                confidence: Double(best.confidence))
        }
        return RecognisedImage(width: w, height: h, boxes: boxes, pages: pages)
    }

    /// The picture to read, and how many pages the source has.
    static func decode(_ data: Data, name: String) throws -> (CGImage, Int) {
        if data.starts(with: Array("%PDF".utf8)) {
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
                let page = pdf.page(at: 1)
            else { throw ImportError.invalid(name, "not a readable PDF") }
            if pdf.isEncrypted && !pdf.isUnlocked { throw ImportError.encrypted(name) }
            let box = page.getBoxRect(.cropBox)
            let scale = pdfSide / max(box.width, box.height, 1)
            let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
            guard
                let ctx = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ImportError.invalid(name, "couldn’t render the PDF page") }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage() else { throw ImportError.invalid(name, "couldn’t render the PDF page") }
            return (image, pdf.numberOfPages)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(
                src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary)
        else { throw ImportError.invalid(name, "not a readable image") }
        return (image, 1)
    }
}

extension ImageOutline {
    /// Reads an image and rebuilds its structure with the layout heuristics alone.
    public static func read(_ data: Data, name: String) throws -> ImageOutline {
        let recognised = try ImageText.recognize(data, name: name)
        let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        let outline = build(recognised, title: base)
        guard !outline.units.isEmpty else { throw ImportError.invalid(name, "no text found in the image") }
        return outline
    }
}
