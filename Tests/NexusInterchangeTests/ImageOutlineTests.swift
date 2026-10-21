import AppKit
import Foundation
import Testing

@testable import NexusCore
@testable import NexusInterchange

/// The topic tree as indented text (two spaces a level).
func outlineText(_ t: ITopic, depth: Int = 0) -> String {
    String(repeating: "  ", count: depth) + t.text + "\n"
        + t.children.map { outlineText($0, depth: depth + 1) }.joined()
}

func box(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> TextBox {
    TextBox(text, x: x, y: y, width: w, height: h, confidence: 0.9)
}

@Suite struct ImageOutlineTests {
    static let list = RecognisedImage(
        width: 800, height: 400,
        boxes: [
            box("Project Plan", 40, 20, 300, 32),
            box("Goals", 40, 80, 70, 16),
            box("• Ship v1 by June", 64, 104, 180, 16),
            box("• Win 100 teams", 64, 128, 160, 16),
            box("Risks", 40, 160, 60, 16),
            box("• Hiring", 64, 184, 90, 16),
            box("◦ Senior iOS", 88, 208, 120, 16),
            box("• Budget", 64, 232, 90, 16),
            box("|", 300, 300, 4, 30),
        ])

    @Test func indentedList() {
        let o = ImageOutline.build(Self.list, title: "plan")
        #expect(o.layout == .list)
        #expect(!o.canvas.synthesizedRoot)
        #expect(
            outlineText(o.canvas.root) == """
                Project Plan
                  Goals
                    Ship v1 by June
                    Win 100 teams
                  Risks
                    Hiring
                      Senior iOS
                    Budget

                """)
        #expect(o.dropped == 1, "a connector mark is not a topic")
        #expect(o.units.map(\.depth) == [0, 1, 2, 2, 1, 2, 3, 2])
    }

    @Test func numberedAndCheckboxes() {
        let image = RecognisedImage(
            width: 600, height: 300,
            boxes: [
                box("1. Plan", 20, 20, 80, 16),
                box("1.1 Scope", 20, 44, 90, 16),
                box("1.2 Budget", 20, 68, 90, 16),
                box("2. Build", 20, 92, 80, 16),
                box("☐ Write tests", 20, 116, 120, 16),
                box("☑ Set up CI", 20, 140, 120, 16),
            ])
        let o = ImageOutline.build(image, title: "Checklist")
        #expect(o.canvas.synthesizedRoot)
        #expect(
            outlineText(o.canvas.root) == """
                Checklist
                  Plan
                    Scope
                    Budget
                  Build
                    Write tests
                    Set up CI

                """)
        let build = o.canvas.root.children[1]
        #expect(build.children.map(\.todo) == [false, true])
    }

    @Test func wrappedBulletJoinsItsItem() {
        let image = RecognisedImage(
            width: 600, height: 300,
            boxes: [
                box("Notes", 20, 20, 120, 28),
                box("• A long point that wraps onto", 20, 64, 320, 16),
                box("the next line", 40, 82, 120, 16),
                box("• Short point", 20, 110, 140, 16),
            ])
        let o = ImageOutline.build(image, title: "x")
        #expect(
            outlineText(o.canvas.root) == """
                Notes
                  A long point that wraps onto the next line
                  Short point

                """)
    }

    @Test func centredMindMap() {
        let image = RecognisedImage(
            width: 1000, height: 600,
            boxes: [
                box("Launch Plan", 400, 290, 120, 24),
                box("Marketing", 600, 180, 90, 16),
                box("Engineering", 600, 400, 100, 16),
                box("Ads", 760, 150, 40, 16),
                box("Press", 760, 210, 50, 16),
                box("Backend", 780, 380, 70, 16),
                box("QA", 780, 420, 30, 16),
                box("Budget", 260, 200, 70, 16),
                box("Team", 270, 390, 50, 16),
                box("Q3 spend", 120, 200, 80, 16),
            ])
        let o = ImageOutline.build(image, title: "map")
        #expect(o.layout == .map)
        #expect(o.canvas.structure == nil, "branches on both sides stay a balanced map")
        #expect(
            outlineText(o.canvas.root) == """
                Launch Plan
                  Marketing
                    Ads
                    Press
                  Engineering
                    Backend
                    QA
                  Team
                  Budget
                    Q3 spend

                """)
    }

    @Test func rightMapWithWrappedTopic() {
        let image = RecognisedImage(
            width: 900, height: 500,
            boxes: [
                box("Research", 40, 240, 110, 26),
                box("Interview", 260, 100, 90, 16),
                box("customers", 262, 119, 88, 16),
                box("Survey", 260, 240, 70, 16),
                box("Read papers", 260, 380, 110, 16),
                box("Ten calls", 440, 80, 80, 16),
                box("Notes", 440, 130, 50, 16),
            ])
        let o = ImageOutline.build(image, title: "map")
        #expect(o.layout == .map)
        #expect(o.canvas.structure == .mindmapRight)
        #expect(
            outlineText(o.canvas.root) == """
                Research
                  Interview customers
                    Ten calls
                    Notes
                  Survey
                  Read papers

                """)
    }

    @Test func twoColumnPoster() {
        let image = RecognisedImage(
            width: 800, height: 320,
            boxes: [
                box("Climate Action", 200, 40, 400, 40),
                box("Causes", 60, 120, 100, 20),
                box("• Fossil fuels", 60, 150, 200, 14),
                box("• Deforestation", 60, 172, 220, 14),
                box("• Agriculture", 60, 194, 180, 14),
                box("Solutions", 440, 120, 130, 20),
                box("• Renewables", 440, 150, 200, 14),
                box("• Reforestation", 440, 172, 210, 14),
                box("• Diet change", 440, 194, 170, 14),
                box("Learn more at the city library and online, with resources for everyone", 60, 260, 680, 14),
            ])
        let o = ImageOutline.build(image, title: "poster")
        #expect(o.layout == .columns)
        #expect(
            outlineText(o.canvas.root) == """
                Climate Action
                  Causes
                    Fossil fuels
                    Deforestation
                    Agriculture
                  Solutions
                    Renewables
                    Reforestation
                    Diet change
                  Learn more at the city library and online, with resources for everyone

                """)
    }

    @Test func flatTextIsGroupedUnderPickedHeadings() {
        let flat = RecognisedImage(
            width: 400, height: 300,
            boxes: ["Groceries", "Milk", "Eggs", "Hardware", "Nails", "Glue"].enumerated().map {
                box($1, 20, 20 + Double($0) * 24, 100, 16)
            })
        let o = ImageOutline.build(flat, title: "Shopping")
        #expect(o.isFlat && o.canvas.root.children.count == 6)
        let g = o.grouped(headings: [0, 3])
        #expect(
            g.map { outlineText($0.root) } == """
                Shopping
                  Groceries
                    Milk
                    Eggs
                  Hardware
                    Nails
                    Glue

                """)
        // Rejected: nothing picked, an index out of range only, most lines picked.
        #expect(o.grouped(headings: []) == nil)
        #expect(o.grouped(headings: [9]) == nil)
        #expect(o.grouped(headings: [0, 1, 2, 3]) == nil)
        // An outline the layout already structured is never regrouped.
        #expect(!ImageOutline.build(Self.list, title: "plan").isFlat)
        #expect(ImageOutline.build(Self.list, title: "plan").grouped(headings: [0]) == nil)
    }

    @Test func importReport() {
        let o = ImageOutline.build(Self.list, title: "plan")
        let im = o.imported(source: "plan.png")
        #expect(im.canvases.count == 1 && im.canvases[0].validate().isEmpty)
        #expect(im.report.format == "Image" && im.report.topics == 8)
        #expect(im.report.lines.contains("Unreadable marks or symbols"))
    }
}

