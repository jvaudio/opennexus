import AppKit
import Foundation
import NexusCore
import NexusFormat
import NexusKeys
import SwiftUI
import Testing

@testable import NexusCanvas

/// Guide mode (M41): the built-in guides, the panel's state in the controller, keys per
/// profile, the Type control, Start with Guide, and the budgets.
@MainActor
@Suite(.serialized) struct GuideTests {
    static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "schema/guide.schema.json")

    /// The first wave reads, matches the schema, is canonical, and quotes real commands.
    @Test func builtInGuidesReadAndQuoteRealCommands() throws {
        let guides = try GuideLibrary.load()
        #expect(guides.map(\.type) == [.architecture, .dfd, .flowchart, .mindmap, .threatModel])
        let schemaData = try Data(contentsOf: Self.schemaURL)
        #expect(CanonicalJSON.data(try CanonicalJSON.parse(schemaData)) == schemaData, "the schema is canonical")
        let validator = SchemaValidator(schema: try CanonicalJSON.parse(schemaData))
        let folder = try #require(GuideLibrary.folder)
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: url)
            let json = try CanonicalJSON.parse(data)
            #expect(validator.validate(json).isEmpty, "\(url.lastPathComponent): \(validator.validate(json))")
            #expect(CanonicalJSON.data(json) == data, "\(url.lastPathComponent) is canonical")
            #expect(json["id"] == .string(url.deletingPathExtension().lastPathComponent))
        }
        let registry = CommandRegistry.standard
        for g in guides {
            #expect(Set(g.steps.map(\.id)).count == g.steps.count, "\(g.id): step ids are unique")
            for s in g.steps {
                for part in GuideTip.parts(s.tip, key: { _ in "K" }, title: { _ in nil }) {
                    if case .text(let t) = part, t.hasPrefix("“"), t.contains(".") {
                        Issue.record("\(g.id).\(s.id) quotes an unknown command: \(t)")
                    }
                }
                let ids = s.tip.split(separator: "{").dropFirst().compactMap { $0.split(separator: "}").first }
                for id in ids { #expect(registry[CommandID(rawValue: String(id))] != nil, "\(g.id).\(s.id): \(id)") }
            }
        }
        #expect(!validator.validate(["id": "x", "type": "mindmap", "steps": []]).isEmpty, "steps can't be empty")
        #expect(
            !validator.validate([
                "id": "x", "type": "mindmap", "steps": [["id": "a", "match": ["colour": "red"], "title": "A"]],
            ]).isEmpty, "unknown match keys are typos")
    }

    /// Each guide starts at its first step on its type's Blank canvas. The DFD template has
    /// its processes, entities and stores, and leaves its flows to be labelled.
    @Test func guidesStartAtTheBeginningAndTemplatesFitThem() throws {
        for g in GuideLibrary.all {
            let blank = try #require(StarterLibrary.starter("blank.\(g.type.rawValue)")).document()
            let p = GuideMatcher.progress(blank.orderedCanvases[0], g)
            #expect(p.current == 0 && !p.complete, "\(g.id)")
        }
        let dfd = try #require(StarterLibrary.starter("dfd")).document().orderedCanvases[0]
        let guide = try #require(GuideLibrary.guide(for: .dfd))
        let p = GuideMatcher.progress(dfd, guide)
        #expect(p.steps.map(\.met) == [true, true, false, true, false])
        #expect(p.current == 2)
    }

    /// The guide and the AI panel share the trailing slot; ⌃⌘G toggles the guide.
    @Test func guideAndAIPanelShareTheSlot() {
        let h = CanvasHarness()
        h.controller.aiPanelVisible = true
        #expect(h.controller.perform(.guide))
        #expect(h.controller.guideVisible && !h.controller.aiPanelVisible)
        #expect(h.controller.guideProgress?.current == 0, "progress is ready when the panel opens")
        h.controller.toggleAIPanel()
        #expect(h.controller.aiPanelVisible && !h.controller.guideVisible && h.controller.guideProgress == nil)
        #expect(h.controller.registry[.guide]?.title == "Guide")
        #expect(h.controller.bindings(for: .guide).first?.glyphs == "⌃⌘G")
    }

    /// Progress follows typing on the next run-loop turn, and selection moves the current step.
    @Test func progressFollowsEditsAndSelection() async throws {
        let h = CanvasHarness()
        h.controller.guideVisible = true
        #expect(h.controller.guideProgress?.steps[0].met == false)
        h.press("space")
        h.type("Launch")
        h.press("return")
        h.press("tab")
        h.type("Goals")
        h.press("return")
        #expect(h.controller.guideUpdatePending, "matching waits for the next turn")
        try await Task.sleep(for: .milliseconds(50))
        let p = try #require(h.controller.guideProgress)
        #expect(p.steps[0].met && p.steps[1].count == 1 && p.current == 1, "the selected main topic's step")
        h.controller.select(h.canvas.root)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.guideProgress?.current == 0)
        // A step with a match selects it; one without says so.
        #expect(h.controller.selectGuideStep(1) && h.canvas.nodes[h.controller.selection.primary]?.text == "Goals")
        #expect(!h.controller.selectGuideStep(2))
    }

    /// Skip is one undo step, saved with the canvas.
    @Test func skipIsAnUndoableEdit() throws {
        let h = CanvasHarness()
        h.controller.guideVisible = true
        h.controller.toggleGuideSkip("main")
        #expect(h.controller.guideProgress?.steps[1].state == .skipped)
        let files = NexusPackage.files(for: h.store.model)
        let canvas = try CanonicalJSON.parse(try #require(files["canvases/c1.json"]))
        #expect(canvas["guide"] == ["id": "mindmap", "skipped": ["main"]])
        #expect(SchemaValidator.bundled.validate(package: files).isEmpty)
        h.undo.undo(h.store)
        h.controller.updateGuide()
        #expect(h.controller.guideProgress?.steps[1].state != .skipped && h.canvas.guide.isDefault)
    }

    /// Tips show the active profile's keys: Outliner adds a child with ⌥↩, not ⇥.
    @Test func tipsUseTheActiveProfilesKeys() {
        let h = CanvasHarness()
        let tip = "Press {topic.addChild}, then {diagram.suggestThreats}."
        let open = h.controller.guideTipParts(tip)
        #expect(open == [.text("Press "), .key("⇥"), .text(", then "), .text("“Suggest STRIDE Threats”"), .text(".")])
        h.controller.profile = .outliner
        #expect(h.controller.guideTipParts(tip)[1] == .key("⌥↩"))
        h.controller.profile = .vim
        #expect(h.controller.guideTipParts("{topic.addSiblingAfter}").first == .key("↩"))
    }

    /// The Data tab's Type sets the selection's node type in one undo step; Set Node Type…
    /// opens that tab.
    @Test func setNodeTypeIsOneStep() throws {
        let h = CanvasHarness(model: DocumentModel(canvases: [Canvas(id: "c1", title: "", type: .dfd, rootText: "C")]))
        h.press("tab")
        h.type("Customer")
        h.press("return")
        let id = h.controller.selection.primary
        #expect(DiagramCatalog.effectiveType(id, in: h.canvas) == .entity)
        h.controller.setNodeType(.store)
        #expect(h.canvas.nodes[id]?.nodeType == .store)
        h.undo.undo(h.store)
        #expect(h.canvas.nodes[id]?.nodeType == nil)
        var shown = false
        h.controller.onShowFormatPanel = { shown = true }
        #expect(h.controller.perform(.setNodeType))
        #expect(shown && UserDefaults.standard.string(forKey: "format.tab") == "data")
    }

    /// Start with Guide: on at first for a Blank starter with a guide, off for templates and
    /// types without one; remembered per starter.
    @Test func startWithGuideIsRememberedPerStarter() throws {
        let prefs = Preferences.isolated()
        func on(_ id: String) -> Bool {
            StarterLibrary.starter(id).map { StarterGallery.startsWithGuide($0, prefs: prefs) } ?? false
        }
        #expect(on("blank.dfd") && !on("dfd") && !on("blank.logic"))
        let g = StarterGallery(purpose: .canvas, prefs: prefs)
        g.selection = "blank.dfd"
        g.startsWithGuide = false
        g.selection = "dfd"
        g.startsWithGuide = true
        #expect(!on("blank.dfd") && on("dfd"))
        g.selection = "blank.logic"
        g.startsWithGuide = true
        #expect(!on("blank.logic"), "no guide, nothing to start")
    }

    /// Budgets on a 1,000-topic map (D297). Moving the selection only refocuses the cached
    /// evaluation: under 2 ms for every guide. An edit evaluates once, the turn after, reusing
    /// the scene's node types: under 2 ms for a mind map, and under a quarter of the scene
    /// rebuild it follows for the rest (the data flow guide also runs the rule checks).
    @Test func matchingBudgets() throws {
        let clock = ContinuousClock()
        let base = bigDocument(mains: 10, subs: 10, leaves: 9).orderedCanvases[0]  // 1,011 topics
        for g in GuideLibrary.all {
            var c = base
            c.type = g.type
            let h = CanvasHarness(model: DocumentModel(canvases: [c]))
            let types = DiagramCatalog.isTechnical(c.type) ? h.controller.scene.nodeTypes : nil
            let p = GuideMatcher.evaluate(c, g, types: types)
            let evaluate = median((0..<5).map { _ in clock.measure { _ = GuideMatcher.evaluate(c, g, types: types) } })
            let focus = median((0..<9).map { _ in clock.measure { _ = p.focused(on: c.root) } })
            let scene = median((0..<3).map { _ in clock.measure { h.controller.rebuildScene() } })
            #expect(ms(focus) < 2, "\(g.id): refocus \(ms(focus)) ms")
            if g.type == .mindmap {
                #expect(ms(evaluate) < 2, "mindmap: \(ms(evaluate)) ms")
            } else {
                #expect(ms(evaluate) < ms(scene) / 4, "\(g.id): \(ms(evaluate)) ms vs scene \(ms(scene)) ms")
            }
        }
    }

    /// The selection moving through a map reuses the evaluation: no matching per arrow key.
    @Test func selectionReusesTheEvaluation() throws {
        let h = CanvasHarness(model: bigDocument(mains: 4, subs: 3, leaves: 2))
        h.controller.guideVisible = true
        let key = try #require(h.controller.guideCache?.key)
        h.press("right")
        h.controller.updateGuide()
        #expect(h.controller.guideCache?.key == key && h.controller.guideProgress?.current == 1)
        h.press("tab")
        h.press("return")
        h.controller.updateGuide()
        #expect(h.controller.guideCache?.key != key, "an edit evaluates again")
    }

    /// Selecting a relationship or another element refocuses the guide too, as the topic
    /// selection does.
    @Test func selectingAnElementRefocuses() throws {
        let h = CanvasHarness(model: bigDocument(mains: 4, subs: 3, leaves: 2))
        h.controller.guideVisible = true
        h.press("right")
        h.controller.updateGuide()
        #expect(h.controller.guideProgress?.current == 1)
        h.controller.selectElement(.relationship("r1"))
        #expect(h.controller.guideUpdatePending)
        h.controller.updateGuide()
        let unfocused = try #require(h.controller.guideCache?.progress.focused(on: nil))
        #expect(h.controller.guideProgress == unfocused && unfocused.current != 1)
    }

    /// For review (NEXUS_SNAPSHOT_DIR): the panel on a half-made data flow, light, dark and in
    /// the pseudo-language, and the Format panel's Type control.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func panelSnapshots() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        func shoot(_ view: some View, _ name: String, size: CGSize, dark: Bool = false) {
            let w = NSWindow(
                contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = NSHostingView(rootView: view)
            w.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "m41-\(name).png"))
        }
        var c = Canvas(id: "c1", title: "", type: .dfd, rootText: "Context")
        var undo = UndoStack()
        c.edit("x", undo: &undo) { e in
            let shop = try! e.addChild(of: e.canvas.root, text: "Online shop")
            _ = try! e.addChild(of: shop, text: "Customer")
        }
        let h = CanvasHarness(model: DocumentModel(canvases: [c]))
        h.controller.guideVisible = true
        let size = CGSize(width: 320, height: 640)
        shoot(GuidePanelView(controller: h.controller), "guide-dfd", size: size)
        shoot(GuidePanelView(controller: h.controller), "guide-dfd-dark", size: size, dark: true)
        Loc.pseudo = true
        shoot(GuidePanelView(controller: h.controller), "guide-dfd-pseudo", size: size)
        Loc.pseudo = false
        let m = CanvasHarness()
        m.controller.guideVisible = true
        shoot(GuidePanelView(controller: m.controller), "guide-mindmap", size: CGSize(width: 320, height: 700))
        let t = CanvasHarness(
            model: DocumentModel(canvases: [Canvas(id: "c1", title: "", type: .threatModel, rootText: "Payments")]))
        t.controller.guideVisible = true
        shoot(GuidePanelView(controller: t.controller), "guide-threat", size: size)
        let logic = CanvasHarness(
            model: DocumentModel(canvases: [Canvas(id: "c1", title: "", type: .logic, rootText: "X")]))
        logic.controller.guideVisible = true
        shoot(GuidePanelView(controller: logic.controller), "guide-coming-soon", size: CGSize(width: 320, height: 300))
        h.controller.select(h.canvas.nodes[h.canvas.root]!.children[0])
        shoot(FormatPanel(controller: h.controller), "format-type", size: CGSize(width: 320, height: 500))
        let g = StarterGallery(purpose: .canvas, prefs: .isolated(), role: .security)
        g.selection = "blank.dfd"
        shoot(StarterGalleryView(model: g), "picker-guided", size: CGSize(width: 900, height: 600))
    }
}
