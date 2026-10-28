import Foundation
import NexusCore

/// Which way an image's text reads (D194). The layout passes read left to right, top to
/// bottom, so right-to-left text is mirrored and vertical text turned before they run.
enum ReadingDirection: Equatable {
    case leftToRight
    /// Arabic or Hebrew: lines start at the right, and indentation grows leftward.
    case rightToLeft
    /// Chinese, Japanese or Korean set in columns, read top to bottom, right to left.
    case vertical

    /// Mostly right-to-left letters read right to left. Vertical needs CJK lines of two or
    /// more characters that Vision reports as columns (at least 1.8× taller than wide), for
    /// most such lines.
    init(_ boxes: [TextBox]) {
        var letters = 0
        var rtl = 0
        var cjkLines = 0
        var columns = 0
        for b in boxes {
            var cjk = 0
            for u in b.text.unicodeScalars where u.properties.isAlphabetic {
                letters += 1
                if Self.isRightToLeft(u) { rtl += 1 }
                if Self.isCJK(u) { cjk += 1 }
            }
            guard cjk >= 2, cjk * 2 >= b.text.count else { continue }
            cjkLines += 1
            if b.height >= 1.8 * b.width { columns += 1 }
        }
        if cjkLines > 0, columns * 5 > cjkLines * 3 {
            self = .vertical
        } else if letters > 0, rtl * 2 > letters {
            self = .rightToLeft
        } else {
            self = .leftToRight
        }
    }

    static func isRightToLeft(_ u: Unicode.Scalar) -> Bool {
        // Hebrew, Arabic, Syriac, Thaana, N'Ko and their presentation forms.
        (0x0590...0x08FF).contains(u.value) || (0xFB1D...0xFDFF).contains(u.value)
            || (0xFE70...0xFEFF).contains(u.value)
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
            0xF900...0xFAFF, 0x20000...0x2FFFF:
            true
        default: false
        }
    }

    /// The image turned to read left to right, top to bottom.
    func normalised(_ image: RecognisedImage) -> RecognisedImage {
        var out = image
        // Connector tracing reads the picture as it is: not for turned text.
        out.ink = nil
        switch self {
        case .leftToRight: return image
        case .rightToLeft:
            for i in out.boxes.indices {
                out.boxes[i].x = image.width - image.boxes[i].maxX
                out.boxes[i].inked = image.boxes[i].inked.map {
                    (image.width - $0.upperBound)...(image.width - $0.lowerBound)
                }
            }
        case .vertical:
            // Columns right to left become rows top to bottom.
            out.width = image.height
            out.height = image.width
            for (i, b) in image.boxes.enumerated() {
                out.boxes[i].x = b.minY
                out.boxes[i].y = image.width - b.maxX
                out.boxes[i].width = b.height
                out.boxes[i].height = b.width
                // Its width in ems and its ink were measured across the column, not along it.
                out.boxes[i].em = nil
                out.boxes[i].inked = nil
            }
        }
        return out
    }

    /// The structure found in the turned image, for the image as it reads.
    func structure(_ s: LayoutStructure?) -> LayoutStructure? {
        switch self {
        case .leftToRight: return s
        case .rightToLeft:
            let mirror: [LayoutStructure: LayoutStructure] = [
                .mindmapRight: .mindmapLeft, .mindmapLeft: .mindmapRight, .fishboneLeft: .fishboneRight,
                .fishboneRight: .fishboneLeft, .logicRight: .logicLeft, .logicLeft: .logicRight,
            ]
            return s.map { mirror[$0] ?? $0 }
        case .vertical:
            // Branches after the root in reading order hang below it; other shapes get the
            // canvas's default.
            return s == .mindmapRight ? .orgDown : nil
        }
    }
}
