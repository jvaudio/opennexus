import CoreGraphics
import CoreText
import Foundation
import NexusTheme

/// Reads the `<svg>` MathJax writes for a formula into `MathGlyphs` (M48). MathJax draws
/// with paths, rules (`rect`, `line`), ellipses and polygons for enclosures, and `text`
/// for characters its font lacks, which become CoreText outlines here. Groups carry
/// transforms and `\color`'s fills and strokes.
enum MathSVGReader {
    static func read(_ svg: String) -> MathGlyphs? {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = delegate
        guard parser.parse(), let box = delegate.viewBox else { return nil }
        return MathGlyphs(
            pieces: delegate.pieces, width: box.width / 1000, ascent: -box.minY / 1000,
            depth: (box.minY + box.height) / 1000)
    }

    /// What an element inherits from its group.
    struct State {
        var transform: CGAffineTransform
        /// nil is "none"; `.some(nil)` is the text's colour (`currentColor`).
        var fill: RGBA??
        var stroke: RGBA??
        var strokeWidth: Double
        var dash: [CGFloat]? = nil
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var viewBox: CGRect?
        var pieces: [MathGlyphs.Piece] = []
        var stack: [State] = []
        /// The `<text>` being read: its state, attributes and characters.
        var text: (State, [String: String], String)?
        /// Groups KaTeX's `\reflectbox` marks (`nexus-reflect`): their depth in the stack and
        /// their first shape, mirrored when the group ends.
        var reflects: [(depth: Int, first: Int)] = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes a: [String: String]
        ) {
            if viewBox == nil, name == "svg" {
                let v = (a["viewBox"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap {
                    Double($0)
                }
                guard v.count == 4 else {
                    parser.abortParsing()
                    return
                }
                viewBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                // MathJax's units (1000 to the em, y down) to ems from the baseline's left end.
                let base = CGAffineTransform(scaleX: 0.001, y: 0.001).translatedBy(x: -v[0], y: 0)
                stack = [State(transform: base, fill: .some(nil), stroke: .some(nil), strokeWidth: 0)]
                return
            }
            guard var s = stack.last else { return }
            var local = Self.transform(a["transform"])
            if name == "svg" {
                // A nested viewport: its x and y move it, its viewBox scales it.
                local = CGAffineTransform(translationX: Self.num(a["x"]), y: Self.num(a["y"]))
                let v = (a["viewBox"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap {
                    Double($0)
                }
                if v.count == 4, let w = Double(a["width"] ?? ""), let h = Double(a["height"] ?? ""), v[2] > 0,
                    v[3] > 0
                {
                    local = local.scaledBy(x: w / v[2], y: h / v[3]).translatedBy(x: -v[0], y: -v[1])
                }
            }
            s.transform = local.concatenating(s.transform)
            Self.paint(a, into: &s)
            // MathJax's style sheet, which a browser would apply over the attributes: table
            // rules and frames are 70 units wide and unfilled, dashed or dotted by class.
            if (name == "line" && a["data-line"] != nil) || (name == "rect" && a["data-frame"] != nil) {
                s.strokeWidth = 70
                s.fill = nil
            }
            let classes = a["class"]?.split(separator: " ") ?? []
            if classes.contains("mjx-dashed") { s.dash = [140] }
            if classes.contains("mjx-dotted") {
                s.dash = [0, 140]
                s.cap = .round
            }
            // An inline style beats both (`\enclose`'s strokes set their width there).
            if let style = a["style"] {
                var props: [String: String] = [:]
                for decl in style.split(separator: ";") {
                    let kv = decl.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 {
                        props[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                Self.paint(props, into: &s)
            }
            stack.append(s)
            if a["class"]?.split(separator: " ").contains("nexus-reflect") == true {
                reflects.append((stack.count, pieces.count))
            }
            switch name {
            case "path":
                if let d = a["d"], let p = MathPathData.parse(d) { add(p, s) }
            case "rect":
                let r = CGRect(
                    x: Self.num(a["x"]), y: Self.num(a["y"]), width: Self.num(a["width"]),
                    height: Self.num(a["height"]))
                add(CGPath(rect: r, transform: nil), s)
            case "line":
                let p = CGMutablePath()
                p.move(to: CGPoint(x: Self.num(a["x1"]), y: Self.num(a["y1"])))
                p.addLine(to: CGPoint(x: Self.num(a["x2"]), y: Self.num(a["y2"])))
                add(p, s, stroked: true)
            case "ellipse", "circle":
                let rx = a["rx"].flatMap(Double.init) ?? Self.num(a["r"])
                let ry = a["ry"].flatMap(Double.init) ?? Self.num(a["r"])
                let r = CGRect(x: Self.num(a["cx"]) - rx, y: Self.num(a["cy"]) - ry, width: 2 * rx, height: 2 * ry)
                add(CGPath(ellipseIn: r, transform: nil), s)
            case "polygon", "polyline":
                let v = (a["points"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap {
                    Double($0)
                }
                let p = CGMutablePath()
                for i in stride(from: 0, to: v.count - 1, by: 2) {
                    let pt = CGPoint(x: v[i], y: v[i + 1])
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                if name == "polygon" { p.closeSubpath() }
                add(p, s, stroked: name == "polyline")
            case "text":
                text = (s, a, "")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text?.2 += string
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
        ) {
            if name == "text", let (s, a, chars) = text {
                addText(chars, s, a)
                text = nil
            }
            if let r = reflects.last, r.depth == stack.count {
                reflects.removeLast()
                mirror(from: r.first)
            }
            if stack.count > 1 { stack.removeLast() }
        }

        /// Mirrors the shapes from `first` on, left to right, in place.
        func mirror(from first: Int) {
            guard first < pieces.count else { return }
            let box = pieces[first...].reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
            var t = CGAffineTransform(translationX: box.midX, y: 0).scaledBy(x: -1, y: 1)
                .translatedBy(x: -box.midX, y: 0)
            for i in first..<pieces.count {
                if let p = pieces[i].path.copy(using: &t) { pieces[i].path = p }
            }
        }

        /// Adds a shape: filled unless it's a line or its fill is "none", and stroked too when
        /// it has a stroke width. A dashed, dotted or capped stroke becomes its outline.
        func add(_ path: CGPath, _ s: State, stroked line: Bool = false) {
            var t = s.transform
            guard let placed = path.copy(using: &t) else { return }
            if !line, case .some(let fill) = s.fill { pieces.append(MathGlyphs.Piece(path: placed, color: fill)) }
            let width = s.strokeWidth * sqrt(abs(t.a * t.d - t.b * t.c))
            guard width > 0, case .some(let stroke) = s.stroke else { return }
            if s.dash == nil, s.cap == .butt, s.join == .miter {
                pieces.append(MathGlyphs.Piece(path: placed, color: stroke, stroke: width))
                return
            }
            var p = path
            if let dash = s.dash, dash.contains(where: { $0 > 0 }) { p = p.copy(dashingWithPhase: 0, lengths: dash) }
            let outline = p.copy(
                strokingWithWidth: s.strokeWidth, lineCap: s.cap, lineJoin: s.join, miterLimit: 10)
            if let o = outline.copy(using: &t) { pieces.append(MathGlyphs.Piece(path: o, color: stroke)) }
        }

        /// A character MathJax's font lacks: drawn from the system's fonts, as a browser would.
        func addText(_ string: String, _ s: State, _ a: [String: String]) {
            guard !string.isEmpty else { return }
            let size = CGFloat(Double((a["font-size"] ?? "").replacingOccurrences(of: "px", with: "")) ?? 1000)
            let variant = a["data-variant"] ?? "normal"
            var font =
                (a["font-family"] ?? "serif").contains("sans")
                ? Fonts.system(size) : Fonts.system(size, design: .serif)
            if variant.contains("bold") { font = Fonts.adding(.traitBold, to: font) }
            if variant.contains("italic") { font = Fonts.adding(.traitItalic, to: font) }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: [TextKey.font: font]) as CFAttributedString)
            let out = CGMutablePath()
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = attrs[kCTFontAttributeName] as! CTFont? ?? font
                let n = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: n)
                var positions = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for i in 0..<n {
                    // Glyph outlines are y up; the text's own space is y down.
                    var t = CGAffineTransform(translationX: positions[i].x, y: 0).scaledBy(x: 1, y: -1)
                    if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], &t) { out.addPath(g) }
                }
            }
            var t = s.transform
            if let placed = out.copy(using: &t) {
                let color: RGBA? = if case .some(let f) = s.fill { f } else { nil }
                pieces.append(MathGlyphs.Piece(path: placed, color: color))
            }
        }

        static func num(_ s: String?) -> Double { s.flatMap { Double($0) } ?? 0 }

        /// `translate`, `scale`, `matrix` and `rotate`, applied left to right.
        static func transform(_ s: String?) -> CGAffineTransform {
            guard let s, !s.isEmpty else { return .identity }
            var t = CGAffineTransform.identity
            var rest = Substring(s)
            while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
                let name = rest[..<open].trimmingCharacters(in: .whitespaces)
                let v = rest[rest.index(after: open)..<close].split(whereSeparator: { $0 == " " || $0 == "," })
                    .compactMap { Double($0) }
                var m = CGAffineTransform.identity
                switch name {
                case "translate": m = CGAffineTransform(translationX: v.first ?? 0, y: v.count > 1 ? v[1] : 0)
                case "scale": m = CGAffineTransform(scaleX: v.first ?? 1, y: v.count > 1 ? v[1] : v.first ?? 1)
                case "matrix" where v.count == 6:
                    m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                case "rotate": m = CGAffineTransform(rotationAngle: (v.first ?? 0) * .pi / 180)
                default: break
                }
                // Later transforms in the list apply first, as in SVG.
                t = m.concatenating(t)
                rest = rest[rest.index(after: close)...]
            }
            return t
        }

        /// A paint: nil for "none", `.some(nil)` for the text's colour, else the colour.
        /// Fill, stroke and line attributes or style properties.
        static func paint(_ a: [String: String], into s: inout State) {
            if let f = a["fill"] { s.fill = paint(f) }
            if let f = a["stroke"] { s.stroke = paint(f) }
            if let w = a["stroke-width"].flatMap({ Double($0.replacingOccurrences(of: "px", with: "")) }) {
                s.strokeWidth = w
            }
            if let d = a["stroke-dasharray"] {
                let v = d.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                s.dash = v.isEmpty ? nil : v.map { CGFloat($0) }
            }
            switch a["stroke-linecap"] {
            case "round": s.cap = .round
            case "square": s.cap = .square
            case "butt": s.cap = .butt
            default: break
            }
            switch a["stroke-linejoin"] {
            case "round": s.join = .round
            case "bevel": s.join = .bevel
            case "miter": s.join = .miter
            default: break
            }
        }

        static func paint(_ s: String) -> RGBA?? {
            let v = s.trimmingCharacters(in: .whitespaces).lowercased()
            switch v {
            case "none", "transparent": return nil
            case "currentcolor", "inherit", "": return .some(nil)
            default: return .some(MathColors.parse(v))
            }
        }
    }
}

/// CSS colours as MathJax writes them for `\color`: names, `#rgb`, `#rrggbb` and `rgb()`.
enum MathColors {
    static func parse(_ s: String) -> RGBA? {
        if s.hasPrefix("#") {
            var h = String(s.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6 || h.count == 8, UInt64(h, radix: 16) != nil else { return nil }
            return RGBA(hex: h)
        }
        if s.hasPrefix("rgb") {
            let inner = s.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func channel(_ p: String) -> Double {
                p.hasSuffix("%") ? (Double(p.dropLast()) ?? 0) / 100 : (Double(p) ?? 0) / 255
            }
            let alpha = parts.count > 3 ? Double(parts[3]) ?? 1 : 1
            return RGBA(r: channel(parts[0]), g: channel(parts[1]), b: channel(parts[2]), a: alpha)
        }
        return names[s].map { RGBA(hex: $0) }
    }

    /// The CSS named colours.
    static let names: [String: String] = [
        "aliceblue": "f0f8ff", "antiquewhite": "faebd7", "aqua": "00ffff", "aquamarine": "7fffd4",
        "azure": "f0ffff", "beige": "f5f5dc", "bisque": "ffe4c4", "black": "000000", "blanchedalmond": "ffebcd",
        "blue": "0000ff", "blueviolet": "8a2be2", "brown": "a52a2a", "burlywood": "deb887", "cadetblue": "5f9ea0",
        "chartreuse": "7fff00", "chocolate": "d2691e", "coral": "ff7f50", "cornflowerblue": "6495ed",
        "cornsilk": "fff8dc", "crimson": "dc143c", "cyan": "00ffff", "darkblue": "00008b", "darkcyan": "008b8b",
        "darkgoldenrod": "b8860b", "darkgray": "a9a9a9", "darkgreen": "006400", "darkgrey": "a9a9a9",
        "darkkhaki": "bdb76b", "darkmagenta": "8b008b", "darkolivegreen": "556b2f", "darkorange": "ff8c00",
        "darkorchid": "9932cc", "darkred": "8b0000", "darksalmon": "e9967a", "darkseagreen": "8fbc8f",
        "darkslateblue": "483d8b", "darkslategray": "2f4f4f", "darkslategrey": "2f4f4f", "darkturquoise": "00ced1",
        "darkviolet": "9400d3", "deeppink": "ff1493", "deepskyblue": "00bfff", "dimgray": "696969",
        "dimgrey": "696969", "dodgerblue": "1e90ff", "firebrick": "b22222", "floralwhite": "fffaf0",
        "forestgreen": "228b22", "fuchsia": "ff00ff", "gainsboro": "dcdcdc", "ghostwhite": "f8f8ff",
        "gold": "ffd700", "goldenrod": "daa520", "gray": "808080", "green": "008000", "greenyellow": "adff2f",
        "grey": "808080", "honeydew": "f0fff0", "hotpink": "ff69b4", "indianred": "cd5c5c", "indigo": "4b0082",
        "ivory": "fffff0", "khaki": "f0e68c", "lavender": "e6e6fa", "lavenderblush": "fff0f5",
        "lawngreen": "7cfc00", "lemonchiffon": "fffacd", "lightblue": "add8e6", "lightcoral": "f08080",
        "lightcyan": "e0ffff", "lightgoldenrodyellow": "fafad2", "lightgray": "d3d3d3", "lightgreen": "90ee90",
        "lightgrey": "d3d3d3", "lightpink": "ffb6c1", "lightsalmon": "ffa07a", "lightseagreen": "20b2aa",
        "lightskyblue": "87cefa", "lightslategray": "778899", "lightslategrey": "778899",
        "lightsteelblue": "b0c4de", "lightyellow": "ffffe0", "lime": "00ff00", "limegreen": "32cd32",
        "linen": "faf0e6", "magenta": "ff00ff", "maroon": "800000", "mediumaquamarine": "66cdaa",
        "mediumblue": "0000cd", "mediumorchid": "ba55d3", "mediumpurple": "9370db", "mediumseagreen": "3cb371",
        "mediumslateblue": "7b68ee", "mediumspringgreen": "00fa9a", "mediumturquoise": "48d1cc",
        "mediumvioletred": "c71585", "midnightblue": "191970", "mintcream": "f5fffa", "mistyrose": "ffe4e1",
        "moccasin": "ffe4b5", "navajowhite": "ffdead", "navy": "000080", "oldlace": "fdf5e6", "olive": "808000",
        "olivedrab": "6b8e23", "orange": "ffa500", "orangered": "ff4500", "orchid": "da70d6",
        "palegoldenrod": "eee8aa", "palegreen": "98fb98", "paleturquoise": "afeeee", "palevioletred": "db7093",
        "papayawhip": "ffefd5", "peachpuff": "ffdab9", "peru": "cd853f", "pink": "ffc0cb", "plum": "dda0dd",
        "powderblue": "b0e0e6", "purple": "800080", "rebeccapurple": "663399", "red": "ff0000",
        "rosybrown": "bc8f8f", "royalblue": "4169e1", "saddlebrown": "8b4513", "salmon": "fa8072",
        "sandybrown": "f4a460", "seagreen": "2e8b57", "seashell": "fff5ee", "sienna": "a0522d", "silver": "c0c0c0",
        "skyblue": "87ceeb", "slateblue": "6a5acd", "slategray": "708090", "slategrey": "708090", "snow": "fffafa",
        "springgreen": "00ff7f", "steelblue": "4682b4", "tan": "d2b48c", "teal": "008080", "thistle": "d8bfd8",
        "tomato": "ff6347", "turquoise": "40e0d0", "violet": "ee82ee", "wheat": "f5deb3", "white": "ffffff",
        "whitesmoke": "f5f5f5", "yellow": "ffff00", "yellowgreen": "9acd32",
    ]
}

/// SVG path data, read from its UTF-8 bytes (MathJax's glyphs are long; a formula can carry
/// tens of thousands of characters). M L H V C S Q T Z, absolute and relative.
enum MathPathData {
    static func parse(_ d: String) -> CGPath? {
        var bytes = Array(d.utf8)
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { buf -> CGPath? in
            let b = buf.baseAddress!
            var i = 0
            let p = CGMutablePath()
            var pt = CGPoint.zero
            var start = CGPoint.zero
            var lastCubic: CGPoint?
            var lastQuad: CGPoint?
            var cmd: UInt8 = 0

            func skip() {
                while b[i] == 32 || b[i] == 44 || b[i] == 10 || b[i] == 13 || b[i] == 9 { i += 1 }
            }
            func isNumberStart(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 }
            func num() -> CGFloat? {
                skip()
                guard isNumberStart(b[i]) else { return nil }
                var sign: Double = 1
                if b[i] == 45 {
                    sign = -1
                    i += 1
                } else if b[i] == 43 {
                    i += 1
                }
                var v: Double = 0
                var any = false
                while b[i] >= 48 && b[i] <= 57 {
                    v = v * 10 + Double(b[i] - 48)
                    i += 1
                    any = true
                }
                if b[i] == 46 {
                    i += 1
                    var scale = 0.1
                    while b[i] >= 48 && b[i] <= 57 {
                        v += Double(b[i] - 48) * scale
                        scale /= 10
                        i += 1
                        any = true
                    }
                }
                if any, b[i] == 101 || b[i] == 69 {
                    var j = i + 1
                    var esign: Double = 1
                    if b[j] == 45 {
                        esign = -1
                        j += 1
                    } else if b[j] == 43 {
                        j += 1
                    }
                    var e: Double = 0
                    var digits = false
                    while b[j] >= 48 && b[j] <= 57 {
                        e = e * 10 + Double(b[j] - 48)
                        j += 1
                        digits = true
                    }
                    if digits {
                        v *= pow(10, esign * e)
                        i = j
                    }
                }
                return any ? CGFloat(sign * v) : nil
            }
            func point(_ rel: Bool) -> CGPoint? {
                guard let x = num(), let y = num() else { return nil }
                return rel ? CGPoint(x: pt.x + x, y: pt.y + y) : CGPoint(x: x, y: y)
            }

            while true {
                skip()
                let c = b[i]
                if c == 0 { break }
                if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) {
                    cmd = c
                    i += 1
                } else if !isNumberStart(c) || cmd == 0 {
                    return nil
                }
                let rel = cmd >= 97
                switch cmd | 0x20 {
                case 109:  // m
                    guard let to = point(rel) else { return p }
                    p.move(to: to)
                    pt = to
                    start = to
                    cmd = rel ? 108 : 76
                    lastCubic = nil
                    lastQuad = nil
                case 108:  // l
                    guard let to = point(rel) else { return p }
                    p.addLine(to: to)
                    pt = to
                    lastCubic = nil
                    lastQuad = nil
                case 104:  // h
                    guard let x = num() else { return p }
                    pt = CGPoint(x: rel ? pt.x + x : x, y: pt.y)
                    p.addLine(to: pt)
                    lastCubic = nil
                    lastQuad = nil
                case 118:  // v
                    guard let y = num() else { return p }
                    pt = CGPoint(x: pt.x, y: rel ? pt.y + y : y)
                    p.addLine(to: pt)
                    lastCubic = nil
                    lastQuad = nil
                case 99:  // c
                    guard let c1 = point(rel), let c2 = point(rel), let to = point(rel) else { return p }
                    p.addCurve(to: to, control1: c1, control2: c2)
                    pt = to
                    lastCubic = c2
                    lastQuad = nil
                case 115:  // s
                    let c1 = lastCubic.map { CGPoint(x: 2 * pt.x - $0.x, y: 2 * pt.y - $0.y) } ?? pt
                    guard let c2 = point(rel), let to = point(rel) else { return p }
                    p.addCurve(to: to, control1: c1, control2: c2)
                    pt = to
                    lastCubic = c2
                    lastQuad = nil
                case 113:  // q
                    guard let c1 = point(rel), let to = point(rel) else { return p }
                    p.addQuadCurve(to: to, control: c1)
                    pt = to
                    lastQuad = c1
                    lastCubic = nil
                case 116:  // t
                    let c1 = lastQuad.map { CGPoint(x: 2 * pt.x - $0.x, y: 2 * pt.y - $0.y) } ?? pt
                    guard let to = point(rel) else { return p }
                    p.addQuadCurve(to: to, control: c1)
                    pt = to
                    lastQuad = c1
                    lastCubic = nil
                case 122:  // z
                    p.closeSubpath()
                    pt = start
                    lastCubic = nil
                    lastQuad = nil
                    // Numbers can't follow Z without a command.
                    cmd = 0
                default:
                    // Arcs and anything else aren't in MathJax's output.
                    return p
                }
            }
            return p
        }
    }
}
