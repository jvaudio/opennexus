import AppKit
import CoreGraphics
import Foundation
import NexusCore
import NexusFormat
import NexusTheme
import Testing

@testable import NexusCanvas
@testable import NexusInterchange
@testable import NexusScene

/// M48's acceptance on the canvas, in exports and in interchange: A2, A3, A5, A7 and A8.
@MainActor
@Suite struct MathAcceptanceTests {
    func node(_ c: Canvas, _ prefix: String) -> NodeID { c.nodes.first { $0.value.text.hasPrefix(prefix) }!.key }
    var document: DocumentModel { MathRenderTests().mathDocument() }

    /// 0.3's document with maths, written by 0.3 (`Tests/NexusFormatTests/Fixtures`).
    static func v03Document() throws -> DocumentModel {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "NexusFormatTests/Fixtures/MathV03.nexus")
        return try NexusPackage.read(from: url)
    }

    // MARK: A2

    /// Every topic of 0.3's document renders: `/math` topics as one display formula each,
    /// inline formulas typeset, `\$` and prices as text, and the note's formulas too.
    @Test func v03DocumentRenders() throws {
        let d = try Self.v03Document()
        let controller = ImageExporter.controller(d, canvas: "c1", ImageExporter.Options())
        let c = controller.canvas
        let scene = controller.scene
        var equations = 0
        for (id, n) in c.nodes {
            let sn = try #require(scene.nodes[id])
            let title = sn.styledTitle(theme: scene.theme, canvas: scene.canvasColor)
            #expect(MathText.error(in: title) == nil, "\(n.text)")
            switch n.textFormat {
            case "math":
                equations += 1
                #expect(MathText.runs(in: title).count == 1 && title.string == "\u{FFFC}", "\(n.text)")
                #expect(sn.formulas(theme: scene.theme, canvas: scene.canvasColor).count == 1)
            case "code":
                #expect(title.string == n.text)
            default:
                if n.text.hasPrefix("Energy") {
                    #expect(title.string == "Energy \u{FFFC} costs $5")
                    let note = MathText.styled(n.note?.text ?? "", TextAttributes(font: Fonts.system(13)))
                    #expect(MathText.runs(in: note).count == 2)
                } else {
                    #expect(title.string == n.text)
                }
            }
        }
        #expect(equations == 6)
    }

    // MARK: A3

    /// SVG: each typeset formula is a group of paths; nothing is an image.
    @Test func svgExportDrawsFormulasAsPaths() throws {
        let svg = SVGExporter.export(document, canvas: "c1", ImageExporter.Options())
        let groups = Self.mathGroups(svg)
        // The quadratic, E = mc², the reaction; not the formula with an error or the prices.
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.contains("<path d=\"M") })
        #expect(!svg.contains("<image"))
        var o = SVGExporter.Options()
        o.outlineText = true
        #expect(Self.mathGroups(SVGExporter.export(document, canvas: "c1", ImageExporter.Options(), o)) == groups)
    }

    /// The HTML viewer draws the SVG export: its formulas are the export's, path for path.
    @Test func viewerDrawsTheSameFormulas() throws {
        let o = ViewerBundleTests.options()
        let bundle = ViewerBundle.build(document, o)
        var svgs: [String] = []
        func walk(_ v: JSONValue) {
            switch v {
            case .string(let s) where s.contains("<svg"): svgs.append(s)
            case .array(let a): a.forEach(walk)
            case .object(let o): o.values.forEach(walk)
            default: break
            }
        }
        walk(bundle)
        let viewer = try #require(svgs.first { $0.contains("class=\"math\"") })
        let export = SVGExporter.export(document, canvas: "c1", ViewerBundle.imageOptions(o.scope, theme: o.theme))
        #expect(Self.mathGroups(viewer).count == 3)
        #expect(Self.mathGroups(viewer) == Self.mathGroups(export))
    }

    static func mathGroups(_ svg: String) -> [String] {
        svg.components(separatedBy: "<g class=\"math\">").dropFirst().map { String($0.prefix { $0 != "\n" }) }
    }

    // MARK: A5

    @Test func topicsTypesetInlineAndDisplay() throws {
        let controller = ImageExporter.controller(document, canvas: "c1", ImageExporter.Options())
        let c = controller.canvas
        let scene = controller.scene
        func title(_ prefix: String) -> StyledText {
            scene.nodes[node(c, prefix)]!.styledTitle(theme: scene.theme, canvas: scene.canvasColor)
        }
        // Inline, with `\$` a dollar sign.
        let energy = title("Energy")
        #expect(energy.string == "Energy \u{FFFC} costs $5")
        #expect(MathText.runs(in: energy).map(\.0.display) == [false])
        // Display: a centred line of its own.
        let water = title("Water")
        #expect(water.string == "Water:\n\u{FFFC}\nforms")
        let run = try #require(MathText.runs(in: water).first)
        #expect(run.0.display && run.0.source == "\\ce{2H2 + O2 -> 2H2O}")
        let layout = MathLayout(water, width: nil)
        #expect(layout.lines.count == 3)
        // An error keeps its source, in the error colour, with MathJax's message.
        let bad = title("Bad")
        #expect(bad.string == "Bad $\\frac{a$ here")
        #expect(MathText.error(in: bad) == "Missing close brace")
        // Prices stay text.
        #expect(title("Prices").string == "Prices $5 and $10 stay")
        // A `/math` topic is one display formula, and its frame holds it.
        let q = scene.nodes[node(c, "x = ")]!
        let f = try #require(q.formulas(theme: scene.theme, canvas: scene.canvasColor).first)
        #expect(q.frame.rect.width >= f.run.width && q.frame.rect.height >= f.run.ascent + f.run.depth)
    }

    @Test func settingOffShowsTheTextAsTyped() throws {
        let h = CanvasHarness(model: document)
        let energy = node(h.canvas, "Energy")
        func title() -> StyledText {
            h.controller.scene.nodes[energy]!.styledTitle(
                theme: h.controller.scene.theme, canvas: h.controller.scene.canvasColor)
        }
        #expect(MathText.runs(in: title()).count == 1)
        let typesetWidth = h.controller.scene.nodes[energy]!.frame.rect.width
        h.controller.prefs.set("editing.typesetMath", false)
        h.host.layoutSubtreeIfNeeded()
        #expect(title().string == "Energy $E = mc^2$ costs \\$5")
        #expect(
            h.controller.scene.nodes[energy]!.formulas(theme: .classic, canvas: RGBA(r: 1, g: 1, b: 1, a: 1)).isEmpty)
        #expect(h.controller.scene.nodes[energy]!.frame.rect.width != typesetWidth)
        // `/math` topics are formulas whatever the setting: they are nothing else.
        let q = node(h.canvas, "x = ")
        #expect(
            MathText.runs(
                in: h.controller.scene.nodes[q]!.styledTitle(theme: .classic, canvas: RGBA(r: 1, g: 1, b: 1, a: 1))
            ).count == 1)
        #expect(Spoken.title(h.canvas.nodes[energy]!, prefs: h.controller.prefs) == "Energy $E = mc^2$ costs \\$5")
        h.controller.prefs.set("editing.typesetMath", true)
        #expect(MathText.runs(in: title()).count == 1)
    }

    /// Notes: the popover's preview, the presenter's notes and the PDF's appendix all set
    /// a note's formulas with `MathText.styled`.
    @Test func notesTypesetTheirFormulas() throws {
        let note = "Derivation: $$E^2 = (pc)^2 + (mc^2)^2$$ with $p = 0$, at \\$5."
        let s = MathText.styled(note, TextAttributes(font: Fonts.system(13)))
        #expect(MathText.runs(in: s).map(\.0.display) == [true, false])
        #expect(s.string == "Derivation:\n\u{FFFC}\nwith \u{FFFC}, at $5.")
        // The notes appendix of a printed PDF draws them as paths over its picture.
        var d = document
        d.canvases["c1"]!.nodes[node(d.canvases["c1"]!, "Energy")]!.note = Note(text: note)
        var o = PrintLayout.Options()
        o.notesAppendix = true
        let pdf = PrintLayout.pdf(d, canvas: "c1", o)
        let doc = try #require(CGDataProvider(data: pdf.data as CFData).flatMap(CGPDFDocument.init))
        #expect(doc.numberOfPages >= 2)
        #expect(try MathRenderTests.ops(pdf.data, page: doc.numberOfPages).fills > 0)
    }

    // MARK: A7

    @Test func voiceOverReadsTheSource() throws {
        let d = document
        let c = d.canvases["c1"]!
        let prefs = Preferences.isolated()
        func spoken(_ prefix: String) -> String { Spoken.describe(node(c, prefix), in: c, prefs: prefs, hints: false) }
        #expect(spoken("x = ").hasPrefix("Equation, x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}. "))
        #expect(spoken("Energy").hasPrefix("Energy E = mc^2 costs $5. "))
        #expect(spoken("Prices").hasPrefix("Prices $5 and $10 stay. "))
        // Once the formula has been typeset, its error is read after the title.
        _ = MathEngine.shared.typeset("\\frac{a", display: false)
        #expect(spoken("Bad").hasPrefix("Bad \\frac{a here. Formula error: Missing close brace. "))
    }

    // MARK: A8

    @Test func markdownRoundTripsFormulas() throws {
        let c = document.canvases["c1"]!
        let md = MarkdownFormat.export(c)
        #expect(md.contains("$$x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}$$"))
        #expect(md.contains("Energy $E = mc^2$ costs \\$5"))
        #expect(md.contains("Water: $$\\ce{2H2 + O2 -> 2H2O}$$ forms"))
        var report = ImportReport(source: "Math.md", format: "Markdown")
        let back = CanvasBuilder.build(
            MarkdownFormat.parse(md, title: "Math", report: &report), id: "m", report: &report)
        for (id, n) in c.nodes where id != c.root {
            let match = back.nodes.values.first { $0.text == n.text }
            #expect(match != nil, "\(n.text)")
            #expect(match?.textFormat == n.textFormat, "\(n.text)")
        }
        // Emphasis marks go, but never from inside a formula.
        var r2 = ImportReport(source: "B.md", format: "Markdown")
        let bold = MarkdownFormat.parse("# Map\n\n- **Area** $a__1 * b**2$\n", title: "B", report: &r2)
        #expect(bold.root.children.first?.text == "Area $a__1 * b**2$")
    }

    @Test func xmindRoundTripsFormulas() throws {
        let d = document
        let exported = XmindWriter.export(d, timeZone: TimeZone(identifier: "UTC")!)
        #expect(!exported.report.lines.contains { $0.contains("Math") })
        let back = try XmindFormat.parse(exported.data, name: "Math.xmind").canvases[0]
        let c = d.canvases["c1"]!
        for (id, n) in c.nodes where id != c.root {
            let match = back.nodes.values.first { $0.text == n.text }
            #expect(match?.textFormat == n.textFormat, "\(n.text)")
        }
    }

    @Test func wordIncludesFormulasAsVectorImages() throws {
        let d = document
        let files = try Zip.read(WordFormat.export(d, typeset: CanvasController.wordFormula))
        let xml = try #require(files["word/document.xml"].flatMap { String(data: $0, encoding: .utf8) })
        // The quadratic, E = mc², the reaction: SVG with a PNG fallback, TeX as alt text.
        #expect(xml.components(separatedBy: "<asvg:svgBlip").count - 1 == 3)
        #expect(xml.contains("descr=\"x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}\""))
        #expect(xml.contains("descr=\"E = mc^2\""))
        #expect(files.keys.filter { $0.hasPrefix("word/media/formula") }.count == 6)
        let svg = try #require(files["word/media/formula1.svg"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(svg.hasPrefix("<svg") && svg.contains("<path") && !svg.contains("<image"))
        let types = try #require(files["[Content_Types].xml"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(types.contains("Extension=\"svg\""))
        // The error stays as typed; with maths in text off, only `/math` topics are images.
        #expect(xml.contains(">$\\frac{a$</w:t>"))
        // A display formula has a line of its own, without the spaces beside it.
        #expect(xml.contains(">Water:</w:t></w:r><w:r><w:br/></w:r><w:r>"))
        #expect(xml.contains("</w:drawing></w:r><w:r><w:br/></w:r><w:r><w:t xml:space=\"preserve\">forms</w:t>"))
        let plain = try Zip.read(WordFormat.export(d, typeset: CanvasController.wordFormula, textMath: false))
        let plainXML = String(data: plain["word/document.xml"]!, encoding: .utf8)!
        #expect(plainXML.components(separatedBy: "<asvg:svgBlip").count - 1 == 1)
        #expect(plainXML.contains("Energy $E = mc^2$ costs \\$5"))
        // Without a typesetter, Word export is what it was before M48.
        let none = try Zip.read(WordFormat.export(d))
        #expect(none["[Content_Types].xml"].flatMap { String(data: $0, encoding: .utf8) }?.contains("svg") == false)
    }
}

