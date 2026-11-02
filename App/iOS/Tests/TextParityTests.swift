import Foundation
import NexusScene
import NexusTheme
import Testing

extension HostedTests {
    /// iPad-against-Mac text parity (M47a's known gap): the iPad's TextKit measures every 27th
    /// (style, title) pair of the corpus, and the sizes are compared with the Mac's, recorded
    /// in `Tests/NexusSceneTests/MacMeasures.json`. Like CoreText against TextKit, agreement
    /// is measured and recorded, and must stay above the floor first measured here.
    @MainActor
    @Suite struct TextParityTests {
        static let titles: [String] =
            (try? JSONDecoder().decode(
                [String].self, from: Data(contentsOf: repoRoot.appending(path: "Tests/NexusSceneTests/Titles.json"))))
            ?? []

        /// The Mac's 375 styles (`TextEngineTests.styles`).
        static let styles: [NodeTextStyle] = {
            var out: [NodeTextStyle] = []
            let weights: [NodeTypography.Weight] = [.regular, .medium, .semibold, .bold, .heavy]
            for size in [12.0, 14, 16, 20, 26] {
                for w in weights {
                    for family in ["system", "serif", "rounded", "mono", "hand"] {
                        for maxWidth in [140.0, 220, 320] {
                            var s = NodeTextStyle(typography: .for(.main), monospaced: false)
                            s.fontSize = size
                            s.weight = w
                            s.family = family
                            s.maxWidth = maxWidth
                            s.lineHeight = (size * 1.3).rounded()
                            s.italic = out.count % 4 == 1
                            out.append(s)
                        }
                    }
                }
            }
            return out
        }()

        @Test func iPadMeasuresAsTheMacDoes() throws {
            #expect(Self.titles.count == 599)
            let mac = try JSONDecoder().decode(
                [[Double]].self,
                from: Data(contentsOf: repoRoot.appending(path: "Tests/NexusSceneTests/MacMeasures.json")))
            var k = 0
            var same = 0
            var close = 0
            var sameByFamily: [String: (Int, Int)] = [:]
            for (i, style) in Self.styles.enumerated() {
                for (j, text) in Self.titles.enumerated() where (i + j) % 27 == 0 {
                    let s = NodeMeasurer.measure(text, style: style)
                    let w = (s.width * 100).rounded() / 100
                    let h = (s.height * 100).rounded() / 100
                    let m = mac[k]
                    k += 1
                    let equal = w == m[0] && h == m[1]
                    if equal { same += 1 }
                    if abs(w - m[0]) <= 1, h == m[1] { close += 1 }
                    let f = sameByFamily[style.family] ?? (0, 0)
                    sameByFamily[style.family] = (f.0 + (equal ? 1 : 0), f.1 + 1)
                }
            }
            #expect(k == mac.count)
            let share = Double(same) / Double(k)
            let closeShare = Double(close) / Double(k)
            let families = sameByFamily.sorted { $0.key < $1.key }.map {
                "\($0.key) \(String(format: "%.1f", Double($0.value.0) / Double($0.value.1) * 100))%"
            }
            print(
                "TEXT-PARITY iPad measures \(same) of \(k) topics as the Mac does (\(String(format: "%.1f", share * 100))%); within 1 pt wide, same lines: \(String(format: "%.1f", closeShare * 100))%; \(families.joined(separator: ", "))"
            )
            #expect(closeShare > 0.9, "iPad text within 1 pt of the Mac's: \(closeShare)")
        }
    }
}
