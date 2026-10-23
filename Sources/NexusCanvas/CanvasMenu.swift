import Foundation
import NexusCore
import NexusKeys

/// What a right-click (or Control-click) landed on (M17).
public enum CanvasMenuTarget: Equatable, Sendable {
    case topic(NodeID)
    /// A topic's image.
    case image(NodeID)
    case element(ElementRef)
    case legend
    /// Empty canvas, at a world point.
    case canvas(CGPoint)
}

/// What a context-menu item does. Most items are registry commands, so titles, key
/// equivalents, validation, undo, toasts and the tour coach match the keyboard (D173).
public enum CanvasMenuAction: Equatable, Sendable {
    /// A registry command, sent through `performRegistryCommand` like a menu-bar item.
    case command(CommandID)
    /// Add Floating Topic (the `.addFloating` command) at the clicked point.
    case floatingTopic(CGPoint)
    /// Paste (the `.paste` command) as floating topics at the clicked point (D222).
    case pasteHere(CGPoint)
    /// Zone (the `.zone` command) with its top-left corner at the clicked point (D223).
    case zoneHere(CGPoint)
    /// Existing actions with no command of their own (D174).
    case editElement(ElementRef)
    case collapseZone(String)
    case removeImage(NodeID)
    case stickers(NodeID)
    /// A structure outside the nine ⌥⌘ ones (D249), applied like them.
    case structure(LayoutStructure)

    /// The registry command the item runs, if it runs one.
    public var command: CommandID? {
        switch self {
        case .command(let id): id
        case .floatingTopic: .addFloating
        case .pasteHere: .paste
        case .zoneHere: .zone
        default: nil
        }
    }
}

public struct CanvasMenuItem: Equatable, Sendable {
    public var title: String
    public var action: CanvasMenuAction
    /// The resolved binding, shown as the item's key equivalent.
    public var key: KeyChord?
    public var checked = false
}

public indirect enum CanvasMenuEntry: Equatable, Sendable {
    case item(CanvasMenuItem)
    case submenu(String, [CanvasMenuEntry])
    case separator

    /// Every item, submenus included, in order.
    public var items: [CanvasMenuItem] {
        switch self {
        case .item(let i): [i]
        case .submenu(_, let entries): entries.flatMap(\.items)
        case .separator: []
        }
    }
}

/// Context menus for the canvas (M17, closing the gap D156 left): built from the registry,
/// showing only what can run on the selection, as ⌘K does (D175).
@MainActor
extension CanvasController {
    /// Commands that act on every selected topic, offered when several are selected (D177).
    static let multiSelectionCommands: [[CommandID]] = [
        [.cut, .copy],
        [.label, .markerPicker, .toggleTodo, .boundary, .summary],
        [.pasteStyle, .resetStyle, .inspector],
        [.delete],
    ]

    /// Selects what was clicked, as a left click would, before its menu is built (D176):
    /// an unselected topic becomes the selection; a selected one keeps a multi-selection.
    public func prepareContextMenu(_ target: CanvasMenuTarget) {
        if mode == .connect { cancelConnect() }
        if mode == .edit { commitEdit() }
        switch target {
        case .topic(let id):
            if !selection.contains(id) || selectedElement != nil { select(id) }
        case .image(let id):
            // Image items act on one topic.
            if selection.nodes != [id] || selectedElement != nil { select(id) }
        case .element(let ref):
            // A zone in a group of selected zones keeps the group, so the menu's Copy, Cut
            // and Duplicate act on all of them, as their keys do (D228).
            if case .zone(let z) = ref, selectedZones.count > 1, selectedZones.contains(z) {
                selectElement(ref, zones: selectedZones)
            } else {
                selectElement(ref)
            }
        case .legend, .canvas:
            if selectedElement != nil { selectElement(nil) }
        }
    }

