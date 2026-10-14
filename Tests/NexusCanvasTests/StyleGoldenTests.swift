import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusTheme

/// M2 acceptance: the NS sample map in 9 node styles × 4 required themes, rendered
/// offscreen and compared with committed goldens. Set REGENERATE_GOLDENS=1 to rewrite
/// them after an intended visual change (review the diff before committing).
@MainActor
@Suite(.serialized) struct StyleGoldenTests {
    nonisolated static let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Goldens")
    nonisolated static let regenerate = ProcessInfo.processInfo.environment["REGENERATE_GOLDENS"] == "1"

    nonisolated static let cases: [(String, String)] = Theme.required.flatMap { t in
        NodeStyle.allCases.map { (t.id, $0.rawValue) }
    }

    @Test(arguments: cases)
    func nodeStyleTheme(theme: String, style: String) throws {
        let h = CanvasHarness(model: nodeStyleSampleDocument(theme: theme, style: style), width: 560, height: 340)
        h.host.canvasView.fitToWindow()
        h.controller.select(h.canvas.nodes[h.canvas.root]!.children[1])
        let rep = try #require(h.renderOffscreen(scale: 1))
        let url = Self.goldenDir.appendingPathComponent("ns-\(theme)-\(style).png")
        if Self.regenerate {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        let goldenData = try Data(contentsOf: url)
        let golden = try #require(NSBitmapImageRep(data: goldenData))
        // Compare like with like: both images after the same PNG encode/decode.
        let current = try #require(
            rep.representation(using: .png, properties: [:]).flatMap(NSBitmapImageRep.init(data:)))
        let diff = ImageDiff.compare(current, golden)
        #expect(diff.sizeMatches, "size changed for \(theme)/\(style)")
        #expect(diff.meanDelta < 0.02, "\(theme)/\(style): mean channel delta \(diff.meanDelta)")
        #expect(diff.changedFraction < 0.02, "\(theme)/\(style): \(diff.changedFraction * 100)% pixels changed")
    }

    /// Every node style really changes the drawing, and so does every theme.
    @Test func stylesAndThemesAreDistinct() throws {
        var reps: [String: NSBitmapImageRep] = [:]
        for (t, s) in [("classic", "outline"), ("classic", "soft"), ("classic", "minimal"), ("graphite", "outline")] {
            let h = CanvasHarness(model: nodeStyleSampleDocument(theme: t, style: s), width: 560, height: 340)
            h.host.canvasView.fitToWindow()
            reps["\(t)/\(s)"] = try #require(h.renderOffscreen(scale: 1))
        }
        #expect(ImageDiff.compare(reps["classic/outline"]!, reps["classic/soft"]!).changedFraction > 0.005)
        #expect(ImageDiff.compare(reps["classic/outline"]!, reps["classic/minimal"]!).changedFraction > 0.005)
        #expect(ImageDiff.compare(reps["classic/outline"]!, reps["graphite/outline"]!).changedFraction > 0.5)
    }
}

/// Pixel comparison with tolerance for anti-aliasing.
enum ImageDiff {
    struct Result {
        var sizeMatches: Bool
        var meanDelta: Double
        var changedFraction: Double
    }

    static func compare(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Result {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let pa = rgba(a), let pb = rgba(b) else {
            return Result(sizeMatches: false, meanDelta: 1, changedFraction: 1)
        }
        var total = 0
        var changed = 0
        let n = pa.count / 4
        for i in 0..<n {
            let d =
                (abs(Int(pa[i * 4]) - Int(pb[i * 4])) + abs(Int(pa[i * 4 + 1]) - Int(pb[i * 4 + 1]))
                    + abs(Int(pa[i * 4 + 2]) - Int(pb[i * 4 + 2]))) / 3
            total += d
            if d > 30 { changed += 1 }
        }
        return Result(
            sizeMatches: true, meanDelta: Double(total) / Double(n) / 255,
            changedFraction: Double(changed) / Double(n))
    }

    /// Redraws an image into one canonical sRGB RGBA8 buffer.
    static func rgba(_ rep: NSBitmapImageRep) -> [UInt8]? {
        guard let cg = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = cg.width
        let h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard
                let ctx = CGContext(
                    data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
