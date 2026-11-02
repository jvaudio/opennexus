import NexusCanvas
import NexusCore
import NexusKeys
import NexusLayout
import NexusScene
import SwiftUI
import Testing
import UIKit

@testable import NexusTouch
@testable import OpenNexus

extension HostedTests {
    /// M47c, the iPhone's compact layout, through the model and the views the screen hosts:
    /// Outline first and technical diagrams fitted (A2, A7), the bottom toolbar and More
    /// (A3), Quick Capture from the widgets' link (A4), comments and the AI panel (A5),
    /// Present's swipes and the presenter view with an external display (A6), and the
    /// one-finger pan (A7). They set compact width themselves, so they pass on the iPad too.
    @MainActor
    @Suite(.serialized) struct CompactTests {
        /// A document on disk with the sample map and, optionally, the API flow starter as a
        /// second canvas, opened as the screen opens it, at compact width.
        func screen(withFlowchart: Bool = false, size: CGSize = CGSize(width: 402, height: 672)) async throws
            -> TouchDocumentModel
        {
            var model = nodeStyleSampleDocument(theme: "classic", style: "soft")
            if withFlowchart {
                var flow = try #require(StarterLibrary.starter("apiFlow")).document(prefs: .shared).orderedCanvases[0]
                flow.id = "c2"
                model = DocumentModel(canvases: [model.orderedCanvases[0], flow])
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "m47c-\(UUID().uuidString).nexus")
            try await TouchDocument.create(at: url, model: model).close()
            let doc = TouchDocument(fileURL: url)
            #expect(await doc.open())
            let m = TouchDocumentModel(document: doc)
            for v in [m.canvasView, m.outlineView] as [UIView] {
                v.frame = CGRect(origin: .zero, size: size)
                v.layoutIfNeeded()
            }
            m.setCompact(true)
            return m
        }

        /// The document's screen in a window of the running app, at compact width.
        func show(_ m: TouchDocumentModel) async throws -> UIWindow {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = UIHostingController(
                rootView: TouchDocumentScreen(model: m).environment(\.horizontalSizeClass, .compact))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            return window
        }

        func node(_ c: CanvasController, _ text: String) -> NodeID {
            c.canvas.nodes.first { $0.value.text == text }!.key
        }

        /// Every topic's frame on the canvas, inside the view less the fit's margins.
        func allTopicsShow(_ m: TouchDocumentModel) -> Bool {
            let v = m.canvasView
            let room = v.bounds.inset(by: v.fitInsets).insetBy(dx: -1, dy: -1)
            return m.controller.canvas.nodes.keys.allSatisfy { id in v.viewRect(of: id).map(room.contains) ?? false }
        }

        @Test func aMapOpensInTheOutlineAndADiagramInTheCanvasFitted() async throws {
            let m = try await screen(withFlowchart: true)
            #expect(m.compact)
            #expect(m.viewMode == .outline, "a mind map opens in the Outline")
            #expect(m.compactMode == .outline)
            #expect(m.outlineView.compact && m.canvasView.compactTouch)

            // The canvas toggle, and back.
            m.setViewMode(.canvas)
            #expect(m.viewMode == .canvas && m.compactMode == .canvas)
            m.setViewMode(.outline)

            // The title menu's other canvas, a flowchart: the canvas, fitted, and refitted
            // when the phone turns.
            m.switchCanvas(to: "c2")
            #expect(m.controller.canvas.type == .flowchart)
            #expect(m.viewMode == .canvas, "a technical diagram opens in the canvas")
            m.canvasView.layoutIfNeeded()
            #expect(allTopicsShow(m), "fitted to the screen, clear of the chrome at its foot")
            m.canvasView.frame = CGRect(x: 0, y: 0, width: 874, height: 300)
            m.canvasView.layoutIfNeeded()
            #expect(allTopicsShow(m), "refitted in landscape")

            // A new step from the bottom toolbar.
            let steps = m.controller.canvas.nodes.count
            m.controller.select(m.controller.canvas.root)
            m.addTopic(child: true)
            m.controller.commitEdit()
            #expect(m.controller.canvas.nodes.count == steps + 1, "Add Child adds a step")
            m.switchCanvas(to: "c1")
            #expect(m.viewMode == .outline)

            // Split isn't offered at compact width: an iPad window narrowing turns it into
            // the Outline.
            m.setCompact(false)
            m.setViewMode(.split)
            m.setCompact(true)
            #expect(m.viewMode == .outline)
            await m.document.close()
        }

