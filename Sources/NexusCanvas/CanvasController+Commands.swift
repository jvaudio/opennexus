import Foundation
import NexusCore
import NexusKeys
import NexusLayout

/// Command handlers, bound to registry ids. Anything not listed here is handled by the
/// view (zoom, fit) or later milestones, and shows as disabled.
@MainActor
extension CanvasController {
    /// Xmind's nine structures in ⌥⌘1…9 order.
    /// ⌥⌘1–9 in artboard 18's order.
    public static let structureCycle: [LayoutStructure] = [
        .mindmapBalanced, .logicRight, .orgDown, .timelineHorizontal, .fishboneLeft, .matrix, .braceRight,
        .treeTable, .treeIndented,
    ]

    /// Commands that work in Select mode on the current selection.
    private var handlers: [CommandID: (CanvasController) -> Void] {
        var h: [CommandID: (CanvasController) -> Void] = [
            .addChild: { c in if !c.techAddChild() { c.addChild() } },
            .slashMenu: { $0.openSlash() },
            .outlineSibling: { $0.addSibling(before: false) },
            .outlineIndent: { c in c.restructure(Loc.t("Indent")) { try $0.demote(c.selection.primary) } },
            .outlineOutdent: { c in c.restructure(Loc.t("Outdent")) { try $0.promote(c.selection.primary) } },
            .outlinePrevious: { $0.stepOutline(-1) },
            .outlineNext: { $0.stepOutline(1) },
            .outlineCollapse: { $0.outlineCollapse() },
            .outlineExpand: { $0.outlineExpand() },
            .convert: { $0.openConvert() },
            .laneUp: { $0.moveLane(-1) },
            .laneDown: { $0.moveLane(1) },
            .iconLibrary: { $0.iconLibraryVisible.toggle() },
            .copyMermaid: { $0.copyMermaid() },
            .threatTable: { $0.threatTableVisible.toggle() },
            .suggestThreats: { $0.suggestStrideEverywhere() },
            .focusBranch: { c in if !c.drillIntoProcess() { c.toggleFocus() } },
            .palette: { $0.openPalette() },
            .quickJump: { $0.openJump() },
            .filterBar: { $0.toggleFilterBar() },
            .find: { $0.openSearch() },
            .findNext: { $0.stepSearch(1) },
            .findPrevious: { $0.stepSearch(-1) },
            .zen: { $0.toggleZen() },
            .present: { c in c.present == nil ? c.startPresent() : c.endPresent() },
            .showCanvas: { $0.viewMode = .canvas },
            .showOutline: { $0.viewMode = .outline },
            .showSplit: { $0.viewMode = .split },
            .showGantt: { $0.viewMode = .gantt },
            .aiAcceptAll: { c in if c.ghosts != nil { c.acceptAllGhosts() } else { _ = c.acceptAllStride() } },
            .aiAccept: { $0.acceptGhost() },
            .aiGhosts: { $0.requestGhosts() },
            .aiPrompt: { $0.openPromptBar() },
            .aiPanel: { $0.toggleAIPanel() },
            .export: { $0.openExport() },
            .mapShot: { $0.openMapShot() },
            .copyAsImage: { $0.copyAsImage() },
            .copyAsMarkdown: { $0.copyAsMarkdown() },
            .printDocument: { $0.openPrint() },
            .printBranch: { $0.openPrint(branch: true) },
            .mergeDocuments: { $0.openMerge() },
            .exportBranchPNG: { $0.exportBranch(.png) },
            .exportBranchSVG: { $0.exportBranch(.svg) },
            .exportBranchMarkdown: { $0.exportBranch(.markdown) },
            .exportZone: { $0.exportZone() },
            .printZone: { $0.printZone() },
            .exportZones: { $0.exportEachZone() },
            .duplicateZone: { $0.duplicateZone() },
            .splitByBranch: { $0.splitByBranch() },
            .newCanvasFromTopic: { $0.newCanvasFromTopic() },
            .duplicateCanvas: { $0.duplicateCanvas() },
            .deleteCanvas: { $0.deleteCanvas() },
            .copyCanvas: { $0.copyCanvas() },
            .pasteCanvas: { $0.pasteCanvas() },
            .saveCanvasAsDocument: { $0.saveCanvasAsDocument() },
            .copy: { $0.copySelection() },
            .cut: { $0.cutSelection() },
            .paste: { $0.paste() },
            .pasteImageAsMap: { $0.pasteImageAsMap() },
            .aiBreakdown: { $0.runAction(.breakdown) },
            .aiTodos: { $0.runAction(.todos) },
            .aiFindGaps: { $0.runAction(.findGaps) },
            .aiExpand: { $0.runAction(.expand) },
            .aiRewrite: { $0.runAction(.rewrite) },
            .aiSummarize: { $0.runAction(.summarize) },
            .aiTranslate: { $0.openAISheet(.translate) },
            .aiMask: { $0.openAISheet(.mask) },
            .aiRemoveBackground: { c in c.openAISheet(.removeBackground(c.selection.primary)) },
            .aiSticker: { c in c.openAISheet(.sticker(c.selection.primary)) },
            .aiRecord: { $0.openAISheet(.record) },
            .addSiblingAfter: { $0.addSibling(before: false) },
            .addSiblingBefore: { $0.addSibling(before: true) },
            .addParent: { $0.addParent() },
            .addFloating: { $0.addFloating(at: nil) },
            .duplicate: { $0.duplicateBranch() },
            .editKeepText: { $0.beginEditing() },
            .selectUp: { $0.navigate(.up, extend: false) },
            .selectDown: { $0.navigate(.down, extend: false) },
            .selectLeft: { $0.navigate(.left, extend: false) },
            .selectRight: { $0.navigate(.right, extend: false) },
            .extendUp: { $0.navigate(.up, extend: true) },
            .extendDown: { $0.navigate(.down, extend: true) },
            .extendLeft: { $0.navigate(.left, extend: true) },
            .extendRight: { $0.navigate(.right, extend: true) },
            .selectRoot: { $0.select($0.canvas.root) },
            .selectSiblings: { $0.selectSiblings() },
            .selectChildren: { $0.selectChildren() },
            .selectAll: { $0.selectAll() },
            .selectAllZones: { $0.selectAllZones() },
            .collapseSelection: { $0.setSelection(Selection($0.selection.primary)) },
            .moveUp: { c in c.restructure(Loc.t("Move Up")) { try $0.reorder(c.selection.primary, by: -1) } },
            .moveDown: { c in c.restructure(Loc.t("Move Down")) { try $0.reorder(c.selection.primary, by: 1) } },
            .promote: { c in c.restructure(Loc.t("Promote")) { try $0.promote(c.selection.primary) } },
            .demote: { c in c.restructure(Loc.t("Demote")) { try $0.demote(c.selection.primary) } },
            // With a relationship, boundary, summary, callout or zone selected, Delete and
            // Reset Style act on it (D178), as the Delete key and the Format panel do.
            .delete: { c in
                if let ref = c.selectedElement { c.deleteElement(ref) } else { c.deleteSelection(keepChildren: false) }
            },
            .deleteKeepChildren: { $0.deleteSelection(keepChildren: true) },
            .fold: { c in c.restructure(Loc.t("Fold")) { try $0.toggleFold(c.selection.primary) } },
            .foldAll: { c in c.restructure(Loc.t("Fold All")) { try $0.toggleFoldAll() } },
            .toggleTodo: { $0.toggleMarker(0) },
            .smartColor: { $0.reshuffleColors() },
            .cycleNodeStyle: { $0.cycleNodeStyle() },
            .connect: { $0.startConnect() },
            .boundary: { $0.addBoundary() },
            .summary: { $0.addSummary() },
            .callout: { $0.addCallout() },
            .zone: { $0.addZone() },
            .bringToFront: { $0.reorderSelection(.front) },
            .sendToBack: { $0.reorderSelection(.back) },
            .note: { $0.onRequest?(.note($0.selection.primary)) },
            .hyperlink: { $0.onRequest?(.link($0.selection.primary)) },
            .comment: { $0.onRequest?(.comments($0.selection.primary)) },
            .toggleLegend: { $0.toggleLegend() },
            .editLegend: { $0.editLegend() },
            .image: { $0.onRequest?(.image($0.selection.primary)) },
            .label: { $0.onRequest?(.labels($0.selection.primary)) },
            .markerPicker: { $0.onRequest?(.markers($0.selection.primary)) },
            .flyBack: { c in if !c.climbLevel() { c.flyBack() } },
            .copyStyle: { $0.copyStyle() },
            .pasteStyle: { $0.pasteStyle() },
            .resetStyle: { c in if let ref = c.selectedElement { c.resetElementStyle(ref) } else { c.resetStyle() } },
        ]
        for n in 1...8 { h[.quickStyle(n)] = { $0.applyQuickStyle(index: n) } }
        for n in 1...9 {
            h[.priority(n)] = { $0.toggleMarker(n) }
            h[.structure(n)] = { $0.setStructure(Self.structureCycle[n - 1]) }
        }
        h.merge(taskHandlers) { a, _ in a }
        h.merge(legendHandlers) { a, _ in a }
        for n in 1...5 {
            h[.navigationTab(n)] = { c in
                c.navTab = c.navTab == n ? nil : n
                if n == 1 && c.navTab == 1 { c.searchFocusSerial += 1 }
                c.refreshView()
            }
        }
        return h
    }