    /// The menu for a target, as entries (the view turns them into an `NSMenu`), for the
    /// current selection.
    public func contextMenu(for target: CanvasMenuTarget) -> [CanvasMenuEntry] {
        guard canvas.nodes[selection.primary] != nil else { return [] }
        let b = MenuBuilder(controller: self, selection: selection, element: selectedElement)
        switch target {
        case .topic:
            return selection.nodes.count > 1 ? b.multiSelectionMenu() : b.topicMenu()
        case .image(let id):
            return b.imageMenu(id)
        case .element(let ref):
            return b.elementMenu(ref)
        case .legend:
            return b.sections([[b.cmd(.editLegend), b.cmd(.toggleLegend)]])
        case .canvas(let p):
            return b.sections([
                [
                    b.placed(.paste, .pasteHere(p)), b.placed(.addFloating, .floatingTopic(p)),
                    b.placed(.zone, .zoneHere(p)),
                ],
                [b.cmd(.selectAll), b.cmd(.fitToWindow)],
                [b.cmd(.export), b.cmd(.printDocument)],
            ])
        }
    }

    /// The menu a target would get once selected, without selecting it (VoiceOver's
    /// custom actions list these, D179).
    func contextMenu(previewing target: CanvasMenuTarget) -> [CanvasMenuEntry] {
        switch target {
        case .topic(let id), .image(let id):
            guard canvas.nodes[id] != nil else { return [] }
            let b = MenuBuilder(controller: self, selection: Selection(id), element: nil)
            return target == .topic(id) ? b.topicMenu() : b.imageMenu(id)
        case .element(let ref):
            var s = selection
            if case .callout(let k) = ref, let c = canvas.callouts.first(where: { $0.id == k }) {
                s = Selection(c.topic)
            }
            return MenuBuilder(controller: self, selection: s, element: ref).elementMenu(ref)
        default:
            return contextMenu(for: target)
        }
    }

    /// Runs a command's at-the-pointer variant as `perform` runs the command: only where
    /// the command can run, and the tour coach hears about it.
    private func runPlaced(_ id: CommandID, _ body: (CanvasController) -> Void) -> Bool {
        guard canPerform(id) else { return false }
        body(self)
        tour?.didRun(id)
        tour?.didChange()
        return true
    }

    // MARK: Outline and Gantt rows (M26, D225)

    /// Selects a right-clicked outline or Gantt row as a click would (D176): an unselected
    /// row becomes the selection, a selected one keeps a multi-selection. Nil is the
    /// Gantt's empty area, which keeps the selection.
    public func prepareRowMenu(_ id: NodeID?) {
        if mode == .connect { cancelConnect() }
        if mode == .edit { commitEdit() }
        if let id, canvas.nodes[id] != nil, !selection.contains(id) || selectedElement != nil { select(id) }
    }

    /// The outline's menu for the selection: the canvas topic menu without what only the
    /// canvas shows (styles, structures, callouts, boundaries, summaries, relationships),
    /// plus the outline's Indent and Outdent and Move Up and Down. Its popovers open on
    /// the row (D254, D255).
    public func outlineContextMenu() -> [CanvasMenuEntry] {
        guard canvas.nodes[selection.primary] != nil else { return [] }
        let b = MenuBuilder(controller: self, selection: selection, element: nil)
        return selection.nodes.count > 1 ? b.outlineMultiSelectionMenu() : b.outlineMenu()
    }

    /// The menu a row would get once selected alone, without selecting it (an outline
    /// row's custom actions list these, D256).
    func outlineContextMenu(previewing id: NodeID) -> [CanvasMenuEntry] {
        guard canvas.nodes[id] != nil else { return [] }
        return MenuBuilder(controller: self, selection: Selection(id), element: nil).outlineMenu()
    }

    /// The Gantt's menu: a row's task commands, or (no row) Go to Today and Export Gantt….
    public func ganttContextMenu(onRow: Bool) -> [CanvasMenuEntry] {
        guard canvas.nodes[selection.primary] != nil else { return [] }
        let b = MenuBuilder(controller: self, selection: selection, element: nil)
        return onRow ? b.ganttMenu() : b.sections([[b.cmd(.ganttToday)], [b.cmd(.exportGantt)], [b.cmd(.ganttExit)]])
    }

