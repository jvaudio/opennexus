import AppKit
import Foundation
import NexusCore
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusScene

/// The starter picker (M40, M50): what it lists, how search and the arrow keys move through
/// it, where it opens, what Create makes, and the user's own starters.
@MainActor
@Suite struct StarterGalleryTests {
    /// No starters of the user's own unless a test gives some.
    static func none() -> MyStarters { MyStarters(folder: nil) }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "starters-\(UUID().uuidString)")
    }

    func gallery(
        _ purpose: StarterGallery.Purpose = .canvas, role: Role = .engineer, mine: MyStarters = none()
    ) -> StarterGallery {
        StarterGallery(purpose: purpose, prefs: .isolated(), role: role, mine: mine)
    }

    /// All 16 types and 100 templates are listed; each collection holds its own (five or
    /// more), and every template is in exactly one.
    @Test func listsEveryTypeAndTemplate() {
        let g = gallery()
        #expect(g.visible.count == 116)
        #expect(g.visible.first?.id == "blank.mindmap", "Blank first: what ⌘N makes")
        #expect(Set(g.visible.filter(\.isBlank).map(\.type)) == Set(DiagramDescriptor.all.map(\.type)))
        let collections = StarterCollection.allCases.map { g.starters(in: .collection($0)).count }
        #expect(collections.reduce(0, +) == 100 && !collections.contains { $0 < 5 })
        #expect(g.starters(in: .blank).count == 16 && g.starters(in: .mine).isEmpty)
        #expect(
            g.sections == [.all, .forYou, .mine, .blank] + StarterCollection.allCases.map { .collection($0) },
            "Recent and Favourites appear once there are some")
    }

    /// For You: the role's Home shelf, then the Blank starters of its kinds of work.
    @Test func forYouFollowsTheRole() {
        let eng = gallery(role: .engineer).starters(in: .forYou)
        #expect(eng.prefix(5).map(\.id) == StarterLibrary.shelf(.engineering).map(\.id))
        #expect(eng.contains { $0.id == "blank.flowchart" } && eng.contains { $0.id == "blank.sequence" })
        #expect(!eng.contains { $0.id == "blank.threatModel" })
        let sec = gallery(role: .security).starters(in: .forYou)
        #expect(sec.contains { $0.id == "threat" } && sec.contains { $0.id == "blank.dfd" })
    }

    /// Search matches names, aliases, kinds, categories and summaries, every word, names first.
    @Test func searchMatchesNamesAliasesAndCategories() {
        let all = StarterLibrary.all
        func ids(_ q: String) -> [String] { StarterGallery.search(q, in: all).map(\.id) }
        #expect(ids("").count == 116)
        #expect(ids("threat").prefix(2) == ["blank.threatModel", "threat"], "names first")
        #expect(ids("ishikawa").first == "ishikawa", "names first")
        #expect(Set(ids("ishikawa")).isSuperset(of: ["blank.fishbone", "fishbone"]), "aliases match")
        #expect(ids("bmc") == ["businessModelCanvas"] && ids("k8s") == ["kubernetes"])
        #expect(ids("STRIDE").contains("threat"), "case doesn't matter")
        #expect(ids("data flow").first == "blank.dfd" && ids("data flow").contains("dfd"))
        #expect(Set(ids("security")).isSuperset(of: ["threat", "dfd", "runbook", "access", "attackTree"]))
        #expect(ids("sequence oauth") == ["oauth"], "every word must match")
        #expect(ids("cafe\u{301}").isEmpty && ids("zzz").isEmpty)
    }

    /// ← → move a card, ↑ ↓ a row; the ends stop the selection.
    @Test func arrowKeysMoveThroughTheGrid() {
        let g = gallery()
        g.columns = 4
        g.selection = g.visible[0].id
        g.move(dx: 1)
        #expect(g.selection == g.visible[1].id)
        g.move(dy: 1)
        #expect(g.selection == g.visible[5].id)
        g.move(dy: -5)
        #expect(g.selection == g.visible[0].id)
        g.move(dx: 400)
        #expect(g.selection == g.visible.last?.id)
    }

    /// Typing keeps the selected card when it still shows, and otherwise takes the first.
    @Test func filteringKeepsTheSelectionVisible() {
        let g = gallery()
        g.selection = "dfd"
        g.query = "data"
        #expect(g.selection == "dfd")
        g.query = "roadmap"
        #expect(g.selection == "roadmap")
        g.query = "zzz"
        #expect(g.selection == nil && g.selected == nil)
        g.query = ""
        g.section = .collection(.security)
        #expect(g.selection == g.visible.first?.id)
    }

    /// The picker opens on the starter used last, so ⌘T ↩ repeats it; Recent lists it.
    @Test func opensOnTheLastStarter() {
        let prefs = Preferences.isolated()
        #expect(StarterLibrary.lastUsed(prefs: prefs).id == "blank.mindmap")
        #expect(StarterGallery(purpose: .canvas, prefs: prefs, mine: Self.none()).selection == "blank.mindmap")
        var made: [String] = []
        let g = StarterGallery(purpose: .canvas, prefs: prefs, mine: Self.none())
        g.onChoose = { made.append($0.id) }
        g.query = "swot"
        g.choose()
        g.choose()
        #expect(made == ["swot"], "↩ and the default button arriving together create once")
        let again = StarterGallery(purpose: .canvas, prefs: prefs, mine: Self.none())
        #expect(again.selection == "swot" && again.recent.map(\.id) == ["swot"])
        #expect(again.sections.contains(.recent) && StarterLibrary.lastUsed(prefs: prefs).id == "swot")
        for id in ["a", "b", "c", "d", "e", "f", "g", "h", "i"] { StarterHistory(prefs.defaults).note(id) }
        #expect(StarterHistory(prefs.defaults).recent.count == StarterHistory.limit)
        #expect(again.recent.isEmpty, "unknown ids are dropped")
        #expect(StarterLibrary.lastUsed(prefs: prefs).id == "blank.mindmap")
    }

    /// Create makes a canvas in this document as one undo step, with a caret on its root.
    @Test func createIsOneUndoStepWithACaret() throws {
        let h = CanvasHarness()
        h.controller.prefs = .isolated()
        let before = h.store.model.canvasOrder
        let id = h.controller.addCanvas(from: try #require(StarterLibrary.starter("blank.dfd")))
        let c = try #require(h.store.model.canvases[id])
        #expect(h.store.model.canvasOrder == before + [id] && h.controller.canvasID == id)
        #expect(c.type == .dfd && c.nodes[c.root]?.text == "Context" && c.title == "Map 2")
        #expect(h.controller.edit?.node == c.root, "a live caret on the root")
        h.controller.commitEdit()
        h.undo.undo(h.store)
        #expect(h.store.model.canvasOrder == before, "one undo step")

        let oauth = try #require(StarterLibrary.starter("oauth"))
        let t = h.controller.addCanvas(from: oauth)
        let made = try #require(h.store.model.canvases[t])
        let built = oauth.canvas(id: t)
        #expect(made.title == "OAuth handshake" && made.nodes.count == built.nodes.count)
        #expect(made.relationships.count == built.relationships.count)
        #expect(h.controller.edit?.selectAll == true, "a template's root is selected, ready to retitle")
        #expect(StarterLibrary.lastUsed(prefs: h.controller.prefs).id == "oauth")
    }

    /// A Blank canvas takes the new-document settings, as ⌘T always did.
    @Test func blankCanvasesTakeTheDefaults() throws {
        let h = CanvasHarness()
        let prefs = Preferences.isolated()
        prefs.set("editing.newCanvasLayout", "free")
        prefs.set("appearance.theme", "graphite")
        h.controller.prefs = prefs
        let id = h.controller.addCanvas(from: StarterLibrary.blanks[0])
        let c = try #require(h.store.model.canvases[id])
        #expect(c.layout.mode == .free && c.style.theme == "graphite" && c.type == .mindmap)
    }

    /// Budgets: the picker lays out under 100 ms with 150 starters (thumbnails draw
    /// afterwards) and the canvas appears under 150 ms after ↩.
    @Test func pickerAndCreateAreFast() throws {
        // 116 built-ins and 34 of the user's own.
        let mine = MyStarters(folder: Self.folder())
        for (i, t) in StarterLibrary.templates.prefix(34).enumerated() {
            var s = t
            s.id = "mine\(i)"
            s.name = "\(t.name) (mine)"
            try mine.install([s], clash: .keepBoth)
        }
        #expect(gallery(mine: mine).visible.count == 150)
        func open() -> Double {
            let start = ContinuousClock.now
            let w = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
                defer: false)
            let v = NSHostingView(rootView: StarterGalleryView(model: gallery(mine: mine)))
            w.contentView = v
            w.layoutIfNeeded()
            v.layoutSubtreeIfNeeded()
            let d = ContinuousClock.now - start
            w.contentView = nil
            return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
        }
        _ = open()  // SwiftUI's first use in the process
        // The fastest of five is the picker's own cost; a slower one is the main thread
        // waiting on the suites running alongside (D486).
        let opens = (0..<5).map { _ in open() }
        print("picker opened in \(opens.map { Int($0) }) ms")
        #expect(opens.min()! < 100, "picker opened in \(opens.min()!) ms at best")

        let h = CanvasHarness()
        h.controller.prefs = .isolated()
        let big = try #require(
            StarterLibrary.templates.filter { $0.order <= 25 }.max { $0.outline.count < $1.outline.count })
        let start = ContinuousClock.now
        h.controller.addCanvas(from: big)
        h.window.layoutIfNeeded()
        h.host.canvasView.layoutSubtreeIfNeeded()
        let d = ContinuousClock.now - start
        let ms = Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
        #expect(ms < 150, "\(big.id) appeared in \(ms) ms")
    }

    /// Thumbnails are the starter's own map, drawn once per appearance and scale.
    @Test func thumbnailsAreDrawnOnceAndFitTheCard() throws {
        let s = try #require(StarterLibrary.starter("c4"))
        let img = try #require(StarterThumbnails.image(s, prefs: .isolated(), dark: false, scale: 2))
        #expect(img.width <= Int(StarterThumbnails.size.width * 2) + 1)
        #expect(img.height <= Int(StarterThumbnails.size.height * 2) + 1)
        #expect(StarterThumbnails.cached(s, dark: false, scale: 2) === img)
        #expect(StarterThumbnails.cached(s, dark: true, scale: 2) == nil)
    }

    /// The setting that turns the picker off is on by default.
    @Test func thePickerIsOnByDefault() {
        #expect(Preferences.isolated().bool("editing.starterPicker"))
        #expect(SettingsSchema.search("starter").contains { $0.2.key == "editing.starterPicker" })
    }

    /// Favourites: a card's ☆ or ⌘D. They persist, and the sidebar lists them once there are some.
    @Test func favouritesPersist() throws {
        let prefs = Preferences.isolated()
        func make() -> StarterGallery { StarterGallery(purpose: .canvas, prefs: prefs, mine: Self.none()) }
        let g = make()
        g.toggleFavourite(try #require(StarterLibrary.starter("swot")))
        g.selection = "kubernetes"
        g.toggleFavourite()
        #expect(g.isFavourite(try #require(StarterLibrary.starter("swot"))) && g.sections.contains(.favourites))
        let again = make()
        #expect(again.favourites.map(\.id) == ["kubernetes", "swot"], "newest first, like Recent")
        again.toggleFavourite(try #require(StarterLibrary.starter("swot")))
        again.section = .favourites
        #expect(again.visible.map(\.id) == ["kubernetes"] && make().favourites.map(\.id) == ["kubernetes"])
        again.toggleFavourite(try #require(StarterLibrary.starter("kubernetes")))
        #expect(!make().sections.contains(.favourites))
    }

    /// Search covers the collection and the type's name as well as names and aliases.
    @Test func searchCoversCollectionsAndTypes() {
        let all = StarterLibrary.all
        func ids(_ q: String) -> Set<String> { Set(StarterGallery.search(q, in: all).map(\.id)) }
        func of(_ c: StarterCollection) -> Set<String> {
            Set(StarterLibrary.templates.filter { $0.collection == c }.map(\.id))
        }
        #expect(ids("personal life").isSuperset(of: of(.personal)))
        #expect(ids("meetings teams").isSuperset(of: of(.meetings)))
        let swimlanes = Set(StarterLibrary.all.filter { $0.type == .swimlane }.map(\.id))
        #expect(ids("swimlane").isSuperset(of: swimlanes) && swimlanes.count == 4)
    }

    /// My Starters: listed in their own section and their collection, found by search, and
    /// renamed, moved, deleted and restored from the picker.
    @Test func myStartersAreListedAndManaged() throws {
        let mine = MyStarters(folder: Self.folder())
        let g = gallery(mine: mine)
        let h = CanvasHarness(model: try #require(StarterLibrary.starter("swot")).document())
        let s = try mine.save(
            Starter.saved(
                from: h.canvas, in: h.store.model, name: "Shop SWOT", collection: .business, summary: "Our shop",
                aliases: ["corner shop"]))
        #expect(s.id == "shop-swot" && s.mine)
        #expect(g.starters(in: .mine).map(\.id) == ["shop-swot"])
        #expect(g.starters(in: .collection(.business)).last?.id == "shop-swot")
        #expect(g.starters(in: .all).count == 117)
        #expect(StarterGallery.search("corner", in: g.starters(in: .all)).map(\.id) == ["shop-swot"])

        g.update(s) {
            $0.name = "Shop review"
            $0.collection = .planning
        }
        let renamed = try #require(MyStarters(folder: mine.folder).starter("shop-swot"))
        #expect(renamed.name == "Shop review" && renamed.collection == .planning, "kept on disk")
        #expect(g.starters(in: .collection(.planning)).contains { $0.id == "shop-swot" })

        g.delete(renamed)
        #expect(g.starters(in: .mine).isEmpty && g.notice == "Deleted “Shop review”" && g.deleted != nil)
        g.undoDelete()
        #expect(g.starters(in: .mine).map(\.name) == ["Shop review"] && g.selection == "shop-swot")
        #expect(g.deleted == nil && g.notice == nil)
    }

    /// Install through the picker: a preview first, refusals as a notice, and the installed
    /// starter selected in My Starters.
    @Test func installingFromThePicker() throws {
        let mine = MyStarters(folder: Self.folder())
        let g = gallery(mine: mine)
        #expect(g.preview(Data("nope".utf8), name: "plan.nexusstarter") == nil)
        #expect(g.notice == "“plan.nexusstarter” isn’t a starter file: it isn’t JSON.")
        var s = try #require(StarterLibrary.starter("trip"))
        s.id = "weekend"
        s.name = "Weekend away"
        let i = try #require(g.preview(StarterFile.data(s), name: "weekend.nexusstarter"))
        #expect(i.starters.map(\.id) == ["weekend"] && i.clashes.isEmpty)
        g.install(i, clash: .keepBoth)
        #expect(g.section == .mine && g.selection == "weekend" && g.notice == "Installed “Weekend away”")
        let again = try #require(g.preview(StarterFile.data(s), name: "weekend.nexusstarter"))
        #expect(again.clashes.map(\.id) == ["weekend"])
        g.install(again, clash: .keepBoth)
        #expect(mine.all.map(\.name) == ["Weekend away", "Weekend away 2"])
    }

    /// Create from a saved starter: the canvas as it was saved, under a fresh id.
    @Test func createFromASavedStarter() throws {
        let src = CanvasHarness(model: try #require(StarterLibrary.starter("project")).document())
        let s = Starter.saved(
            from: src.canvas, in: src.store.model, name: "Plan", collection: nil, summary: "", aliases: [])
        let h = CanvasHarness()
        h.controller.prefs = .isolated()
        let before = h.store.model.canvasOrder
        let id = h.controller.addCanvas(from: s)
        #expect(h.store.model.canvasOrder == before + [id] && h.controller.canvasID == id)
        var made = try #require(h.store.model.canvases[id])
        made.id = src.canvas.id
        #expect(made == src.canvas, "equal apart from its id")
    }
}
