import Foundation
import NexusCore

// MARK: Recognised text

/// A line of text read from an image: its string, its box in image pixels (origin top
/// left, y down) and the recogniser's confidence (0–1).
public struct TextBox: Sendable, Equatable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double
    /// Lines of text in the box (a wrapped topic has several).
    var lineCount = 1
    /// How wide the text sets in the system font per point of size (its width in ems), when
    /// it was measured; nil for boxes made by hand and for turned vertical text (D283).
    var em: Double?
    /// The widths of the text's lines added up, without the gaps between pieces of a line.
    var textWidth: Double
    /// Where the text's ink runs across the box, when the picture's ink is known (D285).
    var inked: ClosedRange<Double>?

    public init(_ text: String, x: Double, y: Double, width: Double, height: Double, confidence: Double = 1) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
        textWidth = width
    }

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    /// Where the text starts: its ink's left edge when that's known, since Vision sometimes
    /// starts a box a good way before the text (D285).
    var indent: Double { inked?.lowerBound ?? minX }
    /// The height of one line: the font size, give or take ascenders and descenders. Never
    /// more than the size the text's width implies, when its width in ems is known: Vision
    /// can draw a box a third taller than the same text elsewhere, but hardly ever wider (D283).
    var size: Double {
        let tall = height / Double(lineCount)
        guard let em, em > 0 else { return tall }
        return min(tall, textWidth / em)
    }

    /// The smallest box holding both; the text joins in reading order.
    func union(_ o: TextBox, separator: String = " ") -> TextBox {
        let first = (minY, minX) <= (o.minY, o.minX) ? self : o
        let second = first == self ? o : self
        let x0 = min(minX, o.minX)
        let y0 = min(minY, o.minY)
        var u = TextBox(
            first.text + separator + second.text, x: x0, y: y0, width: max(maxX, o.maxX) - x0,
            height: max(maxY, o.maxY) - y0, confidence: min(confidence, o.confidence))
        u.lineCount = verticalOverlap(o) >= 0.5 ? max(lineCount, o.lineCount) : lineCount + o.lineCount
        u.em = em.flatMap { a in o.em.map { a + $0 } }
        u.textWidth = textWidth + o.textWidth
        u.inked = inked.flatMap { a in
            o.inked.map { min(a.lowerBound, $0.lowerBound)...max(a.upperBound, $0.upperBound) }
        }
        return u
    }

    /// How much of the shorter box's height the two share (0–1).
    func verticalOverlap(_ o: TextBox) -> Double {
        let shared = min(maxY, o.maxY) - max(minY, o.minY)
        return max(0, shared) / max(1e-9, min(height, o.height))
    }
}

/// What text recognition read from one image or page, before any structure.
public struct RecognisedImage: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var boxes: [TextBox]
    /// This page's number in the source (1 for a picture), and how many pages it has.
    public var page = 1
    public var pages = 1
    /// The picture's lines and shapes, for tracing connectors (D193).
    public var ink: InkMap?

    public init(
        width: Double, height: Double, boxes: [TextBox], page: Int = 1, pages: Int = 1, ink: InkMap? = nil
    ) {
        self.width = width
        self.height = height
        self.boxes = boxes
        self.page = page
        self.pages = pages
        self.ink = ink
    }
}

// MARK: Layout → outline

/// How the image's text was laid out, which decides how its hierarchy is rebuilt (D151).
public enum ImageLayout: String, Sendable {
    /// A document, slide or note: reading order, font size, indentation and bullets.
    case list
    /// A mind-map screenshot: a central topic with branches around it.
    case map
    /// A poster or org chart: a title over side-by-side columns.
    case columns
    /// An Ishikawa diagram: a head at one end of a spine, with causes along diagonal bones.
    case fishbone
}

/// An image's text rebuilt as a map: pure, deterministic and headless (D150, D151).
public struct ImageOutline: Sendable {
    /// One topic with the box it came from, in pre-order; `depth` 0 is the root.
    public struct Unit: Sendable, Equatable {
        public var text: String
        public var box: TextBox
        public var depth: Int
        public var todo: Bool?
    }

    public var canvas: ICanvas
    public var layout: ImageLayout
    /// Every recognised topic in pre-order (a made-up root is not a unit).
    public var units: [Unit]
    /// Marks with no letters or digits, or read with too little confidence.
    public var dropped: Int

