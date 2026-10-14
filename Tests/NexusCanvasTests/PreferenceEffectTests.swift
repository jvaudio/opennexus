import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import NexusAI
@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusKeys
@testable import NexusTheme

/// M8: every setting takes effect live. Each test flips a preference on a real canvas
/// and checks the behaviour changed.
@MainActor
@Suite(.serialized) struct PreferenceEffectTests {
    func node(_ h: CanvasHarness, _ t: String) -> NodeID { h.canvas.nodes.first { $0.value.text == t }!.key }
    var prefs: (CanvasHarness) -> Preferences { { $0.controller.prefs } }

    @Test func typingModesAndNewTopicText() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.controller.select(pricing)
        h.type("Q")
        h.press("return")
        #expect(h.text(pricing) == "Q", "replaces by default")
        h.controller.prefs.set("editing.typing", "append")
        h.type("X")
        h.press("return")
        #expect(h.text(pricing) == "QX", "appends")
        // New topics: placeholder by type, generic, or empty.
        h.controller.prefs.set("editing.placeholderText", "generic")
        h.press("tab")
        #expect(h.controller.edit?.text == "Subtopic")
        h.press("esc")
        h.controller.prefs.set("editing.newTopic", "empty")
        h.controller.select(pricing)
        h.press("tab")
        #expect(h.controller.edit?.text == "")
        h.press("return")
        #expect(h.text(h.controller.selection.primary) == "Subtopic", "an empty new topic keeps its default")
    }

    @Test func slashMenuAndUMLFormatting() {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.select(node(h, "Risks"))
        h.press("tab")
        h.controller.editorTextDidChange("/")
        h.controller.updateSlashFromEditor("/")
        #expect(h.controller.slash != nil)
        h.controller.prefs.set("editing.slashEmpty", false)
        h.controller.updateSlashFromEditor("/d")
        #expect(h.controller.slash == nil)
        h.controller.editorTextDidChange("+name:String")
        h.controller.commitEdit()
        #expect(h.text(h.controller.selection.primary) == "+ name: String")
        h.controller.prefs.set("editing.umlFormat", false)
        #expect(CanvasController.formatUMLMember("-id :Int") == "- id: Int")
    }

    @Test func canvasLookFollowsSettings() {
        let h = CanvasHarness(model: launchPlanDocument())
        let p = h.controller.prefs
        p.set("appearance.background", "plain")
        #expect(h.controller.scene.grid == .none)
        p.set("appearance.background", "lines")
        if case .lines = h.controller.scene.grid {} else { Issue.record("expected lines grid") }
        // Minimum text at 100%.
        let pro = node(h, "Pro")
        let before = h.controller.scene.nodes[pro]!.textStyle.fontSize
        p.set("appearance.minText", "14")
        p.set("accessibility.minText", "16")
        #expect(h.controller.scene.nodes[pro]!.textStyle.fontSize == 16 && before < 16)
        // Selection ring and reflow animation.
        p.set("accessibility.ring", "4")
        h.controller.select(pro)
        #expect(NodeLayer.ringWidth == 4)
        p.set("appearance.animations", "off")
        #expect(!h.controller.animateReflow && h.controller.reduceMotionPreference == true)
        p.set("accessibility.reduceMotion", "off")
        p.set("appearance.animations", "full")
        #expect(h.controller.reduceMotionPreference == nil || h.controller.reduceMotionPreference == false)
        // Adapt text colour off keeps the theme's ink.
        p.set("appearance.adaptText", false)
        #expect(!h.controller.styleEnvironment.adaptText)
    }

    @Test func followSystemAndZenThemes() {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.systemIsDark = true
        h.controller.prefs.set("appearance.followSystem", true)
        #expect(h.controller.scene.theme.isDark, "Classic follows the system to its dark pair")
        h.controller.prefs.set("appearance.followSystem", false)
        #expect(!h.controller.scene.theme.isDark)
        h.controller.prefs.set("appearance.zen", "ultraDark")
        h.controller.toggleZen()
        #expect(h.controller.scene.theme.id == "skeletonDark")
        h.controller.toggleZen()
        #expect(h.controller.zenToday >= 0)
    }

    @Test func pointerSettings() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let p = h.controller.prefs
        #expect(!h.controller.scrollZooms && h.controller.rightDragPans && h.controller.dragToFloat)
        p.set("editing.scroll", "zoom")
        p.set("editing.snapDistance", 12.0)
        p.set("editing.gridSize", 16.0)
        #expect(h.controller.scrollZooms && h.controller.snapDistance == 12 && h.controller.gridSnap == 16)
        p.set("editing.snapGrid", false)
        #expect(h.controller.gridSnap == nil)
        // Double-click on empty canvas: a floating topic, or nothing.
        p.set("editing.doubleClick", "nothing")
        let count = h.canvas.nodes.count
        click(h, at: CGPoint(x: 30, y: 30), count: 2)
        #expect(h.canvas.nodes.count == count)
        p.set("editing.doubleClick", "floating")
        click(h, at: CGPoint(x: 30, y: 30), count: 2)
        #expect(h.canvas.nodes.count == count + 1)
        // Scroll-wheel zoom with a mouse wheel.
        let z = h.host.canvasView.camera.zoom
        scroll(h, dy: 3)
        #expect(h.host.canvasView.camera.zoom != z)
    }

    func click(_ h: CanvasHarness, at p: CGPoint, count: Int) {
        let v = h.host.canvasView
        let w = v.convert(p, to: nil)
        for i in 1...count {
            let e = NSEvent.mouseEvent(
                with: .leftMouseDown, location: w, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
                context: nil,
                eventNumber: 0, clickCount: i, pressure: 1)!
            v.mouseDown(with: e)
        }
    }

    func scroll(_ h: CanvasHarness, dy: Int32) {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        cg.location = h.window.convertPoint(toScreen: CGPoint(x: 400, y: 400))
        let e = NSEvent(cgEvent: cg)!
        h.host.canvasView.scrollWheel(with: e)
    }

    @Test func writingSettingsReachTheEditor() {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.prefs.set("general.spelling", false)
        h.controller.prefs.set("general.smartQuotes", true)
        h.controller.select(node(h, "Pro"))
        h.press("space")
        let ed = h.host.canvasView.editor
        #expect(!ed.isContinuousSpellCheckingEnabled && ed.isAutomaticQuoteSubstitutionEnabled)
    }

    @Test func shortcutsApplyLive() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        var c = h.controller.keyCustomization
        c.record(.addChild, chord: try #require(KeyChord("ctrl+cmd+k")), registry: .standard)
        h.controller.keyCustomization = c
        #expect(h.controller.command(for: KeyChord("ctrl+cmd+k")!) == .addChild)
        let before = h.canvas.nodes.count
        h.controller.select(node(h, "Pro"))
        h.press("ctrl+cmd+k")
        #expect(h.canvas.nodes.count == before + 1)
        h.press("esc")
        // Vim profile: typing no longer replaces, h/j/k/l move.
        h.controller.prefs.set("shortcuts.profile", "vim")
        #expect(h.controller.command(for: KeyChord("j")!) == .selectDown)
    }

    @Test func hyperViaRightOption() {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        h.controller.prefs.set("shortcuts.hyperKey", "rightOption")
        func flags(_ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0,
                windowNumber: h.window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_RightOption))!
        }
        v.flagsChanged(with: flags(.option))
        #expect(v.hyperHeld)
        // ✦J opens the AI panel.
        h.press("j")
        #expect(h.controller.aiPanelVisible)
        v.flagsChanged(with: flags([]))
        #expect(!v.hyperHeld)
        // A tap alone is Esc (here, it closes nothing and changes nothing).
        v.flagsChanged(with: flags(.option))
        v.flagsChanged(with: flags([]))
        // Sticky: tap, release, then the key.
        h.controller.prefs.set("accessibility.stickyHyper", true)
        h.controller.toggleAIPanel()
        v.flagsChanged(with: flags(.option))
        v.flagsChanged(with: flags([]))
        #expect(v.hyperSticky)
        h.press("j")
        #expect(h.controller.aiPanelVisible && !v.hyperSticky)
    }

    @Test func tipsAndEmptyHints() {
        let h = CanvasHarness(model: DocumentModel.blank())
        #expect(h.controller.showsEmptyHints)
        h.controller.noteMouseUse(.addChild)
        h.controller.noteMouseUse(.addChild)
        #expect(h.controller.tip == nil)
        h.controller.noteMouseUse(.addChild)
        #expect(h.controller.tip == Tip(keys: "⇥", does: "adds a child topic"))
        h.press("tab")
        #expect(h.controller.tip == nil && !h.controller.showsEmptyHints, "a key press clears both")
        h.controller.prefs.set("general.tips", false)
        for _ in 0..<5 { h.controller.noteMouseUse(.fold) }
        #expect(h.controller.tip == nil)
    }

    @Test func exportDefaultsFramesAndMasking() throws {
        let h = CanvasHarness(model: launchPlanDocument())
        let p = h.controller.prefs
        p.set("export.scale", "1")
        p.set("export.markdown", "bullets")
        p.set("export.frame", "gradientMat")
        p.set("export.aspect", "1:1")
        let s = ExportState.remembered(.png, prefs: p)
        #expect(s.image.scale == 1 && !s.markdown.headings && s.image.frame == "gradientMat")
        let img = try #require(ImageExporter.image(h.store.model, canvas: "c1", s.image))
        #expect(img.width == img.height, "padded out to 1:1")
        // Masking: Always masks the exported copy; the document is unchanged.
        let pro = node(h, "Pro")
        h.controller.select(pro)
        h.controller.beginEditing(replacingWith: "Pro · billing@acme.io")
        h.controller.commitEdit()
        p.set("export.masking", "always")
        var md = ExportState.remembered(.markdown, prefs: p)
        md.image.scope = .canvas
        let text = try #require(h.controller.exportText(md))
        #expect(!text.contains("billing@acme.io") && text.contains("Pro · ••••"))
        #expect(h.text(pro) == "Pro · billing@acme.io")
        // Strip AI provenance and chats.
        p.set("export.stripAI", true)
        h.store.commitDocument("AI", focus: "c1") { $0.canvases["c1"]!.nodes[pro]!.ai = true }
        #expect(h.controller.exportModel(md).canvases["c1"]!.nodes[pro]!.ai == false)
    }

    @Test func aiReadsNotesOnlyWhenAllowed() {
        let h = CanvasHarness(model: launchPlanDocument())
        let pricing = node(h, "Pricing")
        h.store.commitDocument("Note", focus: "c1") {
            $0.canvases["c1"]!.nodes[pricing]!.note = Note(text: "Secret pricing note")
        }
        #expect(h.controller.request(.ideas, anchor: pricing).outline.contains("Secret pricing note"))
        h.controller.prefs.set("privacy.aiReadNotes", false)
        #expect(!h.controller.request(.ideas, anchor: pricing).outline.contains("Secret pricing note"))
    }

    @Test func newDocumentDefaults() {
        let p = Preferences.isolated()
        p.set("appearance.theme", "graphite")
        p.set("appearance.nodeStyle", "capsule")
        p.set("editing.defaultStructure", "logic.right")
        p.set("editing.newCanvasLayout", "free")
        let d = CanvasController.newDocumentModel(prefs: p)
        let c = d.orderedCanvases[0]
        #expect(
            c.style.theme == "graphite" && c.style.nodeStyle == "capsule" && c.layout.structure == .logicRight
                && c.layout.mode == .free)
        // "Use last": the look of the last closed document wins.
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.prefs = p
        h.store.commitDocument("Look", focus: "c1") { $0.canvases["c1"]!.style.theme = "paper" }
        h.controller.rememberLook()
        p.set("editing.useLast", true)
        #expect(CanvasController.newDocumentModel(prefs: p).orderedCanvases[0].style.theme == "paper")
    }

    @Test func mouseAidsShowAndHide() {
        let h = CanvasHarness(model: launchPlanDocument())
        let v = h.host.canvasView
        h.controller.select(node(h, "Pricing"))
        v.refreshOverlays()
        #expect(v.subviews.contains { String(describing: type(of: $0)).contains("AddTopicButton") && !$0.isHidden })
        h.controller.prefs.set("editing.addButtons", false)
        v.refreshOverlays()
        #expect(!v.subviews.contains { String(describing: type(of: $0)).contains("AddTopicButton") && !$0.isHidden })
        // The floating toolbar after a second click on the selected topic.
        h.controller.prefs.set("editing.floatingToolbar", "click")
        v.toolbarFor = h.controller.selection.primary
        v.refreshOverlays()
        #expect(
            v.subviews.contains { String(describing: type(of: $0)).contains("FloatingToolbarView") && !$0.isHidden })
        h.press("down")
        #expect(
            !v.subviews.contains { String(describing: type(of: $0)).contains("FloatingToolbarView") && !$0.isHidden },
            "keys hide it")
    }
}
