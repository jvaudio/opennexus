import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import Testing
import UIKit

@testable import NexusTouch

extension HostedTests {
    /// A6 and A7's touch half, through the handlers the gesture recognizers call (XCUITest
    /// covers the recognizers themselves in F1): tap, double-tap, drag to reparent with its
    /// drop target, the band, pinch, two-finger pan, the long-press menu, Pencil hover and
    /// Scribble; the VoiceOver tree; Connect mode, ⌘K and ⌘J; and A8's panels and modes.
    @MainActor
    @Suite(.serialized) struct TouchTests {
        /// The sample map, laid out in a 1032 × 800 canvas.
        func harness() -> TouchHarness {
            let h = TouchHarness(model: nodeStyleSampleDocument(theme: "classic", style: "soft"))
            h.view.update(animated: false)
            return h
        }

        func node(_ h: TouchHarness, _ text: String) -> NodeID {
            h.canvas.nodes.first { $0.value.text == text }!.key
        }

        func center(_ h: TouchHarness, _ id: NodeID) -> CGPoint {
            let r = h.view.viewRect(of: id)!
            return CGPoint(x: r.midX, y: r.midY)
        }

        @Test func tapSelectsAndDoubleTapEdits() {
            let h = harness()
            let pricing = node(h, "Pricing")
            h.view.tap(at: center(h, pricing), count: 1, modifiers: [])
            #expect(h.controller.selection.primary == pricing)
            #expect(h.controller.mode == .select)
            h.view.tap(at: center(h, pricing), count: 2, modifiers: [])
            #expect(h.controller.edit?.node == pricing, "a double-tap edits the topic")
        }

        @Test func dragReparentsWithADropTarget() {
            let h = harness()
            let channels = node(h, "Channels")
            let pricing = node(h, "Pricing")
            let from = center(h, channels)
            let to = center(h, pricing)
            for i in 1...10 {
                let t = CGFloat(i) / 10
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                h.view.drag(i == 1 ? .began : .changed, from: from, to: p, modifiers: [])
            }
            #expect(h.view.showsDropTarget, "the halo shows around the target")
            h.view.drag(.ended, from: from, to: to, modifiers: [])
            #expect(h.canvas.parent(of: channels) == pricing, "dropping on Pricing reparents Channels")
        }

        @Test func aBandSelectsWhatItEncloses() {
            let h = harness()
            let devs = node(h, "Devs")
            let teams = node(h, "Teams")
            let box = h.view.viewRect(of: devs)!.union(h.view.viewRect(of: teams)!).insetBy(dx: -12, dy: -12)
            let end = CGPoint(x: box.maxX, y: box.maxY)
            h.view.drag(.began, from: box.origin, to: CGPoint(x: box.midX, y: box.midY), modifiers: [])
            h.view.drag(.changed, from: box.origin, to: end, modifiers: [])
            h.view.drag(.ended, from: box.origin, to: end, modifiers: [])
            #expect(h.controller.selection.nodes == [devs, teams])
        }

        @Test func pinchZoomsAroundTheFingersAndTwoFingersPan() {
            let h = harness()
            let p = CGPoint(x: 600, y: 300)
            let before = h.view.camera.toWorld(p)
            let zoom = h.view.camera.zoom
            h.view.zoom(by: 1.5, around: p)
            #expect(abs(h.view.camera.zoom - zoom * 1.5) < 0.001)
            let after = h.view.camera.toWorld(p)
            #expect(abs(after.x - before.x) < 0.5 && abs(after.y - before.y) < 0.5, "the point under the fingers stays")
            let offset = h.view.camera.offset
            h.view.pan(by: CGPoint(x: 40, y: -25))
            #expect(h.view.camera.offset == CGPoint(x: offset.x + 40, y: offset.y - 25))
        }