    /// Commands that work while editing text.
    private var editorHandlers: [CommandID: (CanvasController) -> Void] {
        [
            .commitEdit: { $0.commitEdit() },
            .commitAndAddChild: { c in
                c.commitEdit()
                c.addChild()
            },
            .commitAndPromote: { c in
                c.commitEdit()
                c.restructure(Loc.t("Promote")) { try $0.promote(c.selection.primary) }
            },
            .commitAndAddParent: { c in
                c.commitEdit()
                c.addParent()
            },
        ]
    }

    public func canPerform(_ id: CommandID) -> Bool {
        if let v = viewCommandValidator, v(id) { return true }
        switch mode {
        case .select:
            guard handlers[id] != nil else { return false }
            // Zone commands need a zone: selected, or holding the selected topic.
            if id == .exportZone || id == .printZone || id == .duplicateZone, targetZone == nil { return false }
            if id == .exportZones || id == .selectAllZones, canvas.zones.isEmpty { return false }
            if legendHandlers[id] != nil, !canPerformLegend(id) { return false }
            return canvas.nodes[selection.primary] != nil
        case .edit:
            return editorHandlers[id] != nil
        case .connect:
            return id == .connectConfirm || id == .connectCancel
        }
    }

    /// Runs a command if it applies in the current mode. Returns false if it does not.
    @discardableResult
    public func perform(_ id: CommandID) -> Bool {
        if id == .convert, let t = tour, t.convertForTour() { return true }
        let ran = performCommand(id)
        if ran {
            tour?.didRun(id)
            tour?.didChange()
        }
        return ran
    }

