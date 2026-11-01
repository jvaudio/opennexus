import Foundation
import NexusCore
import NexusFormat
import Testing

@testable import NexusCanvas
@testable import NexusScene

/// Your own starters (M50): Save Canvas as Starter…, the `.nexusstarter` file and the
/// `.nexusstarters` pack, installing with Replace or Keep Both, and what's refused.
@MainActor
@Suite struct MyStartersTests {
    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "starters-\(UUID().uuidString)")
    }

    /// A canvas with notes, tasks, a boundary, relationships and a picture.
    static func source() throws -> (canvas: Canvas, doc: DocumentModel) {
        var doc = try #require(StarterLibrary.starter("systemDesign")).document(today: TaskDate(day: 20_000))
        var c = doc.orderedCanvases[0]
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        doc.assets["pic.png"] = png
        doc.assets["unused.png"] = png
        let root = try #require(c.nodes[c.root])
        c.nodes[root.children[0]]?.image = AssetRef(asset: "pic.png", width: 40, height: 30)
        doc.canvases[c.id] = c
        return (c, doc)
    }

    /// Save, then create from it: an equal canvas apart from its id, with the pictures it
    /// uses and the document's theme, read back from disk.
    @Test func saveThenCreateGivesAnEqualCanvas() throws {
        let (canvas, doc) = try Self.source()
        let mine = MyStarters(folder: Self.folder())
        let saved = try mine.save(
            Starter.saved(
                from: canvas, in: doc, name: "Our system", collection: .architecture, summary: "Shop and stock",
                aliases: ["shop"]))
        #expect(saved.id == "our-system" && saved.kicker == "ARCHITECTURE" && saved.category == .architecture)
        let read = try #require(MyStarters(folder: mine.folder).starter("our-system"))
        #expect(read.mine && read.name == "Our system" && read.collection == .architecture)
        #expect(read.aliases == ["shop"] && read.summary == "Shop and stock" && read.type == canvas.type)
        let made = read.document()
        #expect(made.assets.keys.sorted() == ["pic.png"], "only the pictures it uses")
        #expect(made.theme == doc.theme)
        var c = made.orderedCanvases[0]
        c.id = canvas.id
        #expect(c == canvas)
        // A second save of the same name keeps both.
        #expect(try mine.save(saved).id == "our-system-2")
    }

    /// One starter and a pack survive export and install unchanged.
    @Test func exportAndInstallRoundTrip() throws {
        let (canvas, doc) = try Self.source()
        let saved = Starter.saved(
            from: canvas, in: doc, name: "Our system", collection: nil, summary: "", aliases: [])
        let trip = try #require(StarterLibrary.starter("trip"))
        let one = try StarterFile.read(StarterFile.data(saved), name: "a.nexusstarter")
        #expect(one.count == 1 && StarterFile.data(one[0]) == StarterFile.data(saved))
        let pack = try StarterFile.read(StarterFile.pack([saved, trip]), name: "b.nexusstarters")
        #expect(pack.map(\.id) == ["our-system", "trip"] && pack.allSatisfy(\.mine))
        #expect(StarterFile.pack(pack) == StarterFile.pack([saved, trip]))
        // A built-in written out reads back as the same starter.
        #expect(pack[1].document(today: TaskDate(day: 1)) == trip.document(today: TaskDate(day: 1)))

        let mine = MyStarters(folder: Self.folder())
        let installed = try mine.install(pack, clash: .keepBoth)
        #expect(installed.map(\.id) == ["our-system", "trip-2"], "a built-in's id is never taken")
        #expect(mine.all.map(\.name) == ["Our system", "Weekend trip"])
    }

    /// Malformed, unknown-version and oversized files are refused, saying why.
    @Test func badFilesAreRefused() throws {
        func refusal(_ data: Data, _ name: String = "x.nexusstarter") -> String? {
            do {
                _ = try StarterFile.read(data, name: name)
                return nil
            } catch {
                return (error as? StarterFile.Refusal)?.message
            }
        }
        let good = StarterFile.data(try #require(StarterLibrary.starter("swot")))
        var json = try #require(CanonicalJSON.parse(good).objectValue)
        #expect(refusal(good) == nil)
        #expect(refusal(Data("{".utf8)) == "“x.nexusstarter” isn’t a starter file: it isn’t JSON.")
        #expect(refusal(Data("[1]".utf8)) == "“x.nexusstarter” isn’t a starter file: it isn’t JSON.")
        #expect(
            refusal(Data(#"{"starters": [], "x": 1}"#.utf8), "p.nexusstarters")
                == "“p.nexusstarters” isn’t a starter pack: a pack holds only “starters”.")
        #expect(
            refusal(Data(#"{"starters": []}"#.utf8), "p.nexusstarters") == "“p.nexusstarters” is an empty starter pack."
        )
        json["sparkles"] = true
        let newer = try #require(refusal(CanonicalJSON.data(.object(json))))
        #expect(
            newer.contains("isn’t a starter this version of OpenNexus can read")
                && newer.hasSuffix("It may come from a newer version."))
        json["sparkles"] = nil
        json["name"] = nil
        #expect(
            try #require(refusal(CanonicalJSON.data(.object(json)))).hasPrefix(
                "“x.nexusstarter” isn’t a valid starter:"))
        json["name"] = "SWOT"
        json["outline"] = nil
        json["document"] = .object(["format": "nope"])
        #expect(
            try #require(refusal(CanonicalJSON.data(.object(json)))).hasPrefix(
                "“x.nexusstarter” isn’t a valid starter:"))
        let big = Data(count: StarterFile.maxBytes + 1)
        #expect(try #require(refusal(big)).hasPrefix("“x.nexusstarter” is too large to be a starter"))
        // In a pack, the bad starter is named by its place.
        let pack = Data(#"{"starters": [\#(String(decoding: good, as: UTF8.self)), {"id": "y"}]}"#.utf8)
        #expect(try #require(refusal(pack, "p.nexusstarters")).hasPrefix("“p.nexusstarters #2” isn’t a valid starter:"))
    }

    /// Installing one you have: Replace swaps it; Keep Both adds a copy beside it.
    @Test func replaceOrKeepBoth() throws {
        let mine = MyStarters(folder: Self.folder())
        var s = try #require(StarterLibrary.starter("retro"))
        s.id = "team-retro"
        s.name = "Team retro"
        try mine.install([s], clash: .keepBoth)
        #expect(mine.clashes([s]).map(\.id) == ["team-retro"])
        s.summary = "Changed"
        try mine.install([s], clash: .replace)
        #expect(mine.all.count == 1 && mine.all[0].summary == "Changed")
        try mine.install([s], clash: .keepBoth)
        #expect(mine.all.map(\.id) == ["team-retro", "team-retro-2"])
        #expect(mine.all.map(\.name) == ["Team retro", "Team retro 2"])
    }

    /// Delete removes the file; Undo writes it back.
    @Test func deleteAndRestore() throws {
        let mine = MyStarters(folder: Self.folder())
        var s = try #require(StarterLibrary.starter("trip"))
        s.id = "holiday"
        try mine.install([s], clash: .keepBoth)
        let url = try #require(mine.url(of: "holiday"))
        #expect(FileManager.default.fileExists(atPath: url.path()))
        let gone = try #require(try mine.remove("holiday"))
        #expect(!FileManager.default.fileExists(atPath: url.path()) && mine.all.isEmpty)
        try mine.restore(gone)
        #expect(mine.all.map(\.id) == ["holiday"])
        // A file that doesn't read is left out, not fatal.
        try Data("{".utf8).write(to: try #require(mine.url(of: "broken")))
        mine.reload()
        #expect(mine.all.map(\.id) == ["holiday"])
    }

    /// Ids from names: lower-case words joined by hyphens, never a blank's.
    @Test func idsFromNames() {
        #expect(Starter.slug("Our Plan, v2") == "our-plan-v2")
        #expect(Starter.slug("Café crème") == "cafe-creme")
        #expect(Starter.slug("2026 goals") == "my-2026-goals")
        #expect(Starter.slug("Blank map") == "my-blank-map")
        #expect(Starter.slug("—") == "my-starter")
        let mine = MyStarters(folder: nil)
        #expect(mine.freshID("swot") == "swot-2" && mine.freshID("blank.dfd") == "blank.dfd-2")
        #expect(throws: StarterFile.Refusal.self) { try mine.save(StarterLibrary.starter("swot")!) }
    }
}