    /// Builds the outline. `title` names a made-up root when the image has no single title.
    /// Right-to-left and vertical text is turned to read left to right first (D194).
    public static func build(_ image: RecognisedImage, title: String) -> ImageOutline {
        let direction = ReadingDirection(image.boxes)
        let b = Builder(image: direction.normalised(image))
        let (tree, layout, found) = b.run()
        let structure = direction.structure(found)
        var root: T
        var synthesized = false
        if tree.count == 1, tree[0].box != nil {
            root = tree[0]
        } else {
            root = T(text: title.isEmpty ? "Image" : title, box: nil, children: tree)
            synthesized = true
        }
        if root.text.isEmpty { root.text = title }
        var units: [Unit] = []
        func collect(_ t: T, depth: Int) {
            if let box = t.box { units.append(Unit(text: t.text, box: box, depth: depth, todo: t.todo)) }
            for c in t.children { collect(c, depth: depth + 1) }
        }
        collect(root, depth: 0)
        var ic = ICanvas(title: title.isEmpty ? root.text : title, root: root.topic)
        ic.synthesizedRoot = synthesized
        ic.structure = structure
        if layout == .fishbone { ic.type = .fishbone }
        return ImageOutline(canvas: ic, layout: layout, units: units, dropped: b.dropped)
    }

    /// The layout showed no nesting below the main topics (a plain list of lines).
    public var isFlat: Bool { units.count >= 4 && units.allSatisfy { $0.depth <= 1 } }

    /// Groups a flat outline: each main topic the on-device model picked as a heading
    /// (indices into the root's children) takes the topics after it, up to the next
    /// heading. Nil, keeping the outline as it is, unless that adds a level without making
    /// most topics headings (D152).
    public func grouped(headings: [Int]) -> ICanvas? {
        let topics = canvas.root.children
        let picked = Set(headings.filter { topics.indices.contains($0) })
        guard isFlat, !picked.isEmpty, picked.count * 2 <= topics.count else { return nil }
        var root = canvas.root
        root.children = []
        var current: Int?
        for (i, t) in topics.enumerated() {
            if picked.contains(i) {
                root.children.append(t)
                current = root.children.count - 1
            } else if let h = current {
                root.children[h].children.append(t)
            } else {
                root.children.append(t)
            }
        }
        guard root.children.contains(where: { !$0.children.isEmpty }) else { return nil }
        var ic = canvas
        ic.root = root
        return ic
    }

    /// The import's result and report: one canvas, text only (D154).
    public func imported(canvas ic: ICanvas? = nil, source: String, grouped: Bool = false) -> Imported {
        ImageImport(outlines: [self], pages: 1).imported(canvases: ic.map { [$0] }, source: source, grouped: grouped)
    }
}

/// A topic while the outline is built.
struct T: Sendable {
    var text: String
    var box: TextBox?
    var children: [T] = []
    var todo: Bool?

    var topic: ITopic {
        var t = ITopic(text, children: children.map(\.topic))
        t.todo = todo
        return t
    }
}

// MARK: Builder

struct Builder {
    var lines: [TextBox]
    var dropped = 0
    let medianHeight: Double
    /// The picture's ink, when it's mostly background: a photo's isn't traced.
    let ink: InkMap?

