import Foundation
import Testing

@testable import NexusCore
@testable import NexusInterchange

/// M36: fishbone sub-causes on their own small bones (D270), told from causes by their ribs
/// (D270), and wrapped onto a ruled second line (D271), on boxes laid out like the pictures.
@Suite struct ImageFishboneTests {
    typealias Cause = (text: String, subs: [(text: String, level: Int)])
    typealias Bone = (label: String, up: Bool, joint: Double, causes: [Cause])

    static let bones: [Bone] = [
        (
            "People", true, 800,
            [
                ("Training", [("New hires", 1), ("Agency staff", 2), ("Refreshers", 1)]),
                ("Staffing", [("Night shift", 1)]),
            ]
        ),
        ("Process", false, 800, [("Handoffs", [("Missing notes", 1)]), ("Checklists", [])]),
        ("Machines", true, 480, [("Wear", []), ("Calibration", [("Monthly checks", 1), ("Spare parts", 1)])]),
        ("Materials", false, 480, [("Supplier", [("Late orders", 1), ("Wrong parts", 1)]), ("Storage", [])]),
    ]

    static let expected = """
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
              Spare parts
          Materials
            Supplier
              Late orders
              Wrong parts
            Storage

        """

    /// A fishbone with its head on the right, bones at a slope of ½, causes in 18 px text
    /// on ribs to their bone, and sub-causes in 14 px text below their cause, each on its
    /// own rib to a small bone parallel to the main one, or (`ribs` false) without ribs, set
    /// back `back` px further from the bone than the causes. `ink` draws the lines. A
    /// sub-cause's text with "/" in it wraps there, onto a centred second line.
    static func picture(
        _ bones: [Bone] = bones, ribs: Bool = true, back: Double = 12, ink: Bool = false
    ) -> RecognisedImage {
        let spine = 350.0
        var boxes = [box("Late deliveries", 960, spine - 12, 190, 24)]
        var map = InkMap(imageWidth: 1200, imageHeight: 700)
        func line(_ a: (Double, Double), _ b: (Double, Double)) { if ink { map.line(from: a, to: b) } }
        line((120, spine), (950, spine))
        for b in bones {
            func boneX(_ y: Double) -> Double { b.joint - 0.5 * abs(spine - y) }
            let labelY: Double = b.up ? 60 : 618
            let edge = b.up ? labelY + 22 : labelY
            let lw = 8.0 * Double(b.label.count)
            boxes.append(box(b.label, boneX(edge) - lw / 2, labelY, lw, 22))
            line((boneX(edge), edge), (b.joint, spine))
            // Blocks from the label inward: downward on an upper bone, upward on a lower one.
            func height(_ c: Cause) -> Double {
                c.subs.reduce(24) { $0 + 30 + 16 * Double($1.text.split(separator: "/").count - 1) }
            }
            var cursor: Double = b.up ? 100 : 600
            for c in b.causes {
                let top = b.up ? cursor : cursor - height(c)
                cursor = b.up ? top + height(c) + 16 : top - 16
                let rib = top + 22
                let end = boneX(rib) - 20
                let w = 7.5 * Double(c.text.count)
                boxes.append(box(c.text, end - w, top, w, 18))
                line((end - w - 4, rib), (boneX(rib), rib))
                // Small bones lean like their bone: toward the head going down an upper bone.
                let drift = b.up ? 0.5 : -0.5
                var from = [(end - 10, rib), (end - 10, rib)]
                var y = rib + 2
                for (s, level) in c.subs {
                    let t = y + 10
                    let parts = s.split(separator: "/").map(String.init)
                    let sRib = t + 18 + 16 * Double(parts.count - 1)
                    let r = from[level - 1]
                    let small = r.0 + drift * (sRib - r.1)
                    let sEnd = ribs ? small - 14 : boneX(sRib) - 20 - back * Double(level)
                    let sw = 6.0 * Double(parts.map(\.count).max()!)
                    for (k, part) in parts.enumerated() {
                        let pw = 6.0 * Double(part.count)
                        boxes.append(box(part, sEnd - sw / 2 - pw / 2, t + 16 * Double(k), pw, 14))
                    }
                    if ribs {
                        line(r, (small, sRib))
                        line((sEnd - sw - 4, sRib), (small, sRib))
                    }
                    if level == 1 { from[1] = (sEnd - 10, sRib) }
                    y = sRib + 2
                }
            }
        }
        var image = RecognisedImage(width: 1200, height: 700, boxes: boxes)
        if ink { image.ink = map }
        return image
    }

    static func mirrored(_ image: RecognisedImage) -> RecognisedImage {
        var m = image
        for i in m.boxes.indices { m.boxes[i].x = 1200 - m.boxes[i].maxX }
        if let ink = image.ink {
            var flipped = InkMap(imageWidth: 1200, imageHeight: 700)
            for y in 0..<ink.height {
                for x in 0..<ink.width where ink[x, y] { flipped[ink.width - 1 - x, y] = true }
            }
            m.ink = flipped
        }
        return m
    }

    /// Sub-causes each on a small bone parallel to their bone, as OpenNexus draws them:
    /// down an upper bone they move toward the head, so they're barely tucked under their
    /// cause, and down a lower one away from it, like the next cause would. Measured along
    /// the small bones, a list of them lines up (D270).
    @Test(arguments: [false, true]) func subCausesAlongSmallBones(ink: Bool) {
        let image = Self.picture(ink: ink)
        let o = ImageOutline.build(image, title: "x")
        #expect(o.layout == .fishbone && o.canvas.structure == .fishboneLeft)
        #expect(outlineText(o.canvas.root) == Self.expected)
        let m = ImageOutline.build(Self.mirrored(image), title: "x")
        #expect(m.canvas.structure == .fishboneRight && outlineText(m.canvas.root) == Self.expected)
    }

    /// Without ribs of their own, set back only ⅔ of a line further than the causes
    /// (in text as large as theirs), sub-causes read as causes from their distance alone
    /// (D237); the causes' ribs, which they lack, tell them apart (D270).
    @Test func unruledSubCausesAreSetBack() {
        var image = Self.picture(ribs: false, ink: true)
        for i in image.boxes.indices where image.boxes[i].height == 14 {
            image.boxes[i].y -= 2
            image.boxes[i].height = 18
        }
        #expect(outlineText(ImageOutline.build(image, title: "x").canvas.root) == Self.expected)
        #expect(
            outlineText(ImageOutline.build(Self.mirrored(image), title: "x").canvas.root) == Self.expected)
        var unseen = image
        unseen.ink = nil
        #expect(outlineText(ImageOutline.build(unseen, title: "x").canvas.root) != Self.expected)
    }

    /// A sub-cause wrapped onto a second line that starts with a capital: with a rib under
    /// the second line and none between them, it's one sub-cause (D271). Without the
    /// picture's lines, it's two, as tightly stacked sub-causes are (D237).
    @Test func ruledSecondLineJoinsItsSubCause() {
        var bones = Self.bones
        bones[1].causes[0].subs[0].text = "Missing notes from/Night Shift"
        var image = Self.picture(bones, ink: true)
        let o = ImageOutline.build(image, title: "x")
        let wrapped = Self.expected.replacingOccurrences(
            of: "Missing notes\n", with: "Missing notes from Night Shift\n")
        #expect(outlineText(o.canvas.root) == wrapped)
        image.ink = nil
        #expect(outlineText(ImageOutline.build(image, title: "x").canvas.root) != wrapped)
    }
}