/// Real Vision on a picture drawn here: an indented list with a large title.
@Suite struct ImageVisionTests {
    static func render(_ lines: [(String, CGFloat, CGFloat)], size: CGSize) -> Data {
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            var y: CGFloat = 30
            for (text, indent, points) in lines {
                let font = points > 30 ? NSFont.boldSystemFont(ofSize: points) : NSFont.systemFont(ofSize: points)
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
                s.draw(at: CGPoint(x: 40 + indent, y: y))
                y += points * 1.6
            }
            return true
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func recognisesARenderedList() throws {
        let png = Self.render(
            [
                ("Weekend Trip", 0, 44), ("Packing", 0, 26), ("Tent", 48, 26), ("Stove", 48, 26), ("Food", 0, 26),
                ("Pasta", 48, 26),
            ], size: CGSize(width: 700, height: 360))
        let im = try Interchange.importFile(name: "trip.png", data: png)
        #expect(im.report.format == "Image")
        let c = im.canvases[0]
        #expect(c.validate().isEmpty)
        func id(_ t: String) -> NodeID? {
            c.nodes.first { $0.value.text.localizedCaseInsensitiveContains(t) }?.key
        }
        #expect(c.nodes[c.root]?.text == "Weekend Trip")
        let packing = try #require(id("Packing"))
        let food = try #require(id("Food"))
        #expect(c.nodes[c.root]?.children == [packing, food])
        #expect(c.nodes[packing]?.children.compactMap { c.nodes[$0]?.text } == ["Tent", "Stove"])
        #expect(c.nodes[food]?.children.compactMap { c.nodes[$0]?.text } == ["Pasta"])
    }

    @Test func readsAPDFsFirstPage() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 500, height: 300)
        let pdf = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        for page in [["Garden", "Vegetables", "Herbs"], ["Second page"]] {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            for (i, text) in page.enumerated() {
                let font = NSFont.systemFont(ofSize: i == 0 ? 40 : 22, weight: i == 0 ? .bold : .regular)
                NSAttributedString(string: text, attributes: [.font: font]).draw(
                    at: CGPoint(x: i == 0 ? 30 : 70, y: 230 - Double(i) * 60))
            }
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let im = try Interchange.importFile(name: "garden.pdf", data: data as Data)
        let c = im.canvases[0]
        #expect(c.nodes[c.root]?.text == "Garden")
        #expect(c.nodes[c.root]?.children.compactMap { c.nodes[$0]?.text } == ["Vegetables", "Herbs"])
        #expect(im.report.lines.contains("PDF pages after the first"))
    }
}
