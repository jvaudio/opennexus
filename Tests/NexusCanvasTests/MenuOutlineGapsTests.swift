import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

/// M33: the gaps M26 left. An image pasted from the empty-canvas menu lands at the pointer,
/// the outline's menu offers the popover items (they open on the row), and outline rows
/// have VoiceOver custom actions.
extension ContextMenuTests {
    func pngData(width: Int, height: Int) throws -> Data {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: An image pasted at the pointer (D253)

    @Test func emptyCanvasPasteOfAnImageMakesAFloatingTopic() throws {
        let (a, _) = try harness()
        let (b, _) = try harness()
        b.controller.pasteboard = a.controller.pasteboard
        let pb = a.controller.pasteboard
        pb.clearContents()
        pb.setData(try pngData(width: 400, height: 300), forType: .png)
        let pricing = node(a, "Pricing")
        a.controller.select(pricing)
        let at = CGPoint(x: -1800, y: -1200)
        let paste = try #require(item(menu(a, at: at), "Paste"))
        #expect((paste.representedObject as? MenuActionBox)?.action == .pasteHere(at))
        let floating = a.canvas.floating.count
        let depth = a.undo.stack.undoStack.count
        choose(paste)
        #expect(a.canvas.floating.count == floating + 1)
        let top = try #require(a.canvas.floating.last)
        let n = try #require(a.canvas.nodes[top])
        #expect(n.position == CanvasPoint(x: -1800, y: -1200) && n.text.isEmpty && n.children.isEmpty)
        #expect(n.image?.width == 200 && n.image?.height == 150, "200 pt wide at most, as ⌘V sizes it")
        #expect(n.image.map { a.store.model.assets[$0.asset] != nil } == true, "the image is in the package")
        #expect(a.canvas.nodes[pricing]?.image == nil, "the selected topic is left alone")
        #expect(a.controller.selection == Selection(top) && a.undo.stack.undoStack.count == depth + 1)

        // ⌘V still puts it on the selected topic.
        let channels = node(b, "Channels")
        b.controller.select(channels)
        let bFloating = b.canvas.floating.count
        #expect(b.controller.perform(.paste))
        #expect(b.canvas.nodes[channels]?.image?.width == 200 && b.canvas.floating.count == bFloating)
    }

    // MARK: Popovers from the outline (D254, D255)

    func outlineRow(_ doc: OutlineDocumentView, _ id: NodeID) throws -> OutlineDocumentView.Row {
        doc.relayout(width: 560)
        return try #require(doc.rows.first { $0.id == id && ($0.kind == .topic || $0.kind == .title) })
    }

    @Test func outlinePopoverItemsOpenOnTheRow() throws {
        let (h, _) = try harness()
        let o = outline(h)
        let doc = o.document
        var shown: [NSMenu] = []
        doc.presentContextMenu = { menu, _ in shown.append(menu) }
        let popovers = try #require(h.host.canvasView.popovers)
        var anchored: [(NSView, CGRect)] = []
        popovers.present = { _, rect, view in anchored.append((view, rect)) }
        // Outline view: the canvas is hidden.
        h.host.canvasView.isHidden = true
        func rightClick(_ id: NodeID) throws -> NSMenu {
            let r = try outlineRow(doc, id)
            doc.rightMouseDown(
                with: rowEvent(h, doc, CGPoint(x: r.textRect.minX + 4, y: r.rect.midY), .rightMouseDown))
            return try #require(shown.last)
        }
        let teams = node(h, "Teams")
        let m = try rightClick(teams)
        #expect(
            titles(m.items.first { $0.title == "Insert" }?.submenu) == [
                "Note", "Hyperlink…", "Image…", "Label", "Markers…", "Sticker…", "-", "Comment…", "Task…", "To-Do",
            ])
        #expect(
            item(m, "Note")?.keyEquivalent == "n" && item(m, "Note")?.keyEquivalentModifierMask == [.shift, .command])
        #expect(item(m, "Note")?.target === doc && item(m, "Sticker…")?.target === doc)
        // Each popover hangs from the row's text, not from the hidden canvas.
        for t in ["Note", "Hyperlink…", "Label", "Markers…", "Sticker…", "Comment…"] {
            choose(item(try rightClick(teams), t))
            let (view, rect) = try #require(anchored.last)
            let r = try outlineRow(doc, teams)
            #expect(view === doc && rect.origin == r.textRect.origin && rect.height == r.textRect.height, "\(t)")
            #expect(rect.width > 0 && rect.width < r.textRect.width, "\(t) points at the text, not across the row")
        }
        #expect(anchored.count == 6 && h.controller.selection == Selection(teams))
        // Image… asks for a file in an open panel (not run here); it's the Image… command.
        #expect((item(m, "Image…")?.representedObject as? String) == CommandID.image.rawValue)

        // Closing gives the outline its focus back, and the key opens on the row too.
        popovers.close()
        #expect(h.window.firstResponder === doc && h.controller.outlineFocused)
        h.press("shift+cmd+n")
        #expect(anchored.count == 7 && anchored.last?.0 === doc)

        // Several rows: Label and Markers… are offered, and hang from the primary row.
        let pricing = node(h, "Pricing")
        let channels = node(h, "Channels")
        h.controller.setSelection(Selection(primary: pricing, nodes: [pricing, channels]))
        let multi = try rightClick(channels)
        #expect(item(multi, "Markers…") != nil)
        choose(item(multi, "Label"))
        let primaryRow = try outlineRow(doc, pricing)
        #expect(anchored.last?.0 === doc && anchored.last?.1.minY == primaryRow.textRect.minY)

