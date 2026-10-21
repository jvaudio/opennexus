import AppKit
import Foundation
import NexusAI
import NexusCore
import NexusKeys
import Testing

@testable import NexusCanvas

/// M14: comments on topics, from the keyboard, with undo, VoiceOver, filters and search.
@MainActor
@Suite(.serialized) struct CommentTests {
    func harness() -> (CanvasHarness, NodeID) {
        var c = Canvas(id: "c1", title: "Review", rootText: "Pricing")
        var u = UndoStack()
        c.edit("Sample", undo: &u) { e in _ = try! e.addChild(of: e.canvas.root, text: "Annual tier") }
        let h = CanvasHarness(model: DocumentModel(canvases: [c]))
        let id = h.canvas.nodes.first { $0.value.text == "Annual tier" }!.key
        h.controller.select(id)
        return (h, id)
    }

    @Test func commandKeyOpensTheThread() {
        let (h, id) = harness()
        var requests: [CanvasRequest] = []
        h.controller.onRequest = { requests.append($0) }
        h.press("ctrl+cmd+n")
        #expect(requests == [.comments(id)])
        let cmd = CommandRegistry.standard[.comment]
        #expect(cmd?.menu == .insert && cmd?.title == "Comment…")
    }

    @Test func addEditDeleteAreOneUndoStepEach() {
        let (h, id) = harness()
        h.controller.prefs.set("editing.commentAuthor", "Ana")
        let t = Date(timeIntervalSince1970: 1_792_504_980)
        let before = h.undo.stack.undoStack.count
        h.controller.addComment("  Drop it?  ", on: id, now: t)
        h.controller.addComment("   ", on: id, now: t)
        #expect(
            h.canvas.nodes[id]?.comments == [
                TopicComment(author: "Ana", date: "2026-10-20T14:03:00Z", text: "Drop it?")
            ])
        h.controller.editComment(0, text: "Drop the annual tier?", on: id)
        #expect(h.canvas.nodes[id]?.comments.first?.text == "Drop the annual tier?")
        h.controller.addComment("Keep it", on: id, now: t)
        h.controller.deleteComment(0, on: id)
        #expect(h.canvas.nodes[id]?.comments.map(\.text) == ["Keep it"])
        #expect(h.undo.stack.undoStack.count == before + 4, "add, edit, add, delete")
        h.undo.undo(h.store)
        #expect(h.canvas.nodes[id]?.comments.count == 2)
        h.controller.editComment(1, text: "", on: id)
        #expect(h.canvas.nodes[id]?.comments.count == 1, "clearing a comment's text deletes it")
    }

    @Test func authorDefaultsToTheMacUser() {
        let (h, _) = harness()
        h.controller.prefs.set("editing.commentAuthor", "  ")
        let mac = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        #expect(h.controller.commentAuthor == mac)
        h.controller.prefs.set("editing.commentAuthor", "Reviewer")
        #expect(h.controller.commentAuthor == "Reviewer")
        #expect(SettingsSchema.allRows.contains { $0.2.key == "editing.commentAuthor" })
    }

    @Test func badgeVoiceOverAndRotor() throws {
        let (h, id) = harness()
        h.controller.addComment("One", on: id)
        h.controller.addComment("Two", on: id)
        let sn = try #require(h.controller.scene.nodes[id])
        #expect(sn.indicators.contains(.comment) && sn.commentCount == 2)
        let spoken = Spoken.describe(id, in: h.canvas, prefs: h.controller.prefs)
        #expect(spoken.contains("2 comments"))
        let tree = try #require(h.host.canvasView.accessibilityTree)
        let rotor = tree.items(.comments)
        #expect(rotor.count == 1 && rotor.first?.accessibilityLabel()?.contains("Annual tier") == true)
        let el = try #require(tree.element(id))
        #expect(el.accessibilityCustomActions()?.contains { $0.name == "Comments" } == true)
        #expect(CommentsPopover.spoken(TopicComment(author: "Ana", date: "", text: "Hi")) == "Comment by Ana: Hi")
    }

    @Test func filterSearchAndMasking() throws {
        let (h, id) = harness()
        h.controller.prefs.set("editing.commentAuthor", "Ana")
        h.controller.addComment("Ask jane@example.com about the budget", on: id)
        let c = h.canvas
        #expect(NodeFilter(clauses: [NodeFilter.parse("comment: yes")!]).matching(in: c) == [id])
        #expect(NodeFilter(clauses: [NodeFilter.parse("comment: Ana")!]).matching(in: c) == [id])
        #expect(NodeFilter(clauses: [NodeFilter.parse("comment: budget")!]).matching(in: c) == [id])
        #expect(NodeFilter(clauses: [NodeFilter.parse("comment: no")!]).matching(in: c) == [c.root])
        var o = SearchOptions()
        #expect(TextSearch.find("budget", o, in: h.store.model, current: c.id).isEmpty, "comments need + Notes")
        o.notes = true
        let hits = TextSearch.find("budget", o, in: h.store.model, current: c.id)
        #expect(hits.map(\.field) == [.comment])
        var e = CanvasEditor(c)
        #expect(TextSearch.replace(hits, query: "budget", with: "plan", o, in: &e) == 1)
        #expect(e.canvas.nodes[id]?.comments.first?.text == "Ask jane@example.com about the plan")
        #expect(CanvasCounts(c).comments == 1 && CanvasCounts(c).commented == 1)
        let masked = Masker.maskedCopy(c, hits: Masker.scan(c), id: c.id)
        #expect(masked.nodes[id]?.comments.first?.text.contains("jane@example.com") == false)
    }
}
