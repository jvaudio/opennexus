import AppKit
import Foundation
import Testing

@testable import NexusAI
@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

/// M8: the tutorial (F5) follows real key presses in a real document.
@MainActor
@Suite(.serialized) struct TourTests {
    func start(_ role: Role = .engineer) -> (CanvasHarness, TourController) {
        let h = CanvasHarness(model: TemplateLibrary.tourDocument(role))
        let tour = TourController(role: role)
        tour.attach(h.controller)
        return (h, tour)
    }

    func settle(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done(), "timed out")
    }

    @Test func allSixLessonsWithRealKeys() async throws {
        let (h, tour) = start(.engineer)
        #expect(h.controller.mode == .edit && tour.lessons.count == 6)
        // 1 · Type.
        h.type("Checkout")
        h.press("return")
        #expect(tour.lesson == 1 && tour.coach == .success)
        // 2 · Tab and Return.
        h.press("tab")
        h.type("Cart")
        h.press("return")
        #expect(tour.lesson == 1 && tour.step == 1, "⇥ counted; ↩ in Edit commits")
        h.press("return")
        h.press("esc")
        h.press("shift+return")
        h.press("esc")
        h.press("cmd+return")
        h.press("esc")
        #expect(tour.lesson == 2 && tour.step == 0)
        // 3 · Move around.
        h.press("down")
        h.press("opt+cmd+up")
        h.press("cmd+/")
        #expect(tour.lesson == 3)
        h.press("cmd+/")
        // 4 · Connect: ⇧⌘L, a hint, ↩, then name the edge.
        h.controller.select(h.canvas.nodes.first { $0.value.text == "Cart" }!.key)
        h.press("shift+cmd+l")
        let hint = try #require(h.controller.connect?.candidates.first?.hint)
        h.type(hint.lowercased())
        h.press("return")
        #expect(tour.lesson == 3 && tour.step == 2, "the edge is drawn")
        h.type("feeds")
        h.press("return")
        #expect(tour.lesson == 4)
        // 5 · Transform: ⌥⌘T converts straight to the role's type.
        h.press("opt+cmd+t")
        #expect(h.canvas.type == Role.engineer.tourConversion && tour.lesson == 5)
        #expect(h.controller.convert == nil)
        // 6 · Ask AI (scripted ideas when Apple Intelligence is off).
        h.controller.select(h.canvas.root)
        h.press("opt+space")
        try await settle { h.controller.ghosts?.loading == false }
        h.press("ctrl+return")
        #expect(tour.finished && tour.elapsedText.contains(":"))
        // Every step was a real edit: undo walks them back.
        #expect(h.undo.stack.canUndo)
    }

    @Test func wrongKeyCoachesWithoutAdvancing() {
        let (h, tour) = start()
        h.type("Trip")
        h.press("return")
        #expect(tour.lesson == 1)
        h.press("return")
        #expect(tour.step == 0)
        if case .wrong(let s) = tour.coach {
            #expect(s.contains("⌘Z"))
        } else {
            Issue.record("expected a wrong-key coach")
        }
        h.press("esc")
        h.press("cmd+z")
        h.press("tab")
        #expect(tour.step == 1 && tour.coach == .success)
    }

    @Test func pauseResumeSkipAndEnd() {
        let (h, tour) = start()
        tour.pause()
        h.type("Ignored")
        h.press("return")
        #expect(tour.lesson == 0, "paused tours don't follow keys")
        tour.resume()
        tour.skipLesson()
        #expect(tour.lesson == 1 && tour.coach == .prompt)
        for _ in 0..<5 { tour.skipLesson() }
        #expect(tour.finished)
        var ended = false
        h.controller.onTourEnded = { _ in ended = true }
        tour.end()
        #expect(ended && h.controller.tour == nil)
    }

    @Test(arguments: Role.allCases) func everyRoleConvertsToItsType(_ role: Role) {
        let (h, tour) = start(role)
        h.type("Start")
        h.press("return")
        for _ in 0..<3 { tour.skipLesson() }
        h.press("tab")
        h.type("Next")
        h.press("return")
        h.press("opt+cmd+t")
        #expect(h.canvas.type == role.tourConversion, "\(role)")
        #expect(h.canvas.validate().isEmpty)
    }
}