        @Test func theBottomBarAddsTopicsAndMoreRunsCommands() async throws {
            let m = try await screen()
            let c = m.controller
            let pricing = node(c, "Pricing")
            c.select(pricing)
            m.addTopic(child: true)
            #expect(c.edit != nil, "Add Child edits the new topic")
            c.editorTextDidChange("Annual")
            m.addTopic(child: false)
            let kids = c.canvas.nodes[pricing]?.children.compactMap { c.canvas.nodes[$0]?.text }
            #expect(kids == ["Free", "Annual", "Subtopic"], "Add Sibling commits Annual and adds the next")
            #expect(c.edit?.node == c.canvas.nodes[pricing]?.children.last)
            c.commitEdit()

            // Style shows the Format panel (a sheet at compact width).
            let shown = m.inspectorVisible
            m.inspectorVisible.toggle()
            #expect(m.inspectorVisible != shown)
            m.inspectorVisible = shown

            // More: a mode, a window command, a request.
            m.run(.zen)
            #expect(c.zen)
            m.run(.zen)
            #expect(!c.zen)
            m.run(.export)
            #expect(c.exportState != nil, "Export… opens")
            c.closeExport()
            c.select(pricing)
            m.run(.comment)
            #expect(m.request?.request.node == pricing, "Comments opens the topic's thread")
            m.closeRequest()
            await m.document.close()
        }

        /// The title's menu: New Canvas opens the starter picker, as on the iPad, and the
        /// starter becomes a canvas; the menu switches canvases; Rename… renames the one
        /// showing, which the subtitle names.
        @Test func theTitleMenuAddsSwitchesAndRenamesCanvases() async throws {
            let m = try await screen(withFlowchart: true)
            let c = m.controller
            let before = c.store.model.canvasOrder
            m.addCanvas()
            if m.choosingStarter {
                m.choosingStarter = false
                _ = c.addCanvas(from: StarterLibrary.lastUsed(prefs: c.prefs))
            }
            let added = try #require(c.store.model.canvasOrder.first { !before.contains($0) })
            #expect(c.canvasID == added, "the new canvas shows")
            m.switchCanvas(to: "c2")
            #expect(c.canvasID == "c2")
            m.switchCanvas(to: added)
            m.runWindowCommand(.renameCanvas)
            #expect(m.renaming == added)
            m.renameText = "Risks"
            m.rename()
            #expect(c.canvas.title == "Risks")
            #expect(m.canvasName == "Risks")
            await m.document.close()
        }

        /// F1's start by touch in the Outline, on screen: the keyboard's bar adds a child and
        /// a sibling, and each new topic's text goes to that topic (the canvas once took the
        /// focus from off screen, and the text went to the topic before).
        @Test func theKeyboardsBarAddsTopicsInTheOutline() async throws {
            let m = try await screen()
            let window = try await show(m)
            defer { window.isHidden = true }
            let c = m.controller
            let o = m.outlineView
            let root = c.canvas.root
            o.tap(at: CGPoint(x: 100, y: 40))
            // The canvas, off screen, asking for the keyboard once the Outline shows (as its
            // deferred `takeKeyboard` did) leaves the Outline's focus alone.
            #expect(m.canvasView.window == nil)
            m.canvasView.takeKeyboard()
            #expect(c.outlineFocused)
            c.select(root)
            c.beginEditing(root)
            #expect(!o.editor.isHidden, "the Outline edits its own row")
            o.editor.selectAll(nil)
            o.editor.insertText("Launch plan")
            o.editor.addTopic(child: true)
            o.editor.insertText("Topic 1")
            o.editor.addTopic(child: false)
            o.editor.insertText("Topic 2")
            _ = o.editor.resignFirstResponder()
            #expect(c.canvas.nodes[root]?.text == "Launch plan")
            let kids = c.canvas.nodes[root]?.children.compactMap { c.canvas.nodes[$0]?.text } ?? []
            #expect(kids.suffix(2) == ["Topic 1", "Topic 2"], "\(kids)")
            await m.document.close()
        }

