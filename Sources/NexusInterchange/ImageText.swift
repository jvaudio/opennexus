import CoreGraphics
import CoreText
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
        let ink = InkMap(image)
        // A photo's ink isn't lines (as for tracing in `Builder`): its marks all stay.
        let lines = ink.flatMap { $0.coverage < 0.3 ? $0 : nil }
        var boxes = try read(image, name: name, width: w, height: h, ink: lines)
        if !boxes.isEmpty, Builder.median(boxes.map(\.height)) <= smallText, let big = doubled(image) {
            boxes = try read(big, name: name, width: w, height: h, ink: lines)
        }
        return RecognisedImage(width: w, height: h, boxes: boxes, ink: ink)
    }

    /// Vision's lines, in the pixels of a `width` × `height` picture, each with its width
    /// in ems (D283). With the picture's `ink`, a lone mark at either end of a line whose
    /// ink runs out of the line's box is a connector read as a character: it's dropped, and
    /// the line takes Vision's box for the rest (D284). One between two words, where a
    /// connector crosses the line, cuts it in two (D483). Each line also notes where its
    /// text's ink runs across it (D285).
    static func read(
        _ image: CGImage, name: String, width w: Double, height h: Double, ink: InkMap? = nil
    ) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        // The revision these rules were tuned on (D482): left unset, Vision takes the
        // newest the SDK knows, so a new Xcode could read the same picture differently.
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ImportError.invalid(name, "text recognition failed (\(error.localizedDescription))")
        }
        // Vision's boxes are normalised with the origin at the bottom left.
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        }
        let font = CTFontCreateUIFontForLanguage(.system, 12, nil)
        var lines: [TextBox] = []
        var pieces: Set<Int> = []
        for obs in request.results ?? [] {
            guard let best = obs.topCandidates(1).first else { continue }
            let got = boxes(
                best.string, line: pixels(obs.boundingBox), confidence: Double(best.confidence), ink: ink, font: font
            ) { (try? best.boundingBox(for: $0)).map { pixels($0.boundingBox) } }
            if got.count > 1 { pieces.formUnion(lines.count..<lines.count + got.count) }
            lines += got
        }
        return dropRepeats(lines, pieces: pieces)
    }

    /// One line Vision read, `string` in `line` (image pixels), as text boxes: without a
    /// connector read as a mark at either end (D284), and cut in pieces where one crosses it
    /// (D483). `at` is Vision's box for part of the string.
    static func boxes(
        _ string: String, line: CGRect, confidence: Double, ink: InkMap?, font: CTFont?,
        at: (Range<String.Index>) -> CGRect?
    ) -> [TextBox] {
        var text = string[...]
        func connector(_ mark: Range<String.Index>) -> Bool {
            guard let ink, let m = at(mark) else { return false }
            return ink.runsOut(of: line, from: m)
        }
        for last in [true, false] {
            if let (mark, rest) = endMark(text, last: last), connector(mark) { text = string[rest] }
        }
        let parts = cut(text, line: line, ink: ink, at: at)
        return parts.map { part, span in
            var r = line
            if part.count < string.count, let kept = at(part.startIndex..<part.endIndex) { r = kept }
            // Vision can share a cut line's width out by characters, over the connector.
            let x0 = max(r.minX, span.lowerBound)
            let x1 = min(r.maxX, span.upperBound)
            if parts.count > 1, x1 > x0 { r = CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height) }
            var b = TextBox(
                String(part), x: r.minX, y: r.minY, width: r.width, height: r.height, confidence: confidence)
            b.em = font.flatMap { ems(part, in: $0) }
            b.inked = ink.map { $0.inked(r) }.map { $0.minX...$0.maxX }
            return b
        }
    }

    /// `text` cut where a connector crosses its `line`: at the lone stroke-like mark between
    /// two words that Vision put nearest each stroke of the picture's ink across the line
    /// (`InkMap.strokes(across:)`). Vision can read two topics on one row, and the connector
    /// between them, as one line ("Two nights - Hotel for the team"). Each piece comes with
    /// the span its box can take, up to the connector. The whole text when there's no cut.
    static func cut(
        _ text: Substring, line: CGRect, ink: InkMap?, at: (Range<String.Index>) -> CGRect?
    ) -> [(text: Substring, span: ClosedRange<Double>)] {
        let whole: [(text: Substring, span: ClosedRange<Double>)] = [(text, line.minX...max(line.minX, line.maxX))]
        let words = text.split(whereSeparator: \.isWhitespace)
        let marks = words.indices.dropFirst().dropLast().filter {
            words[$0].count == 1 && words[$0].first.map(strokeMarks.contains) == true
        }
        guard !marks.isEmpty, let strokes = ink?.strokes(across: line), !strokes.isEmpty else { return whole }
        let centres = marks.compactMap { k in at(words[k].startIndex..<words[k].endIndex).map { (k, $0.midX) } }
        var cuts: [Int: ClosedRange<Double>] = [:]
        for s in strokes {
            // How far a mark's centre is from the stroke; within a line's height counts.
            func off(_ x: Double) -> Double { max(0, s.lowerBound - x, x - s.upperBound) }
            let near = centres.filter { cuts[$0.0] == nil && off($0.1) <= line.height }
            if let (k, _) = near.min(by: { off($0.1) < off($1.1) }) { cuts[k] = s }
        }
        var parts: [(text: Substring, span: ClosedRange<Double>)] = []
        var first = 0
        var left = line.minX
        for (k, s) in cuts.sorted(by: { $0.key < $1.key }) where k > first {
            parts.append((text[words[first].startIndex..<words[k - 1].endIndex], left...max(left, s.lowerBound)))
            first = k + 1
            left = s.upperBound
        }
        guard !parts.isEmpty else { return whole }
        let rest = text[words[first].startIndex..<words[words.count - 1].endIndex]
        parts.append((rest, min(left, line.maxX)...line.maxX))
        return parts
    }

    /// `boxes` without each piece of a cut line (`pieces`) that a whole line already reads
    /// there: half or more of the piece's box inside the line's, and the piece's text in
    /// the line's. Vision on one Mac read "Two nights" on its own and again with the
    /// connector and the topic beside it, as "nights - Hotel for the team" (D483).
    static func dropRepeats(_ boxes: [TextBox], pieces: Set<Int>) -> [TextBox] {
        func rect(_ b: TextBox) -> CGRect { CGRect(x: b.x, y: b.y, width: b.width, height: b.height) }
        return boxes.indices.filter { i in
            guard pieces.contains(i) else { return true }
            let r = rect(boxes[i])
            return !boxes.indices.contains { j in
                guard !pieces.contains(j), boxes[j].text.contains(boxes[i].text) else { return false }
                let shared = r.intersection(rect(boxes[j]))
                return !shared.isNull && shared.width * shared.height >= 0.5 * r.width * r.height
            }
        }.map { boxes[$0] }
    }

    /// What a connector's line, fork or curve can be read as.
    static let strokeMarks: Set<Character> = [
        "-", "–", "—", "_", "~", "=", "|", "/", "\\", "<", ">", "‹", "›", "(", ")", "[", "]", "{", "}",
        // A connector's end dot.
        "•", "·", "∙", "●",
    ]

    /// A lone stroke-like mark set off by a space at the end of `text` (or, with `last`
    /// false, its start): the mark's range and the rest's. Nil when there's none, or
    /// nothing else.
    static func endMark(_ text: Substring, last: Bool) -> (mark: Range<String.Index>, rest: Range<String.Index>)? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return nil }
        let mark = last ? words[words.count - 1] : words[0]
        guard mark.count == 1, let c = mark.first, strokeMarks.contains(c) else { return nil }
        let rest =
            last
            ? words[0].startIndex..<words[words.count - 2].endIndex
            : words[1].startIndex..<words[words.count - 1].endIndex
        return (mark.startIndex..<mark.endIndex, rest)
    }

    /// How wide `text` sets in `font`, per point of its size.
    static func ems(_ text: Substring, in font: CTFont) -> Double? {
        guard
            let s = CFAttributedStringCreate(
                nil, String(text) as CFString, [kCTFontAttributeName as String: font] as CFDictionary)
        else { return nil }
        let line = CTLineCreateWithAttributedString(s)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
        return width > 0 ? width / CTFontGetSize(font) : nil
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