        @Test func aLongPressOpensTheRegistrysMenu() throws {
            let h = harness()
            let timeline = node(h, "Timeline")
            let menu = UIContextMenuInteraction(delegate: h.view)
            let config = h.view.contextMenuInteraction(menu, configurationForMenuAtLocation: center(h, timeline))
            #expect(config != nil)
            #expect(h.controller.selection.primary == timeline, "a long press selects first, as a right-click does")
            let titles = h.controller.contextMenu(for: .topic(timeline)).flatMap(\.items).map(\.title)
            #expect(titles.contains("Add Child Topic"))
        }

        @Test func pencilHoverShowsTheFoldControl() {
            let h = harness()
            let positioning = node(h, "Positioning")
            h.view.hover(at: center(h, positioning))
            #expect(h.view.foldHover == positioning)
            h.view.hover(at: nil)
            #expect(h.view.foldHover == nil)
        }

        @Test func scribbleWritesIntoATopic() throws {
            let h = harness()
            let channels = node(h, "Channels")
            let scribble = UIIndirectScribbleInteraction(delegate: h.view)
            var found: [NodeID] = []
            h.view.indirectScribbleInteraction(scribble, requestElementsIn: h.view.viewRect(of: channels)!) {
                found = $0
            }
            #expect(found.contains(channels))
            var input: (any UIResponder & UITextInput)?
            h.view.indirectScribbleInteraction(scribble, focusElementIfNeeded: channels, referencePoint: .zero) {
                input = $0
            }
            #expect(h.controller.edit?.node == channels, "writing over a topic edits it")
            let editor = try #require(input as? UITextView)
            editor.selectedRange = NSRange(location: 0, length: (editor.text as NSString).length)
            editor.insertText("Partners")
            h.controller.commitEdit()
            #expect(h.canvas.nodes[channels]?.text == "Partners")
        }

        @Test func voiceOverReadsAndActsOnTheCanvas() throws {
            let h = harness()
            let items = (h.view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
            let labels = items.compactMap(\.accessibilityLabel)
            #expect(labels.first?.hasPrefix("Launch plan. ") == true, "the central topic first")
            #expect(labels.contains { $0.hasPrefix("Pricing. ") })
            let pricing = try #require(items.first { $0.accessibilityLabel?.hasPrefix("Pricing. ") == true })
            #expect(pricing.accessibilityActivate())
            #expect(h.controller.selection.primary == node(h, "Pricing"))
            let actions = pricing.accessibilityCustomActions ?? []
            let add = try #require(actions.first { $0.name == "Add child" })
            let before = h.canvas.nodes[node(h, "Pricing")]!.children.count
            _ = add.actionHandler?(add)
            #expect(h.canvas.nodes[node(h, "Pricing")]!.children.count == before + 1)
        }

        @Test func connectPaletteAndJumpFromAHardwareKeyboard() {
            let h = harness()
            h.controller.select(node(h, "Pricing"))
            h.key("shift+cmd+l")
            #expect(h.controller.connect != nil, "⇧⌘L starts Connect mode")
            h.key("esc")
            #expect(h.controller.connect == nil)
            h.key("cmd+k")
            #expect(h.controller.palette != nil)
            h.key("esc")
            h.key("cmd+j")
            #expect(h.controller.jump != nil, "⌘J opens Quick Jump")
        }

        @Test func thePanelsAndModesOpen() {
            let h = harness()
            h.controller.select(node(h, "Positioning"))
            #expect(h.controller.perform(.focusBranch))
            #expect(h.controller.focusRoot == node(h, "Positioning"))
            #expect(h.controller.perform(.focusBranch))
            #expect(h.controller.focusRoot == nil)
            #expect(h.controller.perform(.zen))
            #expect(h.controller.zen)
            #expect(h.controller.perform(.zen))
            #expect(h.controller.perform(.filterBar))
            #expect(h.controller.filterBarVisible)
            #expect(h.controller.perform(.find))
            #expect(h.controller.navTab == 1, "find opens the navigation panel's search")
            #expect(h.controller.perform(.aiPanel))
            #expect(h.controller.aiPanelVisible)
            for (id, mode) in [
                (CommandID.showOutline, CanvasViewMode.outline), (.showSplit, .split), (.showGantt, .gantt),
            ] {
                #expect(h.controller.perform(id))
                #expect(h.controller.viewMode == mode)
            }
            h.controller.viewMode = .canvas
            #expect(h.controller.perform(.present))
            #expect(h.controller.present != nil)
            h.view.tap(at: CGPoint(x: 500, y: 400), count: 1, modifiers: [])
            #expect(h.controller.present?.index == 1, "a tap advances the presentation")
        }

        /// The rest of A8: ⌘I opens and closes the Format inspector (the screen shows it beside
        /// the canvas), AI ghosts arrive and one is accepted, and a scan becomes a map: a page
        /// made into a PDF as `DocumentScanner` makes the camera's pages, read as the screen
        /// reads it. The camera itself isn't in the Simulator.
        @Test func theInspectorGhostsAndAScanWork() async throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "a8-\(UUID().uuidString).nexus")
            try await TouchDocument.create(at: url, model: nodeStyleSampleDocument(theme: "classic", style: "soft"))
                .close()
            let doc = TouchDocument(fileURL: url)
            #expect(await doc.open())
            let screen = TouchDocumentModel(document: doc)
            let shown = screen.inspectorVisible
            #expect(screen.canvasView.handle(KeyChord("cmd+i")!, characters: "i"))
            #expect(screen.inspectorVisible == !shown)
            #expect(screen.canvasView.handle(KeyChord("cmd+i")!, characters: "i"))
            #expect(screen.inspectorVisible == shown)
            await doc.close()