    private func performCommand(_ id: CommandID) -> Bool {
        // ⌘= and ⌘- step the Gantt's timeline scale while it's showing.
        if viewMode == .gantt, mode == .select, id == .zoomIn || id == .zoomOut {
            stepGanttScale(id == .zoomIn ? -1 : 1)
            return true
        }
        if let v = viewCommandHandler, v(id) { return true }
        switch mode {
        case .select:
            guard let h = handlers[id], canvas.nodes[selection.primary] != nil else { return false }
            h(self)
            return true
        case .edit:
            guard let h = editorHandlers[id] else { return false }
            h(self)
            return true
        case .connect:
            if id == .connectConfirm { finishConnect(); return true }
            if id == .connectCancel { cancelConnect(); return true }
            return false
        }
    }

    // MARK: Create

    /// Inserts a node and opens its editor in the same call: the caret is live before
    /// any animation starts.
    private func create(_ name: String, _ body: (inout CanvasEditor) throws -> NodeID) {
        let s = signposter.beginInterval("create→caret")
        defer { signposter.endInterval("create→caret", s) }
        let generic = prefs.string("editing.placeholderText") == "generic"
        guard
            let id = perform(
                name, refresh: false, selectionAfter: { Selection($0) },
                { e in
                    let id = try body(&e)
                    // Settings › Editing › Placeholder text: "Main Topic" everywhere, or by type.
                    if generic {
                        let t = e.canvas.depth(of: id) <= 1 ? "Main Topic" : "Subtopic"
                        e.update(id) { $0.text = t }
                    }
                    return id
                })
        else { return }
        // "New topics start with: Empty" opens the editor empty; the default text stays as
        // the placeholder and is kept if nothing is typed.
        let text = prefs.string("editing.newTopic") == "empty" ? "" : canvas.nodes[id]?.text ?? ""
        edit = EditSession(node: id, text: text, selectAll: true)
        mode = .edit
        rebuildScene()
        onEditChange?(edit)
        onSceneChange?(true)
        onReveal?(id)
    }

    public func addChild() {
        let target = selection.primary
        create(Loc.t("Add Topic")) { try $0.addChild(of: target) }
    }

