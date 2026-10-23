import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Reads the text in an image (PNG, JPEG, HEIC, TIFF, GIF, screenshots) or every page of a
/// PDF with Vision, on this Mac (D150, D190). Synchronous, so the CLI and `Interchange` can
/// import images like any other file; the app calls it off the main thread.
public enum ImageText {
    /// The longest page side a PDF renders at before recognition.
    static let pdfSide: CGFloat = 2400
    /// Pages read from one PDF or multi-page TIFF; the import report counts the rest.
    public static let maxPages = 100

    /// Each page's text: a picture is one page, a PDF or multi-page TIFF up to `maxPages`.
    /// `progress` gets (0, pages to read) once the source is open, so page counts show from
    /// the first page (D238), then (pages read, pages to read) after each page. Checks for
    /// cancellation between pages.
    public static func recognize(
        _ data: Data, name: String, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> [RecognisedImage] {
        let source = try Source(data, name: name)
        let count = min(source.count, maxPages)
        progress?(0, count)
        var pages: [RecognisedImage] = []
        for i in 0..<count {
            try Task.checkCancellation()
            var page = try recognize(try source.image(i, name: name), name: name)
            page.page = i + 1
            page.pages = source.count
            pages.append(page)
            progress?(i + 1, count)
        }
        return pages
    }

    /// Text this many pixels tall or smaller is read again at twice the size: Vision
    /// misreads small text (it read 20 px labels backwards, and dropped some).
    static let smallText = 22.0

    static func recognize(_ image: CGImage, name: String) throws -> RecognisedImage {
        let w = Double(image.width)
        let h = Double(image.height)
        var boxes = try read(image, name: name, width: w, height: h)
        if !boxes.isEmpty, Builder.median(boxes.map(\.height)) <= smallText, let big = doubled(image) {
            boxes = try read(big, name: name, width: w, height: h)
        }
        return RecognisedImage(width: w, height: h, boxes: boxes, ink: InkMap(image))
    }

    /// Vision's lines, in the pixels of a `width` × `height` picture.
    static func read(_ image: CGImage, name: String, width w: Double, height h: Double) throws -> [TextBox] {
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
        return (request.results ?? []).compactMap { obs in
            guard let best = obs.topCandidates(1).first else { return nil }
            // Vision's boxes are normalised with the origin at the bottom left.
            let r = obs.boundingBox
            return TextBox(
                best.string, x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h,
                confidence: Double(best.confidence))
        }
    }

    /// The picture at twice its size, smoothly scaled, on white.
    static func doubled(_ image: CGImage) -> CGImage? {
        let w = image.width * 2
        let h = image.height * 2
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The pages to read: a PDF's, a TIFF's, or one picture's.
    struct Source {
        var pdf: CGPDFDocument?
        var images: CGImageSource?
        var count: Int
        /// One scale for every PDF page, so text sizes compare across pages.
        var scale: CGFloat = 1

        init(_ data: Data, name: String) throws {
            if data.starts(with: Array("%PDF".utf8)) {
                guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
                    pdf.numberOfPages > 0
                else { throw ImportError.invalid(name, "not a readable PDF") }
                if pdf.isEncrypted && !pdf.isUnlocked { throw ImportError.encrypted(name) }
                self.pdf = pdf
                count = pdf.numberOfPages
                let longest =
                    (1...min(count, ImageText.maxPages)).compactMap { pdf.page(at: $0) }
                    .map { $0.getBoxRect(.cropBox) }.map { max($0.width, $0.height) }.max() ?? 1
                scale = pdfSide / max(longest, 1)
                return
            }
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0
            else { throw ImportError.invalid(name, "not a readable image") }
            images = src
            // A TIFF's images are pages; a GIF's are animation frames, read as one picture.
            let type = CGImageSourceGetType(src).map { $0 as String }
            count = type.flatMap { UTType($0) }?.conforms(to: .tiff) == true ? CGImageSourceGetCount(src) : 1
        }

        func image(_ i: Int, name: String) throws -> CGImage {
            if let images {
                guard
                    let image = CGImageSourceCreateImageAtIndex(
                        images, i, [kCGImageSourceShouldAllowFloat: false] as CFDictionary)
                else { throw ImportError.invalid(name, "not a readable image") }
                return image
            }
            guard let pdf, let page = pdf.page(at: i + 1) else { throw ImportError.invalid(name, "not a readable PDF") }
            let box = page.getBoxRect(.cropBox)
            let size = CGSize(
                width: max(1, (box.width * scale).rounded()), height: max(1, (box.height * scale).rounded()))
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
            return image
        }
    }
}

extension ImageOutline {
    /// Reads an image or every page of a PDF and rebuilds the structure with the layout
    /// heuristics alone.
    public static func read(
        _ data: Data, name: String, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> ImageImport {
        let pages = try ImageText.recognize(data, name: name, progress: progress)
        let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        let result = build(pages: pages, title: base)
        guard result.outlines.contains(where: { !$0.units.isEmpty }) else {
            throw ImportError.invalid(name, "no text found in the image")
        }
        return result
    }
}
