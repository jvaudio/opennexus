import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusKeys

/// M17: right-click and Control-click menus on every kind of canvas element, built from
/// the command registry.
@MainActor
@Suite(.serialized) struct ContextMenuTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID { h.canvas.nodes.first { $0.value.text == text }!.key }

    /// The launch plan with a relationship, a boundary, a summary, a callout, a zone, an
    /// image and a legend, plus the app's window command for the Format panel.
    func harness() throws -> (CanvasHarness, Elements) {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("nexus-test-\(UUID().uuidString)"))
        h.controller.externalCommands = [.inspector]
        let pricing = node(h, "Pricing")
        let kids = h.canvas.nodes[pricing]!.children
        let channels = node(h, "Channels")
        let timeline = node(h, "Timeline")
        let risks = node(h, "Risks")
        let ids = try #require(
            h.controller.perform("Elements") { e -> Elements in
                let b = try e.addBoundary(around: [risks], title: "Watch")
                _ = try e.addSummary(over: [kids[0], kids[2]], text: "3 plans")
                let callout = try e.addCallout(on: channels, text: "Ask Sam")
                e.connect(channels, to: timeline)
                let r = e.canvas.relationships[0].id
                e.updateRelationship(r) { $0.label = "drives" }
                let top = e.addFloating(at: CanvasPoint(x: 2000, y: 1400), text: "Parking lot")
                let z = e.addZone(
                    title: "Ideas", origin: CanvasPoint(x: 1960, y: 1340), width: 320, height: 200, members: [top])
                e.update(kids[1]) { $0.image = AssetRef(asset: "pro.png", width: 120, height: 80) }
                return Elements(
                    relationship: r, boundary: b, summary: e.canvas.summaries[0].id,
                    callout: e.canvas.callouts.first { $0.topic == callout }!.id, zone: z)
            })
        return (h, ids)
    }

    struct Elements {
        var relationship, boundary, summary, callout, zone: String
    }

    // MARK: Helpers

    func event(
        _ h: CanvasHarness, at world: CGPoint, _ type: NSEvent.EventType = .rightMouseDown,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        let v = h.host.canvasView
        let at = v.convert(v.camera.toView(world), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: at, modifierFlags: flags, timestamp: 0, windowNumber: h.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func menu(_ h: CanvasHarness, at world: CGPoint) -> NSMenu? { h.host.canvasView.menu(for: event(h, at: world)) }

    func center(_ h: CanvasHarness, _ id: NodeID) -> CGPoint { h.controller.scene.nodes[id]!.frame.center }

    /// Titles with "-" for separators.
    func titles(_ m: NSMenu?) -> [String] { m?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? [] }

    func item(_ m: NSMenu?, _ title: String) -> NSMenuItem? {
        for i in m?.items ?? [] {
            if i.title == title, i.submenu == nil { return i }
            if let found = item(i.submenu, title) { return found }
        }
        return nil
    }

    func allItems(_ m: NSMenu) -> [NSMenuItem] {
        m.items.flatMap { i in i.submenu.map { allItems($0) } ?? (i.isSeparatorItem ? [] : [i]) }
    }

    /// Runs an item as AppKit would.
    func run(_ h: CanvasHarness, _ item: NSMenuItem?) {
        guard let item, let action = item.action else {
            Issue.record("no item")
            return
        }
        #expect(h.host.canvasView.validateMenuItem(item), "\(item.title) is enabled")
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// A point on the relationship (its label or line).
    func relationshipPoint(_ h: CanvasHarness, _ id: String) throws -> CGPoint {
        let r = try #require(h.canvas.relationships.first { $0.id == id })
        let (a, b) = (center(h, r.from.topic!), center(h, r.to.topic!))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let v = h.host.canvasView
        for dy in stride(from: -160.0, through: 160, by: 4) {
            for dx in stride(from: -160.0, through: 160, by: 4) {
                let p = CGPoint(x: mid.x + dx, y: mid.y + dy)
                if v.node(at: v.camera.toView(p)) == nil, v.elements.hitTest(p) == .relationship(id) { return p }
            }
        }
        throw MenuTestError.notFound
    }

    enum MenuTestError: Error { case notFound }

    /// The document window's part of the responder chain: it runs Format Panel (⌘I).
    final class WindowStandIn: NSResponder, RegistryCommandTarget, NSMenuItemValidation {
        var ran: [CommandID] = []
        func performRegistryCommand(_ sender: Any?) {
            ((sender as? NSMenuItem)?.representedObject as? String).map { ran.append(CommandID(rawValue: $0)) }
        }
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            (item.representedObject as? String) == CommandID.inspector.rawValue
        }
    }

    // MARK: Contents

    @Test func topicMenuSelectsAndOffersWhatApplies() throws {
        let (h, _) = try harness()
        let pricing = node(h, "Pricing")
        h.controller.select(h.canvas.root)
        let m = menu(h, at: center(h, pricing))
        #expect(h.controller.selection == Selection(pricing), "right-clicking selects the topic first")
        #expect(
            titles(m) == [
                "Add Child Topic", "Add Sibling After", "Add Sibling Before", "Add Parent Topic", "-",
                "Edit Topic", "Insert", "-", "Cut", "Copy", "Paste", "Duplicate Branch", "-",
                "Copy Style", "Reset Style", "Format Panel", "Structure", "-",
                "Fold / Unfold Branch", "Focus on Branch", "-", "Export Branch", "-",
                "Delete", "Delete, Keep Children",
            ])
        let insert = m?.items.first { $0.title == "Insert" }?.submenu
        #expect(
            titles(insert) == [
                "Note", "Hyperlink…", "Image…", "Label", "Markers…", "Sticker…", "-", "Comment…", "Task…", "To-Do",
                "-", "Callout", "Boundary", "Summary", "Relationship (Connect Mode)",
            ])
        let structure = try #require(m?.items.first { $0.title == "Structure" }?.submenu)
        #expect(
            titles(structure) == [
                "Mind Map", "Logic Chart", "Org Chart", "Timeline", "Fishbone", "Matrix", "Brace Map", "Tree Table",
                "Tree Chart",
            ])
        #expect(
            structure.items[2].keyEquivalent == "3"
                && structure.items[2].keyEquivalentModifierMask == [.option, .command])
        #expect(
            titles(m?.items.first { $0.title == "Export Branch" }?.submenu) == [
                "Export Branch as PNG…", "Export Branch as SVG…", "Export Branch as Markdown…", "-", "Print Branch…",
                "New Canvas from Topic",
            ])
        // Key equivalents come from the resolved bindings.
        let child = try #require(item(m, "Add Child Topic"))
        #expect(child.keyEquivalent == "\t" && child.keyEquivalentModifierMask == [])
        #expect(item(m, "Duplicate Branch")?.keyEquivalent == "d")

        // The central topic: no siblings, parent, duplicate or delete.
        let root = titles(menu(h, at: center(h, h.canvas.root)))
        #expect(root.contains("Add Child Topic") && root.contains("Fold / Unfold Branch"))
        for t in [
            "Add Sibling After", "Add Sibling Before", "Add Parent Topic", "Duplicate Branch", "Delete",
            "Delete, Keep Children", "Cut",
        ] {
            #expect(!root.contains(t), "\(t) on the central topic")
        }
        // A leaf has nothing to fold; Paste Style shows once a style is copied.
        let leaf = node(h, "Free tier")
        #expect(!titles(menu(h, at: center(h, leaf))).contains("Fold / Unfold Branch"))
        #expect(!titles(menu(h, at: center(h, leaf))).contains("Paste Style"))
        run(h, item(menu(h, at: center(h, leaf)), "Copy Style"))
        #expect(h.controller.toast?.text == "Style copied")
        #expect(titles(menu(h, at: center(h, leaf))).contains("Paste Style"))
        // The current structure is checked.
        h.controller.select(h.canvas.root)
        let rootStructure = menu(h, at: center(h, h.canvas.root))?.items.first { $0.title == "Structure" }?.submenu
        #expect(rootStructure?.items.first?.state == .on && rootStructure?.items[1].state == .off)
    }

    @Test func multiSelectionOffersWhatAppliesToEveryTopic() throws {
        let (h, _) = try harness()
        let pricing = node(h, "Pricing")
        let channels = node(h, "Channels")
        let positioning = node(h, "Positioning")
        h.controller.setSelection(Selection(primary: pricing, nodes: [pricing, channels]))
        let m = menu(h, at: center(h, channels))
        #expect(h.controller.selection.nodes == [pricing, channels], "a selected topic keeps the selection")
        #expect(
            titles(m) == [
                "Cut", "Copy", "-", "Label", "Markers…", "To-Do", "Boundary", "Summary", "-", "Reset Style",
                "Format Panel", "-", "Delete",
            ])
        run(h, item(m, "To-Do"))
        #expect(h.canvas.nodes[pricing]?.todo != nil && h.canvas.nodes[channels]?.todo != nil)
        run(h, item(menu(h, at: center(h, channels)), "Boundary"))
        #expect(h.canvas.boundaries.last?.nodes == [pricing, channels])
        // Topics with different parents can't share a summary.
        h.controller.setSelection(Selection(primary: pricing, nodes: [pricing, node(h, "Pro")]))
        #expect(!titles(menu(h, at: center(h, pricing))).contains("Summary"))
        // An unselected topic replaces the selection.
        _ = menu(h, at: center(h, positioning))
        #expect(h.controller.selection == Selection(positioning))
    }

    @Test func elementMenus() throws {
        let (h, ids) = try harness()
        let window = WindowStandIn()
        h.window.nextResponder = window

        // Relationship.
        let rel = menu(h, at: try relationshipPoint(h, ids.relationship))
        #expect(h.controller.selectedElement == .relationship(ids.relationship))
        #expect(titles(rel) == ["Edit Label", "-", "Format Panel", "Reset Style", "-", "Delete"])
        run(h, item(rel, "Format Panel"))
        #expect(window.ran == [.inspector], "window commands go up the responder chain")
        run(h, item(rel, "Edit Label"))
        #expect(h.controller.mode == .edit && h.controller.edit?.element == .relationship(ids.relationship))
        h.controller.commitEdit()

        // Boundary (its title band).
        let b = try #require(h.controller.scene.boundaries.first { $0.boundary.id == ids.boundary })
        let bm = menu(h, at: CGPoint(x: b.rect.midX, y: b.rect.minY + 4))
        #expect(h.controller.selectedElement == .boundary(ids.boundary))
        #expect(titles(bm) == ["Edit Title", "-", "Format Panel", "Reset Style", "-", "Delete"])

        // Summary (its bracket).
        let s = try #require(h.controller.scene.summaries.first)
        let sm = menu(h, at: CGPoint(x: s.bracket.midX, y: s.bracket.midY))
        #expect(h.controller.selectedElement == .summary(ids.summary))
        #expect(titles(sm) == ["Edit Text", "-", "Format Panel", "Reset Style", "-", "Delete"])

        // Callout (its topic).
        let k = try #require(h.canvas.callouts.first { $0.id == ids.callout })
        let km = menu(h, at: center(h, k.topic))
        #expect(h.controller.selectedElement == .callout(ids.callout) && h.controller.selection.primary == k.topic)
        #expect(titles(km) == ["Edit Text", "-", "Format Panel", "Reset Style", "-", "Delete"])

        // Zone (its title bar, not the topic inside).
        let z = try #require(h.controller.scene.zones.first { $0.zone.id == ids.zone })
        let zm = menu(h, at: CGPoint(x: z.rect.minX + 60, y: z.rect.minY + 12))
        #expect(h.controller.selectedElement == .zone(ids.zone))
        #expect(
            titles(zm) == [
                "Edit Title", "-", "Format Panel", "Reset Style", "Collapse Zone", "Bring to Front", "Send to Back",
                "-", "Export Zone…", "Print Zone…", "-", "Delete",
            ])
        run(h, item(zm, "Collapse Zone"))
        #expect(h.canvas.zones.first?.collapsed == true)
        #expect(item(menu(h, at: CGPoint(x: z.rect.minX + 60, y: z.rect.minY + 12)), "Expand Zone") != nil)
    }

    @Test func imageLegendAndEmptyCanvasMenus() throws {
        let (h, _) = try harness()
        let pro = node(h, "Pro")
        let n = try #require(h.controller.scene.nodes[pro])
        let image = CGPoint(x: n.frame.rect.minX + n.imageRect.midX, y: n.frame.rect.minY + n.imageRect.midY)
        let im = menu(h, at: image)
        #expect(h.controller.selection == Selection(pro))
        #expect(
            titles(im) == ["Replace Image…", "Remove Image", "-", "Remove Image Background", "Make a Sticker…"])
        #expect(item(im, "Replace Image…")?.keyEquivalent == "i", "Insert › Image…'s key")
        let depth = h.undo.stack.undoStack.count
        run(h, item(im, "Remove Image"))
        #expect(h.canvas.nodes[pro]?.image == nil && h.undo.stack.undoStack.count == depth + 1)
        // Off the image, the topic's own menu.
        #expect(titles(menu(h, at: center(h, pro))).first == "Add Child Topic")

        // The legend.
        h.controller.toggleLegend()
        let l = try #require(h.controller.scene.legend)
        #expect(titles(menu(h, at: CGPoint(x: l.rect.midX, y: l.rect.midY))) == ["Edit Legend…", "Legend"])

        // Empty canvas: a floating topic lands where the menu opened.
        let empty = CGPoint(x: -1800, y: -1200)
        let cm = menu(h, at: empty)
        #expect(
            titles(cm) == [
                "Paste", "Add Floating Topic", "Zone", "-", "Select All Topics", "Fit Map to Window", "-", "Export…",
                "Print…",
            ])
        let floating = h.canvas.floating.count
        run(h, item(cm, "Add Floating Topic"))
        #expect(h.canvas.floating.count == floating + 1 && h.controller.mode == .edit)
        let added = try #require(h.canvas.floating.last)
        #expect(h.canvas.nodes[added]?.position == CanvasPoint(x: -1800, y: -1200))
        h.controller.commitEdit()
        run(h, item(menu(h, at: CGPoint(x: -1800, y: 900)), "Select All Topics"))
        #expect(h.controller.selection.nodes.count == h.canvas.visibleNodes().count)
    }

    // MARK: Every item is a command or an existing action

    @Test func everyItemMapsToARegistryCommandOrAnAction() throws {
        let (h, ids) = try harness()
        h.controller.copyStyle()
        let pricing = node(h, "Pricing")
        let pro = node(h, "Pro")
        let n = h.controller.scene.nodes[pro]!
        let z = h.controller.scene.zones.first!
        let b = h.controller.scene.boundaries.first!
        var points: [CGPoint] = [
            center(h, pricing), center(h, h.canvas.root), center(h, node(h, "Free tier")),
            CGPoint(x: n.frame.rect.minX + n.imageRect.midX, y: n.frame.rect.minY + n.imageRect.midY),
            CGPoint(x: z.rect.minX + 60, y: z.rect.minY + 12), CGPoint(x: b.rect.midX, y: b.rect.minY + 4),
            center(h, h.canvas.callouts[0].topic), CGPoint(x: -1800, y: -1200),
            try relationshipPoint(h, ids.relationship),
        ]
        points.append(center(h, pricing))
        let registry = CommandRegistry.standard
        let structureTitles = CanvasController.structureCycle.map {
            Loc.t(CanvasController.diagramType(for: $0).displayName)
        }
        var seen = 0
        for (i, p) in points.enumerated() {
            if i == points.count - 1 {
                h.controller.setSelection(Selection(primary: pricing, nodes: [pricing, node(h, "Channels")]))
            }
            let m = try #require(menu(h, at: p))
            for it in allItems(m) {
                seen += 1
                if it.action == #selector(CanvasView.performRegistryCommand(_:)) {
                    let raw = try #require(it.representedObject as? String)
                    let d = try #require(registry[CommandID(rawValue: raw)], "\(raw) is a registry command")
                    #expect(
                        it.title == Loc.t(d.title) || structureTitles.contains(it.title)
                            || it.title == "Replace Image…",
                        "\(it.title) is the command's title")
                    let chord = h.controller.bindings(for: d.id).first
                    #expect(it.keyEquivalent == (chord?.key.keyEquivalent ?? ""), "\(it.title)'s key")
                    if let chord { #expect(it.keyEquivalentModifierMask == chord.menuModifierMask) }
                } else {
                    #expect(it.action == #selector(CanvasView.performMenuAction(_:)), "\(it.title)")
                    #expect(it.representedObject is MenuActionBox, "\(it.title) carries an action")
                }
                #expect(it.target === h.host.canvasView)
            }
        }
        #expect(seen > 60)
    }

    // MARK: Menu equals keyboard

    /// Each item, run from the menu, leaves the document, selection, mode and undo stack
    /// exactly as the command does from the keyboard.
    @Test func runningAnItemEqualsRunningTheCommand() throws {
        let cases: [(String, CommandID)] = [
            ("Add Child Topic", .addChild), ("Add Sibling After", .addSiblingAfter),
            ("Add Sibling Before", .addSiblingBefore), ("Add Parent Topic", .addParent),
            ("Duplicate Branch", .duplicate), ("Delete", .delete), ("Delete, Keep Children", .deleteKeepChildren),
            ("Fold / Unfold Branch", .fold), ("Reset Style", .resetStyle), ("Logic Chart", .structure(2)),
            ("Boundary", .boundary), ("To-Do", .toggleTodo), ("Focus on Branch", .focusBranch),
            ("Callout", .callout), ("Summary", .summary), ("Copy", .copy), ("Cut", .cut),
        ]
        for (title, id) in cases {
            let (a, _) = try harness()
            let (b, _) = try harness()
            let target = node(a, "Pricing")
            b.controller.select(target)
            let m = menu(a, at: center(a, target))
            run(a, item(m, title))
            #expect(b.controller.perform(id), "\(id) runs")
            #expect(a.canvas == b.canvas, "\(title): same document")
            #expect(a.controller.selection == b.controller.selection, "\(title): same selection")
            #expect(a.controller.mode == b.controller.mode && a.controller.edit == b.controller.edit, "\(title)")
            #expect(a.controller.focusRoot == b.controller.focusRoot, "\(title)")
            #expect(a.undo.stack.undoStack.count == b.undo.stack.undoStack.count, "\(title): one undo step")
        }
    }

    @Test func elementDeleteAndResetMatchTheKeys() throws {
        // Delete from the relationship's menu equals the Delete key.
        let (a, ids) = try harness()
        let (b, _) = try harness()
        let p = try relationshipPoint(a, ids.relationship)
        a.controller.updateRelationship(ids.relationship) { $0.width = 4 }
        b.controller.updateRelationship(ids.relationship) { $0.width = 4 }
        run(a, item(menu(a, at: p), "Reset Style"))
        b.controller.selectElement(.relationship(ids.relationship))
        b.press("opt+cmd+r")
        #expect(a.canvas == b.canvas && a.canvas.relationships.first?.width != 4, "⌥⌘R resets the element")
        run(a, item(menu(a, at: p), "Delete"))
        b.press("delete")
        #expect(a.canvas == b.canvas && a.canvas.relationships.isEmpty)
        #expect(a.undo.stack.undoStack.count == b.undo.stack.undoStack.count)
        #expect(a.controller.selectedElement == nil && b.controller.selectedElement == nil)
        // Topic › Delete from the menu bar with an element selected removes the element.
        a.controller.selectElement(.boundary(ids.boundary))
        #expect(a.controller.perform(.delete) && a.canvas.boundaries.isEmpty && a.canvas.nodes[node(a, "Risks")] != nil)
    }

    @Test func rightClickAndControlClickOpenTheMenu() throws {
        let (h, _) = try harness()
        let v = h.host.canvasView
        var shown: [String] = []
        v.presentContextMenu = { menu, _ in shown.append(menu.items.first?.title ?? "") }
        let pricing = node(h, "Pricing")
        v.mouseDown(with: event(h, at: center(h, pricing), .leftMouseDown, flags: [.control]))
        #expect(shown == ["Add Child Topic"] && h.controller.selection == Selection(pricing))
        v.mouseUp(with: event(h, at: center(h, pricing), .leftMouseUp))
        // Right-button down and up without a drag (right-drag pans when that's on).
        h.controller.prefs.set("editing.rightDragPan", true)
        v.rightMouseDown(with: event(h, at: CGPoint(x: -1800, y: -1200)))
        v.rightMouseUp(with: event(h, at: CGPoint(x: -1800, y: -1200), .rightMouseUp))
        #expect(shown.last == "Paste")
    }

    // MARK: VoiceOver

    @Test func voiceOverActionsComeFromTheMenus() throws {
        let (h, ids) = try harness()
        let v = h.host.canvasView
        let risks = try #require(v.accessibilityTree.element(node(h, "Risks")))
        let names = risks.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(
            Array(names.prefix(6)) == ["Edit", "Add child", "Add sibling", "Connect from here", "Comments", "Fold"])
        for t in ["Add Parent Topic", "Duplicate Branch", "Note", "Hyperlink…", "Focus on Branch", "Delete"] {
            #expect(names.contains(t), "\(t) is an action")
        }
        for t in ["Edit Topic", "Add Child Topic", "Add Sibling After", "Comment…", "Mind Map"] {
            #expect(!names.contains(t), "\(t) isn't repeated")
        }
        #expect(Set(names).count == names.count)
        // An action runs on its own topic, whatever is selected.
        h.controller.select(node(h, "Pricing"))
        let depth = h.undo.stack.undoStack.count
        _ = risks.accessibilityCustomActions()?.first { $0.name == "Duplicate Branch" }?.handler?()
        #expect(h.canvas.nodes[h.canvas.root]?.children.filter { h.text($0) == "Risks" }.count == 2)
        #expect(h.undo.stack.undoStack.count == depth + 1)

        // A topic with an image adds the image's items.
        let pro = try #require(v.accessibilityTree.element(node(h, "Pro")))
        let proNames = pro.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(proNames.contains("Remove Image") && !proNames.contains("Replace Image…"))

        // Relationships and boundaries (the rotors' elements).
        let edge = try #require(v.accessibilityTree.edgeItems().first)
        #expect(
            edge.accessibilityCustomActions()?.map(\.name) == ["Edit Label", "Format Panel", "Reset Style", "Delete"])
        _ = edge.accessibilityCustomActions()?.first { $0.name == "Delete" }?.handler?()
        #expect(h.canvas.relationships.isEmpty)
        let box = try #require(v.accessibilityTree.boundaryItems().first { $0.ref == .boundary(ids.boundary) })
        #expect(box.accessibilityCustomActions()?.first?.name == "Edit Title")

        // The canvas: the empty-canvas menu.
        let canvasNames = v.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(canvasNames.contains("Add Floating Topic") && canvasNames.contains("Fit Map to Window"))
    }
}