    init(image: RecognisedImage) {
        ink = image.ink.flatMap { $0.coverage < 0.3 ? $0 : nil }
        var kept: [TextBox] = []
        for var b in image.boxes {
            // A separator dot mid-line reads as a bullet ("Beta • Nov").
            b.text = b.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " • ", with: " · ")
            let readable = b.text.rangeOfCharacter(from: .alphanumerics) != nil
            if readable, b.confidence >= 0.3, b.width > 0, b.height > 0 {
                kept.append(b)
            } else {
                dropped += 1
            }
        }
        lines = Self.mergeRows(kept)
        medianHeight = Self.median(lines.map(\.size))
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 1 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Pieces of one visual line (the recogniser splits at wide spaces) become one line.
    static func mergeRows(_ boxes: [TextBox]) -> [TextBox] {
        var out: [TextBox] = []
        for b in boxes.sorted(by: { ($0.minX, $0.minY) < ($1.minX, $1.minY) }) {
            if let i = out.lastIndex(where: { a in
                let h = max(a.size, b.size)
                let gap = b.minX - a.maxX
                return gap > -0.3 * h && gap < 0.9 * h && a.verticalOverlap(b) >= 0.6
                    && h / min(a.size, b.size) < 1.35
            }) {
                out[i] = out[i].union(b)
            } else {
                out.append(b)
            }
        }
        return out.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// (forest, layout, structure)
    func run() -> ([T], ImageLayout, LayoutStructure?) {
        guard lines.count > 1 else { return (list(lines), .list, nil) }
        // A fishbone first: its head sits at one end of a spine nothing else crosses.
        if let (tree, structure) = fishbone() { return ([tree], .fishbone, structure) }
        // A title over side-by-side columns (a poster, an org chart) first: its title sits
        // at the top, where no mind map puts its centre.
        let split = columnSplit()
        if case let (title?, columns)? = split {
            return (self.columns(title: title, columns), .columns, nil)
        }
        if let r = mapRoots().first {
            let (tree, structure) = map(root: r)
            return ([tree], .map, structure)
        }
        if let (title, columns) = split {
            return (self.columns(title: title, columns), .columns, nil)
        }
        return (list(lines), .list, nil)
    }

    var content: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (
            lines.map(\.minX).min() ?? 0, lines.map(\.minY).min() ?? 0, lines.map(\.maxX).max() ?? 0,
            lines.map(\.maxY).max() ?? 0
        )
    }

    // MARK: Map screenshots

    /// Candidates for the central topic of a mind-map screenshot, if the text is laid out
    /// around one: most of the other text sits beside it, spreading above and below it (or,
    /// in a small map, on both sides of it). Best first: the fewest topics stacked directly
    /// over or under it, then the largest (a box can come back too tall).
    func mapRoots() -> [Int] {
        let c = content
        let center = ((c.minX + c.maxX) / 2, (c.minY + c.maxY) / 2)
        let tallest = lines.indices.sorted { lines[$0].size > lines[$1].size }.prefix(3)
        let central = lines.indices.min {
            hypot(lines[$0].midX - center.0, lines[$0].midY - center.1)
                < hypot(lines[$1].midX - center.0, lines[$1].midY - center.1)
        }!
        var out: [(index: Int, stacked: Int)] = []
        for r in Set(tallest + [central]).sorted() {
            let R = lines[r]
            // Every mind-map app draws the central topic larger than the branches.
            guard R.size >= 1.1 * medianHeight else { continue }
            let others = lines.indices.filter { $0 != r }.map { lines[$0] }
            let n = Double(others.count)
            guard n >= 2 else { continue }
            let tol = 0.5 * medianHeight
            let left = others.filter { $0.maxX <= R.minX + tol }.count
            let right = others.filter { $0.minX >= R.maxX - tol }.count
            let above = others.filter { $0.midY < R.midY - 0.25 * R.height }.count
            let below = others.filter { $0.midY > R.midY + 0.25 * R.height }.count
            let beside = Double(left + right) >= (0.6 * n).rounded(.up)
            let balanced = Double(min(above, below)) >= max(1, (0.2 * n).rounded(.down))
            let inside = R.minY > c.minY + 0.2 * (c.maxY - c.minY)
            let small = n <= 4 && left > 0 && right > 0 && inside
            if beside && (balanced || small) { out.append((r, others.count - left - right)) }
        }
        return out.sorted { ($0.stacked, -lines[$0.index].size) < ($1.stacked, -lines[$1.index].size) }.map(\.index)
    }

    enum Side { case right, left, above, below }

