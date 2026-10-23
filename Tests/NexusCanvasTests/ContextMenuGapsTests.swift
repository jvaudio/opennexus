import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

/// M26: the context-menu gaps M17 left. Paste and Zone on empty canvas land where the menu
/// opened, Format Panel toggles with a checkmark, and the outline and the Gantt have menus.
extension ContextMenuTests {
    /// The document window's Format panel: ⌘I toggles it, and its menu item is checked
    /// while it's open (as `DocumentWindowController.validateMenuItem` does).
    final class FormatPanelStandIn: NSResponder, RegistryCommandTarget, NSMenuItemValidation {
        var open = false
        func performRegistryCommand(_ sender: Any?) {
            if (sender as? NSMenuItem)?.representedObject as? String == CommandID.inspector.rawValue { open.toggle() }
        }
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard (item.representedObject as? String) == CommandID.inspector.rawValue else { return false }
            item.state = open ? .on : .off
            return true
        }
    }

    /// Runs an item as AppKit would, whichever view it targets.
    func choose(_ item: NSMenuItem?) {
        guard let item, let action = item.action else {
            Issue.record("no item")
            return
        }
        #expect((item.target as? any NSMenuItemValidation)?.validateMenuItem(item) == true, "\(item.title) is enabled")
        NSApp.sendAction(action, to: item.target, from: item)
    }

    func subtreeRect(_ h: CanvasHarness, _ id: NodeID) -> CGRect {
        h.canvas.subtree(id).compactMap { h.controller.scene.nodes[$0]?.frame.rect }.reduce(CGRect.null) {
            $0.union($1)
        }
    }

    // MARK: Paste and Zone at the pointer (D222, D223)

    @Test func emptyCanvasPasteLandsAtThePointer() throws {
        let (a, ids) = try harness()
        let (b, _) = try harness()
        b.controller.pasteboard = a.controller.pasteboard
        let pricing = node(a, "Pricing")
        a.controller.select(pricing)
        a.controller.copySelection()
        let at = CGPoint(x: -1800, y: -1200)
        let m = menu(a, at: at)
        let paste = try #require(item(m, "Paste"))
        #expect(paste.action == #selector(CanvasView.performMenuAction(_:)))
        #expect((paste.representedObject as? MenuActionBox)?.action == .pasteHere(at))
        #expect(paste.keyEquivalent == "v" && paste.keyEquivalentModifierMask == [.command], "⌘V's key")
        let mains = a.canvas.nodes[a.canvas.root]?.children.count
        let floating = a.canvas.floating.count
        let depth = a.undo.stack.undoStack.count
        choose(paste)
        #expect(a.canvas.floating.count == floating + 1 && a.canvas.nodes[a.canvas.root]?.children.count == mains)
        let top = try #require(a.canvas.floating.last)
        #expect(a.text(top) == "Pricing" && a.canvas.nodes[top]?.children.count == 3)
        #expect(a.canvas.nodes[top]?.position == CanvasPoint(x: -1800, y: -1200), "the topic lands at the pointer")
        #expect(a.controller.selection == Selection(top) && a.undo.stack.undoStack.count == depth + 1)

        // ⌘V still pastes under the selection.
        b.controller.select(node(b, "Channels"))
        #expect(b.controller.perform(.paste))
        #expect(b.canvas.floating.count == floating && b.canvas.nodes[node(b, "Channels")]?.children.count == 3)

        // Several branches stack below the pointer without overlapping.
        a.controller.setSelection(Selection(primary: pricing, nodes: [pricing, node(a, "Channels")]))
        a.controller.copySelection()
        let below = CGPoint(x: -1800, y: 900)
        choose(item(menu(a, at: below), "Paste"))
        let pair = Array(a.canvas.floating.suffix(2))
        #expect(pair.map { a.text($0) } == ["Pricing", "Channels"] && a.controller.selection.nodes == pair)
        #expect(a.canvas.nodes[pair[0]]?.position == CanvasPoint(x: -1800, y: 900))
        #expect(a.canvas.nodes[pair[1]]?.position?.x == -1800)
        #expect(subtreeRect(a, pair[0]).maxY <= subtreeRect(a, pair[1]).minY, "stacked, not overlapping")
        #expect(a.undo.stack.undoStack.count == depth + 2, "one undo step")

        // One line of text becomes one floating topic there.
        a.controller.pasteboard.clearContents()
        a.controller.pasteboard.setString("Call the printer", forType: .string)
        choose(item(menu(a, at: CGPoint(x: -2600, y: 400)), "Paste"))
        let line = try #require(a.canvas.floating.last)
        #expect(a.text(line) == "Call the printer" && a.canvas.nodes[line]?.position == CanvasPoint(x: -2600, y: 400))

        // A copied zone lands with its top-left corner there.
        a.controller.copyZone(ids.zone)
        let zones = a.canvas.zones.count
        choose(item(menu(a, at: CGPoint(x: -2600, y: -1200)), "Paste"))
        let z = try #require(a.canvas.zones.last)
        #expect(a.canvas.zones.count == zones + 1 && z.origin == CanvasPoint(x: -2600, y: -1200))
        #expect(a.controller.selectedElement == .zone(z.id) && z.members.count == 1)
    }

    @Test func emptyCanvasZoneLandsAtThePointer() throws {
        let (a, _) = try harness()
        let (b, _) = try harness()
        let parking = node(a, "Parking lot")
        a.controller.select(parking)
        b.controller.select(parking)
        let at = CGPoint(x: -1800, y: -1200)
        let m = menu(a, at: at)
        #expect(a.controller.selection == Selection(parking), "right-clicking empty canvas keeps the topics")
        let zone = try #require(item(m, "Zone"))
        #expect((zone.representedObject as? MenuActionBox)?.action == .zoneHere(at))
        #expect(zone.keyEquivalent == "z" && zone.keyEquivalentModifierMask == [.option, .command], "⌥⌘Z's key")
        let depth = a.undo.stack.undoStack.count
        choose(zone)
        let z = try #require(a.canvas.zones.last)
        #expect(a.canvas.zones.count == 2 && z.origin == CanvasPoint(x: -1800, y: -1200) && z.members.isEmpty)
        #expect(a.controller.mode == .edit && a.controller.edit?.element == .zone(z.id), "its title opens")
        #expect(a.undo.stack.undoStack.count == depth + 1)
        a.controller.commitEdit()

        // ⌥⌘Z still wraps the selected floating topics.
        b.press("opt+cmd+z")
        #expect(b.canvas.zones.count == 2 && b.canvas.zones.last?.members == [parking])
        #expect(b.canvas.zones.last?.origin != CanvasPoint(x: -1800, y: -1200))
    }

    // MARK: Format Panel (D224)

    @Test func formatPanelItemTogglesWithACheckmark() throws {
        let (h, _) = try harness()
        let panel = FormatPanelStandIn()
        h.window.nextResponder = panel
        let pricing = node(h, "Pricing")
        func formatItem() throws -> NSMenuItem {
            let m = try #require(menu(h, at: center(h, pricing)))
            m.update()
            return try #require(item(m, "Format Panel"))
        }
        #expect(try formatItem().state == .off)
        choose(try formatItem())
        #expect(panel.open)
        #expect(try formatItem().state == .on, "checked while the panel is open")
        choose(try formatItem())
        #expect(!panel.open, "choosing it again closes the panel, as ⌘I does")
        #expect(try formatItem().state == .off)
    }

    // MARK: Outline (D225, D226)

    func outline(_ h: CanvasHarness) -> OutlineView {
        let outline = OutlineView(controller: h.controller)
        outline.frame = CGRect(x: 0, y: 0, width: 560, height: 800)
        h.window.contentView?.addSubview(outline)
        outline.layoutSubtreeIfNeeded()
        h.window.makeFirstResponder(outline.document)
        outline.document.relayout(width: 560)
        return outline
    }

    func rowEvent(
        _ h: CanvasHarness, _ view: NSView, _ p: CGPoint, _ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []
    )
        -> NSEvent
    {
        NSEvent.mouseEvent(
            with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func outlineMenuActsOnTheClickedRow() throws {
        let (h, _) = try harness()
        let o = outline(h)
        let doc = o.document
        var shown: [NSMenu] = []
        doc.presentContextMenu = { menu, _ in shown.append(menu) }
        func rightClick(_ id: NodeID, flags: NSEvent.ModifierFlags = []) throws -> NSMenu {
            doc.relayout(width: 560)
            let r = try #require(doc.rows.first { $0.id == id && ($0.kind == .topic || $0.kind == .title) })
            let p = CGPoint(x: r.textRect.minX + 4, y: r.rect.midY)
            if flags.isEmpty {
                doc.rightMouseDown(with: rowEvent(h, doc, p, .rightMouseDown))
            } else {
                doc.mouseDown(with: rowEvent(h, doc, p, .leftMouseDown, flags))
            }
            return try #require(shown.last)
        }
        let teams = node(h, "Teams")
        let devs = node(h, "Developers")
        h.controller.select(h.canvas.root)
        let m = try rightClick(teams)
        #expect(h.controller.selection == Selection(teams), "right-clicking a row selects it first")
        #expect(
            titles(m) == [
                "Add Child Topic", "Add Sibling After", "Add Sibling Before", "Add Parent Topic", "-", "Edit Topic",
                "Insert", "-", "Indent", "Outdent", "Move Up", "-", "Cut", "Copy", "Paste", "Duplicate Branch",
                "-", "Format Panel", "-", "Export Branch", "-", "Delete", "Delete, Keep Children",
            ])
        // Every item but Sticker… is a registry command with the canvas's title and key,
        // aimed at the outline.
        for it in allItems(m) where it.title != "Sticker…" {
            #expect(it.action == #selector(CanvasView.performRegistryCommand(_:)) && it.target === doc, "\(it.title)")
            let id = CommandID(rawValue: try #require(it.representedObject as? String))
            #expect(it.keyEquivalent == (h.controller.bindings(for: id).first?.key.keyEquivalent ?? ""), "\(it.title)")
        }
        #expect(item(m, "Indent")?.keyEquivalent == "\t", "the outline scope's Tab")

        // Running an item equals the key: Indent is Tab.
        let depth = h.undo.stack.undoStack.count
        choose(item(m, "Indent"))
        #expect(h.canvas.parent(of: teams) == devs && h.undo.stack.undoStack.count == depth + 1)
        h.press("shift+tab")
        #expect(h.canvas.parent(of: teams) == node(h, "Positioning"), "the outline's keys are unchanged")

        // Control-click opens the same menu; a leaf has no fold, the title row no delete.
        let positioning = node(h, "Positioning")
        let pm = titles(try rightClick(positioning, flags: [.control]))
        #expect(h.controller.selection == Selection(positioning) && pm.contains("Fold / Unfold Branch"))
        for t in ["Indent", "Outdent", "Move Up"] {
            #expect(!pm.contains(t), "\(t) on the first main topic")
        }
        #expect(pm.contains("Move Down"))
        let pricing = node(h, "Pricing")
        let root = titles(try rightClick(h.canvas.root))
        for t in ["Delete", "Cut", "Add Sibling After", "Indent", "Outdent", "Move Up"] {
            #expect(!root.contains(t), "\(t) on the title row")
        }
        // Add Child Topic opens the new row's editor.
        choose(item(try rightClick(pricing), "Add Child Topic"))
        #expect(h.controller.mode == .edit && h.canvas.parent(of: h.controller.edit!.node) == pricing)
        h.controller.commitEdit()

        // A row in a multi-selection keeps it and gets what acts on every row.
        let channels = node(h, "Channels")
        h.controller.setSelection(Selection(primary: pricing, nodes: [pricing, channels]))
        let multi = try rightClick(channels)
        #expect(h.controller.selection.nodes == [pricing, channels])
        #expect(
            titles(multi) == ["Cut", "Copy", "-", "Label", "Markers…", "To-Do", "-", "Format Panel", "-", "Delete"])
        choose(item(multi, "To-Do"))
        #expect(h.canvas.nodes[pricing]?.todo != nil && h.canvas.nodes[channels]?.todo != nil)

        // Format Panel goes to the window and shows its checkmark there.
        let panel = FormatPanelStandIn()
        h.window.nextResponder = panel
        let fm = try rightClick(teams)
        fm.update()
        #expect(item(fm, "Format Panel")?.state == .off)
        choose(item(fm, "Format Panel"))
        #expect(panel.open)

        // The menu bar's items (no target) aren't run by the outline: they go up the chain,
        // so a menu key never replaces the outline scope's own.
        let bar = NSMenuItem(
            title: "Add Child Topic", action: #selector(CanvasView.performRegistryCommand(_:)), keyEquivalent: "\t")
        bar.representedObject = CommandID.addChild.rawValue
        #expect(!doc.validateMenuItem(bar))
        let count = h.canvas.nodes.count
        doc.performRegistryCommand(bar)
        #expect(h.canvas.nodes.count == count)

        // VoiceOver: each row's Show Menu opens its menu.
        var popped: [(NSMenu, CGPoint)] = []
        doc.popUpMenu = { popped.append(($0, $1)) }
        let rows = doc.accessibilityChildren() as? [MenuRowElement] ?? []
        let devRow = try #require(rows.first { $0.accessibilityLabel() == "Developers" })
        #expect(devRow.accessibilityPerformShowMenu())
        #expect(h.controller.selection == Selection(devs) && popped.last?.0.items.first?.title == "Add Child Topic")
        #expect(doc.accessibilityPerformShowMenu() && popped.count == 2)
        o.removeFromSuperview()
    }

    // MARK: Gantt (D225, D226)

    func ganttHarness() -> CanvasHarness {
        let h = CanvasHarness(model: ganttDocument())
        h.controller.today = TaskDate("2026-11-04")!
        h.controller.onViewMode = { [weak h] m in
            h?.host.showGantt(m == .gantt)
            if m == .gantt { h?.host.ganttView.focus() } else { h?.window.makeFirstResponder(h?.host.canvasView) }
        }
        h.controller.viewMode = .gantt
        h.host.ganttView.layoutSubtreeIfNeeded()
        h.host.ganttView.surface.reload()
        return h
    }

    @Test func ganttMenuActsOnTheClickedRow() throws {
        let h = ganttHarness()
        let (b, s) = (ganttHarness(), h.host.ganttView.surface)
        var shown: [NSMenu] = []
        s.presentContextMenu = { menu, _ in shown.append(menu) }
        func point(_ id: NodeID?) throws -> CGPoint {
            s.reload()
            let L = try #require(s.layout)
            guard let id else { return CGPoint(x: s.visibleRect.minX + 40, y: L.rows.last!.frame.maxY + 120) }
            let r = try #require(L.rows.first { $0.id == id })
            return CGPoint(x: s.visibleRect.minX + 40, y: r.frame.midY)
        }
        func rightClick(_ id: NodeID?, flags: NSEvent.ModifierFlags = []) throws -> NSMenu {
            let p = try point(id)
            if flags.isEmpty {
                s.rightMouseDown(with: rowEvent(h, s, p, .rightMouseDown))
            } else {
                s.mouseDown(with: rowEvent(h, s, p, .leftMouseDown, flags))
            }
            return try #require(shown.last)
        }
        let code = node(h, "Code")
        let m = try rightClick(code)
        #expect(h.controller.selection == Selection(code) && h.window.firstResponder === s)
        #expect(
            titles(m) == [
                "Edit Task…", "Mark Done", "Progress", "-", "Reschedule", "-", "Remove Dependencies", "-", "Cut",
                "Copy",
                "-", "Back to Canvas", "-", "Delete",
            ])
        #expect(item(m, "Mark Done")?.keyEquivalent == " " && item(m, "Edit Task…")?.keyEquivalent == "\r")
        let progress = try #require(m.items.first { $0.title == "Progress" }?.submenu)
        #expect(
            progress.items.count == 10 && progress.items[4].title == "Progress 40%" && progress.items[4].state == .on)
        #expect(
            titles(m.items.first { $0.title == "Reschedule" }?.submenu) == [
                "Move a Working Day Earlier", "Move a Working Day Later", "Move a Week Earlier", "Move a Week Later",
                "Shorten by a Working Day", "Lengthen by a Working Day",
            ])
        for it in allItems(m) { #expect(it.target === s, "\(it.title) runs in the Gantt") }

        // Running an item equals the key (⌥→ moves the task and its dependants).
        b.controller.select(code)
        choose(item(m, "Move a Working Day Later"))
        b.press("opt+right")
        #expect(h.canvas == b.canvas && h.undo.stack.undoStack.count == b.undo.stack.undoStack.count)
        choose(item(try rightClick(code), "Mark Done"))
        #expect(h.canvas.nodes[code]?.todo?.done == true)
        #expect(item(try rightClick(code), "Mark Done")?.state == .on, "checked when done")

        // An undated task offers Schedule from Today, not Reschedule; Control-click works too.
        let docs = node(h, "Docs")
        let dm = try rightClick(docs, flags: [.control])
        #expect(h.controller.selection == Selection(docs))
        #expect(titles(dm).contains("Schedule from Today") && !titles(dm).contains("Reschedule"))
        #expect(!titles(dm).contains("Remove Dependencies"))
        // Two tasks can be linked; a summary row has only the row's items.
        let launch = node(h, "Launch")
        h.controller.setSelection(Selection(primary: docs, nodes: [docs, launch]))
        let lm = try rightClick(launch)
        #expect(h.controller.selection.nodes == [docs, launch] && titles(lm).contains("Link Tasks"))
        choose(item(lm, "Link Tasks"))
        #expect(h.canvas.nodes[launch]?.todo?.after.contains { $0.task == docs } == true)
        #expect(
            titles(try rightClick(node(h, "Build"))) == [
                "Edit Task…", "-", "Cut", "Copy", "-", "Back to Canvas", "-", "Delete",
            ])
        // Below the rows: the chart's own items.
        let before = h.controller.selection
        #expect(titles(try rightClick(nil)) == ["Go to Today", "-", "Export Gantt…", "-", "Back to Canvas"])
        #expect(h.controller.selection == before, "the empty area keeps the selection")

        // The keys are unchanged.
        h.controller.select(code)
        h.window.makeFirstResponder(s)
        h.press("space")
        #expect(h.canvas.nodes[code]?.todo?.done == false)

        // VoiceOver: a row's Show Menu opens its menu.
        var popped: [NSMenu] = []
        s.popUpMenu = { menu, _ in popped.append(menu) }
        s.reload()
        let rows = s.accessibilityChildren() as? [MenuRowElement] ?? []
        let designRow = try #require(rows.first { $0.accessibilityLabel()?.hasPrefix("Design") == true })
        #expect(designRow.accessibilityPerformShowMenu())
        #expect(
            h.controller.selection == Selection(node(h, "Design")) && popped.last?.items.first?.title == "Edit Task…")
        #expect(s.accessibilityPerformShowMenu() && popped.count == 2)
    }
}