        @Test func theOutlineReadsCommentsAndOpensTheThread() async throws {
            let m = try await screen()
            let c = m.controller
            let pricing = node(c, "Pricing")
            c.addComment("Check the annual price", on: pricing)
            c.addComment("Agreed\nsecond line", on: pricing)
            m.outlineView.relayout()
            let row = try #require(m.outlineView.rows.first { $0.id == pricing && $0.kind == .comments })
            #expect(row.text.string.hasPrefix("2 comments · "))
            #expect(row.text.string.hasSuffix("Agreed"), "the latest comment's first line")
            let read = (m.outlineView.accessibilityElements ?? []).compactMap {
                ($0 as? UIAccessibilityElement)?.accessibilityLabel
            }
            #expect(read.contains(row.text.string), "VoiceOver reads the line")
            m.outlineView.tap(at: CGPoint(x: row.rect.midX, y: row.rect.midY))
            #expect(m.request?.request.node == pricing)
            #expect(c.selection.primary == pricing)

            // The iPhone's margins: a third level keeps most of the width.
            let deep = try #require(m.outlineView.rows.first { $0.depth == 2 })
            #expect(deep.textRect.width >= 300, "\(deep.textRect)")
            #expect(m.outlineView.rows.allSatisfy { $0.rect.maxX <= 402 })
            await m.document.close()
        }

        @Test func aOneFingerDragPansUnlessItStartsOnASelectedTopic() {
            let h = TouchHarness(
                model: nodeStyleSampleDocument(theme: "classic", style: "soft"), width: 402, height: 672)
            h.view.compactTouch = true
            h.view.update(animated: false)
            let channels = h.canvas.nodes.first { $0.value.text == "Channels" }!.key
            let pricing = h.canvas.nodes.first { $0.value.text == "Pricing" }!.key
            func center(_ id: NodeID) -> CGPoint {
                let r = h.view.viewRect(of: id)!
                return CGPoint(x: r.midX, y: r.midY)
            }
            func drag(_ from: CGPoint, _ to: CGPoint) {
                for i in 1...10 {
                    let t = CGFloat(i) / 10
                    let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                    h.view.drag(i == 1 ? .began : .changed, from: from, to: p, modifiers: [])
                }
                h.view.drag(.ended, from: from, to: to, modifiers: [])
            }

            // From an unselected topic: the canvas moves, the topic stays where it is.
            let before = h.view.camera.offset
            let start = center(channels)
            drag(start, CGPoint(x: start.x + 40, y: start.y + 90))
            #expect(h.view.camera.offset.x == before.x + 40 && h.view.camera.offset.y == before.y + 90)
            #expect(h.canvas.parent(of: channels) == h.canvas.root)
            #expect(h.controller.selection.primary != channels, "panning doesn't select")

            // From empty canvas: it pans rather than drawing a band.
            let selected = h.controller.selection
            let offset = h.view.camera.offset
            drag(CGPoint(x: 20, y: 640), CGPoint(x: 60, y: 600))
            #expect(h.view.camera.offset.x == offset.x + 40)
            #expect(h.controller.selection == selected)

            // From a selected topic: it moves, here onto Pricing.
            h.controller.select(channels)
            h.view.update(animated: false)
            drag(center(channels), center(pricing))
            #expect(h.canvas.parent(of: channels) == pricing)
        }

        /// A topic drawn smaller than a finger (a fitted diagram in landscape) takes a tap
        /// within its 44-point target, which is also its frame for VoiceOver (A8).
        @Test func aSmallTopicTakesATapNearIt() {
            let h = TouchHarness(
                model: nodeStyleSampleDocument(theme: "classic", style: "soft"), width: 874, height: 402)
            h.view.compactTouch = true
            h.view.setZoom(0.25)
            h.view.update(animated: false)
            let root = h.canvas.root
            let world = h.controller.scene.nodes[root]!.frame.rect
            let r = h.view.viewRect(of: root)!
            #expect(r.height < 30, "drawn small: \(r)")
            let target = h.view.touchTarget(world)
            #expect(abs(target.height - 44) < 0.01 && abs(target.midY - r.midY) < 0.01)

            let channels = h.canvas.nodes.first { $0.value.text == "Channels" }!.key
            h.controller.select(channels)
            let near = CGPoint(x: r.midX, y: r.minY - 6)
            #expect(!r.contains(near), "the finger is off the topic")
            h.view.tap(at: near, count: 1, modifiers: [])
            #expect(h.controller.selection.primary == root)

            // Without compact touch (the iPad's regular width), the same tap is on the canvas.
            h.view.compactTouch = false
            h.controller.select(channels)
            h.view.tap(at: near, count: 1, modifiers: [])
            #expect(h.controller.selection.primary != root)
        }

