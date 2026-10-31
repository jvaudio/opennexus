import CoreGraphics
import Foundation
import NexusCore
import NexusTheme
import Testing

@testable import NexusScene

/// M48's coverage corpus, goldens, malformed input and render time (A1, A4, A6). One test
/// at a time: the corpus and the malformed inputs keep JavaScriptCore busy for seconds,
/// which would show up in the render time. They use an engine of their own, so other
/// suites' tests, typesetting on the main thread, don't wait behind them.
@Suite(.serialized) struct MathCorpusTests {
    static let engine = MathEngine()
    nonisolated static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Math")
    nonisolated static let regenerate = ProcessInfo.processInfo.environment["REGENERATE_GOLDENS"] == "1"

    /// The corpus's formulas with their sections.
    static func corpus() throws -> [(section: String, tex: String)] {
        let text = try String(contentsOf: dir.appending(path: "katex-functions.txt"), encoding: .utf8)
        var section = ""
        var out: [(String, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3))
            } else if !line.hasPrefix("#") {
                out.append((section, String(line)))
            }
        }
        return out
    }

    /// A1: every line typesets, inline and display, with shapes to draw.
    @Test func katexCorpusTypesets() throws {
        let corpus = try Self.corpus()
        #expect(corpus.count > 850)
        var failures: [String] = []
        for (section, tex) in corpus {
            for display in [false, true] {
                switch Self.engine.typeset(tex, display: display) {
                case .glyphs(let g):
                    if g.width <= 0 { failures.append("\(section): \(tex) has no width") }
                case .error(let message):
                    failures.append("\(section): \(tex) (\(display ? "display" : "inline")): \(message)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failed:\n\(failures.joined(separator: "\n"))")
    }

    /// A1's representative formulas: fractions, matrices, aligned, cases, reactions with
    /// arrows, states and charges, units, and a few more (`Math/goldens.txt`).
    static func goldens() throws -> [(name: String, tex: String)] {
        let text = try String(contentsOf: dir.appending(path: "goldens.txt"), encoding: .utf8)
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map {
            let parts = $0.split(separator: "\t", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// A1: each representative formula as committed (REGENERATE_GOLDENS=1 rewrites them).
    @Test func goldensMatch() throws {
        let list = try Self.goldens()
        #expect(list.count == 40)
        let goldens = Self.dir.appending(path: "Goldens")
        var changed: [String] = []
        for (name, tex) in list {
            let g = try #require(Self.engine.typeset(tex, display: true).glyphs, "\(name)")
            let svg = g.svg(fontSize: 20, color: RGBA(r: 0, g: 0, b: 0, a: 1)) + "\n"
            let url = goldens.appending(path: "\(name).svg")
            if Self.regenerate {
                try svg.write(to: url, atomically: true, encoding: .utf8)
            } else if (try? String(contentsOf: url, encoding: .utf8)) != svg {
                changed.append(name)
            }
        }
        #expect(changed.isEmpty, "Differ from their goldens: \(changed)")
    }

    /// A2: everything 0.3's `/math` drew (its symbols, functions and constructs, from
    /// `RichFormats.swift` at v0.3) typesets, inline and display.
    @Test func v03InputsTypeset() {
        let symbols = [
            "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "iota", "kappa",
            "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega",
            "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega", "sum", "prod", "int",
            "oint", "infty", "cdot", "times", "div", "pm", "mp", "leq", "le", "geq", "ge", "neq", "ne", "approx",
            "equiv", "sim", "propto", "to", "rightarrow", "leftarrow", "Rightarrow", "Leftarrow", "iff", "mapsto",
            "in", "notin", "subset", "subseteq", "cup", "cap", "emptyset", "forall", "exists", "partial", "nabla",
            "ldots", "cdots", "dots", "langle", "rangle", "lfloor", "rfloor", "lceil", "rceil", "neg", "wedge", "vee",
            "circ", "star", "ast", "prime", "degree", "quad", "qquad", ",", ";", "!", "{", "}", "%", "$", "&", "_", "#",
        ]
        let functions = [
            "sin", "cos", "tan", "log", "ln", "exp", "lim", "max", "min", "sup", "inf", "det", "arg", "deg", "gcd",
            "Pr", "mod",
        ]
        let constructs = [
            "\\frac{a}{b}", "\\frac12", "\\sqrt{x}", "\\sqrt x", "\\mathbb{NZQRCP}", "\\mathrm{d}x", "\\text{if } x",
            "\\operatorname{rank} A", "\\left( \\frac{a}{b} \\right)", "\\big( x \\big)", "\\Big[ x \\Big]",
            "\\bigl( x \\bigr)", "\\displaystyle \\sum_i x_i", "x^2", "x_i", "x^{n+1}_{k}", "e^{i\\pi} + 1 = 0",
            "x^2 + \\alpha", "E[X] = \\sum_i x_i \\cdot p(x_i)", "a - b = c < d > e",
        ]
        var failures: [String] = []
        for tex in symbols.map({ "x \\\($0) y" }) + functions.map({ "\\\($0) x" }) + constructs {
            for display in [false, true] {
                if case .error(let m) = Self.engine.typeset(tex, display: display) {
                    failures.append("\(tex): \(m)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    /// A6: 1,000 malformed inputs never crash and each comes back as an error.
    @Test func malformedInputsAreErrors() {
        var rng = SplitMix(seed: 48)
        let pieces = [
            "\\frac{", "}", "{", "\\left(", "\\right]", "\\begin{matrix}", "\\end{pmatrix}", "&", "\\\\", "^", "_",
            "^^", "__", "\\sqrt[", "\\ce{", "->[", "\\pu{", "\\color{", "\\nosuch", "\\begin{", "\\end{", "#1",
            "\\newcommand{", "\\text{", "$", "\\over", "\\choose", "\\middle|", "\\hline", "\\cancel",
            "x", "2", "+", " ", "\\alpha", "\\mathbb", "\\operatorname{", "\\href{", "\\unicode{", "\\\\[",
        ]
        // Each ends with something that can't be closed, after up to 12 random pieces. No
        // \def: it can swallow the ending whole (`\def\begin{matrix}` is valid TeX).
        let ends = ["\\frac{", "\\left(", "\\begin{matrix}", "\\sqrt[", "\\ce{", "{", "\\nosuch"]
        var messages = Set<String>()
        for i in 0..<1000 {
            var s = ""
            for _ in 0..<Int(rng.next() % 13) { s += pieces[Int(rng.next() % UInt64(pieces.count))] }
            s += ends[i % ends.count]
            let r = Self.engine.typeset(s, display: i % 2 == 0)
            guard case .error(let m) = r else {
                Issue.record("Typeset without an error: \(s)")
                continue
            }
            #expect(!m.isEmpty)
            messages.insert(m)
        }
        #expect(messages.count > 10, "\(messages)")
    }

    /// A4: with the engine warm, a formula it hasn't seen typesets and draws in under 5 ms
    /// (median over the 40 representative formulas); a cached one in a fraction of that.
    /// The engine is the test's own, so other suites' formulas don't queue ahead of it.
    @Test func warmRenderIsFast() throws {
        let engine = MathEngine()
        let ctx = CGContext(
            data: nil, width: 600, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let black = CGColor(gray: 0, alpha: 1)
        let list = try Self.goldens()
        for (_, tex) in list { _ = engine.typeset(tex, display: true) }
        engine.clearCache()
        var fresh: [Double] = []
        var cached: [Double] = []
        for (name, tex) in list {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let g = try #require(engine.typeset(tex, display: true).glyphs, "\(name)")
            g.draw(in: ctx, at: CGPoint(x: 4, y: 80), fontSize: 18, color: black, flipped: false)
            let t1 = DispatchTime.now().uptimeNanoseconds
            let again = try #require(engine.typeset(tex, display: true).glyphs)
            again.draw(in: ctx, at: CGPoint(x: 4, y: 80), fontSize: 18, color: black, flipped: false)
            let t2 = DispatchTime.now().uptimeNanoseconds
            fresh.append(Double(t1 - t0) / 1e6)
            cached.append(Double(t2 - t1) / 1e6)
        }
        let median = { (a: [Double]) in a.sorted()[a.count / 2] }
        print(
            "Math render, median: new formula \(median(fresh)) ms (slowest \(fresh.max()!) ms), cached \(median(cached)) ms"
        )
        #expect(median(fresh) < 5)
        #expect(median(cached) < 1)
    }
}

/// A seeded generator, so the malformed inputs are the same on every run.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