        // Split view: the row while the outline has focus, the topic while the canvas has.
        h.host.canvasView.isHidden = false
        h.controller.select(teams)
        h.window.makeFirstResponder(doc)
        #expect(h.controller.perform(.note) && anchored.last?.0 === doc)
        h.window.makeFirstResponder(h.host.canvasView)
        #expect(!h.controller.outlineFocused && h.controller.perform(.note))
        let (canvasView, rect) = try #require(anchored.last)
        #expect(canvasView === h.host.canvasView && rect == h.host.canvasView.viewRect(of: teams))
        popovers.close()
        #expect(h.window.firstResponder === h.host.canvasView)

        // A row the outline doesn't show (under a fold) falls back to the canvas.
        h.controller.select(pricing)
        #expect(h.controller.perform(.fold))
        let free = node(h, "Free tier")
        #expect(doc.popoverAnchor(free) == nil && doc.popoverAnchor(pricing) != nil)
        o.removeFromSuperview()
    }

    // MARK: VoiceOver on outline rows (D256)

    @Test func outlineRowsHaveVoiceOverActions() throws {
        let (h, _) = try harness()
        let o = outline(h)
        let doc = o.document
        let popovers = try #require(h.host.canvasView.popovers)
        var anchored: [NSView] = []
        popovers.present = { _, _, view in anchored.append(view) }
        h.host.canvasView.isHidden = true
        func row(_ label: String) throws -> MenuRowElement {
            doc.relayout(width: 560)
            let rows = doc.accessibilityChildren() as? [MenuRowElement] ?? []
            return try #require(rows.first { $0.accessibilityLabel() == label })
        }
        func names(_ label: String) throws -> [String] {
            try row(label).accessibilityCustomActions()?.map(\.name) ?? []
        }
        func run(_ name: String, on label: String) throws -> Bool {
            let a = try #require(try row(label).accessibilityCustomActions()?.first { $0.name == name }, "\(name)")
            return a.handler?() ?? false
        }

        // The canvas topic's own actions where the row's menu has them, then the rest of it.
        let pricing = try names("Pricing")
        #expect(Array(pricing.prefix(5)) == ["Edit", "Add child", "Add sibling", "Comments", "Fold"])
        for t in [
            "Add Parent Topic", "Note", "Hyperlink…", "Image…", "Label", "Markers…", "Sticker…", "Task…", "To-Do",
            "Indent", "Move Up", "Move Down", "Cut", "Copy", "Duplicate Branch", "Format Panel", "Delete",
            "Delete, Keep Children",
        ] {
            #expect(pricing.contains(t), "\(t) is an action")
        }
        for t in [
            "Outdent", "Edit Topic", "Add Child Topic", "Add Sibling After", "Comment…", "Fold / Unfold Branch",
            "Connect from here", "Callout", "Mind Map", "Insert", "Export Branch",
        ] {
            #expect(!pricing.contains(t), "\(t) isn't an action here")
        }
        #expect(Set(pricing).count == pricing.count)
        #expect(!(try names("Developers")).contains("Fold"), "a leaf has nothing to fold")
        let title = try names("Launch plan")
        for t in ["Add sibling", "Delete", "Cut", "Indent"] {
            #expect(!title.contains(t), "\(t) on the title row")
        }

        // An action runs on its own row, whatever is selected, with the outline focused.
        let teams = node(h, "Teams")
        h.controller.select(node(h, "Channels"))
        h.window.makeFirstResponder(h.host.canvasView)
        #expect(try run("Edit", on: "Teams"))
        #expect(h.controller.mode == .edit && h.controller.edit?.node == teams && h.controller.outlineFocused)
        #expect(h.window.firstResponder === doc.editor)
        h.controller.commitEdit()
        #expect(try run("Note", on: "Teams"))
        #expect(anchored.last === doc && h.controller.selection == Selection(teams))
        #expect(try run("Comments", on: "Teams") && anchored.count == 2)

        // Window commands go up the responder chain, as the menu's do.
        let panel = FormatPanelStandIn()
        h.window.nextResponder = panel
        #expect(try run("Format Panel", on: "Teams") && panel.open)

        // Commands are one undo step each, and equal their keys.
        var depth = h.undo.stack.undoStack.count
        #expect(try run("Duplicate Branch", on: "Risks"))
        #expect(h.canvas.nodes[h.canvas.root]?.children.filter { h.text($0) == "Risks" }.count == 2)
        #expect(h.undo.stack.undoStack.count == depth + 1)
        let mains = h.canvas.nodes[h.canvas.root]?.children ?? []
        let channels = node(h, "Channels")
        let before = try #require(mains.firstIndex(of: channels).map { mains[$0 - 1] })
        depth = h.undo.stack.undoStack.count
        #expect(try run("Indent", on: "Channels"))
        #expect(h.canvas.parent(of: channels) == before && h.undo.stack.undoStack.count == depth + 1)
        #expect(try run("Fold", on: "Pricing"))
        let folded = try names("Pricing")
        #expect(h.canvas.nodes[node(h, "Pricing")]?.folded == true && folded.contains("Unfold"))
        o.removeFromSuperview()
    }
}
