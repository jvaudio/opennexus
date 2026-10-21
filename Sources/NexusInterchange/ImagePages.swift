import Foundation
import NexusCore

/// A picture's or a PDF's pages rebuilt as maps (D190): a canvas per page, or one canvas
/// when the pages continue one document.
public struct ImageImport: Sendable {
    /// One per canvas, in page order.
    public var outlines: [ImageOutline]
    /// Pages in the source.
    public var pages: Int
    /// Pages after `ImageText.maxPages`, not read.
    public var unread = 0
    /// Pages with no text.
    public var blank = 0
    /// Page numbers and running headers or footers left out.
    public var furniture = 0
    /// The pages were read as one document, one after another.
    public var continuous = false

    public init(outlines: [ImageOutline], pages: Int) {
        self.outlines = outlines
        self.pages = pages
    }

    /// The import's result and report, text only (D154). `canvases` replaces the outlines'
    /// own (Apple Intelligence's grouping, D152).
    public func imported(canvases: [ICanvas]? = nil, source: String, grouped: Bool = false) -> Imported {
        var report = ImportReport(source: source, format: grouped ? "Image · Apple Intelligence" : "Image")
        report.sheets = pages
        let dropped = outlines.reduce(0) { $0 + $1.dropped }
        if dropped > 0 { report.skip("Unreadable marks or symbols", dropped) }
        report.skip("Shapes, lines, colours and pictures (text only)")
        if furniture > 0 { report.skip("Page numbers, headers and footers", furniture) }
        if blank > 0 { report.skip("Pages with no text", blank) }
        if unread > 0 { report.skip("Pages after page \(ImageText.maxPages)", unread) }
        let list = canvases ?? outlines.map(\.canvas)
        return Imported(canvases: CanvasBuilder.build(list, report: &report), report: report)
    }
}

extension ImageOutline {
    /// Builds every page read (D190). The pages continue one document when each reads as a
    /// list and none after the first opens with a title (a first line 1.5× the body text or
    /// larger): their text is then read as one list, page after page, so the points under a
    /// heading that carry over to the next page stay under it. Otherwise (slides, posters, a
    /// map or a fishbone on each page) each page becomes a canvas, titled by its own title.
    public static func build(pages: [RecognisedImage], title: String) -> ImageImport {
        var result = ImageImport(outlines: [], pages: max(pages.first?.pages ?? 1, pages.count))
        result.unread = result.pages - pages.count
        var pages = pages
        if pages.count > 1 { result.furniture = removeFurniture(&pages) }
        let read = pages.filter { $0.boxes.contains { $0.text.rangeOfCharacter(from: .alphanumerics) != nil } }
        result.blank = pages.count - read.count
        guard read.count > 1 else {
            result.outlines = [
                build(read.first ?? pages.first ?? RecognisedImage(width: 1, height: 1, boxes: []), title: title)
            ]
            return result
        }
        let each = read.map { page in
            var o = build(page, title: "\(title) · page \(page.page)")
            if !o.canvas.synthesizedRoot { o.canvas.title = o.canvas.root.text }
            return o
        }
        // Body text: every line but each page's first.
        func first(_ p: RecognisedImage) -> TextBox? { p.boxes.min { ($0.minY, $0.minX) < ($1.minY, $1.minX) } }
        let body = Builder.median(read.flatMap { p in p.boxes.filter { $0 != first(p) }.map(\.height) })
        let titled = read.dropFirst().contains { first($0).map { $0.height >= 1.5 * body } ?? false }
        if each.allSatisfy({ $0.layout == .list }), !titled {
            result.continuous = true
            result.outlines = [build(stacked(read), title: title)]
        } else {
            result.outlines = each
        }
        return result
    }

    /// The pages one under another, as one long page.
    static func stacked(_ pages: [RecognisedImage]) -> RecognisedImage {
        var out = RecognisedImage(width: pages.map(\.width).max() ?? 1, height: 0, boxes: [])
        for p in pages {
            out.boxes += p.boxes.map { b in
                var b = b
                b.y += out.height
                return b
            }
            out.height += p.height
        }
        return out
    }

    /// Takes out page numbers ("12", "Page 3", "4 of 9") in the top or bottom 6% of a page,
    /// and text repeated in that margin on at least half the pages (a running header or
    /// footer, its numbers aside). Returns how many lines it took out.
    static func removeFurniture(_ pages: inout [RecognisedImage]) -> Int {
        func margin(_ b: TextBox, _ p: RecognisedImage) -> Int? {
            b.maxY <= 0.06 * p.height ? 0 : b.minY >= 0.94 * p.height ? 1 : nil
        }
        func key(_ b: TextBox, _ m: Int) -> String {
            "\(m)|" + b.text.lowercased().replacing(/\d+/, with: "#").trimmingCharacters(in: .whitespaces)
        }
        var seen: [String: Int] = [:]
        for p in pages {
            for k in Set(p.boxes.compactMap { b in margin(b, p).map { key(b, $0) } }) { seen[k, default: 0] += 1 }
        }
        let repeated = max(2, (pages.count + 1) / 2)
        let number = /^\W*((page|p\.?)\s*)?\d{1,4}(\s*(\/|of)\s*\d{1,4})?\W*$/.ignoresCase()
        var removed = 0
        for i in pages.indices {
            let p = pages[i]
            pages[i].boxes = p.boxes.filter { b in
                guard let m = margin(b, p) else { return true }
                let furniture = b.text.wholeMatch(of: number) != nil || seen[key(b, m), default: 0] >= repeated
                if furniture { removed += 1 }
                return !furniture
            }
        }
        return removed
    }
}
