import CoreGraphics
import Foundation

/// Which parts of a picture carry ink: anything clearly unlike its background colour, at
/// most 1,200 cells on the longest side, a cell set when any pixel in it is ink. What
/// connector tracing follows (D193).
public struct InkMap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Image pixels per cell.
    public let scale: Double
    var cells: [Bool]

    static let longest = 1200

    /// A blank map over an image of `size` pixels.
    public init(imageWidth: Double, imageHeight: Double) {
        let f = max(1, (max(imageWidth, imageHeight) / Double(Self.longest)).rounded(.up))
        scale = f
        width = max(1, Int((imageWidth / f).rounded(.up)))
        height = max(1, Int((imageHeight / f).rounded(.up)))
        cells = Array(repeating: false, count: width * height)
    }

    /// The picture's ink: pixels whose colour differs from the background (the commonest
    /// colour along its edges) by more than a faint fill does. Transparency reads as white.
    public init?(_ image: CGImage) {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0,
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // The background: the commonest colour on the border, to 4 bits a channel.
        var counts: [Int: Int] = [:]
        func key(_ i: Int) -> Int { Int(px[i] >> 4) << 8 | Int(px[i + 1] >> 4) << 4 | Int(px[i + 2] >> 4) }
        for x in stride(from: 0, to: w, by: 2) {
            counts[key(x * 4), default: 0] += 1
            counts[key(((h - 1) * w + x) * 4), default: 0] += 1
        }
        for y in stride(from: 0, to: h, by: 2) {
            counts[key(y * w * 4), default: 0] += 1
            counts[key((y * w + w - 1) * 4), default: 0] += 1
        }
        let bg = counts.max { $0.value < $1.value }?.key ?? 0xFFF
        let (br, bgG, bb) = ((bg >> 8) * 17, ((bg >> 4) & 15) * 17, (bg & 15) * 17)
        self.init(imageWidth: Double(w), imageHeight: Double(h))
        let f = Int(scale)
        for y in 0..<h {
            let row = (y / f) * width
            for x in 0..<w {
                let i = (y * w + x) * 4
                let d = abs(Int(px[i]) - br) + abs(Int(px[i + 1]) - bgG) + abs(Int(px[i + 2]) - bb)
                if d > 90 { cells[row + x / f] = true }
            }
        }
    }

    public subscript(x: Int, y: Int) -> Bool {
        get { x >= 0 && y >= 0 && x < width && y < height && cells[y * width + x] }
        set { if x >= 0, y >= 0, x < width, y < height { cells[y * width + x] = newValue } }
    }

    /// Draws a line between two points in image pixels (for tests and synthetic pictures).
    public mutating func line(from a: (Double, Double), to b: (Double, Double)) {
        let steps = Int(max(abs(b.0 - a.0), abs(b.1 - a.1)) / scale) + 1
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            self[Int((a.0 + (b.0 - a.0) * t) / scale), Int((a.1 + (b.1 - a.1) * t) / scale)] = true
        }
    }

    /// Fraction of cells that are ink.
    var coverage: Double { Double(cells.lazy.filter { $0 }.count) / Double(max(1, cells.count)) }

    /// `box` (in image pixels) narrowed to the columns where its middle rows have ink: where
    /// its text is, when Vision drew the box wider than the text (D285). The box as it is
    /// when that would take away half its width or more, or there's no ink. The middle
    /// rows leave out a border or an underline.
    func inked(_ box: CGRect) -> CGRect {
        func cell(_ v: Double) -> Int { Int((v / scale).rounded(.down)) }
        let top = cell(box.minY + 0.2 * box.height)
        let rows = top...max(top, cell(box.maxY - 0.2 * box.height))
        let left = cell(box.minX)
        let inked = (left...max(left, cell(box.maxX))).filter { x in rows.contains { self[x, $0] } }
        guard let first = inked.first, let last = inked.last else { return box }
        let minX = max(box.minX, Double(first) * scale)
        let maxX = min(box.maxX, Double(last + 1) * scale)
        guard maxX - minX > 0.5 * box.width else { return box }
        return CGRect(x: minX, y: box.minY, width: maxX - minX, height: box.height)
    }

    /// Whether the ink in `mark` runs out of `box` (both in image pixels): a walk over ink
    /// from inside `mark` gets at least 3 px and two cells past the box's edge. A character
    /// keeps inside the box Vision drew around its line; a connector read as one carries
    /// on past it (D284).
    func runsOut(of box: CGRect, from mark: CGRect) -> Bool {
        func cell(_ v: Double) -> Int { Int((v / scale).rounded(.down)) }
        let out = max(2, Int((3 / scale).rounded(.up)))
        let (bx0, by0, bx1, by1) = (cell(box.minX), cell(box.minY), cell(box.maxX), cell(box.maxY))
        let (wx0, wy0) = (max(0, bx0 - out), max(0, by0 - out))
        let (wx1, wy1) = (min(width - 1, bx1 + out), min(height - 1, by1 + out))
        let seeds = mark.intersection(box)
        guard !seeds.isNull else { return false }
        let (sx0, sy0) = (max(wx0, cell(seeds.minX)), max(wy0, cell(seeds.minY)))
        let (sx1, sy1) = (min(wx1, cell(seeds.maxX)), min(wy1, cell(seeds.maxY)))
        guard sx0 <= sx1, sy0 <= sy1 else { return false }
        var queue: [(Int, Int)] = []
        var seen = Set<Int>()
        for y in sy0...sy1 {
            for x in sx0...sx1 where self[x, y] && seen.insert(y * width + x).inserted { queue.append((x, y)) }
        }
        var head = 0
        while head < queue.count {
            let (x, y) = queue[head]
            head += 1
            if x <= bx0 - out || x >= bx1 + out || y <= by0 - out || y >= by1 + out { return true }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let nx = x + dx
                let ny = y + dy
                guard nx >= wx0, nx <= wx1, ny >= wy0, ny <= wy1, self[nx, ny],
                    seen.insert(ny * width + nx).inserted
                else { continue }
                queue.append((nx, ny))
            }
        }
        return false
    }
}

