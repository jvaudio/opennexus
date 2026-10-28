import AppKit
import Foundation
import NexusCore
import SwiftUI
import Testing

@testable import NexusCanvas

/// The starter picker (M40): what it lists, how search and the arrow keys move through it,
/// where it opens, and what Create makes.
@MainActor
@Suite struct StarterGalleryTests {
    func gallery(_ purpose: StarterGallery.Purpose = .canvas, role: Role = .engineer) -> StarterGallery {
        StarterGallery(purpose: purpose, prefs: .isolated(), role: role)
    }

    /// All 16 types and 25 templates are listed; each category holds its own, and every
    /// starter is in exactly one.
    @Test func listsEveryTypeAndTemplate() {
        let g = gallery()
        #expect(g.visible.count == 41)
        #expect(g.visible.first?.id == "blank.mindmap", "Blank first: what ⌘N makes")
        #expect(Set(g.visible.filter(\.isBlank).map(\.type)) == Set(DiagramDescriptor.all.map(\.type)))
        let categories = StarterCategory.allCases.map { g.starters(in: .category($0)).count }
        #expect(categories.reduce(0, +) == 41 && !categories.contains(0))
        #expect(g.sections.first == .all && !g.sections.contains(.recent), "Recent appears once something is used")
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
        #expect(ids("").count == 41)
        #expect(ids("threat").prefix(2) == ["blank.threatModel", "threat"], "names first")
        #expect(ids("ishikawa") == ["blank.fishbone", "fishbone"], "aliases match")
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
        g.section = .category(.security)
        #expect(g.selection == g.visible.first?.id)
    }

    /// The picker opens on the starter used last, so ⌘T ↩ repeats it; Recent lists it.
    @Test func opensOnTheLastStarter() {
        let prefs = Preferences.isolated()
        #expect(StarterLibrary.lastUsed(prefs: prefs).id == "blank.mindmap")
        #expect(StarterGallery(purpose: .canvas, prefs: prefs).selection == "blank.mindmap")
        var made: [String] = []
        let g = StarterGallery(purpose: .canvas, prefs: prefs)
        g.onChoose = { made.append($0.id) }
        g.query = "swot"
        g.choose()
        g.choose()
        #expect(made == ["swot"], "↩ and the default button arriving together create once")
        let again = StarterGallery(purpose: .canvas, prefs: prefs)
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

    /// Budgets: the picker lays out under 100 ms (thumbnails draw afterwards) and the canvas
    /// appears under 150 ms after ↩.
    @Test func pickerAndCreateAreFast() throws {
        func open() -> Double {
            let start = ContinuousClock.now
            let w = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
                defer: false)
            let v = NSHostingView(rootView: StarterGalleryView(model: gallery()))
            w.contentView = v
            w.layoutIfNeeded()
            v.layoutSubtreeIfNeeded()
            let d = ContinuousClock.now - start
            w.contentView = nil
            return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
        }
        _ = open()  // SwiftUI's first use in the process
        let opens = (0..<3).map { _ in open() }.sorted()
        #expect(opens[1] < 100, "picker opened in \(opens[1]) ms")

        let h = CanvasHarness()
        h.controller.prefs = .isolated()
        let big = try #require(StarterLibrary.templates.max { $0.outline.count < $1.outline.count })
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
}
