import AppKit
import Foundation
import NexusCore
import NexusFormat
import NexusKeys
import NexusTheme
import SwiftUI
import Testing

@testable import NexusCanvas

/// Present, part 4 (M42): the fly-to path, builds and Showtime, the new keys, Present from
/// Selected Topic, notes in PowerPoint, and fly-to frame times.
@MainActor
@Suite(.serialized) struct PresentMotionTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    // MARK: Fly-to

    /// The path starts and ends on the two views, rises over the map for a long move, and
    /// zooms in place when the centre doesn't move.
    @Test func flyPathRisesAndLands() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let a = Camera(offset: CGPoint(x: 0, y: 0), zoom: 1)
        let b = Camera(offset: CGPoint(x: -6000, y: -400), zoom: 1.2)
        let path = FlyPath(from: a, to: b, in: bounds)
        func close(_ x: Camera, _ y: Camera) -> Bool {
            abs(x.zoom - y.zoom) < 1e-3 && abs(x.offset.x - y.offset.x) < 0.5 && abs(x.offset.y - y.offset.y) < 0.5
        }
        #expect(close(path.camera(at: 0, in: bounds), a) && close(path.camera(at: 1, in: bounds), b))
        let mid = path.camera(at: 0.5, in: bounds)
        #expect(mid.zoom < 0.5, "a long move pulls back: \(mid.zoom)")
        // The centre only moves forward.
        let xs = stride(from: 0.0, through: 1.0, by: 0.05).map { path.at(CGFloat($0)).center.x }
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0.0 <= $0.1 + 1e-6 })
        // A short hop barely leaves the map.
        let near = FlyPath(from: a, to: Camera(offset: CGPoint(x: -80, y: 0), zoom: 1), in: bounds)
        #expect(near.camera(at: 0.5, in: bounds).zoom > 0.9)
        // Zoom in place.
        let zoomIn = FlyPath(
            from: Camera(offset: .zero, zoom: 1), to: Camera(offset: CGPoint(x: -800, y: -500), zoom: 2), in: bounds)
        #expect(abs(zoomIn.at(0.5).center.x - 800) < 1e-3 && abs(zoomIn.camera(at: 1, in: bounds).zoom - 2) < 1e-3)
        // The tween follows it, and ends exactly on the target.
        let tween = CameraTween(from: a, to: b, start: 0, duration: Motion.fly, fly: (path, bounds))
        #expect(tween.value(at: Motion.fly / 2).0.zoom < 0.5 && tween.value(at: Motion.fly).0 == b)
    }

    // MARK: Builds and Showtime

    func presenting(_ style: String, reduce: Bool = false) -> CanvasHarness {
        var doc = launchPlanDocument()
        doc.canvases["c1"]!.presentation.style = style
        let h = CanvasHarness(model: doc)
        h.host.canvasView.reduceMotionOverride = reduce
        h.press("shift+cmd+p")
        h.press("right")
        return h
    }

    /// Dynamic builds a branch slide's topics in, with their lines drawing on; Showtime also
    /// enlarges the focus topic; Calm builds nothing; Reduce Motion only cross-fades.
    @Test func buildsFollowTheStyle() throws {
        let h = presenting("dynamic")
        let v = h.host.canvasView
        let slide = h.controller.slides[1]
        #expect(v.builtSlideID == slide.id)
        let dev = node(h, "Developers")
        #expect(v.nodeLayer(dev)?.animation(forKey: "present.pop") != nil)
        #expect(v.nodeLayer(dev)?.animation(forKey: "present.fade") != nil)
        #expect(v.nodeLayer(node(h, "Pricing"))?.animation(forKey: "present.pop") == nil, "only this branch")
        #expect(h.controller.scene.nodes[node(h, "Pricing")]?.blurred == true, "the spotlight blurs the rest")
        #expect(v.showtimeFocusID == nil)

        let s = presenting("showtime")
        let pos = node(s, "Positioning")
        #expect(s.host.canvasView.showtimeFocusID == pos)
        #expect(s.host.canvasView.nodeLayer(pos)?.animation(forKey: "present.showtime") != nil)
        #expect(s.controller.scene.nodes[pos]?.glow == true)
        s.press("esc")
        #expect(s.host.canvasView.showtimeFocusID == nil && s.host.canvasView.builtSlideID == nil)

        let c = presenting("calm")
        #expect(c.host.canvasView.nodeLayer(node(c, "Developers"))?.animation(forKey: "present.pop") == nil)
        #expect(c.controller.scene.nodes[node(c, "Pricing")]?.blurred == false, "Calm dims without blurring")

        let r = presenting("dynamic", reduce: true)
        let rl = r.host.canvasView.nodeLayer(node(r, "Developers"))
        #expect(rl?.animation(forKey: "present.fade")?.duration == Motion.reducedCrossFade)
        #expect(rl?.animation(forKey: "present.pop") == nil)
    }

    // MARK: Keys

    /// B and W blank the screen until the next key; digits then ↩ jump; O shows the whole map.
    @Test func blankJumpAndOverview() {
        let h = presenting("dynamic")
        h.press("b")
        #expect(h.controller.present?.blank == "black")
        h.press("w")
        #expect(h.controller.present?.blank == "white", "the other letter switches")
        h.press("right")
        #expect(h.controller.present?.blank == nil && h.controller.present?.index == 1, "any key brings it back")
        h.press("4")
        #expect(h.controller.present?.typed == "4")
        h.press("return")
        #expect(h.controller.present?.index == 3 && h.controller.present?.typed == "")
        h.press("return")
        #expect(h.controller.present?.index == 4, "↩ alone still steps")
        h.press("o")
        #expect(h.controller.present?.overview == true)
        #expect(h.controller.scene.nodes.values.allSatisfy { !$0.blurred }, "the overview shows it all")
        h.press("esc")
        #expect(h.controller.present?.overview == false && h.controller.present != nil, "Esc leaves the overview first")
        h.controller.presentClick()
        #expect(h.controller.present?.index == 5, "a click steps")
    }

    /// A blank screen takes the next key before the strip's focused control does; F or ?
    /// drop digits typed for a jump.
    @Test func blankComesFirstAndTypedDigitsDrop() {
        let h = presenting("dynamic")
        h.press("tab")
        #expect(h.controller.focusedStripControl != nil)
        let deck = h.canvas.presentation
        h.press("b")
        h.press("return")
        #expect(h.controller.present?.blank == nil && h.canvas.presentation == deck, "↩ only brings the slide back")
        h.press("esc")
        h.press("4")
        h.press("f")
        #expect(h.controller.present?.typed == "" && h.controller.present?.stageOnly == true)
        let index = h.controller.present?.index ?? 0
        h.press("return")
        #expect(h.controller.present?.index == index + 1, "↩ steps; the 4 is gone")
    }

    /// Esc ends on the slide's topic, selected; ⌥⌘P starts from the selection.
    @Test func escEndsOnTheTopicAndOptCmdPStartsThere() {
        let h = presenting("calm")
        h.press("right")
        let pricing = node(h, "Pricing")
        h.press("esc")
        #expect(h.controller.present == nil && h.controller.selection.primary == pricing)
        h.controller.select(node(h, "Newsletter"))
        h.press("opt+cmd+p")
        #expect(h.controller.present?.index == 3 && h.controller.slides[3].title == "Channels")
        #expect(h.controller.registry[.presentFromTopic] != nil)
        #expect(h.controller.bindings(for: .presentFromTopic).first?.glyphs == "⌥⌘P")
    }

    /// Style, depth and overviews from the strip, as edits.
    @Test func stripSetsStyleDepthAndOverviews() {
        let h = presenting("dynamic")
        h.controller.chooseStripMenu("style", "showtime")
        #expect(h.canvas.presentation.style == "showtime")
        h.controller.activateStripControl("style")
        #expect(h.canvas.presentation.style == "calm", "↩ steps to the next choice")
        h.controller.activateStripControl("depth")
        #expect(h.canvas.presentation.depth == "all")
        h.controller.activateStripControl("overview")
        #expect(h.canvas.presentation.overview)
        h.undo.undo(h.store)
        #expect(!h.canvas.presentation.overview)
        #expect(h.controller.stripMenuChoices("style").map(\.0) == ["calm", "dynamic", "showtime"])
    }

    // MARK: Exports

    /// Topic notes become the slides' speaker notes; a deck without notes has none.
    @Test func pptxCarriesSpeakerNotes() throws {
        let img = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )?.makeImage())
        let plain = SlideExporter.pptx([img, img], titles: ["A", "B"])
        #expect(!ViewsTests.zipEntries(plain).contains { $0.contains("notes") })
        let deck = SlideExporter.pptx(
            [img, img, img], titles: ["A", "B", "C"], notes: [nil, "Say <this> & that\nThen this", ""])
        let names = ViewsTests.zipEntries(deck)
        #expect(names.contains("ppt/notesMasters/notesMaster1.xml") && names.contains("ppt/theme/theme2.xml"))
        #expect(
            names.filter { $0.hasPrefix("ppt/notesSlides/notesSlide") }.sorted() == ["ppt/notesSlides/notesSlide2.xml"])
        #expect(names.contains("ppt/notesSlides/_rels/notesSlide2.xml.rels"))
    }

    /// A masked PowerPoint export masks the slides' titles and speaker notes, as it does
    /// the slides.
    @Test func maskedPptxMasksTitlesAndNotes() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.controller.perform("Owner") { e in
            e.update(pricing) {
                $0.text = "Pricing for dana.ruiz@example.com"
                $0.note = Note(text: "Ask dana.ruiz@example.com")
            }
        }
        var s = ExportState.remembered(.powerpoint)
        s.format = .powerpoint
        func text(_ s: ExportState) throws -> String {
            let files = try Zip.read(try #require(h.controller.exportData(s)))
            return files.filter { $0.key.hasSuffix(".xml") }.values.map { String(decoding: $0, as: UTF8.self) }
                .joined()
        }
        s.mask = false
        #expect(try text(s).contains("dana.ruiz@example.com"), "the test has something to mask")
        s.mask = true
        #expect(try !text(s).contains("dana.ruiz@example.com"))
    }

    // MARK: Fly-to frame times

    /// Each fly-to frame's main-thread work (camera, culling, text scale, commit) with the
    /// spotlight on: median under 8.3 ms on 1,000 topics and 16.7 ms on 5,000.
    @Test func flyToFrameTimes() {
        for (doc, budget) in [
            (bigDocument(mains: 10, subs: 10, leaves: 9), 8.3), (bigDocument(mains: 20, subs: 25, leaves: 9), 16.7),
        ] {
            let h = CanvasHarness(model: doc)
            let v = h.host.canvasView
            v.reduceMotionOverride = true
            h.window.orderFrontRegardless()
            h.press("shift+cmd+p")
            h.press("right")
            CATransaction.flush()
            let from = v.camera
            h.controller.goToSlide(h.controller.slides.count - 1)
            let to = v.camera
            let path = FlyPath(from: from, to: to, in: v.bounds)
            let clock = ContinuousClock()
            var frames: [Duration] = []
            for i in 0...42 {
                let c = path.camera(at: CGFloat(i) / 42, in: v.bounds)
                frames.append(
                    clock.measure {
                        v.setCamera(c, animated: false)
                        CATransaction.flush()
                    })
            }
            let m = ms(median(frames))
            #expect(m < budget, "\(doc.topicCount) topics: median fly-to frame \(m) ms")
        }
    }

    /// For review (NEXUS_SNAPSHOT_DIR): a branch slide's resting frame in each style, a
    /// deeper slide, and the presenter view.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func styleSnapshots() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        func write(_ img: CGImage?, _ name: String) throws {
            let rep = NSBitmapImageRep(cgImage: try #require(img))
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "m42-\(name).png"))
        }
        for style in PresentationSettings.styles {
            var doc = launchPlanDocument()
            doc.canvases["c1"]!.presentation.style = style
            doc.canvases["c1"]!.nodes[doc.canvases["c1"]!.root]!.children.first.map {
                doc.canvases["c1"]!.nodes[$0]!.markers = ["star-red"]
            }
            try write(
                SlideExporter.renderSlide(doc, canvas: "c1", index: 1, size: CGSize(width: 1280, height: 720)), style)
        }
        var deep = launchPlanDocument()
        deep.canvases["c1"]!.presentation.depth = "all"
        deep.canvases["c1"]!.presentation.overview = true
        try write(
            SlideExporter.renderSlide(deep, canvas: "c1", index: 2, size: CGSize(width: 1280, height: 720)), "overview")
        let h = CanvasHarness(model: launchPlanDocument())
        h.press("shift+cmd+p")
        h.press("right")
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered,
            defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(
            rootView: PresenterView(controller: h.controller).background(Color(nsColor: .windowBackgroundColor)))
        w.layoutIfNeeded()
        w.orderFrontRegardless()
        // The cards draw their slides in tasks, which need the main actor free.
        try await Task.sleep(for: .seconds(2))
        if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "m42-presenter.png"))
        }
        w.orderOut(nil)
    }
}