/// Follows connector lines over a page's ink (D193).
struct Tracer {
    let ink: InkMap
    let lines: [TextBox]
    /// Text, slightly padded: never walked through.
    var walls: [Bool]

    init(ink: InkMap, lines: [TextBox]) {
        self.ink = ink
        self.lines = lines
        walls = Array(repeating: false, count: ink.width * ink.height)
        for t in lines {
            let m = 0.1 * t.size
            for y in max(0, cell(t.minY - m))...min(ink.height - 1, cell(t.maxY + m)) {
                for x in max(0, cell(t.minX - m))...min(ink.width - 1, cell(t.maxX + m)) {
                    walls[y * ink.width + x] = true
                }
            }
        }
    }

    func cell(_ v: Double) -> Int { Int((v / ink.scale).rounded(.down)) }

    func open(_ x: Int, _ y: Int) -> Bool { ink[x, y] && !walls[y * ink.width + x] }

    /// The topic that line `b`'s connector leads to: from the ink around `b` on the side
    /// facing the centre, a breadth-first walk over ink, never further out than `b`'s inner
    /// edge and never through text, to the first topic that `accepts` as a parent, reached
    /// on its side facing `b` within most of a line of its text (a shape's padding). Nil
    /// when no ink leads to one.
    func parent(of b: Int, side: Builder.Side, accepts: (Int) -> Bool) -> Int? {
        let B = lines[b]
        func reach(_ t: TextBox) -> (Int, Int, Int, Int) {
            let m = 0.8 * t.size
            switch side {
            case .right: return (cell(t.midX), cell(t.minY - m), cell(t.maxX + m), cell(t.maxY + m))
            case .left: return (cell(t.minX - m), cell(t.minY - m), cell(t.midX), cell(t.maxY + m))
            case .below: return (cell(t.minX - m), cell(t.midY), cell(t.maxX + m), cell(t.maxY + m))
            case .above: return (cell(t.minX - m), cell(t.minY - m), cell(t.maxX + m), cell(t.midY))
            }
        }
        let candidates = lines.indices.filter { $0 != b && accepts($0) }.map { ($0, reach(lines[$0])) }
        guard !candidates.isEmpty else { return nil }
        let tol = cell(0.25 * B.size)
        let inner: (Int, Int) -> Bool =
            switch side {
            case .right: { x, _ in x <= cell(B.minX) + tol }
            case .left: { x, _ in x >= cell(B.maxX) - tol }
            case .below: { _, y in y <= cell(B.minY) + tol }
            case .above: { _, y in y >= cell(B.maxY) - tol }
            }
        // Seeds: ink just inside `b`'s inner edge, where its shape's border or underline
        // meets its connector, outside text.
        let h = B.size
        let (x0, y0, x1, y1): (Double, Double, Double, Double) =
            switch side {
            case .right: (B.minX - 1.2 * h, B.minY - 0.4 * h, B.minX, B.maxY + 0.6 * h)
            case .left: (B.maxX, B.minY - 0.4 * h, B.maxX + 1.2 * h, B.maxY + 0.6 * h)
            case .below: (B.minX - 0.4 * h, B.minY - 1.2 * h, B.maxX + 0.4 * h, B.minY)
            case .above: (B.minX - 0.4 * h, B.maxY, B.maxX + 0.4 * h, B.maxY + 1.2 * h)
            }
        var queue: [(Int, Int)] = []
        var seen = Set<Int>()
        for y in max(0, cell(y0))...max(0, min(ink.height - 1, cell(y1))) {
            for x in max(0, cell(x0))...max(0, min(ink.width - 1, cell(x1)))
            where open(x, y) && inner(x, y) && seen.insert(y * ink.width + x).inserted {
                queue.append((x, y))
            }
        }
        var head = 0
        let cap = ink.width * ink.height / 4
        while head < queue.count, head < cap {
            let (x, y) = queue[head]
            head += 1
            if let hit = candidates.first(where: { x >= $0.1.0 && x <= $0.1.2 && y >= $0.1.1 && y <= $0.1.3 }) {
                return hit.0
            }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let nx = x + dx
                let ny = y + dy
                guard open(nx, ny), inner(nx, ny), seen.insert(ny * ink.width + nx).inserted else { continue }
                queue.append((nx, ny))
            }
        }
        return nil
    }
}
