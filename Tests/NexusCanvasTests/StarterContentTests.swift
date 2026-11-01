import AppKit
import Foundation
import NexusCore
import Testing

@testable import NexusCanvas
@testable import NexusScene

/// The built-in starters' content (M50): the rules their authors wrote to, checked here so
/// `swift test` runs them; every type and collection well stocked; guides met and data-flow
/// rules kept; no two topics overlapping; and a PNG golden of each. Set REGENERATE_GOLDENS=1
/// to rewrite the goldens, and STARTER_SHEETS=<folder> to draw contact sheets of them for
/// review by eye.
@MainActor
@Suite(.serialized) struct StarterContentTests {
    nonisolated static let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "StarterGoldens")
    nonisolated static let regenerate = ProcessInfo.processInfo.environment["REGENERATE_GOLDENS"] == "1"
    /// Scheduled tasks count from here, so the goldens don't depend on the day they're drawn.
    static let today = TaskDate(year: 2026, month: 1, day: 5)!

    /// Placeholder text, which no starter may hold.
    static let placeholders = ["lorem", "ipsum", "dolor", "foo", "baz", "todo", "tbd", "asdf", "xxx"]
    /// Real companies, products and people, which the new starters leave out (the 25 keep
    /// theirs: the ADR starter's queue is named).
    static let realNames = [
        "google", "alphabet", "amazon", "aws", "azure", "microsoft", "apple", "iphone", "ipad", "android", "meta",
        "facebook", "instagram", "twitter", "netflix", "uber", "airbnb", "stripe", "paypal", "salesforce", "oracle",
        "ibm", "tesla", "openai", "anthropic", "slack", "zoom", "jira", "atlassian", "notion", "figma", "github",
        "gitlab", "shopify", "spotify", "visa", "mastercard", "kafka", "postgres", "postgresql", "mysql", "redis",
        "mongodb", "nginx", "docker", "terraform", "elon", "musk", "bezos", "zuckerberg",
    ]

    static var templates: [Starter] { StarterLibrary.templates }
    /// The 75 written for M50.
    static var added: [Starter] { templates.filter { $0.order > 25 } }

    /// An outline line's text, depth and node type.
    static func row(_ line: String) -> (text: String, depth: Int, type: String?) {
        let depth = line.prefix { $0 == " " }.count / 2
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ">", maxSplits: 1)
        let text = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return (text, depth, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil)
    }

    static func words(_ s: String) -> Int { s.split { $0.isWhitespace }.count }

    /// Every piece of text a starter shows or searches by, lower-cased.
    static func allText(_ s: Starter) -> String {
        var parts = [s.name, s.summary, s.kicker, s.title, s.note ?? ""] + s.aliases
        parts += s.outline.map { row($0).text }
        parts += s.details.flatMap { [$0.note ?? "", $0.edge ?? ""] }
        parts += s.relationships.map(\.label) + s.boundaries.map(\.title) + s.lanes.map(\.title)
        return parts.joined(separator: "\n").lowercased()
    }

    static func contains(_ word: String, in text: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }

    /// What's wrong with a new starter, by the authors' rules.
    static func problems(_ s: Starter) -> [String] {
        var out: [String] = []
        func bad(_ m: String) { out.append(m) }
        if s.collection == nil { bad("no collection") }
        if s.shelf != nil { bad("a shelf: Home's rows stay as they were") }
        if s.aliases.count < 2 { bad("fewer than two aliases") }
        if s.aliases.contains(where: { $0 != $0.lowercased() }) { bad("aliases are lower case") }
        if Set(s.aliases).count != s.aliases.count { bad("aliases repeat") }
        if (s.note ?? "").count < 20 { bad("the root note says how to use it") }
        if s.kicker != s.kicker.uppercased() { bad("the kicker is in capitals") }
        if s.summary.hasSuffix(".") || words(s.summary) > 6 { bad("the summary: six words or fewer, no full stop") }

        let rows = s.outline.map(row)
        let size = rows.count + (s.type == .sequence ? s.relationships.count : 0)
        if !(12...40).contains(size) { bad("\(size) topics; 12–40") }
        let types = DiagramCatalog.nodeTypes(for: s.type).map(\.id)
        for r in rows {
            if words(r.text) > 6 { bad("“\(r.text)”: more than six words") }
            if let t = r.type.map(NodeType.init(rawValue:)),
                !types.contains(t) && !(s.type == .architecture && DiagramCatalog.info(t, in: s.type) != nil)
            {
                bad("“\(r.text)”: \(s.type.rawValue) has no node type \(t.rawValue)")
            }
        }
        let texts = rows.map(\.text)
        if Set(texts).count != texts.count { bad("topic texts repeat") }
        if texts.first == DiagramDescriptor[s.type].rootText { bad("the root is the placeholder; name it") }
        let text = allText(s)
        for w in placeholders + realNames where contains(w, in: text) { bad("“\(w)”") }
        let known = Set(texts)
        for d in s.details where !known.contains(d.topic) { bad("details: no topic “\(d.topic)”") }
        for g in s.boundaries + s.lanes { for t in g.topics where !known.contains(t) { bad("\(g.title): no “\(t)”") } }
        if s.type == .swimlane && s.lanes.count < 2 { bad("a swimlane has two or more lanes") }
        return out
    }

    /// A hundred or more, every diagram type three or more times and every collection five.
    @Test func everyTypeAndCollectionIsStocked() {
        #expect(Self.templates.count == 100)
        #expect(Self.added.count == 75)
        for d in DiagramDescriptor.all {
            #expect(Self.templates.count { $0.type == d.type } >= 3, "\(d.type.rawValue)")
        }
        for c in StarterCollection.allCases {
            #expect(Self.templates.count { $0.collection == c } >= 5, "\(c.rawValue)")
        }
        #expect(Self.templates.allSatisfy { $0.collection != nil }, "every built-in is in a collection")
        #expect(Self.added.allSatisfy { $0.shelf == nil }, "Home's shelves keep their 25")
    }

    @Test func newStartersKeepTheContentRules() {
        for s in Self.added {
            let p = Self.problems(s)
            #expect(p.isEmpty, "\(s.id): \(p.joined(separator: "; "))")
        }
    }

    /// The 25 keep the rules they already met: aliases, short topics, no placeholders.
    @Test func theFirst25KeepTheRulesTheyMet() {
        for s in Self.templates where s.order <= 25 {
            #expect(s.aliases.count >= 2 && s.aliases.allSatisfy { $0 == $0.lowercased() }, "\(s.id)")
            for r in s.outline.map(Self.row) { #expect(Self.words(r.text) <= 6, "\(s.id): \(r.text)") }
            let text = Self.allText(s)
            for w in Self.placeholders { #expect(!Self.contains(w, in: text), "\(s.id): \(w)") }
        }
    }

    /// Every topic of a technical starter has a type, given or taken from its place; notes,
    /// markers and tasks land where the starter says.
    @Test func detailsAndTypesLandOnTheirTopics() throws {
        for s in Self.added {
            let c = s.document(today: Self.today).orderedCanvases[0]
            let byText = Dictionary(c.nodes.values.map { ($0.text, $0) }, uniquingKeysWith: { a, _ in a })
            #expect(c.nodes[c.root]?.note?.text.isEmpty == false, "\(s.id): a root note")
            for d in s.details {
                let n = try #require(byText[d.topic], "\(s.id): \(d.topic)")
                if let note = d.note { #expect(n.note?.text == note, "\(s.id): \(d.topic)'s note") }
                if let edge = d.edge { #expect(n.edgeLabel == edge, "\(s.id): \(d.topic)'s edge") }
                #expect(Set(d.markers).isSubset(of: Set(n.markers)), "\(s.id): \(d.topic)'s markers")
                #expect((n.todo != nil) == d.isTask, "\(s.id): \(d.topic)'s task")
            }
            guard DiagramDescriptor[s.type].technical else { continue }
            let parents = c.parentMap()
            let title = DiagramDescriptor[s.type].rootIsTitle
            for id in c.nodes.keys where !(title && id == c.root) {
                #expect(
                    DiagramCatalog.effectiveType(id, in: c, parents: parents) != nil,
                    "\(s.id): “\(c.nodes[id]?.text ?? "")” has no type")
            }
        }
    }

    /// Each new starter of a guided type meets its guide's required steps, and its data
    /// flows break no DFD rule.
    @Test func guidedStartersMeetTheirGuides() {
        for s in Self.added {
            let c = s.document(today: Self.today).orderedCanvases[0]
            if let g = GuideLibrary.guide(for: s.type) {
                let open = GuideMatcher.progress(c, g).steps.filter { !$0.optional && !$0.met }
                #expect(open.isEmpty, "\(s.id): \(open.map(\.id))")
            }
            let v = DFDRules.check(c)
            #expect(v.isEmpty, "\(s.id): \(v.map(\.title))")
        }
    }

    /// No two topics overlap in any starter's laid-out canvas (a matrix cell holds its
    /// topics, so a cell and what's in it don't count).
    @Test func noTopicsOverlap() {
        for s in Self.templates {
            let h = CanvasHarness(model: s.document(today: Self.today), width: 880, height: 560)
            let c = h.canvas
            let parents = c.parentMap()
            func ancestor(_ a: NodeID, of b: NodeID) -> Bool {
                var p = parents[b]
                while let x = p {
                    if x == a { return true }
                    p = parents[x]
                }
                return false
            }
            let nodes = h.controller.scene.nodes.map { ($0.key, $0.value.frame.rect.insetBy(dx: 1, dy: 1)) }
            var overlaps: [String] = []
            for (i, a) in nodes.enumerated() {
                for b in nodes[(i + 1)...] where a.1.intersects(b.1) {
                    if s.type == .matrix && (ancestor(a.0, of: b.0) || ancestor(b.0, of: a.0)) { continue }
                    overlaps.append("“\(c.nodes[a.0]?.text ?? "")” and “\(c.nodes[b.0]?.text ?? "")”")
                }
            }
            #expect(overlaps.isEmpty, "\(s.id): \(overlaps.prefix(4).joined(separator: ", "))")
        }
    }

    /// A PNG of each, light, at 1×, compared like the style goldens.
    @Test func everyStarterMatchesItsGolden() throws {
        if Self.regenerate {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
        }
        var drawn: [(String, NSBitmapImageRep)] = []
        for s in Self.templates {
            let rep = try #require(Self.render(s), "\(s.id)")
            drawn.append((s.id, rep))
            let url = Self.goldenDir.appending(path: "\(s.id).png")
            if Self.regenerate {
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                continue
            }
            let golden = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)), "\(s.id) has a golden")
            let current = try #require(
                rep.representation(using: .png, properties: [:]).flatMap(NSBitmapImageRep.init(data:)))
            let diff = ImageDiff.compare(current, golden)
            #expect(diff.sizeMatches, "\(s.id): size changed")
            #expect(diff.meanDelta < 0.02, "\(s.id): mean channel delta \(diff.meanDelta)")
            #expect(diff.changedFraction < 0.02, "\(s.id): \(diff.changedFraction * 100)% of pixels changed")
        }
        if let dir = ProcessInfo.processInfo.environment["STARTER_SHEETS"] {
            try Self.contactSheets(drawn, to: URL(fileURLWithPath: dir))
        }
    }

    static func render(_ s: Starter) -> NSBitmapImageRep? {
        let h = CanvasHarness(model: s.document(today: today), width: 880, height: 560)
        h.host.canvasView.fitToWindow()
        return h.renderOffscreen(scale: 1)
    }

    /// Twelve renders a sheet, labelled, at half size: for reviewing by eye.
    static func contactSheets(_ drawn: [(String, NSBitmapImageRep)], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cell = CGSize(width: 440, height: 300)
        for (n, chunk) in stride(from: 0, to: drawn.count, by: 12).map({ Array(drawn[$0..<min($0 + 12, drawn.count)]) })
            .enumerated()
        {
            let sheet = NSImage(size: CGSize(width: cell.width * 3, height: cell.height * 4))
            sheet.lockFocus()
            NSColor.white.setFill()
            CGRect(origin: .zero, size: sheet.size).fill()
            for (i, (id, rep)) in chunk.enumerated() {
                let x = CGFloat(i % 3) * cell.width
                let y = sheet.size.height - CGFloat(i / 3 + 1) * cell.height
                rep.draw(in: CGRect(x: x, y: y + 20, width: cell.width, height: cell.height - 20))
                (id as NSString).draw(
                    at: CGPoint(x: x + 6, y: y + 3),
                    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.systemRed])
                NSColor.lightGray.setStroke()
                NSBezierPath(rect: CGRect(x: x, y: y, width: cell.width, height: cell.height)).stroke()
            }
            sheet.unlockFocus()
            let png = sheet.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
            try png?.write(to: dir.appending(path: String(format: "sheet-%02d.png", n + 1)))
        }
    }
}
