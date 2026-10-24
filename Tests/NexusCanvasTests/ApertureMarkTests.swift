import AppKit
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusTheme

/// `ApertureMark` against the brand kit (brand/BRAND.md): the spec's numbers, and pixels
/// compared with the kit's own masters at 1024, 64, 32 and 16 px in each palette. The
/// references are the kit's files, read from `brand/`: its PNGs, and its SVGs rasterized by
/// macOS. The tolerance allows for anti-aliasing at the edges only.
@MainActor
@Suite struct ApertureMarkTests {
    static let brand = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "brand")

    // MARK: Numbers

    @Test func partsMatchTheSpecTable() {
        // BRAND.md §1: b, ring stroke, gap, ring end points.
        let table: [(Double, Double, Double, CGPoint, CGPoint)] = [
            (1.0, 5, 45, CGPoint(x: 35.90, y: 22.10), CGPoint(x: 35.90, y: 41.90)),
            (1.1, 5.5, 46.2, CGPoint(x: 35.69, y: 21.90), CGPoint(x: 35.69, y: 42.10)),
            (1.5, 7.5, 51, CGPoint(x: 34.81, y: 21.12), CGPoint(x: 34.81, y: 42.88)),
            (1.7, 8.5, 53.4, CGPoint(x: 34.35, y: 20.76), CGPoint(x: 34.35, y: 43.24)),
            (1.9, 9.5, 55.8, CGPoint(x: 33.87, y: 20.42), CGPoint(x: 33.87, y: 43.58)),
        ]
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.006 }
        for (b, stroke, gap, up, down) in table {
            let p = ApertureMark.parts(b: b)
            #expect(near(p.ringStroke, stroke) && near(p.gap, gap), "b \(b)")
            #expect(near(p.ringEnds.0.x, up.x) && near(p.ringEnds.0.y, up.y), "b \(b) upper end")
            #expect(near(p.ringEnds.1.x, down.x) && near(p.ringEnds.1.y, down.y), "b \(b) lower end")
            #expect(near(p.branchStroke, 3.4 * b) && near(p.endRadius, 5 * (1 + 0.45 * (b - 1))))
            #expect(near(p.rootRadius, 6.2 * (1 + 0.45 * (b - 1))))
        }
    }

    @Test func opticalSizeFollowsTheRenderedSize() {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }
        #expect(near(ApertureMark.boost(forSize: 1024), 1) && near(ApertureMark.boost(forSize: 128), 1))
        #expect(near(ApertureMark.boost(forSize: 80), 1.25), "halfway between 32 and 128")
        #expect(near(ApertureMark.boost(forSize: 32), 1.5) && near(ApertureMark.boost(forSize: 24), 1.7))
        #expect(near(ApertureMark.boost(forSize: 16), 1.9) && near(ApertureMark.boost(forSize: 10), 1.9))
    }

    // MARK: Pixels

    struct Diff: CustomStringConvertible {
        /// The share of pixels whose largest channel difference is over 32 (of 255).
        var over: Double
        var mean: Double
        var description: String { String(format: "%.2f%% of pixels off, mean %.2f", over * 100, mean) }
    }

    static func pixels(_ img: CGImage, _ n: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let ctx = CGContext(
            data: &buf, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        return buf
    }

    static func diff(_ a: CGImage, _ b: CGImage, _ n: Int) -> Diff {
        let x = pixels(a, n)
        let y = pixels(b, n)
        var off = 0
        var total = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(x[i + c]) - Int(y[i + c]))) }
            if d > 32 { off += 1 }
            total += d
        }
        return Diff(over: Double(off) / Double(n * n), mean: Double(total) / Double(n * n))
    }

    /// A kit file at `n` px: PNGs as they are, SVGs rasterized by macOS (drawn in order).
    static func reference(_ paths: [String], _ n: Int) throws -> CGImage {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: n, height: n)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for p in paths {
            let img = try #require(NSImage(contentsOf: brand.appending(path: p)), "\(p)")
            img.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.cgImage)
    }

    /// The mark rendered by SwiftUI at `n` px, optionally placed in a larger canvas.
    static func render(
        _ palette: ApertureMark.Palette, _ size: ApertureMark.OpticalSize = .automatic, dark: Bool = false, n: Int,
        in canvas: Int? = nil, at origin: CGPoint = .zero
    ) throws -> CGImage {
        let side = CGFloat(canvas ?? n)
        let view = ZStack(alignment: .topLeading) {
            Color.clear
            ApertureMark(palette: palette, opticalSize: size)
                .frame(width: CGFloat(n), height: CGFloat(n))
                .offset(x: origin.x, y: origin.y)
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: view)
        r.scale = 1
        return try #require(r.cgImage)
    }

    func expectClose(_ a: CGImage, _ b: CGImage, _ n: Int, _ what: String) {
        // NEXUS_SNAPSHOT_DIR=<folder> writes both images, to look at them side by side.
        if let dir = ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] {
            let name =
                "aperture-\(what.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: ""))"
            for (img, tag) in [(a, "mark"), (b, "kit")] {
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(tag).png"))
            }
        }
        let d = Self.diff(a, b, n)
        let t = Self.tolerance(n)
        #expect(d.over < t.over && d.mean < t.mean, "\(what): \(d)")
    }

    /// Anti-aliasing touches more of a small image: at 16 px a third of the pixels are edges.
    /// SwiftUI and macOS's SVG renderer disagree there by a few levels, never on shape.
    static func tolerance(_ n: Int) -> (over: Double, mean: Double) {
        n >= 128 ? (0.012, 2.5) : n >= 32 ? (0.04, 4.5) : (0.08, 8)
    }

    /// The tolerance still catches real mistakes: the wrong optical size, or a mirrored mark.
    @Test func toleranceCatchesWrongMarks() throws {
        let kit16 = try Self.reference(["svg/mark/opennexus-mark-16px.svg"], 16)
        let t = Self.tolerance(16)
        let thin = Self.diff(try Self.render(.light, .boost(1), n: 16), kit16, 16)
        #expect(thin.over >= t.over || thin.mean >= t.mean, "b = 1 at 16 px: \(thin)")
        let kit32 = try Self.reference(["svg/mark/opennexus-mark-32px.svg"], 32)
        let mirrored = try Self.render(.light, n: 32)
        let ctx = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 32, y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(mirrored, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let flipped = Self.diff(try #require(ctx.makeImage()), kit32, 32)
        #expect(flipped.over >= Self.tolerance(32).over, "mirrored: \(flipped)")
        let wrongColours = Self.diff(try Self.render(.dark, n: 32), kit32, 32)
        #expect(wrongColours.over >= Self.tolerance(32).over, "dark palette for light: \(wrongColours)")
    }

    @Test func matchesTheMastersAt1024() throws {
        expectClose(
            try Self.render(.light, n: 1024), try Self.reference(["png/opennexus-mark-1024.png"], 1024), 1024, "light")
        expectClose(
            try Self.render(.dark, n: 1024), try Self.reference(["png/opennexus-mark-on-dark-1024.png"], 1024), 1024,
            "dark")
        // Automatic follows the colour scheme.
        expectClose(
            try Self.render(.automatic, dark: true, n: 1024),
            try Self.reference(["svg/mark/opennexus-mark-on-dark.svg"], 1024), 1024, "automatic, dark")
        expectClose(
            try Self.render(.mono(.black), n: 1024),
            try Self.reference(["svg/mark/opennexus-mark-mono-black.svg"], 1024),
            1024, "mono")
    }

    @Test func matchesTheMastersAt64() throws {
        // The kit's masters are drawn at b = 1; at 64 px the automatic size would be bolder.
        expectClose(
            try Self.render(.light, .boost(1), n: 64), try Self.reference(["svg/mark/opennexus-mark.svg"], 64), 64,
            "light")
        expectClose(
            try Self.render(.dark, .boost(1), n: 64), try Self.reference(["svg/mark/opennexus-mark-on-dark.svg"], 64),
            64,
            "dark")
    }

    @Test func matchesTheOpticalSizesAt32And16() throws {
        // Automatic picks b = 1.5 at 32 px and 1.9 at 16 px: the kit's small masters.
        expectClose(
            try Self.render(.light, n: 32), try Self.reference(["svg/mark/opennexus-mark-32px.svg"], 32), 32, "light 32"
        )
        expectClose(
            try Self.render(.dark, n: 32), try Self.reference(["svg/mark/opennexus-mark-on-dark-32px.svg"], 32), 32,
            "dark 32")
        expectClose(
            try Self.render(.light, n: 16), try Self.reference(["svg/mark/opennexus-mark-16px.svg"], 16), 16, "light 16"
        )
        expectClose(
            try Self.render(.dark, n: 16), try Self.reference(["svg/mark/opennexus-mark-on-dark-16px.svg"], 16), 16,
            "dark 16")
    }

    @Test func appIconPaletteMatchesTheIconComposerLayers() throws {
        // The layers place the grid at translate(155.43) scale(11.14), at the app icon's b = 1.1.
        let k = 11.14
        let origin = 155.43 + ApertureMark.viewBox.minX * k
        let side = Int((ApertureMark.viewBox.width * k).rounded())
        let mark = try Self.render(.appIcon, .boost(1.1), n: side, in: 1024, at: CGPoint(x: origin, y: origin))
        let layers = try Self.reference(
            [
                "icon/icon-composer-layers/1-ring.svg", "icon/icon-composer-layers/2-branches.svg",
                "icon/icon-composer-layers/3-root.svg",
            ], 1024)
        expectClose(mark, layers, 1024, "app icon")
    }
}
