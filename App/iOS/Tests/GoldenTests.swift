import NexusCanvas
import NexusCore
import NexusTheme
import NexusTouch
import Testing
import UIKit
import Vision

extension HostedTests {
    /// A3: the 36 style × theme goldens, rendered offscreen by the touch canvas on iOS and
    /// compared with the Mac's committed PNGs within the Mac's own golden tolerance.
    @MainActor
    @Suite(.serialized) struct GoldenTests {
        nonisolated static let goldenDir = repoRoot.appending(path: "Tests/NexusCanvasTests/Goldens")

        nonisolated static let cases: [(String, String)] = Theme.required.flatMap { t in
            NodeStyle.allCases.map { (t.id, $0.rawValue) }
        }

        /// Exports, Quick Look's preview and the presenter's slides draw as the canvas does, not
        /// upside down (D410): Vision reads the sample map's topics from an exported PNG and
        /// from the first slide, the first branch above the last.
        @Test func exportsAndSlidesAreUpright() throws {
            let doc = nodeStyleSampleDocument(theme: "classic", style: "soft")
            let png = try #require(HeadlessExport.previewPNG(doc))
            try Self.expectUpright(try #require(UIImage(data: png)?.cgImage), "the exported PNG")
            let slide = try #require(
                SlideExporter.renderSlide(doc, canvas: "c1", index: 0, size: CGSize(width: 1280, height: 720)))
            try Self.expectUpright(slide, "the first slide")
        }

        static func expectUpright(_ image: CGImage, _ what: String) throws {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            var found: [String: CGRect] = [:]
            for o in request.results ?? [] {
                if let t = o.topCandidates(1).first?.string { found[t] = o.boundingBox }
            }
            // Vision's boxes have y up.
            let first = try #require(found["Positioning"], "\(what): \(found.keys.sorted())")
            let last = try #require(found["Timeline"], "\(what): \(found.keys.sorted())")
            #expect(first.minY > last.minY, "\(what): Positioning is above Timeline")
        }

        @Test(arguments: cases)
        func nodeStyleTheme(theme: String, style: String) throws {
            let h = TouchHarness(model: nodeStyleSampleDocument(theme: theme, style: style), width: 560, height: 340)
            h.view.fitToWindow()
            h.controller.select(h.canvas.nodes[h.canvas.root]!.children[1])
            let image = h.view.renderImage(scale: 1)
            let png = try #require(image.pngData())
            if let dir = ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] {
                try png.write(to: URL(fileURLWithPath: dir).appending(path: "ios-\(theme)-\(style).png"))
            }
            let golden = try #require(
                UIImage(contentsOfFile: Self.goldenDir.appending(path: "ns-\(theme)-\(style).png").path)?.cgImage)
            // Compare like with like: both images after the same PNG encode/decode.
            let current = try #require(UIImage(data: png)?.cgImage)
            let diff = ImageDiff.compare(current, golden)
            print("GOLDEN \(theme)/\(style) mean \(diff.meanDelta) changed \(diff.changedFraction)")
            #expect(diff.sizeMatches, "size changed for \(theme)/\(style)")
            #expect(diff.meanDelta < 0.02, "\(theme)/\(style): mean channel delta \(diff.meanDelta)")
            #expect(diff.changedFraction < 0.02, "\(theme)/\(style): \(diff.changedFraction * 100)% pixels changed")
        }
    }
}