        @Test func presentSwipesAndTheIPhonesHint() async throws {
            let h = TouchHarness(
                model: nodeStyleSampleDocument(theme: "classic", style: "soft"), width: 402, height: 672)
            h.view.compactTouch = true
            #expect(h.controller.perform(.present))
            let mid = CGPoint(x: 300, y: 300)
            h.view.drag(.began, from: mid, to: mid, modifiers: [])
            h.view.drag(.ended, from: mid, to: CGPoint(x: 160, y: 310), modifiers: [])
            #expect(h.controller.present?.index == 1, "a swipe left goes on")
            h.view.drag(.began, from: mid, to: mid, modifiers: [])
            h.view.drag(.ended, from: mid, to: CGPoint(x: 420, y: 290), modifiers: [])
            #expect(h.controller.present?.index == 0, "a swipe right goes back")
            h.view.drag(.began, from: mid, to: mid, modifiers: [])
            h.view.drag(.ended, from: mid, to: CGPoint(x: 330, y: 320), modifiers: [])
            #expect(h.controller.present?.index == 0, "a short drag doesn't")

            // On the iPhone with no second display, a toast says how to reach a TV.
            ExternalDisplay.shared.disconnect()
            let m = try await screen()
            #expect(m.controller.perform(.present))
            #expect(m.controller.toast?.text.contains("Screen Mirroring") == true)
            m.controller.endPresent()
            await m.document.close()
        }

        /// A6: AirPlay's Screen Mirroring gives the app an external display scene; here a
        /// second window stands in for it. The canvas presents there and the phone shows the
        /// presenter view (its layout is the UI test's).
        @Test func presentingOverAirPlayShowsThePresenterViewOnThePhone() async throws {
            let m = try await screen()
            let phone = try await show(m)
            let tv = UIWindow(windowScene: phone.windowScene!)
            tv.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
            tv.rootViewController = UIHostingController(rootView: ExternalDisplayView())
            tv.isHidden = false
            defer {
                ExternalDisplay.shared.disconnect()
                ExternalDisplay.shared.presenting = nil
                phone.isHidden = true
                tv.isHidden = true
            }
            // The screen is up before presenting starts, as in the app.
            tv.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            ExternalDisplay.shared.connect()
            #expect(m.controller.perform(.present))
            #expect(m.presenting && m.presenterVisible)
            #expect(m.canvasPlace == .external)
            for _ in 0..<50 where m.canvasView.window !== tv {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(m.canvasView.window === tv, "the slides are on the external display")
            #expect(m.canvasView.window !== phone, "the phone shows the presenter view in its place")
            m.controller.stepSlide(1)
            #expect(m.controller.present?.index == 1)
            m.controller.endPresent()
            #expect(!m.presenting)
            await m.document.close()
        }

        /// A5: from the canvas too, a topic's thread and the AI panel are sheets at compact
        /// width.
        @Test func theCanvasOpensTheThreadAndTheAIPanelAsSheets() async throws {
            let m = try await screen()
            let c = m.controller
            let window = try await show(m)
            defer { window.isHidden = true }
            func sheet(_ shown: Bool) async throws -> Bool {
                for _ in 0..<100 where (window.rootViewController?.presentedViewController != nil) != shown {
                    try await Task.sleep(for: .milliseconds(20))
                }
                return window.rootViewController?.presentedViewController != nil
            }
            m.setViewMode(.canvas)
            let pricing = node(c, "Pricing")
            c.select(pricing)
            m.run(.comment)
            #expect(m.request?.request.node == pricing)
            #expect(try await sheet(true), "the thread is a sheet")
            m.closeRequest()
            #expect(try await !sheet(false))
            c.toggleAIPanel()
            #expect(try await sheet(true), "the AI panel is a sheet")
            c.toggleAIPanel()
            #expect(try await !sheet(false))
            await m.document.close()
        }

        /// A4: the widgets' link opens Quick Capture, whose idea lands in the Inbox.
        @Test func quickCaptureFromTheWidgetsLinkLandsInTheInbox() async throws {
            let scene = TouchScene()
            Integrations.shared.attach(scene)
            scene.handle(URL(string: "opennexus://inbox/add")!)
            let capture = try #require(scene.capture, "the link opens Quick Capture")
            #expect(capture.targets.current.url == nil, "the Inbox first")
            let idea = "Captured \(UUID().uuidString.prefix(6))"
            capture.text = idea
            capture.save()
            #expect(capture.saved != nil && capture.text.isEmpty, "saved, and ready for the next")
            #expect(scene.document == nil, "Home stays where it was")
            #expect(await IntegrationTests().inbox(waitingFor: idea).contains(idea))
            capture.onClose()
            #expect(scene.capture == nil)
        }
    }
}