    /// Runs an item that isn't a plain command (the view sends commands up the responder
    /// chain itself). Returns false if it didn't run.
    @discardableResult
    public func runMenuAction(_ action: CanvasMenuAction) -> Bool {
        switch action {
        case .command(let id):
            if externalCommands.contains(id) {
                onExternalCommand?(id)
                return true
            }
            return perform(id)
        case .floatingTopic(let p):
            menuFloatingPoint = p
            defer { menuFloatingPoint = nil }
            return perform(.addFloating)
        case .pasteHere(let p):
            return runPlaced(.paste) { $0.paste(at: p) }
        case .zoneHere(let p):
            return runPlaced(.zone) { $0.addZone(at: p) }
        case .editElement(let ref):
            beginEditingElement(ref)
        case .collapseZone(let id):
            perform(Loc.t("Collapse Zone")) { $0.updateZone(id) { $0.collapsed.toggle() } }
        case .removeImage(let id):
            removeImage(on: id)
        case .stickers(let id):
            onRequest?(.stickers(id))
        case .structure(let s):
            setStructure(s)
        }
        return true
    }
}

/// Builds menus for one selection (the current one, or a topic VoiceOver is on).
@MainActor
struct MenuBuilder {
    let controller: CanvasController
    let selection: Selection
    let element: ElementRef?

    var c: CanvasController { controller }

    /// Insert's popover items (note, link, image, label, markers, sticker), and comments
    /// and tasks: the canvas's and the outline's (D255).
    func insertItems() -> [[CanvasMenuEntry?]] {
        [
            [
                cmd(.note), cmd(.hyperlink), cmd(.image), cmd(.label), cmd(.markerPicker),
                item(Loc.t("Sticker…"), .stickers(selection.primary)),
            ],
            [cmd(.comment), cmd(.taskDetails), cmd(.toggleTodo)],
        ]
    }

    func topicMenu() -> [CanvasMenuEntry] {
        let id = selection.primary
        let insert = sections(insertItems() + [[cmd(.callout), cmd(.boundary), cmd(.summary), cmd(.connect)]])
        let canvas = c.canvas
        let current = canvas.nodes[id]?.structure ?? (id == canvas.root ? canvas.layout.structure : nil)
        let nine = CanvasController.structureCycle.enumerated().map { i, s in
            cmd(.structure(i + 1), title: CanvasController.structureName(s), checked: s == current)
        }
        // The extras (D249) have no command of their own; they're offered where the nine are.
        let extras = CanvasController.structureExtras.map { s -> CanvasMenuEntry? in
            guard canRun(.structure(1)) else { return nil }
            return .item(
                CanvasMenuItem(
                    title: CanvasController.structureName(s), action: .structure(s), key: nil, checked: s == current))
        }
        let structures = sections([nine, extras])
        let export = sections([
            [cmd(.exportBranchPNG), cmd(.exportBranchSVG), cmd(.exportBranchMarkdown)],
            [cmd(.printBranch), cmd(.newCanvasFromTopic)],
        ])
        return sections([
            [cmd(.addChild), cmd(.addSiblingAfter), cmd(.addSiblingBefore), cmd(.addParent)],
            [cmd(.editKeepText), submenu(Loc.t("Insert"), insert)],
            [cmd(.cut), cmd(.copy), cmd(.paste), cmd(.duplicate)],
            [
                cmd(.copyStyle), cmd(.pasteStyle), cmd(.resetStyle), cmd(.inspector),
                submenu(Loc.t("Structure"), structures),
            ],
            [cmd(.fold), cmd(.focusBranch)],
            [submenu(Loc.t("Export Branch"), export)],
            [cmd(.delete), cmd(.deleteKeepChildren)],
        ])
    }

    func multiSelectionMenu() -> [CanvasMenuEntry] {
        sections(CanvasController.multiSelectionCommands.map { $0.map { cmd($0) } })
    }