            let h = harness()
            h.controller.ai = ScriptedEngine()
            let channels = node(h, "Channels")
            h.controller.select(channels)
            #expect(h.controller.perform(.aiGhosts))
            for _ in 0..<200 where h.controller.ghosts?.loading != false {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(h.controller.ghosts?.ideas.map(\.text) == ["Idea one", "Idea two", "Idea three"])
            #expect(h.canvas.nodes[channels]?.children.isEmpty == true, "ghosts aren't in the map")
            #expect(h.controller.perform(.aiAccept))
            #expect(h.canvas.nodes[channels]?.children.map(h.text) == ["Idea one"])

            let page = UIGraphicsImageRenderer(size: CGSize(width: 850, height: 1100)).image { _ in
                UIColor.white.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 850, height: 1100))
                let lines: [(String, CGFloat, CGFloat, CGFloat)] = [
                    ("Garden plan", 44, 80, 80), ("Vegetables", 30, 80, 190), ("Tomatoes", 24, 140, 250),
                    ("Beans", 24, 140, 300), ("Flowers", 30, 80, 400), ("Tulips", 24, 140, 460),
                ]
                for (text, size, x, y) in lines {
                    (text as NSString).draw(
                        at: CGPoint(x: x, y: y),
                        withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: size > 40 ? .bold : .regular)])
                }
            }
            let pdf = try #require(DocumentScanner.Coordinator.pdf([page]))
            let canvases = h.store.model.canvasOrder.count
            h.controller.importImage(pdf, name: "Scan.pdf")
            for _ in 0..<1000 where h.store.model.canvasOrder.count == canvases {
                try await Task.sleep(for: .milliseconds(10))
            }
            let scanned = try #require(h.store.model.canvasOrder.last.flatMap { h.store.model.canvases[$0] })
            let texts = Set(scanned.nodes.values.map(\.text))
            let expected: Set = ["Garden plan", "Vegetables", "Tomatoes", "Beans", "Flowers", "Tulips"]
            #expect(texts.isSuperset(of: expected), "\(texts)")
            let vegetables = try #require(scanned.nodes.first { $0.value.text == "Vegetables" }?.value)
            #expect(vegetables.children.compactMap { scanned.nodes[$0]?.text } == ["Tomatoes", "Beans"])
        }
    }
}