    /// Each topic hangs from the nearest topic between it and the centre: to its left on
    /// the right side, to its right on the left side, above or below it in a vertical tree.
    func map(root r: Int) -> (tree: T, structure: LayoutStructure?) {
        let wrapped = Self.mergeWrapped(lines, keep: r)
        let lines = wrapped.lines
        let r = wrapped.root
        let R = lines[r]
        let tol = 0.5 * medianHeight
        func side(_ b: TextBox) -> Side {
            if b.minX - R.maxX >= -tol { return .right }
            if R.minX - b.maxX >= -tol { return .left }
            return b.midY < R.midY ? .above : .below
        }
        func distance(_ b: TextBox) -> Double {
            switch side(b) {
            case .right: b.minX - R.maxX
            case .left: R.minX - b.maxX
            case .above: R.minY - b.maxY
            case .below: b.minY - R.maxY
            }
        }
        /// Cost of hanging `b` from `p`, or nil when `p` is not between `b` and the centre.
        func cost(_ b: TextBox, from p: TextBox, isRoot: Bool) -> Double? {
            let s = side(b)
            switch s {
            case .right, .left:
                let gap = s == .right ? b.minX - p.maxX : p.minX - b.maxX
                let starts = s == .right ? p.minX < b.minX - tol : p.maxX > b.maxX + tol
                guard isRoot || (gap >= -tol && starts) else { return nil }
                return max(0, gap) + 1.5 * abs(b.midY - p.midY)
            case .above, .below:
                let gap = s == .below ? b.minY - p.maxY : p.minY - b.maxY
                guard isRoot || gap >= -0.2 * tol else { return nil }
                return max(0, gap) + 1.5 * abs(b.midX - p.midX)
            }
        }
        let order = lines.indices.filter { $0 != r }.sorted { distance(lines[$0]) < distance(lines[$1]) }
        var parent: [Int: Int] = [:]
        var placed = [r]
        var isPlaced: Set = [r]
        let tracer = ink.map { Tracer(ink: $0, lines: lines) }
        for i in order {
            let b = lines[i]
            var best = (r, cost(b, from: R, isRoot: true)!)
            for p in placed where p != r && side(lines[p]) == side(b) {
                if let c = cost(b, from: lines[p], isRoot: false), c < best.1 { best = (p, c) }
            }
            // A connector line, where one can be followed, outranks the geometry (D193).
            let s = side(b)
            if let p = tracer?.parent(
                of: i, side: s,
                accepts: { p in
                    isPlaced.contains(p)
                        && (p == r || (side(lines[p]) == s && cost(b, from: lines[p], isRoot: false) != nil))
                })
            {
                best.0 = p
            }
            parent[i] = best.0
            placed.append(i)
            isPlaced.insert(i)
        }
        var kids: [Int: [Int]] = [:]
        for (child, p) in parent { kids[p, default: []].append(child) }
        func ordered(_ ids: [Int], under p: Int) -> [Int] {
            guard !ids.isEmpty else { return [] }
            if p != r {
                let s = side(lines[ids[0]])
                return ids.sorted {
                    s == .left || s == .right
                        ? (lines[$0].midY, lines[$0].midX) < (lines[$1].midY, lines[$1].midX)
                        : (lines[$0].midX, lines[$0].midY) < (lines[$1].midX, lines[$1].midY)
                }
            }
            // Clockwise from the top, as a balanced map lays its branches out; a one-sided
            // map reads top to bottom.
            func on(_ s: Side) -> [Int] { ids.filter { side(lines[$0]) == s } }
            let left = on(.left).sorted { lines[$0].midY < lines[$1].midY }
            let oneSided = on(.right).isEmpty && on(.above).isEmpty && on(.below).isEmpty
            return on(.above).sorted { lines[$0].midX < lines[$1].midX }
                + on(.right).sorted { lines[$0].midY < lines[$1].midY }
                + on(.below).sorted { lines[$0].midX > lines[$1].midX }
                + (oneSided ? left : left.reversed())
        }
        func tree(_ i: Int) -> T {
            var t = Self.topic(lines[i])
            t.children = ordered(kids[i] ?? [], under: i).map(tree)
            return t
        }
        let sides = Set(lines.indices.filter { $0 != r }.map { side(lines[$0]) })
        let structure: LayoutStructure? =
            sides == [.right] ? .mindmapRight : sides == [.left] ? .mindmapLeft : sides == [.below] ? .orgDown : nil
        return (tree(r), structure)
    }

