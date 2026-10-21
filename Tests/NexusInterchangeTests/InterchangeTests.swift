import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

@Suite struct ImporterGoldenTests {
    static let fixtures = [
        "zen.xmind", "xmind8.xmind", "freemind.mm", "mindmanager.mmap", "garden.mindnode", "notes.textpack",
        "handbook.docx", "flow.drawio", "compressed.drawio", "outline.opml", "notes.md", "indented.txt", "spaces.txt",
        "mindmap.mmd", "flow.mmd", "sequence.mmd", "classes.mmd", "plan.puml", "seq.puml",
    ]

    @Test(arguments: fixtures) func importer(_ name: String) throws {
        let imported = try Interchange.importFile(name: name, data: try fixture(name))
        #expect(!imported.canvases.isEmpty)
        for c in imported.canvases { #expect(c.validate().isEmpty, "\(name): \(c.validate())") }
        #expect(imported.report.topics == imported.canvases.reduce(0) { $0 + $1.nodes.count })
        golden("import/\(name).txt", dump(imported))
    }

    @Test func xmindZenDetails() throws {
        let im = try Interchange.importFile(name: "zen.xmind", data: try fixture("zen.xmind"))
        let r = im.report
        #expect(r.sheets == 3 && r.canvases == 3, "two sheets plus one distinct nested copy")
        let c = im.canvases[0]
        func id(_ t: String) -> NodeID { c.nodes.first { $0.value.text == t }!.key }
        #expect(c.nodes[c.root]!.note?.text == "North star: retention.")
        #expect(c.layout.structure == .mindmapRight)
        #expect(c.nodes[id("Kickoff")]!.markers == ["priority-1"] && c.nodes[id("Kickoff")]!.labels == ["Q1"])
        #expect(c.nodes[id("Owners")]!.markers == ["progress-100"], "Xmind task pies are progress markers")
        #expect(c.nodes[id("Risks")]!.markers == ["flag-red", "progress-50"])
        #expect(c.nodes[id("Roadmap")]!.folded && c.nodes[id("Roadmap")]!.link == "https://example.com/roadmap")
        #expect(
            c.nodes[id("Churn")]!.link == TopicLink.make(canvas: c.id, node: id("Next")),
            "xmind:# links resolve to topics")
        #expect(c.nodes[id("Risks")]!.image != nil && im.assets.count == 1)
        #expect(c.boundaries.map(\.title) == ["Prep"] && c.boundaries[0].nodes == [id("Agenda"), id("Owners")])
        #expect(c.summaries.count == 1 && c.nodes[c.summaries[0].topic]!.text == "Sequenced")
        #expect(c.callouts.count == 1 && c.nodes[c.callouts[0].topic]!.text == "Watch closely")
        #expect(c.floating.count == 1 && c.nodes[c.floating[0]]!.position == CanvasPoint(x: 300, y: -200))
        #expect(c.relationships.count == 1 && c.relationships[0].label == "drives")
        #expect(im.canvases[1].nodes.values.contains { $0.text == "Engineering" }, "attributed titles join")
        #expect(im.canvases[1].type == .org)
        let skipped = r.skipped.map(\.0)
        #expect(skipped.contains("Gantt task dates (not in v1)"))
        #expect(skipped.contains("Audio note on “Kickoff” (kept as attachment)"))
        #expect(skipped.contains("Marker “smiley-laugh” (no equivalent)"))
        #expect(skipped.contains("Relationship to a missing topic"))
    }

    @Test func xmind8Details() throws {
        let im = try Interchange.importFile(name: "xmind8.xmind", data: try fixture("xmind8.xmind"))
        #expect(im.canvases.count == 2)
        let c = im.canvases[0]
        func id(_ t: String) -> NodeID { c.nodes.first { $0.value.text == t }!.key }
        #expect(c.type == .logic)
        #expect(c.nodes[id("Research")]!.markers == ["priority-2", "star-gold"])
        #expect(c.nodes[id("Research")]!.note?.text == "Talk to 5 users" && c.nodes[id("Research")]!.labels == ["ux"])
        #expect(c.nodes[id("Build")]!.image != nil && c.nodes[id("Build")]!.folded)
        #expect(c.summaries.count == 1 && c.boundaries.count == 1 && c.floating.count == 1)
        #expect(c.relationships.first?.label == "informs")
    }