    /// The outline row menu (D225, D255): the topic menu's items that work without the
    /// canvas, Insert's popovers included (they open on the row).
    func outlineMenu() -> [CanvasMenuEntry] {
        let export = sections([
            [cmd(.exportBranchPNG), cmd(.exportBranchSVG), cmd(.exportBranchMarkdown)],
            [cmd(.printBranch), cmd(.newCanvasFromTopic)],
        ])
        return sections([
            [cmd(.addChild), cmd(.addSiblingAfter), cmd(.addSiblingBefore), cmd(.addParent)],
            [cmd(.editKeepText), submenu(Loc.t("Insert"), sections(insertItems()))],
            [cmd(.outlineIndent), cmd(.outlineOutdent), cmd(.moveUp), cmd(.moveDown)],
            [cmd(.cut), cmd(.copy), cmd(.paste), cmd(.duplicate)],
            [cmd(.fold), cmd(.inspector)],
            [submenu(Loc.t("Export Branch"), export)],
            [cmd(.delete), cmd(.deleteKeepChildren)],
        ])
    }

    /// Several outline rows: what acts on every one of them (D177's rule).
    func outlineMultiSelectionMenu() -> [CanvasMenuEntry] {
        sections([
            [cmd(.cut), cmd(.copy)], [cmd(.label), cmd(.markerPicker), cmd(.toggleTodo)], [cmd(.inspector)],
            [cmd(.delete)],
        ])
    }

    /// The Gantt row menu (D225): the Gantt's own task commands, each with its key, for the
    /// selected tasks.
    func ganttMenu() -> [CanvasMenuEntry] {
        let canvas = c.canvas
        let picked = Set(selection.nodes).union([selection.primary])
        let tasks = c.taskSchedule.rows.map(\.id).filter { picked.contains($0) && canvas.nodes[$0]?.todo != nil }
        let dated = tasks.filter { canvas.span(of: $0) != nil }
        let undated = tasks.filter { canvas.span(of: $0) == nil }
        let done = !tasks.isEmpty && tasks.allSatisfy { canvas.nodes[$0]?.todo?.done == true }
        let progress = Set(tasks.map { canvas.progress(of: $0) })
        let steps = (0...9).compactMap { n in cmd(.ganttProgress(n), checked: progress == [n * 10]) }
        let move = [
            cmd(.ganttEarlier), cmd(.ganttLater), cmd(.ganttWeekEarlier), cmd(.ganttWeekLater), cmd(.ganttShorten),
            cmd(.ganttLengthen),
        ].compactMap { $0 }
        let linked = tasks.contains { !(canvas.nodes[$0]?.todo?.after.isEmpty ?? true) }
        return sections([
            [
                cmd(.ganttEditTask), tasks.isEmpty ? nil : cmd(.ganttToggleDone, checked: done),
                tasks.isEmpty ? nil : submenu(Loc.t("Progress"), steps),
            ],
            [
                undated.isEmpty ? nil : cmd(.ganttScheduleToday),
                dated.isEmpty ? nil : submenu(Loc.t("Reschedule"), move),
            ],
            [tasks.count < 2 ? nil : cmd(.ganttLink), linked ? cmd(.ganttUnlink) : nil],
            [cmd(.cut), cmd(.copy)],
            [cmd(.ganttExit)],
            [cmd(.delete)],
        ])
    }

    func imageMenu(_ id: NodeID) -> [CanvasMenuEntry] {
        sections([
            [cmd(.image, title: Loc.t("Replace Image…")), item(Loc.t("Remove Image"), .removeImage(id))],
            [cmd(.aiRemoveBackground), cmd(.aiSticker)],
        ])
    }

