import AppKit
import Foundation
import Testing

@testable import NexusAI
@testable import NexusCore

private func canvas(_ tree: [(String, [String])], notes: [String: String] = [:]) -> Canvas {
    var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        for (main, subs) in tree {
            let m = try! e.addChild(of: e.canvas.root, text: main)
            for s in subs { try! e.addChild(of: m, text: s) }
        }
    }
    for (text, note) in notes {
        let id = c.nodes.first { $0.value.text == text }!.key
        c.nodes[id]!.note = Note(text: note)
    }
    return c
}

@Suite struct MaskerTests {
    @Test func findsEachKindAndMasksACopy() {
        let c = canvas(
            [
                ("Contacts", ["Ask maria.lopez@acme.io", "Call +1 (415) 555-0134"]),
                ("Secrets", ["Key sk_live_51HxQe2KfR8vTn3", "Build"]),
            ],
            notes: ["Build": "Tim Cook approved the budget."])
        let hits = Masker.scan(c)
        let byKind = Dictionary(grouping: hits, by: \.kind)
        #expect(byKind[.emails]?.map(\.text) == ["maria.lopez@acme.io"])
        #expect(byKind[.phones]?.map(\.text) == ["+1 (415) 555-0134"])
        #expect(byKind[.keys]?.map(\.text) == ["sk_live_51HxQe2KfR8vTn3"])
        #expect(byKind[.names]?.contains { $0.text == "Tim Cook" && $0.field == "note" } == true)
        #expect(Masker.counts(hits).map(\.1).reduce(0, +) == hits.count)

        // Unticking a hit keeps it.
        let kept = hits.filter { $0.kind != .phones }
        let copy = Masker.maskedCopy(c, hits: kept, id: "c2")
        #expect(copy.id == "c2" && copy.title == "Launch plan (masked)")
        let texts = Set(copy.nodes.values.map(\.text))
        #expect(texts.contains("Ask ████████████"))
        #expect(texts.contains("Call +1 (415) 555-0134"))
        #expect(!texts.contains { $0.contains("sk_live") })
        #expect(copy.nodes.values.compactMap(\.note?.text).allSatisfy { !$0.contains("Tim Cook") })
        #expect(c.nodes.values.contains { $0.text == "Ask maria.lopez@acme.io" }, "the original stays")
    }

    @Test func plainMapHasNoHits() {
        #expect(Masker.scan(canvas([("Pricing", ["Free tier", "Pro"])])).isEmpty)
    }
}

@Suite struct TranslatorTests {
    @Test func stringsAndCopy() {
        var c = canvas([("Pricing", ["Free tier"]), ("Code", [])], notes: ["Pricing": "Keep it simple."])
        let code = c.nodes.first { $0.value.text == "Code" }!.key
        c.nodes[code]!.textFormat = "code"
        let pricing = c.nodes.first { $0.value.text == "Pricing" }!.key
        c.nodes[pricing]!.labels = ["Q4"]
        var o = MapTranslator.Options()
        #expect(
            Set(MapTranslator.strings(c, o)) == [
                "Launch plan", "Pricing", "Q4", "Keep it simple.", "Free tier", "Code",
            ])
        o.keepCode = true
        o.notes = false
        #expect(!MapTranslator.strings(c, o).contains("Code"))
        #expect(!MapTranslator.strings(c, o).contains("Keep it simple."))

        let table = [
            "Launch plan": "Plan de lanzamiento", "Pricing": "Precios", "Q4": "T4", "Free tier": "Nivel gratuito",
        ]
        let copy = MapTranslator.translatedCopy(c, o, translations: table, id: "c2", language: "Spanish")
        #expect(copy.title == "Plan de lanzamiento (Spanish)")
        #expect(copy.nodes[pricing]!.text == "Precios" && copy.nodes[pricing]!.labels == ["T4"])
        #expect(copy.nodes[pricing]!.note?.text == "Keep it simple.", "notes were left out")
        #expect(copy.nodes[code]!.text == "Code")
        #expect(copy.nodes.count == c.nodes.count && copy.nodes.keys == c.nodes.keys, "structure untouched")
    }
}

@Suite struct StickerTests {
    @Test func promptUsesTopicAndParent() {
        let c = canvas([("Channels", ["Product Hunt"])])
        let id = c.nodes.first { $0.value.text == "Product Hunt" }!.key
        #expect(StickerMaker.prompt(for: id, in: c) == "product hunt for channels")
    }
}

/// Vision and the language model share the Neural Engine; run them one at a time so the
/// latency measurement isn’t competing with a cut-out.
@Suite(.serialized) struct OnDeviceModelTests {
    @Suite struct SubjectLiftTests {
        /// A red disc on a white field: the cut-out keeps the disc and clears the corners.
        @Test func removesBackground() async throws {
            let size = 256
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 64, y: 64, width: 128, height: 128)).fill()
            NSGraphicsContext.restoreGraphicsState()
            let png = rep.representation(using: .png, properties: [:])!
            do {
                let out = try await SubjectLift.removeBackground(png)
                let cut = try #require(NSBitmapImageRep(data: out))
                #expect(cut.colorAt(x: 2, y: 2)!.alphaComponent < 0.1)
                #expect(cut.colorAt(x: cut.pixelsWide / 2, y: cut.pixelsHigh / 2)!.alphaComponent > 0.9)
            } catch is SubjectLift.NoSubject {
                // Vision may decline a synthetic shape; the error is the documented outcome.
            }
        }
    }

    @Suite struct AppleEngineTests {
        /// Acceptance: the first ghost arrives in under 1.5 s on Apple silicon (warm session).
        /// Runs only where Apple Intelligence is ready.
        @Test(.enabled(if: AppleEngine().availability == .ready)) func firstGhostUnderOneAndAHalfSeconds() async throws
        {
            let engine = AppleEngine()
            engine.prewarm()
            try await Task.sleep(for: .seconds(2))
            let c = canvas([("Pricing", ["Free tier", "Pro"]), ("Risks", ["Competitor response"])])
            let risks = c.nodes.first { $0.value.text == "Risks" }!.key
            let req = AIRequest(
                action: .ideas, outline: MapContext.outline(c), anchorPath: MapContext.path(c, to: risks),
                anchorText: "Risks",
                existingChildren: ["Competitor response"])
            let start = ContinuousClock.now
            var first: Duration?
            var count = 0
            for try await idea in engine.ideas(req) {
                if first == nil { first = ContinuousClock.now - start }
                #expect(!idea.text.isEmpty)
                count += 1
            }
            let latency = try #require(first)
            print("first ghost: \(latency), \(count) ideas")
            #expect(latency < .milliseconds(1500))
            #expect(count >= 3)
        }

        @Test func unavailableEngineExplains() async {
            let e = UnavailableEngine(.off)
            await #expect(throws: (any Error).self) { try await e.draft(AIRequest(action: .explain, prompt: "q")) }
        }
    }
}