    @Test func brokenFilesFailCleanly() throws {
        #expect(throws: ImportError.empty("empty.xmind")) {
            try Interchange.importFile(name: "empty.xmind", data: try fixture("empty.xmind"))
        }
        #expect(throws: ImportError.encrypted("encrypted.xmind")) {
            try Interchange.importFile(name: "encrypted.xmind", data: try fixture("encrypted.xmind"))
        }
        #expect(throws: ImportError.self) {
            try Interchange.importFile(name: "truncated.xmind", data: try fixture("truncated.xmind"))
        }
        #expect(throws: ImportError.unrecognised("photo.heic")) {
            try Interchange.importFile(name: "photo.heic", data: Data([1]))
        }
    }

    /// Every prefix and some bit-flips of every binary fixture: errors, never crashes.
    @Test func fuzzedArchivesNeverCrash() throws {
        for name in ["zen.xmind", "xmind8.xmind", "mindmanager.mmap", "handbook.docx", "garden.mindnode"] {
            let data = try fixture(name)
            var rng = SystemRandomNumberGenerator()
            for cut in stride(from: 0, to: data.count, by: max(1, data.count / 60)) {
                _ = try? Interchange.importFile(name: name, data: data.prefix(cut))
            }
            for _ in 0..<60 {
                var d = data
                for _ in 0..<4 {
                    let i = Int.random(in: 0..<d.count, using: &rng)
                    d[i] ^= UInt8.random(in: 1...255, using: &rng)
                }
                _ = try? Interchange.importFile(name: name, data: d)
            }
        }
    }

    /// The real-world corpus (artboard 33's migration path). Set NEXUS_XMIND_CORPUS to a file
    /// listing .xmind paths, one per line. Reports counts only, never content.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_XMIND_CORPUS"] != nil)) func realCorpus() throws {
        let list = try String(
            contentsOfFile: ProcessInfo.processInfo.environment["NEXUS_XMIND_CORPUS"]!, encoding: .utf8)
        var imported = 0
        var placeholders = 0
        var failed: [String] = []
        var topics = 0
        var skipped = 0
        for path in list.split(separator: "\n").map(String.init) where !path.isEmpty {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            // Cloud placeholders (not downloaded) are zero bytes; reading them would download.
            if (attrs?[.size] as? Int ?? 0) == 0 {
                placeholders += 1
                continue
            }
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            do {
                let im = try Interchange.importFile(name: (path as NSString).lastPathComponent, data: data)
                for c in im.canvases { #expect(c.validate().isEmpty) }
                imported += 1
                topics += im.report.topics
                skipped += im.report.notConverted
            } catch {
                failed.append("\(error)")
            }
        }
        print(
            "xmind corpus: \(imported) imported, \(topics) topics, \(skipped) items not converted, \(placeholders) cloud placeholders skipped, \(failed.count) failed"
        )
        #expect(failed.isEmpty, "\(failed)")
        #expect(imported > 0)
    }
}

@Suite struct ExporterGoldenTests {
    static let samples: [(String, Canvas)] = [
        ("launch", launchPlan()), ("flow", flowchart()), ("sequence", sequence()), ("threats", threatModel()),
    ]

    @Test func textExporters() {
        for (name, c) in Self.samples {
            golden("export/\(name).md", MarkdownFormat.export(c))
            var bullets = MarkdownFormat.Options()
            bullets.headings = false
            bullets.mermaidBlock = true
            golden("export/\(name).bullets.md", MarkdownFormat.export(c, options: bullets))
            golden("export/\(name).opml", OPMLFormat.export(c))
            golden("export/\(name).mmd", MermaidFormat.export(c))
            golden("export/\(name).puml", PlantUMLFormat.export(c))
            golden("export/\(name).drawio", DrawIOFormat.export(c))
            golden("export/\(name).csv", CSVFormat.export(c))
            golden("export/\(name).txt", IndentedText.export(c))
        }
        let c = launchPlan()
        golden("export/launch.mindmap.mmd", MermaidFormat.export(c, flavour: .mindmap))
        golden("export/launch.class.mmd", MermaidFormat.export(c, flavour: .class))
        let doc = DocumentModel(canvases: Self.samples.map(\.1))
        golden("export/document.json", DocumentJSON.export(doc))
        golden("export/document.compact.json", DocumentJSON.export(doc, pretty: false))
        golden("export/document.yaml", DocumentJSON.yaml(doc))
    }