    func elementMenu(_ ref: ElementRef) -> [CanvasMenuEntry] {
        let edit: String
        switch ref {
        case .relationship: edit = Loc.t("Edit Label")
        case .boundary, .zone: edit = Loc.t("Edit Title")
        case .summary, .callout: edit = Loc.t("Edit Text")
        }
        var zone: [CanvasMenuEntry?] = []
        var files: [CanvasMenuEntry?] = []
        if case .zone(let id) = ref {
            let collapsed = c.canvas.zones.first { $0.id == id }?.collapsed ?? false
            zone = [
                item(collapsed ? Loc.t("Expand Zone") : Loc.t("Collapse Zone"), .collapseZone(id)),
                cmd(.bringToFront), cmd(.sendToBack),
            ]
            files = [cmd(.exportZone), cmd(.printZone)]
        }
        // A selected zone copies, cuts and duplicates as a zone (M20, D196).
        let clipboard: [CanvasMenuEntry?] =
            if case .zone = ref { [cmd(.copy), cmd(.cut), cmd(.duplicateZone)] } else { [] }
        return sections([
            [item(edit, .editElement(ref))],
            [cmd(.inspector), cmd(.resetStyle)] + zone,
            clipboard,
            files,
            [cmd(.delete)],
        ])
    }

    /// A command's item, or nil when it can't run on this selection.
    func cmd(_ id: CommandID, title: String? = nil, checked: Bool = false) -> CanvasMenuEntry? {
        guard let d = c.registry[id], canRun(id) else { return nil }
        return .item(
            CanvasMenuItem(
                title: title ?? Loc.t(d.title), action: .command(id), key: c.bindings(for: id).first, checked: checked))
    }

    func item(_ title: String, _ action: CanvasMenuAction) -> CanvasMenuEntry? {
        .item(CanvasMenuItem(title: title, action: action, key: nil))
    }

    /// A command's item that runs at the clicked point instead (Add Floating Topic, Paste
    /// and Zone on empty canvas), with the command's title and key.
    func placed(_ id: CommandID, _ action: CanvasMenuAction) -> CanvasMenuEntry? {
        guard let d = c.registry[id], canRun(id) else { return nil }
        return .item(CanvasMenuItem(title: Loc.t(d.title), action: action, key: c.bindings(for: id).first))
    }

    func submenu(_ title: String, _ entries: [CanvasMenuEntry]) -> CanvasMenuEntry? {
        entries.isEmpty ? nil : .submenu(title, entries)
    }

    /// Groups with separators between them; empty groups vanish.
    func sections(_ groups: [[CanvasMenuEntry?]]) -> [CanvasMenuEntry] {
        let kept = groups.map { $0.compactMap { $0 } }.filter { !$0.isEmpty }
        return Array(kept.map { [.separator] + $0 }.joined().dropFirst())
    }

    /// The palette's rule (`canRun`), plus what each command needs of this selection, so a
    /// menu never offers an item that would do nothing (D175).
    func canRun(_ id: CommandID) -> Bool {
        guard c.canRun(id) else { return false }
        let canvas = c.canvas
        let primary = selection.primary
        let root = canvas.root
        if case .zone = element, [.copy, .cut, .duplicateZone].contains(id) { return true }
        switch id {
        case .addSiblingAfter, .addSiblingBefore, .addParent, .duplicate:
            // The central topic and floating, summary and callout tops have no siblings.
            return canvas.parent(of: primary) != nil
        case .deleteKeepChildren:
            return primary != root
        case .delete where element != nil:
            return true
        case .delete, .cut:
            return selection.nodes.contains { $0 != root }
        case .fold:
            return !(canvas.nodes[primary]?.children.isEmpty ?? true)
        case .outlineIndent, .moveUp:
            // A previous sibling to move under or past.
            guard let p = canvas.parent(of: primary) else { return false }
            return canvas.nodes[p]?.children.first != primary
        case .outlineOutdent:
            return canvas.parent(of: primary).flatMap { canvas.parent(of: $0) } != nil
        case .moveDown:
            guard let p = canvas.parent(of: primary) else { return false }
            return canvas.nodes[p]?.children.last != primary
        case .pasteStyle:
            return c.styleClipboard != nil
        case .summary:
            var e = CanvasEditor(canvas)
            return (try? e.addSummary(over: selection.nodes)) != nil
        case .exportZone, .printZone:
            if case .zone = element { return true }
            return element == nil && c.targetZone != nil
        default:
            return true
        }
    }
}