    public func addSibling(before: Bool) {
        let target = selection.primary
        create(Loc.t("Add Topic")) { try $0.addSibling(of: target, before: before) }
    }

    public func addParent() {
        let target = selection.primary
        create(Loc.t("Add Parent Topic")) { try $0.addParent(of: target) }
    }

    public func addFloating(at point: CGPoint?) {
        let p = point ?? menuFloatingPoint ?? floatingPlacement?() ?? defaultFloatingPoint()
        create(Loc.t("Add Floating Topic")) { $0.addFloating(at: CanvasPoint(x: p.x, y: p.y)) }
    }

    func defaultFloatingPoint() -> CGPoint {
        let b = scene.bounds
        guard !b.isNull else { return CGPoint(x: 0, y: 160) }
        return CGPoint(x: b.minX + 60, y: b.maxY + 60)
    }

    func duplicateBranch() {
        if case .zone(let id)? = selectedElement { return duplicateZone(id) }  // the selected zones (D228)
        let target = selection.primary
        perform(Loc.t("Duplicate"), selectionAfter: { Selection($0) }) { try $0.duplicate(target) }
        onReveal?(selection.primary)
    }

    // MARK: Restructure

    func restructure(_ name: String, _ body: (inout CanvasEditor) throws -> Void) {
        perform(name, body)
        onReveal?(selection.primary)
    }

    func deleteSelection(keepChildren: Bool) {
        let targets = selection.nodes
        if keepChildren {
            let target = selection.primary
            perform(Loc.t("Delete"), selectionAfter: { Selection($0) }) { try $0.deleteKeepingChildren(target) }
        } else {
            perform(Loc.t("Delete"), selectionAfter: { Selection($0) }) { try $0.delete(targets) }
        }
        onReveal?(selection.primary)
    }

    func toggleMarker(_ n: Int) {
        let targets = selection.nodes
        perform(n == 0 ? Loc.t("To-Do") : Loc.f("Priority %lld", n)) { e in
            for t in targets { e.toggleMarker(t, priority: n) }
        }
    }

    public func setTheme(_ id: String) {
        guard canvas.style.theme != id else { return }
        perform(Loc.t("Change Theme")) { e in e.updateMeta { $0.style.theme = id } }
    }

    func reshuffleColors() {
        perform(Loc.t("Smart Color")) { e in e.updateMeta { $0.style.paletteShift += 1 } }
        showToast(Loc.t("Smart color reshuffled"))
    }

    /// ⌥⌘1…9: the root changes the canvas structure; any other node overrides its branch.
    public func setStructure(_ s: LayoutStructure) {
        let target = selection.primary
        let root = canvas.root
        let technical = DiagramCatalog.isTechnical(canvas.type)
        morphSerial += 1
        perform(Loc.t("Change Structure")) { e in
            if target == root {
                // The central topic's structure is the canvas's type (Mind Map ⌥⌘T in the toolbar).
                if technical {
                    e.convert(to: Self.diagramType(for: s))
                }
                e.updateMeta {
                    $0.layout.structure = s
                    $0.type = Self.diagramType(for: s)
                }
            } else {
                e.update(target) { $0.structure = s }
            }
        }
        onReveal?(selection.primary)
    }

    /// The hierarchy diagram type that uses a structure.
    static func diagramType(for s: LayoutStructure) -> DiagramType {
        switch s.family {
        case "logic": .logic
        case "org": .org
        case "timeline": .timeline
        case "fishbone": .fishbone
        case "matrix": .matrix
        case "brace": .brace
        case "treeTable": .treeTable
        case "tree": .tree
        default: .mindmap
        }
    }

    // MARK: Select helpers

    func selectSiblings() {
        guard let p = canvas.parent(of: selection.primary), let kids = canvas.nodes[p]?.children else { return }
        setSelection(Selection(primary: selection.primary, nodes: kids))
    }

    func selectChildren() {
        guard let kids = canvas.nodes[selection.primary]?.children, let first = kids.first else { return }
        if canvas.nodes[selection.primary]?.folded == true {
            restructure(Loc.t("Unfold")) { [primary = selection.primary] in try $0.toggleFold(primary) }
        }
        setSelection(Selection(primary: first, nodes: kids))
    }

    func selectAll() {
        let all = canvas.visibleNodes()
        setSelection(Selection(primary: selection.primary, nodes: all))
    }
}