    @Test func wordExport() throws {
        let doc = DocumentModel(canvases: [launchPlan()])
        let data = WordFormat.export(doc)
        let files = try Zip.read(data)
        #expect(
            Set(files.keys) == [
                "[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "word/_rels/document.xml.rels",
                "word/styles.xml",
                "word/document.xml",
            ])
        let xml = String(decoding: files["word/document.xml"]!, as: UTF8.self)
        #expect(try XMLDocument(data: files["word/document.xml"]!).rootElement() != nil)
        golden("export/launch.docx.document.xml", xml)
        // With a diagram image.
        let img = WordFormat.export(doc, images: ["c1": (Data([0x89, 0x50]), 800, 400)])
        #expect(try Zip.read(img)["word/media/image1.png"] == Data([0x89, 0x50]))
        // Word import reads our own export back.
        var r = ImportReport(source: "x", format: "Word")
        let back = try WordFormat.parse(data, name: "Launch plan", report: &r)
        #expect(back.root.text == "Launch plan" && back.root.children.map(\.text).count == 5)
    }

    /// A worksheet's cells as rows of text, by cell reference (inline strings and numbers).
    func cells(_ xml: Data) throws -> [[String]] {
        let root = try #require(try XMLDocument(data: xml).rootElement())
        var rows: [[String]] = []
        for row in try root.nodes(forXPath: "./*[local-name()='sheetData']/*[local-name()='row']") {
            var out: [String] = []
            for c in try row.nodes(forXPath: "./*[local-name()='c']") {
                guard let c = c as? XMLElement, let ref = c.attribute(forName: "r")?.stringValue else { continue }
                let col = ref.prefix { $0.isLetter }.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
                while out.count < col { out.append("") }
                out.append(c.stringValue ?? "")
            }
            rows.append(out)
        }
        return rows
    }

    @Test func excelExport() throws {
        let doc = DocumentModel(canvases: [launchPlan(), threatModel()])
        let data = ExcelFormat.export(doc)
        let files = try Zip.read(data)
        #expect(
            Set(files.keys) == [
                "[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "xl/workbook.xml",
                "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml",
            ])
        for (name, part) in files { #expect(try XMLDocument(data: part).rootElement() != nil, "\(name) parses") }
        let types = String(decoding: files["[Content_Types].xml"]!, as: UTF8.self)
        #expect(types.contains("/xl/worksheets/sheet2.xml") && types.contains("spreadsheetml.sheet.main+xml"))
        let workbook = String(decoding: files["xl/workbook.xml"]!, as: UTF8.self)
        #expect(workbook.contains("name=\"Launch plan\"") && workbook.contains("name=\"Payments\""))
        let rels = String(decoding: files["xl/_rels/workbook.xml.rels"]!, as: UTF8.self)
        #expect(rels.contains("Target=\"worksheets/sheet1.xml\"") && rels.contains("Target=\"styles.xml\""))

        // Mind map: one row per topic in outline order, header first.
        let plan = try cells(files["xl/worksheets/sheet1.xml"]!)
        #expect(plan[0] == ExcelFormat.columns)
        #expect(plan.count == 1 + launchPlan().nodes.count)
        #expect(
            plan.dropFirst().map { $0[2] }.prefix(5) == [
                "Launch plan", "Positioning", "Developers", "Teams", "Pricing",
            ])
        let pricing = try #require(plan.first { $0.count > 2 && $0[2] == "Pricing" })
        #expect(pricing[0] == "1" && pricing[1] == "Launch plan" && pricing[3] == "Keep the free tier generous.")
        #expect(pricing[4] == "Q4")
        let pro = try #require(plan.first { $0.count > 2 && $0[2] == "Pro" })
        #expect(pro[0] == "2" && pro[1] == "Launch plan › Pricing" && pro[5] == "priority-1" && pro[6] == "open")
        // The level column holds numbers.
        let sheet1 = String(decoding: files["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(sheet1.contains("<c r=\"A3\"><v>1</v></c>") && sheet1.contains("state=\"frozen\""))

        // Technical canvas: type, STRIDE, risk and status.
        let threats = try cells(files["xl/worksheets/sheet2.xml"]!)
        #expect(threats[0] == ExcelFormat.columns + ExcelFormat.technicalColumns)
        let key = try #require(threats.first { $0.count > 2 && $0[2] == "Stolen API key" })
        #expect(Array(key[7...]) == ["Threat", "Spoofing", "High", "Open"])
        let api = try #require(threats.first { $0.count > 2 && $0[2] == "Payments API" })
        #expect(api[7] == "Process")
    }

    @Test func excelSheetNamesAndUnsafeText() throws {
        var a = launchPlan()
        a.title = "Q3: plan/[draft]?"
        a.id = "a"
        var b = launchPlan()
        b.title = "q3 plan" + String(repeating: "x", count: 40)
        b.id = "b"
        var c = launchPlan()
        c.title = "Q3 plandraft"
        c.id = "c"
        let root = c.root
        c.nodes[root]!.text = "Bell \u{07} and <tags> & \"quotes\""
        let files = try Zip.read(ExcelFormat.export(DocumentModel(canvases: [a, b, c])))
        let workbook = try XMLDocument(data: files["xl/workbook.xml"]!)
        let names = try workbook.nodes(forXPath: "//*[local-name()='sheet']").compactMap {
            ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue
        }
        #expect(names == ["Q3 plandraft", "q3 plan" + String(repeating: "x", count: 24), "Q3 plandraft (2)"])
        #expect(names.allSatisfy { $0.count <= 31 })
        let rows = try cells(files["xl/worksheets/sheet3.xml"]!)
        #expect(rows[1][2] == "Bell  and <tags> & \"quotes\"")
    }

    @Test func noWatermarkAnywhere() {
        for (_, c) in Self.samples {
            let doc = DocumentModel(canvases: [c])
            let outputs = [
                MarkdownFormat.export(c), OPMLFormat.export(c), MermaidFormat.export(c), PlantUMLFormat.export(c),
                CSVFormat.export(c), DocumentJSON.yaml(doc), String(decoding: WordFormat.export(doc), as: UTF8.self),
            ]
            for o in outputs {
                for mark in ["watermark", "Made with", "made with", "Created with", "Generated by", "trial"] {
                    #expect(!o.contains(mark))
                }
            }
        }
    }
}

