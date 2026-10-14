import Foundation
import NexusCore
import NexusKeys
import NexusLayout

/// Command handlers, bound to registry ids. Anything not listed here is handled by the
/// view (zoom, fit) or later milestones, and shows as disabled.
@MainActor
extension CanvasController {
    /// Xmind's nine structures in ⌥⌘1…9 order.
    public static let structureCycle: [LayoutStructure] = [
        .mindmapBalanced, .logicRight, .braceRight, .orgDown, .treeDown, .timelineHorizontal, .fishboneLeft,
        .matrix, .treeTable,
    ]

    /// Commands that work in Select mode on the current selection.
    private var handlers: [CommandID: (CanvasController) -> Void] {
        var h: [CommandID: (CanvasController) -> Void] = [
            .addChild: { $0.addChild() },
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
            .collapseSelection: { $0.setSelection(Selection($0.selection.primary)) },
            .moveUp: { c in c.restructure("Move Up") { try $0.reorder(c.selection.primary, by: -1) } },
            .moveDown: { c in c.restructure("Move Down") { try $0.reorder(c.selection.primary, by: 1) } },
            .promote: { c in c.restructure("Promote") { try $0.promote(c.selection.primary) } },
            .demote: { c in c.restructure("Demote") { try $0.demote(c.selection.primary) } },
            .delete: { $0.deleteSelection(keepChildren: false) },
            .deleteKeepChildren: { $0.deleteSelection(keepChildren: true) },
            .fold: { c in c.restructure("Fold") { try $0.toggleFold(c.selection.primary) } },
            .foldAll: { c in c.restructure("Fold All") { try $0.toggleFoldAll() } },
            .toggleTodo: { $0.toggleMarker(0) },
            .smartColor: { $0.reshuffleColors() },
        ]
        for n in 1...9 {
            h[.priority(n)] = { $0.toggleMarker(n) }
            h[.structure(n)] = { $0.setStructure(Self.structureCycle[n - 1]) }
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
                c.restructure("Promote") { try $0.promote(c.selection.primary) }
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
            return canvas.nodes[selection.primary] != nil
        case .edit:
            return editorHandlers[id] != nil
        case .connect:
            return false
        }
    }

    /// Runs a command if it applies in the current mode. Returns false if it does not.
    @discardableResult
    public func perform(_ id: CommandID) -> Bool {
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
            return false
        }
    }

    // MARK: Create

    /// Inserts a node and opens its editor in the same call: the caret is live before
    /// any animation starts.
    private func create(_ name: String, _ body: (inout CanvasEditor) throws -> NodeID) {
        let s = signposter.beginInterval("create→caret")
        defer { signposter.endInterval("create→caret", s) }
        guard let id = perform(name, refresh: false, selectionAfter: { Selection($0) }, body) else { return }
        let text = canvas.nodes[id]?.text ?? ""
        edit = EditSession(node: id, text: text, selectAll: true)
        mode = .edit
        rebuildScene()
        onEditChange?(edit)
        onSceneChange?(true)
        onReveal?(id)
    }

    public func addChild() {
        let target = selection.primary
        create("Add Topic") { try $0.addChild(of: target) }
    }

    public func addSibling(before: Bool) {
        let target = selection.primary
        create("Add Topic") { try $0.addSibling(of: target, before: before) }
    }

    public func addParent() {
        let target = selection.primary
        create("Add Parent Topic") { try $0.addParent(of: target) }
    }

    public func addFloating(at point: CGPoint?) {
        let p = point ?? floatingPlacement?() ?? defaultFloatingPoint()
        create("Add Floating Topic") { $0.addFloating(at: CanvasPoint(x: p.x, y: p.y)) }
    }

    private func defaultFloatingPoint() -> CGPoint {
        let b = scene.bounds
        guard !b.isNull else { return CGPoint(x: 0, y: 160) }
        return CGPoint(x: b.minX + 60, y: b.maxY + 60)
    }

    func duplicateBranch() {
        let target = selection.primary
        perform("Duplicate", selectionAfter: { Selection($0) }) { try $0.duplicate(target) }
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
            perform("Delete", selectionAfter: { Selection($0) }) { try $0.deleteKeepingChildren(target) }
        } else {
            perform("Delete", selectionAfter: { Selection($0) }) { try $0.delete(targets) }
        }
        onReveal?(selection.primary)
    }

    func toggleMarker(_ n: Int) {
        let targets = selection.nodes
        perform(n == 0 ? "To-Do" : "Priority \(n)") { e in
            for t in targets { e.toggleMarker(t, priority: n) }
        }
    }

    public func setTheme(_ id: String) {
        guard canvas.style.theme != id else { return }
        perform("Change Theme") { e in e.updateMeta { $0.style.theme = id } }
    }

    func reshuffleColors() {
        perform("Smart Color") { e in e.updateMeta { $0.style.paletteShift += 1 } }
        showToast("Smart color reshuffled")
    }

    /// ⌥⌘1…9: the root changes the canvas structure; any other node overrides its branch.
    public func setStructure(_ s: LayoutStructure) {
        let target = selection.primary
        let root = canvas.root
        perform("Change Structure") { e in
            if target == root {
                e.updateMeta { $0.layout.structure = s }
            } else {
                e.update(target) { $0.structure = s }
            }
        }
        onReveal?(selection.primary)
    }

    // MARK: Select helpers

    func selectSiblings() {
        guard let p = canvas.parent(of: selection.primary), let kids = canvas.nodes[p]?.children else { return }
        setSelection(Selection(primary: selection.primary, nodes: kids))
    }

    func selectChildren() {
        guard let kids = canvas.nodes[selection.primary]?.children, let first = kids.first else { return }
        if canvas.nodes[selection.primary]?.folded == true {
            restructure("Unfold") { [primary = selection.primary] in try $0.toggleFold(primary) }
        }
        setSelection(Selection(primary: first, nodes: kids))
    }

    func selectAll() {
        let all = canvas.visibleNodes()
        setSelection(Selection(primary: selection.primary, nodes: all))
    }
}
