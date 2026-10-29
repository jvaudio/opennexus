import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusScene

/// M43: the interactive viewer's bundle (`schema/viewer.schema.json`).
@MainActor
@Suite(.serialized) struct ViewerBundleTests {
    nonisolated static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "NexusFormatTests/Fixtures")

    static func fixture(_ name: String) throws -> DocumentModel {
        try NexusPackage.read(from: fixtures.appending(path: "\(name).nexus"))
    }

    static func node(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }

    static func options(_ edit: (inout ViewerBundle.Options) -> Void = { _ in }) -> ViewerBundle.Options {
        var o = ViewerBundle.Options()
        o.today = TaskDate(year: 2026, month: 10, day: 28)
        edit(&o)
        return o
    }

    static func object(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o) = v { return o }
        return [:]
    }

    static func array(_ v: JSONValue?) -> [JSONValue] {
        if case .array(let a) = v { return a }
        return []
    }

    static func canvases(_ b: JSONValue) -> [[String: JSONValue]] { array(object(b)["canvases"]).map { object($0) } }

    /// The launch plan with a note, a comment, a web link, an attachment and a zone.
    static func richDocument() -> DocumentModel {
        var doc = launchPlanDocument()
        var c = doc.canvases["c1"]!
        let pricing = node(c, "Pricing")
        c.nodes[pricing]?.note = Note(text: "Secret pricing note")
        c.nodes[pricing]?.comments = [TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "Hidden remark")]
        c.nodes[node(c, "Channels")]?.link = "https://example.com/channels"
        c.nodes[node(c, "Risks")]?.attachments = [AssetRef(asset: "brief.pdf", name: "Brief.pdf")]
        c.nodes[node(c, "Timeline")]?.folded = true
        var undo = UndoStack()
        c.edit("Zone", undo: &undo) { e in
            let top = e.addFloating(at: CanvasPoint(x: 2000, y: 1400), text: "Parking lot")
            _ = try? e.addChild(of: top, text: "Later idea")
            _ = e.addZone(
                title: "Ideas", origin: CanvasPoint(x: 1960, y: 1340), width: 320, height: 200, members: [top])
        }
        doc.canvases["c1"] = c
        doc.assets["brief.pdf"] = Data("%PDF-1.4 brief".utf8)
        return doc
    }

    @Test func fixturesMatchTheSchemaAndAreDeterministic() throws {
        for name in ["LaunchPlan", "TaskPlan", "Review"] {
            let doc = try Self.fixture(name)
            let b = ViewerBundle.build(doc, Self.options())
            let issues = SchemaValidator.viewer.validate(b)
            #expect(issues.isEmpty, "\(name): \(issues.prefix(5))")
            #expect(
                CanonicalJSON.compact(b) == CanonicalJSON.compact(ViewerBundle.build(doc, Self.options())), "\(name)")
            #expect(Self.canvases(b).count == doc.canvasOrder.count)
        }
    }

    /// Every topic has details, a place in the drawing and a spot in the outline.
    @Test func everyTopicIsIndexed() throws {
        let doc = Self.richDocument()
        let b = ViewerBundle.build(doc, Self.options())
        #expect(SchemaValidator.viewer.validate(b).isEmpty)
        let c = try #require(Self.canvases(b).first)
        let canvas = doc.canvases["c1"]!
        let topics = Self.object(c["topics"])
        #expect(Set(topics.keys) == Set(canvas.nodes.keys.map(\.rawValue)))
        let layouts = Self.object(c["layouts"])
        let saved = Self.object(Self.object(layouts["saved"])["topics"])
        let expanded = Self.object(Self.object(layouts["expanded"])["topics"])
        // Folded: Timeline's two children are drawn only in Everything, and Timeline carries +2.
        let timeline = Self.node(canvas, "Timeline").rawValue
        #expect(Set(expanded.keys) == Set(topics.keys))
        #expect(saved.count == topics.count - 2)
        let fold = Self.object(saved[timeline])
        #expect(fold["hidden"] == .number(2))
        #expect(Self.array(fold["badge"]).count == 4)
        #expect(Self.object(expanded[timeline])["hidden"] == nil)
        // The outline holds every topic once, the central topic first.
        var seen: [String] = []
        func walk(_ v: JSONValue) {
            let o = Self.object(v)
            if case .string(let id)? = o["id"] { seen.append(id) }
            Self.array(o["children"]).forEach(walk)
        }
        Self.array(c["outline"]).forEach(walk)
        #expect(seen.count == canvas.nodes.count && Set(seen) == Set(topics.keys))
        #expect(seen.first == canvas.root.rawValue)
        // Each SVG names its topics with the layout's prefix.
        let svg = Self.object(layouts["saved"])["svg"]
        guard case .string(let s)? = svg else { Issue.record("no svg"); return }
        #expect(s.contains("data-nexus-id=\"\(timeline)\""))
        #expect(s.contains("<svg xmlns=\"http://www.w3.org/2000/svg\""))
    }

    @Test func detailsMatchTheApp() throws {
        let doc = Self.richDocument()
        let b = ViewerBundle.build(doc, Self.options())
        let canvas = doc.canvases["c1"]!
        let topics = Self.object(Self.canvases(b).first?["topics"])
        let pricing = Self.object(topics[Self.node(canvas, "Pricing").rawValue])
        #expect(pricing["note"] == .string("Secret pricing note"))
        #expect(Self.array(pricing["comments"]).count == 1)
        // The label is what VoiceOver says for the topic in the app.
        guard case .string(let label)? = pricing["label"] else { Issue.record("no label"); return }
        #expect(label.hasPrefix("Pricing. Main topic"))
        #expect(label.contains("Has note") && label.contains("1 comment"))
        let channels = Self.object(topics[Self.node(canvas, "Channels").rawValue])
        #expect(Self.object(channels["link"])["kind"] == .string("web"))
        // Attachments: named and sized, bytes only when asked for.
        let risks = Self.object(topics[Self.node(canvas, "Risks").rawValue])
        let att = Self.object(Self.array(risks["attachments"]).first)
        #expect(att["name"] == .string("Brief.pdf") && att["size"] == .number(14) && att["asset"] == nil)
        #expect(Self.object(Self.object(b)["assets"]).isEmpty)
        let with = ViewerBundle.build(doc, Self.options { $0.attachments = true })
        let asset = Self.object(Self.object(Self.object(with)["assets"])["brief.pdf"])
        #expect(asset["type"] == .string("application/pdf"))
        #expect(asset["data"] == .string(Data("%PDF-1.4 brief".utf8).base64EncodedString()))
    }

    @Test func notesAndCommentsCanBeLeftOut() throws {
        let doc = Self.richDocument()
        let b = ViewerBundle.build(
            doc,
            Self.options {
                $0.notes = false
                $0.comments = false
            })
        let text = CanonicalJSON.compact(b)
        #expect(!text.contains("Secret pricing note") && !text.contains("Hidden remark"))
        #expect(SchemaValidator.viewer.validate(b).isEmpty)
    }

    @Test func branchAndZoneScopes() throws {
        let doc = Self.richDocument()
        let canvas = doc.canvases["c1"]!
        let pricing = Self.node(canvas, "Pricing")
        let branch = ViewerBundle.build(doc, Self.options { $0.scope = .branch("c1", pricing) })
        #expect(SchemaValidator.viewer.validate(branch).isEmpty)
        let c = try #require(Self.canvases(branch).first)
        #expect(Set(Self.object(c["topics"]).keys) == Set(canvas.subtree(pricing).map(\.rawValue)))
        let saved = Self.object(Self.object(Self.object(c["layouts"])["saved"])["topics"])
        #expect(Set(saved.keys) == Set(canvas.subtree(pricing).map(\.rawValue)))
        #expect(!CanonicalJSON.compact(branch).contains("Positioning"))
        // The branch keeps its place in the tree: Pricing is still a main topic.
        guard case .string(let label)? = Self.object(Self.object(c["topics"])[pricing.rawValue])["label"] else {
            Issue.record("no label")
            return
        }
        #expect(label.contains("Main topic"))

        let zone = try #require(canvas.zones.first)
        let z = ViewerBundle.build(doc, Self.options { $0.scope = .zone("c1", zone.id) })
        #expect(SchemaValidator.viewer.validate(z).isEmpty)
        let zc = try #require(Self.canvases(z).first)
        #expect(Set(Self.object(zc["topics"]).keys) == Set(zone.members.flatMap { canvas.subtree($0) }.map(\.rawValue)))
        #expect(!CanonicalJSON.compact(z).contains("Pricing"))
    }

    @Test func threatModelCarriesItsTable() throws {
        let doc = DocumentModel(canvases: [TechSamples.threatModel()])
        let b = ViewerBundle.build(doc, Self.options())
        #expect(SchemaValidator.viewer.validate(b).isEmpty)
        let threats = Self.object(Self.canvases(b).first?["threats"])
        #expect(Self.array(threats["columns"]).count == Stride.tableHeader.count)
        #expect(Self.array(threats["rows"]).count == Stride.threats(doc.canvases.values.first!).count)
    }

    @Test func theSchemaRejectsGarbage() {
        #expect(!SchemaValidator.viewer.validate(.object(["format": .string("opennexus-viewer")])).isEmpty)
        #expect(!SchemaValidator.viewer.validate(.array([])).isEmpty)
    }
}