@Suite struct RoundTripTests {
    func shape(_ c: Canvas) -> [String] {
        var out: [String] = []
        c.walk { _, n, d in out.append(String(repeating: ".", count: d) + n.text) }
        return out
    }

    func reimport(_ text: String, _ name: String) throws -> Canvas {
        try Interchange.importFile(name: name, data: Data(text.utf8)).canvases[0]
    }

    @Test func markdownOPMLMermaidIndented() throws {
        let c = launchPlan()
        #expect(shape(try reimport(MarkdownFormat.export(c), "a.md")) == shape(c))
        var bullets = MarkdownFormat.Options()
        bullets.headings = false
        #expect(shape(try reimport(MarkdownFormat.export(c, options: bullets), "a.md")) == shape(c))
        #expect(shape(try reimport(OPMLFormat.export(c), "a.opml")) == shape(c))
        #expect(shape(try reimport(MermaidFormat.mindmap(c), "a.mmd")) == shape(c))
        #expect(shape(try reimport(IndentedText.export(c), "a.txt")) == shape(c))
        #expect(shape(try reimport(PlantUMLFormat.mindmap(c), "a.puml")) == shape(c))
        // Notes, labels, to-dos, priority and links survive Markdown.
        let md = try reimport(MarkdownFormat.export(c), "a.md")
        let pricing = md.nodes.values.first { $0.text == "Pricing" }!
        #expect(pricing.note?.text == "Keep the free tier generous." && pricing.labels == ["Q4"])
        let pro = md.nodes.values.first { $0.text == "Pro" }!
        #expect(pro.markers == ["priority-1"] && pro.todo == Todo(done: false))
        #expect(md.nodes.values.first { $0.text == "Risks" }!.link == "https://example.com/risks")
    }

