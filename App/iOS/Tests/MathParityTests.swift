import CoreGraphics
import Foundation
import NexusTheme
import Testing

@testable import NexusScene

extension HostedTests {
    /// M48's A9: MathJax in the iPhone's and iPad's JavaScriptCore typesets the Mac's
    /// corpus, and the 40 representative formulas come out as the Mac's goldens, byte for
    /// byte (`Tests/NexusSceneTests/Math`).
    @Suite struct MathParityTests {
        static let dir = repoRoot.appending(path: "Tests/NexusSceneTests/Math")

        @Test func corpusTypesets() throws {
            let text = try String(contentsOf: Self.dir.appending(path: "katex-functions.txt"), encoding: .utf8)
            let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
            #expect(lines.count > 850)
            var failures: [String] = []
            for tex in lines {
                for display in [false, true] {
                    if case .error(let m) = MathEngine.shared.typeset(tex, display: display) {
                        failures.append("\(tex): \(m)")
                    }
                }
            }
            #expect(failures.isEmpty, "\(failures.count) failed: \(failures.prefix(20))")
        }

        @Test func goldensMatchTheMacs() throws {
            let list = try String(contentsOf: Self.dir.appending(path: "goldens.txt"), encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#") }
            #expect(list.count == 40)
            var changed: [String] = []
            for line in list {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                let g = try #require(MathEngine.shared.typeset(parts[1], display: true).glyphs, "\(parts[0])")
                let svg = g.svg(fontSize: 20, color: RGBA(r: 0, g: 0, b: 0, a: 1)) + "\n"
                let mac = try String(contentsOf: Self.dir.appending(path: "Goldens/\(parts[0]).svg"), encoding: .utf8)
                if svg != mac { changed.append(parts[0]) }
            }
            #expect(changed.isEmpty, "Differ from the Mac's: \(changed)")
        }

        /// A4's warm render, measured as the Mac measures it (`MathCorpusTests`).
        @Test func warmRenderIsFast() throws {
            let list = try String(contentsOf: Self.dir.appending(path: "goldens.txt"), encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#") }
                .map { String($0.split(separator: "\t", maxSplits: 1)[1]) }
            let engine = MathEngine()
            let ctx = CGContext(
                data: nil, width: 600, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            for tex in list { _ = engine.typeset(tex, display: true) }
            engine.clearCache()
            var fresh: [Double] = []
            for tex in list {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let g = try #require(engine.typeset(tex, display: true).glyphs)
                g.draw(
                    in: ctx, at: CGPoint(x: 4, y: 80), fontSize: 18, color: CGColor(gray: 0, alpha: 1), flipped: false)
                fresh.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            let median = fresh.sorted()[fresh.count / 2]
            print("Math render on iOS, median: new formula \(median) ms (slowest \(fresh.max()!) ms)")
            #expect(median < 5)
        }
    }
}
