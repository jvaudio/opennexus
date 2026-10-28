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

/// M19: every PDF page, fishbones, command lists and other scripts, on synthetic boxes.
@Suite struct ImagePagesTests {
    static func page(_ n: Int, of pages: Int, _ boxes: [TextBox]) -> RecognisedImage {
        RecognisedImage(width: 600, height: 800, boxes: boxes, page: n, pages: pages)
    }

    @Test func slidesBecomeACanvasEach() {
        let pages = [
            Self.page(
                1, of: 3,
                [
                    box("Kickoff", 40, 60, 200, 40), box("• Goals", 60, 140, 90, 16), box("• Team", 60, 164, 80, 16),
                    box("1", 296, 770, 8, 14),
                ]),
            Self.page(2, of: 3, [box("2", 296, 770, 8, 14)]),
            Self.page(
                3, of: 3,
                [
                    box("Timeline", 40, 60, 220, 40), box("• Beta", 60, 140, 80, 16), box("• Launch", 60, 164, 96, 16),
                    box("Page 3 of 3", 260, 770, 80, 14),
                ]),
        ]
        let r = ImageOutline.build(pages: pages, title: "deck")
        #expect(!r.continuous && r.outlines.map(\.canvas.title) == ["Kickoff", "Timeline"])
        #expect(outlineText(r.outlines[1].canvas.root) == "Timeline\n  Beta\n  Launch\n")
        #expect(r.blank == 1 && r.furniture == 3)
        let im = r.imported(source: "deck.pdf")
        #expect(im.canvases.count == 2 && im.report.sheets == 3)
        #expect(
            im.report.lines.contains("Pages with no text")
                && im.report.lines.contains("Page numbers, headers and footers ×3"))
    }

    @Test func aContinuingDocumentIsOneList() {
        let pages = [
            Self.page(
                1, of: 2,
                [
                    box("Field Guide", 40, 10, 200, 14), box("Birds", 40, 60, 220, 40), box("Waders", 40, 120, 100, 20),
                    box("• Heron", 60, 150, 80, 16), box("• Stork", 60, 174, 80, 16),
                ]),
            Self.page(
                2, of: 2,
                [
                    box("Field Guide", 40, 10, 200, 14), box("• Crane", 60, 60, 80, 16),
                    box("Songbirds", 40, 100, 120, 20),
                    box("• Robin", 60, 130, 80, 16),
                ]),
        ]
        let r = ImageOutline.build(pages: pages, title: "guide")
        #expect(r.continuous && r.outlines.count == 1 && r.furniture == 2)
        #expect(
            outlineText(r.outlines[0].canvas.root) == """
                Birds
                  Waders
                    Heron
                    Stork
                    Crane
                  Songbirds
                    Robin

                """)
    }

    /// Boxes as Vision reads OpenNexus's own fishbone export (half size): bones lean right
    /// toward a head on the right.
    static let fishbone = RecognisedImage(
        width: 924, height: 402,
        boxes: [
            box("Risks", 181, 91, 39, 13), box("Competitor response", 60, 131, 134, 14),
            box("Channels", 357, 61, 66, 15), box("Product Hunt", 292, 95, 88, 19), box("Newsletter", 330, 131, 71, 16),
            box("GA • Jan", 345, 197, 56, 16), box("Beta • Nov", 315, 230, 68, 16), box("Timeline", 360, 294, 62, 19),
            box("Positioning", 585, 60, 79, 16), box("Developers", 546, 98, 74, 16), box("Teams", 592, 132, 43, 14),
            box("Launch plan", 738, 177, 117, 21), box("Annual discount", 533, 195, 105, 16),
            box("Pro", 593, 229, 24, 14),
            box("Free tier", 549, 261, 56, 15), box("Pricing", 585, 325, 52, 19),
        ])

    @Test func fishboneBecomesAnIshikawaDiagram() {
        let o = ImageOutline.build(Self.fishbone, title: "x")
        #expect(o.layout == .fishbone && o.canvas.type == .fishbone && o.canvas.structure == .fishboneLeft)
        let expected = """
            Launch plan
              Positioning
                Developers
                Teams
              Pricing
                Free tier
                Pro
                Annual discount
              Channels
                Product Hunt
                Newsletter
              Timeline
                Beta · Nov
                GA · Jan
              Risks
                Competitor response

            """
        #expect(outlineText(o.canvas.root) == expected)
        // Mirrored, the head is on the left and the bones lean left.
        var mirrored = Self.fishbone
        for i in mirrored.boxes.indices { mirrored.boxes[i].x = 924 - mirrored.boxes[i].maxX }
        let m = ImageOutline.build(mirrored, title: "x")
        #expect(m.canvas.structure == .fishboneRight && outlineText(m.canvas.root) == expected)
    }

    /// A curved map whose "Flowers" branch sits further out than "Beans", a neighbour's
    /// child, and level with it: the geometry alone hangs it from "Beans"; its connector
    /// line leads to "Garden".
    static func curvedMap(ink: Bool) -> RecognisedImage {
        let boxes = [
            box("Garden", 379, 277, 103, 25), box("Vegetables", 557, 148, 106, 30), box("Tomatoes", 695, 101, 85, 20),
            box("Beans", 699, 176, 52, 18), box("Flowers", 788, 252, 70, 21), box("Fruit", 559, 403, 42, 18),
            box("Apples", 687, 441, 60, 21), box("Tools", 200, 163, 48, 18), box("Spade", 60, 122, 53, 18),
        ]
        var image = RecognisedImage(width: 900, height: 560, boxes: boxes)
        guard ink else { return image }
        var map = InkMap(imageWidth: 900, imageHeight: 560)
        func frame(_ b: TextBox) -> (Double, Double, Double, Double) {
            (b.minX - 10, b.minY - 6, b.maxX + 10, b.maxY + 6)
        }
        for b in boxes {
            let (x0, y0, x1, y1) = frame(b)
            map.line(from: (x0, y0), to: (x1, y0))
            map.line(from: (x1, y0), to: (x1, y1))
            map.line(from: (x1, y1), to: (x0, y1))
            map.line(from: (x0, y1), to: (x0, y0))
        }
        // Elbow connectors from each parent's edge to its child's.
        for (p, c) in [(0, 1), (1, 2), (1, 3), (0, 4), (0, 5), (5, 6), (0, 7), (7, 8)] {
            let (pf, cf) = (frame(boxes[p]), frame(boxes[c]))
            let right = boxes[c].midX > boxes[p].midX
            let a = (right ? pf.2 : pf.0, (pf.1 + pf.3) / 2)
            let b = (right ? cf.0 : cf.2, (cf.1 + cf.3) / 2)
            let mid = (a.0 + b.0) / 2
            map.line(from: a, to: (mid, a.1))
            map.line(from: (mid, a.1), to: (mid, b.1))
            map.line(from: (mid, b.1), to: b)
        }
        image.ink = map
        return image
    }

    @Test func connectorLinesDecideTheParent() {
        let expected = """
            Garden
              Vegetables
                Tomatoes
                Beans
              Flowers
              Fruit
                Apples
              Tools
                Spade

            """
        #expect(outlineText(ImageOutline.build(Self.curvedMap(ink: true), title: "x").canvas.root) == expected)
        // Without the picture's lines, the geometry hangs "Flowers" from "Beans".
        let geometric = ImageOutline.build(Self.curvedMap(ink: false), title: "x").canvas.root
        #expect(geometric.children[0].children[1].children.map(\.text) == ["Flowers"])
        // A picture that's mostly ink (a photo) isn't traced.
        var photo = Self.curvedMap(ink: true)
        let cells = photo.ink!.cells.count
        photo.ink?.cells = Array(repeating: true, count: cells)
        #expect(outlineText(ImageOutline.build(photo, title: "x").canvas.root) == outlineText(geometric))
    }

    /// A line with its width in ems set so its width implies `size`.
    static func line(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, size: Double) -> TextBox {
        var b = box(text, x, y, w, h)
        b.em = w / size
        return b
    }

    @Test func sizeIsNeverMoreThanTheWidthImplies() {
        var pricing = box("Pricing", 173, 509, 104, 38)
        #expect(pricing.size == 38)
        pricing.em = 104 / 29.4
        #expect(abs(pricing.size - 29.4) < 1e-9)
        let tall = Self.line("Pro", 211, 689, 48, 28, size: 31)
        #expect(tall.size == 28, "a tight box keeps its height")
        // Lines joined add up their widths and ems.
        let wrapped = Self.line("Book a room near the", 761, 118, 278, 31, size: 25.6)
            .union(Self.line("office for forty people", 766, 151, 276, 28, size: 24.6))
        #expect(abs(wrapped.size - (278 + 276) / (278 / 25.6 + 276 / 24.6)) < 1e-9)
    }

    /// A tree drawn as an indented list, with the boxes Vision drew on macOS 27.2: one main
    /// topic's ("Pricing") came back as tall as a heading, but its width says it's set like
    /// the other main topics, so the ones after it stay its siblings (D283).
    @Test func aBoxTallerThanItsWidthImpliesIsNoHeading() {
        let boxes = [
            Self.line("Launch plan", 140.8, 130.7, 231.9, 40.7, size: 37.7),
            Self.line("Positioning", 173.8, 247.6, 158.8, 33.4, size: 28.1),
            Self.line("Developers", 209.4, 341.5, 144.3, 27.6, size: 25.3),
            Self.line("Teams", 209.4, 425.4, 82.9, 25.1, size: 25.5),
            Self.line("Pricing", 172.8, 509.3, 104.3, 38.2, size: 29.4),
            Self.line("Free tier", 209.6, 604.9, 106.1, 26.3, size: 24.8),
            Self.line("Pro", 210.9, 688.7, 47.5, 28.0, size: 27.7),
            Self.line("Annual discount", 207.3, 774.7, 207.3, 26.3, size: 25.4),
            Self.line("Channels", 174.0, 860.4, 134.8, 31.0, size: 28.7),
            Self.line("Product Hunt", 209.7, 953.6, 169.6, 26.4, size: 25.1),
            Self.line("Newsletter", 209.6, 1038.0, 139.1, 26.7, size: 25.3),
            Self.line("Timeline", 174.3, 1125.5, 122.5, 28.3, size: 28.6),
            Self.line("Beta · Nov", 209.5, 1216.6, 132.2, 27.3, size: 24.3),
            Self.line("GA · Jan", 209.7, 1302.0, 106.0, 26.0, size: 23.9),
            Self.line("Risks", 174.0, 1388.2, 78.4, 30.3, size: 29.4),
            Self.line("Competitor response", 209.7, 1481.0, 266.2, 31.0, size: 24.9),
        ]
        let expected = """
            Launch plan
              Positioning
                Developers
                Teams
              Pricing
                Free tier
                Pro
                Annual discount
              Channels
                Product Hunt
                Newsletter
              Timeline
                Beta · Nov
                GA · Jan
              Risks
                Competitor response

            """
        var image = RecognisedImage(width: 596, height: 1620, boxes: boxes)
        #expect(outlineText(ImageOutline.build(image, title: "x").canvas.root) == expected)
        // By their heights alone, "Pricing" is a heading over the main topics after it.
        for i in image.boxes.indices { image.boxes[i].em = nil }
        let heights = ImageOutline.build(image, title: "x").canvas.root
        #expect(heights.children.map(\.text) == ["Positioning", "Pricing"])
    }

    /// Vision can start a box well before its text ("Trains", 17 px early): indents are
    /// read from where the text's ink starts (D285).
    @Test func indentsStartWhereTheTextsInkDoes() {
        var trains = box("Trains", 1272.9, 234.4, 96.8, 27.5)
        trains.inked = 1289...1362
        var hotel = box("Hotel for the team", 1288.0, 318.9, 230.9, 27.0)
        hotel.inked = 1290...1513
        var nights = box("Two nights", 1330.5, 402.8, 141.2, 27.7)
        nights.inked = 1333...1466
        var image = RecognisedImage(width: 1638, height: 714, boxes: [trains, hotel, nights])
        #expect(
            outlineText(ImageOutline.build(image, title: "Travel").canvas.root) == """
                Travel
                  Trains
                  Hotel for the team
                    Two nights

                """)
        // From the boxes' edges, "Hotel for the team" is indented under "Trains".
        for i in image.boxes.indices { image.boxes[i].inked = nil }
        #expect(
            outlineText(ImageOutline.build(image, title: "Travel").canvas.root) == """
                Trains
                  Hotel for the team
                    Two nights

                """)
    }

    /// A lone mark at either end of a line is a connector read as a character when its ink
    /// runs out of the line's box: a line carrying on, or a fork's curves (D284).
    @Test func connectorMarksRunOutOfTheirLine() throws {
        let line = CGRect(x: 100, y: 100, width: 260, height: 24)
        let mark = CGRect(x: 346, y: 100, width: 14, height: 24)
        var connector = InkMap(imageWidth: 600, imageHeight: 300)
        connector.line(from: (348, 112), to: (440, 112))
        #expect(connector.runsOut(of: line, from: mark))
        var dash = InkMap(imageWidth: 600, imageHeight: 300)
        dash.line(from: (348, 112), to: (357, 112))
        #expect(!dash.runsOut(of: line, from: mark), "a dash inside the box is text")
        var fork = InkMap(imageWidth: 600, imageHeight: 300)
        fork.line(from: (346, 112), to: (359, 95))
        fork.line(from: (346, 112), to: (359, 129))
        #expect(fork.runsOut(of: line, from: mark))

        let hotel: Substring = "Hotel for the team -"
        let (m, rest) = try #require(ImageText.endMark(hotel, last: true))
        #expect(hotel[m] == "-" && hotel[rest] == "Hotel for the team")
        let morning: Substring = "< Morning"
        #expect(ImageText.endMark(morning, last: false).map { morning[$0.rest] } == "Morning")
        #expect(ImageText.endMark(morning, last: true) == nil)
        #expect(ImageText.endMark("team-", last: true) == nil, "a mark set off by a space")
        #expect(ImageText.endMark("Pros and cons", last: true) == nil)
        #expect(ImageText.endMark("Why ?", last: true) == nil, "only marks a stroke can look like")
        #expect(ImageText.endMark("-", last: true) == nil)
    }

    /// Boxes as Vision reads `ImageVisionTests.fishboneWithSubCauses` (head on the right),
    /// with one sub-cause of a sub-cause ("Agency staff") set back again under "New hires".
    static let fishboneWithSubCauses = RecognisedImage(
        width: 1200, height: 700,
        boxes: [
            box("Machines", 313, 83, 96, 21), box("Wear", 322, 135, 45, 19), box("Calibration", 299, 175, 87, 20),
            box("Monthly checks", 245, 200, 102, 19), box("Storage", 341, 467, 65, 18),
            box("Supplier", 319, 506, 66, 19), box("Late orders", 270, 532, 75, 14),
            box("Wrong parts", 266, 549, 78, 17), box("Materials", 315, 591, 92, 21), box("People", 647, 86, 66, 19),
            box("Training", 620, 137, 65, 18), box("New hires", 582, 163, 62, 14),
            box("Agency staff", 524, 180, 80, 14), box("Refreshers", 577, 197, 68, 14),
            box("Staffing", 660, 230, 62, 18), box("Night shift", 615, 255, 68, 18),
            box("Checklists", 634, 481, 84, 22), box("Handoffs", 622, 522, 75, 19),
            box("Missing notes", 568, 549, 89, 18), box("Process", 641, 593, 81, 22),
            box("Late deliveries", 959, 337, 191, 24),
        ])

    @Test func fishboneSubCausesHangFromTheirCauses() {
        let expected = """
            Late deliveries
              People
                Training
                  New hires
                    Agency staff
                  Refreshers
                Staffing
                  Night shift
              Process
                Handoffs
                  Missing notes
                Checklists
              Machines
                Wear
                Calibration
                  Monthly checks
              Materials
                Supplier
                  Late orders
                  Wrong parts
                Storage

            """
        let o = ImageOutline.build(Self.fishboneWithSubCauses, title: "x")
        #expect(o.layout == .fishbone && o.canvas.structure == .fishboneLeft)
        #expect(outlineText(o.canvas.root) == expected)
        var mirrored = Self.fishboneWithSubCauses
        for i in mirrored.boxes.indices { mirrored.boxes[i].x = 1200 - mirrored.boxes[i].maxX }
        let m = ImageOutline.build(mirrored, title: "x")
        #expect(m.canvas.structure == .fishboneRight && outlineText(m.canvas.root) == expected)
        // In type as large as the causes', set back from the bone is enough.
        var same = Self.fishboneWithSubCauses
        for i in same.boxes.indices where same.boxes[i].height < 18 {
            same.boxes[i].y -= 1
            same.boxes[i].height = 18
        }
        #expect(outlineText(ImageOutline.build(same, title: "x").canvas.root) == expected)
        // Lines along the bone, each as far from it as the others, stay causes.
        #expect(
            outlineText(ImageOutline.build(Self.fishbone, title: "x").canvas.root).hasPrefix(
                "Launch plan\n  Positioning\n    Developers\n    Teams\n"))
    }

    @Test func columnsOfTextAreNotAFishbone() {
        // A right map: branches stacked in one column beside the root aren't bones.
        let image = RecognisedImage(
            width: 900, height: 500,
            boxes: [
                box("Trip", 40, 240, 80, 26), box("Packing", 200, 100, 80, 16), box("Tent", 330, 80, 40, 16),
                box("Stove", 330, 120, 50, 16), box("Food", 200, 200, 50, 16), box("Pasta", 330, 190, 50, 16),
                box("Route", 200, 300, 60, 16), box("Maps", 330, 290, 50, 16), box("Budget", 200, 400, 70, 16),
                box("Fuel", 330, 390, 40, 16),
            ])
        let o = ImageOutline.build(image, title: "x")
        #expect(o.layout == .map && o.canvas.type == .mindmap)
        #expect(outlineText(o.canvas.root).hasPrefix("Trip\n  Packing\n    Tent\n    Stove\n  Food\n    Pasta\n"))
    }

    /// Commands in a monospaced font, each starting in lowercase, keep their own lines;
    /// prose that wraps still joins.
    @Test func commandListsKeepTheirLines() {
        func mono(_ text: String, _ y: Double) -> TextBox { box(text, 40, y, Double(text.count) * 9.6, 16) }
        let image = RecognisedImage(
            width: 600, height: 400,
            boxes: [
                box("Setup", 40, 20, 100, 28),
                mono("git clone https://example.com/app", 64), mono("cd app", 84), mono("npm install", 104),
                mono("npm test", 124),
                box("Notes", 40, 170, 100, 28),
                box("Run the tests before every push, and keep", 40, 214, 400, 16),
                box("the build green", 40, 234, 150, 16),
            ])
        let o = ImageOutline.build(image, title: "x")
        #expect(
            outlineText(o.canvas.root) == """
                x
                  Setup
                    git clone https://example.com/app
                    cd app
                    npm install
                    npm test
                  Notes
                    Run the tests before every push, and keep the build green

                """)
        // Short lowercase lines in a proportional font: the next one would have fitted.
        let short = RecognisedImage(
            width: 600, height: 300,
            boxes: [
                box("Errands", 40, 20, 140, 28), box("call the bank", 40, 64, 120, 16),
                box("post the parcel", 40, 84, 140, 16), box("buy milk and bread for the week", 40, 104, 300, 16),
            ])
        #expect(ImageOutline.build(short, title: "x").canvas.root.children.count == 3)
    }

    @Test func rightToLeftTextIsMirrored() {
        // Arabic, as Vision reads it: right-aligned, bullets indented from the right.
        let image = RecognisedImage(
            width: 700, height: 360,
            boxes: [
                box("خطة المشروع", 441, 36, 217, 43), box("الأهداف", 586, 96, 78, 24),
                box("• إطلاق النسخة الأولى", 422, 134, 200, 30), box("• الفريق", 544, 174, 79, 31),
                box("المخاطر", 582, 218, 82, 24),
            ])
        let o = ImageOutline.build(image, title: "x")
        #expect(
            outlineText(o.canvas.root) == """
                خطة المشروع
                  الأهداف
                    إطلاق النسخة الأولى
                    الفريق
                  المخاطر

                """)
    }

    @Test func verticalTextReadsInColumnsRightToLeft() {
        // Japanese set vertically: a title column at the right, then a heading and its items.
        let image = RecognisedImage(
            width: 500, height: 600,
            boxes: [
                box("旅行の計画", 420, 30, 40, 200), box("持ち物", 340, 34, 26, 96), box("テント", 260, 66, 24, 90),
                box("食料", 200, 66, 24, 60), box("費用", 140, 34, 26, 64),
            ])
        let o = ImageOutline.build(image, title: "x")
        #expect(
            outlineText(o.canvas.root) == """
                旅行の計画
                  持ち物
                    テント
                    食料
                  費用

                """)
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

    /// A curved map drawn here, with connector lines: read with real Vision, "Flowers"
    /// follows its line to "Garden" (M19).
    @Test func curvedMapFollowsItsConnectors() throws {
        let size = CGSize(width: 900, height: 560)
        let topics: [(String, CGFloat, CGFloat, CGFloat, Int?)] = [
            ("Garden", 380, 270, 30, nil), ("Vegetables", 560, 150, 20, 0), ("Tomatoes", 700, 100, 18, 1),
            ("Beans", 700, 175, 18, 1), ("Flowers", 790, 250, 20, 0), ("Fruit", 560, 400, 20, 0),
            ("Apples", 690, 440, 18, 5), ("Tools", 200, 160, 20, 0), ("Spade", 60, 120, 18, 7),
        ]
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            var frames: [CGRect] = []
            for (text, x, y, points, _) in topics {
                let font = points > 24 ? NSFont.boldSystemFont(ofSize: points) : NSFont.systemFont(ofSize: points)
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
                s.draw(at: CGPoint(x: x, y: y))
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s.size()).insetBy(dx: -10, dy: -6))
            }
            NSColor.systemTeal.setStroke()
            for (i, t) in topics.enumerated() {
                let border = NSBezierPath(roundedRect: frames[i], xRadius: 8, yRadius: 8)
                border.lineWidth = 2
                border.stroke()
                guard let p = t.4 else { continue }
                let (f, pf) = (frames[i], frames[p])
                let right = f.midX > pf.midX
                let a = CGPoint(x: right ? pf.maxX : pf.minX, y: pf.midY)
                let b = CGPoint(x: right ? f.minX : f.maxX, y: f.midY)
                let path = NSBezierPath()
                path.move(to: a)
                path.curve(
                    to: b, controlPoint1: CGPoint(x: (a.x + b.x) / 2, y: a.y),
                    controlPoint2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                path.lineWidth = 2
                path.stroke()
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
        let im = try Interchange.importFile(name: "garden.png", data: rep.representation(using: .png, properties: [:])!)
        let c = im.canvases[0]
        func children(_ id: NodeID) -> [String] { c.nodes[id]?.children.compactMap { c.nodes[$0]?.text } ?? [] }
        #expect(c.nodes[c.root]?.text == "Garden")
        #expect(Set(children(c.root)) == ["Vegetables", "Flowers", "Fruit", "Tools"])
        let vegetables = try #require(c.nodes.first { $0.value.text == "Vegetables" }?.key)
        #expect(children(vegetables) == ["Tomatoes", "Beans"])
    }

    /// A fishbone drawn here, head on the right (or mirrored, on the left): bones at a
    /// slope of ½, causes in 17 pt along them with a rib each, and each cause's sub-causes
    /// in 13 pt stacked tightly under it, set back 40 px from its end nearest the bone (M29).
    static func fishboneWithSubCauses(headRight: Bool) -> Data {
        let size = CGSize(width: 1200, height: 700)
        let spine: CGFloat = 350
        typealias Bone = (label: String, up: Bool, joint: CGFloat, causes: [(String, [String])])
        let bones: [Bone] = [
            ("People", true, 800, [("Training", ["New hires", "Refreshers"]), ("Staffing", ["Night shift"])]),
            ("Process", false, 800, [("Handoffs", ["Missing notes"]), ("Checklists", [])]),
            ("Machines", true, 480, [("Wear", []), ("Calibration", ["Monthly checks"])]),
            ("Materials", false, 480, [("Supplier", ["Late orders", "Wrong parts"]), ("Storage", [])]),
        ]
        func mx(_ x: CGFloat) -> CGFloat { headRight ? x : size.width - x }
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            /// Draws `text` with its head-side end at `end` (in head-right coordinates).
            func text(_ s: String, end: CGFloat, top: CGFloat, points: CGFloat, bold: Bool = false) -> CGFloat {
                let font = bold ? NSFont.boldSystemFont(ofSize: points) : NSFont.systemFont(ofSize: points)
                let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
                let w = a.size().width
                a.draw(at: CGPoint(x: headRight ? end - w : size.width - end, y: top))
                return w
            }
            func line(_ a: CGPoint, _ b: CGPoint, _ color: NSColor) {
                color.setStroke()
                let p = NSBezierPath()
                p.move(to: CGPoint(x: mx(a.x), y: a.y))
                p.line(to: CGPoint(x: mx(b.x), y: b.y))
                p.lineWidth = 3
                p.stroke()
            }
            line(CGPoint(x: 120, y: spine), CGPoint(x: 930, y: spine), .systemOrange)
            let headWidth = NSAttributedString(
                string: "Late deliveries", attributes: [.font: NSFont.boldSystemFont(ofSize: 28)]
            ).size().width
            _ = text("Late deliveries", end: 960 + headWidth, top: spine - 17, points: 28, bold: true)
            for b in bones {
                func boneX(_ y: CGFloat) -> CGFloat { b.joint - 0.5 * abs(spine - y) }
                let end: CGFloat = b.up ? 110 : 590
                line(CGPoint(x: boneX(end), y: end), CGPoint(x: b.joint, y: spine), .systemTeal)
                let labelWidth = NSAttributedString(
                    string: b.label, attributes: [.font: NSFont.boldSystemFont(ofSize: 20)]
                ).size().width
                _ = text(b.label, end: boneX(end) + labelWidth / 2, top: b.up ? 82 : 592, points: 20, bold: true)
                // Each cause's block (its line, then its sub-causes), from the label inward.
                var tops: [CGFloat] = []
                var y: CGFloat = b.up ? 135 : 565
                for (_, subs) in b.causes {
                    let height = 24 + 18 * CGFloat(subs.count)
                    tops.append(b.up ? y : y - height)
                    y += b.up ? height + 16 : -(height + 16)
                }
                for ((cause, subs), top) in zip(b.causes, tops) {
                    let right = boneX(top + 10) - 14
                    let w = text(cause, end: right, top: top, points: 17)
                    line(CGPoint(x: right - w - 4, y: top + 23), CGPoint(x: boneX(top + 23), y: top + 23), .systemTeal)
                    for (i, s) in subs.enumerated() {
                        _ = text(s, end: right - 40, top: top + 26 + 18 * CGFloat(i), points: 13)
                    }
                }
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

    /// M29: real Vision on the drawn fishbone, head on either side: sub-causes come back
    /// as children of their causes, in order, and the causes stay on their bones.
    @Test(arguments: [true, false]) func fishboneSubCausesReadBack(headRight: Bool) throws {
        let png = Self.fishboneWithSubCauses(headRight: headRight)
        let im = try Interchange.importFile(name: "fishbone.png", data: png)
        let c = im.canvases[0]
        func outline(_ id: NodeID, _ d: Int = 0) -> String {
            String(repeating: "  ", count: d) + (c.nodes[id]?.text ?? "") + "\n"
                + (c.nodes[id]?.children ?? []).map { outline($0, d + 1) }.joined()
        }
        let expected = """
            Late deliveries
              People
                Training
                  New hires
                  Refreshers
                Staffing
                  Night shift
              Process
                Handoffs
                  Missing notes
                Checklists
              Machines
                Wear
                Calibration
                  Monthly checks
              Materials
                Supplier
                  Late orders
                  Wrong parts
                Storage

            """
        #expect(outline(c.root) == expected)
        #expect(c.type == .fishbone && c.layout.structure == (headRight ? .fishboneLeft : .fishboneRight))
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

    @Test func readsEveryPDFPage() throws {
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
        // The second page opens with a title of its own, so it's a canvas of its own.
        #expect(im.canvases.count == 2 && im.canvases[1].title == "Second page" && im.report.sheets == 2)
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var list: [String] = []
        }
        let calls = Calls()
        _ = try ImageText.recognize(data as Data, name: "garden.pdf") { done, total in
            calls.lock.withLock { calls.list.append("\(done)/\(total)") }
        }
        #expect(calls.list == ["0/2", "1/2", "2/2"], "the page count comes before the first page (M29)")
    }
}