/// A4's budgets with maths. Formulas typeset synchronously here (the apps typeset in the
/// background), so these are the slower case.
@MainActor
@Suite(.serialized) struct MathPerformanceTests {
    /// 209 topics, each with a formula no other test uses (nothing cached).
    static func formulaDocument(_ nonce: Int) -> DocumentModel {
        var d = bigDocument(mains: 8, subs: 5, leaves: 4)
        var c = d.canvases["c1"]!
        var undo = UndoStack()
        let ids = c.nodes.keys.filter { $0 != c.root }.sorted { $0.rawValue < $1.rawValue }
        c.edit("Math", undo: &undo) { e in
            for (k, id) in ids.enumerated() {
                e.update(id) { $0.text += " $\\frac{a_{\(k)}}{b+\(nonce)} + \\sqrt{x_{\(k)}}$" }
            }
        }
        d.canvases["c1"] = c
        return d
    }

    /// A map with 200 formulas opens less than 1 s slower than the same map without them.
    @Test func formulasOpenLessThanASecondSlower() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "open-math-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nonce = Int.random(in: 1_000...999_999)
        let plain = dir.appending(path: "Plain.nexus")
        let maths = dir.appending(path: "Maths.nexus")
        try NexusPackage.write(bigDocument(mains: 8, subs: 5, leaves: 4), to: plain)
        try NexusPackage.write(Self.formulaDocument(nonce), to: maths)
        func open(_ url: URL) -> Duration {
            ContinuousClock().measure {
                let h = CanvasHarness(model: try! NexusPackage.read(from: url))
                h.host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                #expect(h.controller.scene.nodes.count == 209)
            }
        }
        _ = open(plain)
        let without = open(plain)
        let with = open(maths)
        print("open 209 topics: \(ms(without)) ms; with 208 formulas \(ms(with)) ms")
        #expect(ms(with) - ms(without) < 1_000)
    }

    /// Key press to a new topic with a live caret, in a map where every topic has a formula.
    @Test func keyToCaretWithFormulasUnder16ms() throws {
        let h = CanvasHarness(model: Self.formulaDocument(Int.random(in: 1_000...999_999)))
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for i in 0..<30 {
            let main = h.canvas.nodes[h.canvas.root]!.children[i % 8]
            h.controller.select(main)
            samples.append(clock.measure { h.press("tab") })
            #expect(h.controller.mode == .edit && !h.host.canvasView.editor.isHidden)
            h.press("return")
        }
        let m = median(samples)
        print("key→caret with formulas: median \(ms(m)) ms, max \(ms(samples.max()!)) ms")
        #expect(ms(m) < 16)
    }

    /// Typing inside a formula: each key makes a new formula, typeset for the topic and
    /// the preview beneath it before the caret moves.
    @Test func typingInAFormulaUnder16ms() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = h.canvas.nodes.first { $0.value.text == "Pricing" }!.key
        h.controller.select(pricing)
        h.press("tab")
        h.type("$x$")
        h.press("left")
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for ch in "+abcdefghijklmnopqrstuvwxyz+abc" {
            samples.append(clock.measure { h.type(String(ch)) })
        }
        #expect(h.controller.edit?.text == "$x+abcdefghijklmnopqrstuvwxyz+abc$")
        #expect(h.controller.mathPreview()?.error == nil)
        #expect(h.controller.mathPreview().map { MathText.runs(in: $0.text).count } == 1)
        let m = median(samples)
        print("key in a formula: median \(ms(m)) ms, max \(ms(samples.max()!)) ms")
        #expect(ms(m) < 16)
    }
}
