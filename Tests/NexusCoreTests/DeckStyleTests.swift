import Testing

@testable import NexusCore

/// Present, part 4 (M42): deck styles, depth, overviews, the camera rule, starting from a
/// topic, and what a slide builds.
@Suite struct DeckStyleTests {
    /// Launch plan › Positioning › Developers › (Survey, Interviews); Pricing › Free tier.
    func sample() -> (Canvas, [String: NodeID]) {
        var c = Canvas(id: "c1", title: "", rootText: "Launch plan")
        var undo = UndoStack()
        var ids: [String: NodeID] = [:]
        c.edit("x", undo: &undo) { e in
            let pos = try! e.addChild(of: e.canvas.root, text: "Positioning")
            let dev = try! e.addChild(of: pos, text: "Developers")
            ids["survey"] = try! e.addChild(of: dev, text: "Survey")
            _ = try! e.addChild(of: dev, text: "Interviews")
            ids["teams"] = try! e.addChild(of: pos, text: "Teams")
            let pricing = try! e.addChild(of: e.canvas.root, text: "Pricing")
            ids["free"] = try! e.addChild(of: pricing, text: "Free tier")
            ids["pos"] = pos
            ids["dev"] = dev
            ids["pricing"] = pricing
        }
        return (c, ids)
    }

    @Test func settingsReadAndWriteOnlyWhatChanged() throws {
        var s = PresentationSettings()
        #expect(s.style == "dynamic" && s.depth == "main" && !s.overview && s.isDefault)
        #expect(s.json == [:], "the defaults aren't written")
        s.style = "calm"
        s.depth = "all"
        s.overview = true
        #expect(s.json == ["style": "calm", "depth": "all", "overview": true])
        #expect(try PresentationSettings(json: s.json, path: "p") == s)
        // A deck from before M42 reads as Dynamic, with its transition kept.
        let old = try PresentationSettings(json: ["transition": "zoom"], path: "p")
        #expect(old.style == "dynamic" && old.transition == "zoom")
    }

    /// Cut always cuts; Calm keeps Glide; Zoom and the other styles fly.
    @Test func cameraMoveFollowsStyleAndTransition() {
        var s = PresentationSettings()
        #expect(s.cameraMove == "fly")
        s.style = "calm"
        #expect(s.cameraMove == "glide")
        s.transition = "zoom"
        #expect(s.cameraMove == "fly")
        s.transition = "cut"
        #expect(s.cameraMove == "cut")
        s.style = "showtime"
        #expect(s.cameraMove == "cut")
    }

    /// Main topics, as before; Every branch walks topics with children in outline order,
    /// each framed with its parent; Overviews go between branches.
    @Test func depthAndOverviews() {
        var (c, ids) = sample()
        #expect(
            Deck.slides(c).map(\.id) == [
                "title", "branch:\(ids["pos"]!.rawValue)", "branch:\(ids["pricing"]!.rawValue)",
            ])
        c.presentation.depth = "all"
        let all = Deck.slides(c)
        #expect(
            all.map(\.id) == [
                "title", "branch:\(ids["pos"]!.rawValue)", "branch:\(ids["dev"]!.rawValue)",
                "branch:\(ids["pricing"]!.rawValue)",
            ])
        #expect(all[2].focus.first == ids["pos"] && all[2].highlight == [ids["dev"]!] && all[2].title == "Developers")
        #expect(all[2].focus.contains(ids["survey"]!) && !all[2].focus.contains(ids["teams"]!))
        c.presentation.overview = true
        let withOverview = Deck.slides(c).map(\.id)
        #expect(withOverview[3] == "overview:\(ids["pos"]!.rawValue)" && withOverview.count == 5, "none after the last")
        // Saved orders, skips and merges keep working across depths.
        c.presentation.skipped = ["branch:\(ids["dev"]!.rawValue)"]
        #expect(Deck.slides(c)[2].skipped)
        // Flow decks ignore depth.
        var flow = c
        flow.type = .flowchart
        #expect(Deck.slides(flow).allSatisfy { $0.id == "title" || $0.id.hasPrefix("flow:") })
    }

    /// ⌥⌘P starts at the selection's own slide, or its nearest ancestor's.
    @Test func startsFromTheSelectedTopic() {
        var (c, ids) = sample()
        let main = Deck.slides(c)
        #expect(Deck.index(for: ids["survey"]!, in: main, canvas: c) == 1, "Positioning's slide")
        #expect(Deck.index(for: ids["free"]!, in: main, canvas: c) == 2)
        #expect(Deck.index(for: c.root, in: main, canvas: c) == 0)
        c.presentation.depth = "all"
        let all = Deck.slides(c)
        #expect(Deck.index(for: ids["survey"]!, in: all, canvas: c) == 2, "Developers' slide")
        c.presentation.skipped = ["branch:\(ids["dev"]!.rawValue)"]
        #expect(Deck.index(for: ids["survey"]!, in: Deck.slides(c), canvas: c) == 1, "a skipped slide isn't a start")
    }

    /// A branch slide builds the topics under its focus; title and overview slides don't.
    @Test func buildsAreTheBranchUnderTheFocus() {
        var (c, ids) = sample()
        c.presentation.depth = "all"
        c.presentation.overview = true
        let s = Deck.slides(c)
        #expect(Deck.builds(s[0], in: c).isEmpty)
        #expect(Deck.builds(s[1], in: c).map { c.nodes[$0]!.text } == ["Developers", "Survey", "Interviews", "Teams"])
        #expect(Deck.builds(s[2], in: c).map { c.nodes[$0]!.text } == ["Survey", "Interviews"])
        #expect(s[3].id.hasPrefix("overview:") && Deck.builds(s[3], in: c).isEmpty)
    }
}
