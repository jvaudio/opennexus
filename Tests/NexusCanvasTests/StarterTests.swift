import Foundation
import NexusCore
import NexusFormat
import Testing

@testable import NexusCanvas

/// Starters build exactly what the Swift templates they replaced built (M39 A3): each
/// template's canvas, in canonical JSON, was captured into `StarterFixtures/` before the
/// templates became data. Set REGENERATE_GOLDENS=1 to rewrite them after a deliberate change.
@MainActor
@Suite struct StarterFixtureTests {
    nonisolated static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "StarterFixtures")
    nonisolated static let regenerate = ProcessInfo.processInfo.environment["REGENERATE_GOLDENS"] == "1"

    static func canvasJSON(_ doc: DocumentModel) throws -> Data {
        let files = NexusPackage.files(for: doc)
        return try #require(files["canvases/\(doc.canvasOrder[0].rawValue).json"])
    }

    @Test func everyTemplateBuildsItsFixture() throws {
        if Self.regenerate { try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true) }
        #expect(StarterLibrary.templates.count == 25)
        for t in StarterLibrary.templates {
            let data = try Self.canvasJSON(t.document())
            let url = Self.dir.appending(path: "\(t.id).json")
            if Self.regenerate {
                try data.write(to: url)
                continue
            }
            let fixture = try Data(contentsOf: url)
            #expect(data == fixture, "\(t.id) no longer builds its fixture")
        }
    }
}

@MainActor
@Suite struct StarterLibraryTests {
    static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "schema/starter.schema.json")

    /// Every built-in reads, matches the published schema and is written canonically.
    @Test func builtInsReadMatchTheSchemaAndAreCanonical() throws {
        let starters = try StarterLibrary.load()
        #expect(starters.count == 25)
        #expect(Set(starters.map(\.id)).count == starters.count, "ids are unique")
        #expect(starters.map(\.order) == Array(1...25), "orders run 1…25")
        let schemaData = try Data(contentsOf: Self.schemaURL)
        #expect(CanonicalJSON.data(try CanonicalJSON.parse(schemaData)) == schemaData, "the schema is canonical")
        let validator = SchemaValidator(schema: try CanonicalJSON.parse(schemaData))
        let folder = try #require(StarterLibrary.folder)
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: url)
            let json = try CanonicalJSON.parse(data)
            #expect(validator.validate(json).isEmpty, "\(url.lastPathComponent): \(validator.validate(json))")
            #expect(CanonicalJSON.data(json) == data, "\(url.lastPathComponent) is canonical")
            #expect(json["id"] == .string(url.deletingPathExtension().lastPathComponent), "file named after its id")
        }
    }

    /// The schema refuses what the loader would misread.
    @Test func schemaRefusesBadStarters() throws {
        let validator = SchemaValidator(schema: try CanonicalJSON.parse(Data(contentsOf: Self.schemaURL)))
        let good: [String: JSONValue] = [
            "id": "x", "order": 1, "name": "X", "summary": "S", "kicker": "K", "category": "thinking",
            "type": "mindmap",
            "title": "", "outline": ["Root", "  Child"],
        ]
        func valid(_ change: (inout [String: JSONValue]) -> Void) -> Bool {
            var d = good
            change(&d)
            return validator.validate(.object(d)).isEmpty
        }
        #expect(valid { _ in })
        #expect(!valid { $0["category"] = "learning" }, "learning is a shelf, not a category")
        #expect(!valid { $0["id"] = "blank.mindmap" }, "blank ids are generated")
        #expect(!valid { $0["outline"] = ["Root", " Child"] }, "indents are two spaces")
        #expect(!valid { $0["colour"] = "red" }, "unknown keys are typos")
    }

    @Test func relationshipsNameOutlineTopics() {
        for t in StarterLibrary.templates {
            let texts = Set(
                t.outline.map {
                    $0.trimmingCharacters(in: .whitespaces).split(separator: ">").first.map {
                        $0.trimmingCharacters(in: .whitespaces)
                    } ?? ""
                })
            for l in t.relationships {
                #expect(texts.contains(l.from) && texts.contains(l.to), "\(t.id): \(l.from) → \(l.to)")
            }
            #expect(t.document().orderedCanvases[0].relationships.count == t.relationships.count, "\(t.id)")
        }
    }

    /// Every diagram type has a Blank starter that makes what ⌘N's model makes for it.
    @Test func everyTypeHasABlankStarter() {
        #expect(StarterLibrary.blanks.map(\.type) == DiagramDescriptor.all.map(\.type))
        #expect(Set(StarterLibrary.all.map(\.id)).count == StarterLibrary.all.count, "ids are unique")
        for b in StarterLibrary.blanks {
            #expect(b.isBlank && b.shelf == nil && b.id == "blank.\(b.type.rawValue)")
            let c = b.document().orderedCanvases[0]
            #expect(c.type == b.type && c.nodes[c.root]?.text == DiagramDescriptor[b.type].rootText)
            #expect(
                NexusPackage.files(for: b.document())
                    == NexusPackage.files(for: CanvasController.newDocumentModel(prefs: .isolated(), type: b.type)))
        }
        #expect(StarterLibrary.starter("blank.dfd")?.type == .dfd && StarterLibrary.starter("dfd")?.isBlank == false)
    }
}