    /// A topic whose text wraps onto a second line reads as two boxes stacked tightly.
    /// `apart` keeps a line (second) under another (first) apart even when they stack like
    /// a wrap: a fishbone's sub-cause under its cause (D237).
    static func mergeWrapped(
        _ lines: [TextBox], keep root: Int, apart: ((TextBox, TextBox) -> Bool)? = nil
    ) -> (lines: [TextBox], root: Int) {
        var items = lines.enumerated().map { ($0.element, $0.offset == root) }
        var merged = true
        while merged {
            merged = false
            outer: for i in items.indices {
                for j in items.indices where j != i {
                    let a = items[i].0
                    let b = items[j].0
                    let h = max(a.size, b.size)
                    let gap = b.minY - a.maxY
                    let aligned =
                        abs(a.midX - b.midX) < 0.25 * max(a.width, b.width) || abs(a.minX - b.minX) < 0.3 * h
                    guard gap > -0.2 * h, gap < 0.45 * h, aligned, h / min(a.size, b.size) < 1.45,
                        !(apart?(a, b) ?? false)
                    else { continue }
                    items[i] = (a.union(b), items[i].1 || items[j].1)
                    items.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return (items.map(\.0), items.firstIndex { $0.1 } ?? 0)
    }

    // MARK: Posters and org charts

    /// A title (optional) and side-by-side columns whose lines share rows.
    func columnSplit() -> (title: Int?, columns: [[Int]])? {
        let c = content
        let width = c.maxX - c.minX
        let tallest = lines.indices.max { lines[$0].size < lines[$1].size }!
        let T = lines[tallest]
        let title: Int? =
            T.size >= 1.15 * medianHeight && lines.filter({ $0.maxY < T.minY }).count <= 1 ? tallest : nil
        let body = lines.indices.filter { $0 != title && lines[$0].width <= 0.6 * width }
        guard body.count >= 4 else { return nil }
        // Vertical gutters: x ranges no body line crosses.
        let minGap = max(1.2 * medianHeight, 0.02 * width)
        var segments: [(lo: Double, hi: Double, ids: [Int])] = []
        for i in body.sorted(by: { lines[$0].minX < lines[$1].minX }) {
            let b = lines[i]
            if var last = segments.last, b.minX < last.hi + minGap {
                last.hi = max(last.hi, b.maxX)
                last.ids.append(i)
                segments[segments.count - 1] = last
            } else {
                segments.append((b.minX, b.maxX, [i]))
            }
        }
        let columns = segments.map(\.ids)
        guard columns.count >= 2, columns.filter({ $0.count >= 2 }).count >= 2 else { return nil }
        // Real columns sit side by side: their lines share rows. An indented list's
        // children never share a row with their short parents.
        for (a, b) in zip(columns, columns.dropFirst()) {
            let (small, other) = a.count <= b.count ? (a, b) : (b, a)
            let sharing = small.filter { i in other.contains { lines[$0].verticalOverlap(lines[i]) >= 0.3 } }.count
            guard Double(sharing) >= 0.3 * Double(small.count) else { return nil }
        }
        return (title, columns)
    }

    func columns(title: Int?, _ columns: [[Int]]) -> [T] {
        let inColumns = Set(columns.flatMap { $0 })
        let top = columns.flatMap { $0 }.map { lines[$0].minY }.min() ?? 0
        let spanning = lines.indices.filter { !inColumns.contains($0) && $0 != title }
        let before = spanning.filter { lines[$0].midY < top }.map { lines[$0] }
        let after = spanning.filter { lines[$0].midY >= top }.map { lines[$0] }
        let body = Self.mergeCarryOn(inColumns.sorted().map { lines[$0] })
        let branches = list(before) + rows(body) + list(after)
        guard let title else { return branches }
        var root = Self.topic(lines[title])
        root.children = branches
        return [root]
    }

    /// Side-by-side headings in the top row each take the text below them, up to halfway to
    /// the next heading, and the same split repeats under them (an org chart's levels). A
    /// single stack of lines is a list.
    func rows(_ boxes: [TextBox]) -> [T] {
        guard let first = boxes.min(by: { $0.minY < $1.minY }) else { return [] }
        let row = boxes.filter { $0.verticalOverlap(first) >= 0.5 }.sorted { $0.midX < $1.midX }
        let separate = zip(row, row.dropFirst()).allSatisfy { $0.maxX < $1.minX }
        guard row.count >= 2, separate else { return list(boxes) }
        let rest = boxes.filter { b in !row.contains(b) }
        return row.indices.map { k in
            let lo = k == 0 ? -Double.infinity : (row[k - 1].midX + row[k].midX) / 2
            let hi = k == row.count - 1 ? Double.infinity : (row[k].midX + row[k + 1].midX) / 2
            var t = Self.topic(row[k])
            t.children = rows(rest.filter { $0.midX >= lo && $0.midX < hi })
            return t
        }
    }

    /// A topic's text wrapping inside its box: tightly under the line above, aligned with
    /// it, carrying on in lowercase.
    static func mergeCarryOn(_ boxes: [TextBox]) -> [TextBox] {
        var out: [TextBox] = []
        for b in boxes.sorted(by: { ($0.minY, $0.minX) < ($1.minY, $1.minX) }) {
            if let i = out.lastIndex(where: { a in
                let h = max(a.size, b.size)
                let gap = b.minY - a.maxY
                return gap > -0.2 * h && gap < 0.45 * h && b.text.first?.isLowercase == true
                    && (abs(a.minX - b.minX) < 0.5 * h || abs(a.midX - b.midX) < 0.5 * h)
                    && wraps(a, into: b, among: boxes)
            }) {
                out[i] = out[i].union(b)
            } else {
                out.append(b)
            }
        }
        return out
    }

    // MARK: Documents, slides and notes

    struct Marker {
        var kind: String?
        var numbers = 0
        var todo: Bool?
    }

    static let bullets: Set<Character> = [
        "•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□", "◆", "◇", "►", "▶", "➤", "→", "-", "–", "—", "*", "·",
    ]

    /// Strips a leading bullet, checkbox, number ("2.", "1.3", "4)") or letter ("a)").
    static func marker(_ text: String) -> (Marker, String) {
        var m = Marker()
        var s = Substring(text)
        if let f = s.first, ["☐", "□", "☑", "☒", "✓", "✔", "✅"].contains(f) {
            m.todo = f != "☐" && f != "□"
            m.kind = "☐"
            s = s.dropFirst()
        } else if let f = s.first, bullets.contains(f), s.count > 1 {
            m.kind = String(f)
            s = s.dropFirst()
        } else if let r = s.range(of: #"^\d{1,3}(\.\d{1,3})*[.)]?(?=\s)"#, options: .regularExpression),
            s[r].contains(".") || s[r].contains(")")
        {
            let token = s[r].trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
            m.kind = "1"
            m.numbers = token.split(separator: ".").count
            s = s[r.upperBound...]
        } else if let r = s.range(of: #"^[A-Za-z][.)](?=\s)"#, options: .regularExpression) {
            m.kind = s.first!.isUppercase ? "A" : "a"
            s = s[r.upperBound...]
        }
        let rest = s.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (Marker(), text) : (m, rest)
    }

    static func topic(_ b: TextBox) -> T {
        let (m, text) = marker(b.text)
        return T(text: text, box: b, todo: m.todo)
    }

    /// Reading order with a seniority key per line: much larger type (a title) first, then
    /// less indentation, then larger type, then no bullet before a bullet, then fewer number
    /// levels. Each line hangs from the nearest earlier line that is more senior. A box's
    /// height swings ±30% with ascenders, descenders and padding, so only a large size
    /// difference outranks indentation.
    func list(_ input: [TextBox]) -> [T] {
        guard !input.isEmpty else { return [] }
        let sorted = input.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        let body = Self.median(sorted.map(\.size))
        // Heading tiers: heights clearly above body text, largest first.
        let heading = 1.25 * body
        var tiers: [Double] = []
        for h in sorted.map(\.size).filter({ $0 >= heading }).sorted(by: >)
        where tiers.last.map({ h < $0 / 1.2 }) ?? true {
            tiers.append(h)
        }
        func tier(_ h: Double) -> Int { h < heading ? tiers.count : tiers.firstIndex { h >= $0 / 1.2 } ?? tiers.count }

        struct Line {
            var box: TextBox
            var text: String
            var marker: Marker
            var tier: Int
        }
        var items: [Line] = []
        for b in sorted {
            let (m, text) = Self.marker(b.text)
            let line = Line(box: b, text: text, marker: m, tier: tier(b.size))
            // A wrapped line: no marker, tucked just under the previous line's text.
            if let prev = items.last, m.kind == nil, line.tier == prev.tier {
                let h = max(prev.box.size, b.size)
                let gap = b.minY - prev.box.maxY
                let dx = b.minX - prev.box.minX
                let widest = sorted.filter { abs($0.minX - prev.box.minX) < 0.5 * h }.map(\.width).max() ?? 0
                let hanging = prev.marker.kind != nil && dx >= 0.3 * h && dx <= 2.2 * h
                let paragraph =
                    prev.marker.kind == nil && abs(dx) < 0.5 * h && prev.box.width >= 0.8 * widest
                    && !prev.text.hasSuffix(":") && prev.box.width > 12 * h
                // A topic's text wrapping inside its box: the next line carries on in lowercase.
                let carriesOn =
                    prev.marker.kind == nil && text.first?.isLowercase == true
                    && (abs(dx) < 0.5 * h || abs(b.midX - prev.box.midX) < 0.5 * h)
                if gap < 0.6 * h, gap > -0.3 * h, hanging || paragraph || carriesOn,
                    Self.wraps(prev.box, into: b, among: sorted)
                {
                    items[items.count - 1].box = prev.box.union(b)
                    items[items.count - 1].text += " " + text
                    continue
                }
            }
            items.append(line)
        }
        // Indent levels: where the text starts, within half a line height, is one level.
        var indents: [Double] = []
        for x in items.map(\.box.indent).sorted() where indents.last.map({ x - $0 > 0.5 * body }) ?? true {
            indents.append(x)
        }
        func indent(_ x: Double) -> Int { indents.lastIndex { x >= $0 - 0.5 * body } ?? 0 }
        var kinds: [String] = []
        for k in items.compactMap(\.marker.kind) where !kinds.contains(k) { kinds.append(k) }
        func key(_ l: Line) -> [Int] {
            [
                l.box.size >= 1.5 * body ? l.tier : tiers.count, indent(l.box.indent), l.tier,
                l.marker.kind.flatMap { kinds.firstIndex(of: $0) }.map { $0 + 1 } ?? 0, l.marker.numbers,
            ]
        }
        // Stack of (key, node path).
        var forest: [T] = []
        var stack: [(key: [Int], path: [Int])] = []
        for l in items {
            let k = key(l)
            while let top = stack.last, !top.key.lexicographicallyPrecedes(k) { stack.removeLast() }
            let t = T(text: l.text, box: l.box, todo: l.marker.todo)
            if let parent = stack.last {
                let path = parent.path
                let index = Self.append(t, at: path, in: &forest)
                stack.append((k, path + [index]))
            } else {
                forest.append(t)
                stack.append((k, [forest.count - 1]))
            }
        }
        return forest
    }

    /// Whether `next` can carry on `prev`'s text rather than start a line of its own (D194).
    /// Text wraps only when the next line's first word wouldn't have fitted after the line
    /// before, given the widest line in that column, and monospaced text (commands, code)
    /// never wraps: its lines break where the writer broke them.
    static func wraps(_ prev: TextBox, into next: TextBox, among boxes: [TextBox]) -> Bool {
        let h = max(prev.size, next.size)
        let column = boxes.filter { abs($0.minX - prev.minX) < 0.5 * h && abs($0.size - prev.size) < 0.35 * prev.size }
        let widest = column.map(\.width).max() ?? prev.width
        let perCharacter = next.width / Double(max(1, next.text.count))
        let word = Double(next.text.prefix { !$0.isWhitespace }.count)
        if prev.width + perCharacter * (word + 1) < widest { return false }
        return !monospaced(block(prev, in: column))
    }

    /// The run of lines in `column` around `line`, each tightly under the one before.
    static func block(_ line: TextBox, in column: [TextBox]) -> [TextBox] {
        let stack = column.sorted { $0.minY < $1.minY }
        guard let at = stack.firstIndex(of: line) else { return [line] }
        func tight(_ a: TextBox, _ b: TextBox) -> Bool { b.minY - a.maxY < max(a.size, b.size) }
        var lo = at
        var hi = at
        while lo > 0, tight(stack[lo - 1], stack[lo]) { lo -= 1 }
        while hi < stack.count - 1, tight(stack[hi], stack[hi + 1]) { hi += 1 }
        return Array(stack[lo...hi])
    }

    /// Three or more lines of six or more characters whose width per character agrees
    /// within 3%: a monospaced font, where every character, space included, is as wide.
    static func monospaced(_ lines: [TextBox]) -> Bool {
        let ratios = lines.filter { $0.text.count >= 6 }.map { $0.width / Double($0.text.count) }
        guard ratios.count >= 3 else { return false }
        let m = median(ratios)
        return ratios.allSatisfy { abs($0 - m) <= 0.03 * m }
    }

    /// Appends `t` under the node at `path`; returns its index among the children.
    static func append(_ t: T, at path: [Int], in forest: inout [T]) -> Int {
        func go(_ nodes: inout [T], _ rest: ArraySlice<Int>) -> Int {
            let i = rest.first!
            if rest.count == 1 {
                nodes[i].children.append(t)
                return nodes[i].children.count - 1
            }
            return go(&nodes[i].children, rest.dropFirst())
        }
        return go(&forest, path[...])
    }
}