    @Test func mermaidFlowchartRebuilds() throws {
        let c = flowchart()
        let back = try reimport(Mermaid.flowchart(c), "f.mmd")
        #expect(back.type == .flowchart)
        #expect(Set(back.nodes.values.map(\.text)) == Set(c.nodes.values.map(\.text)))
        let decision = back.nodes.values.first { $0.text == "Account exists?" }!
        #expect(decision.nodeType == .decision)
        #expect(back.nodes.values.first { $0.text == "Create reset token" }!.edgeLabel == "Yes")
        #expect(back.relationships.count == 1)
        let seq = try reimport(Mermaid.sequence(sequence()), "s.mmd")
        #expect(seq.type == .sequence && seq.relationships.map(\.label) == ["POST /cart", "201"])
        #expect(seq.relationships[1].kind == "return")
    }

    @Test func documentJSONIsLossless() throws {
        let doc = DocumentModel(canvases: [launchPlan(), flowchart()])
        let back = try DocumentJSON.parse(Data(DocumentJSON.export(doc).utf8), name: "d.json")
        #expect(back.orderedCanvases == doc.orderedCanvases)
        let compact = try DocumentJSON.parse(Data(DocumentJSON.export(doc, pretty: false).utf8), name: "d.json")
        #expect(compact.orderedCanvases == doc.orderedCanvases)
    }

    /// Settings › Files › JSON documents carry their images inline (M8).
    @Test func documentJSONEmbedsAssetsWhenAsked() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let doc = DocumentModel(canvases: [launchPlan()], assets: ["ab12.png": png])
        let lean = try DocumentJSON.parse(Data(DocumentJSON.export(doc).utf8), name: "d.json")
        #expect(lean.assets.isEmpty)
        let full = try DocumentJSON.parse(Data(DocumentJSON.export(doc, assets: true).utf8), name: "d.json")
        #expect(full.assets == doc.assets && full.orderedCanvases == doc.orderedCanvases)
    }

    @Test func pastedTextIsRecognised() {
        #expect(Interchange.parsePasted("Just one line") == nil)
        let (md, _) = Interchange.parsePasted("# Trip\n## Packing\n- Passport\n")!
        #expect(md.root.text == "Trip" && md.root.children[0].children[0].text == "Passport")
        let (ind, _) = Interchange.parsePasted("Groceries\n\tFruit\n\tBread")!
        #expect(ind.root.children.map(\.text) == ["Fruit", "Bread"])
        let (mm, _) = Interchange.parsePasted("flowchart TD\n  A[One] --> B[Two]")!
        #expect(mm.type == .flowchart && mm.root.children.first?.text == "Two")
    }
}

@Suite struct ZipTests {
    @Test func roundTripStoreAndDeflate() throws {
        let big = Data(String(repeating: "OpenNexus ", count: 2000).utf8)
        var z = ZipWriter()
        z.add("a.txt", "hello")
        z.add("dir/b.bin", big)
        z.add("empty", Data())
        let data = z.finish()
        #expect(data.count < big.count, "deflated")
        let files = try Zip.read(data)
        #expect(files == ["a.txt": Data("hello".utf8), "dir/b.bin": big, "empty": Data()])
        var s = ZipWriter(store: true)
        s.add("x", big)
        #expect(try Zip.read(s.finish())["x"] == big)
        #expect(throws: Zip.ReadError.notAZip) { try Zip.read(Data("not a zip at all, clearly".utf8)) }
    }

    /// Archives made by Python's zipfile (the fixtures) read back.
    @Test func readsForeignArchives() throws {
        let files = try Zip.read(try fixture("zen.xmind"))
        #expect(files["content.json"] != nil && files["resources/pic.png"]?.count == 70)
    }
}
