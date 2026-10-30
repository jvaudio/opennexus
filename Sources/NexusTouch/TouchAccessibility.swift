#if os(iOS)
import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import UIKit

/// The canvas as VoiceOver sees it on the iPad (M47b, D392): the Mac's labels, actions and
/// rotors (`CanvasAccessibility`) as UIAccessibility elements. iOS reads a container as a
/// list, so topics come in reading order (preorder from each top) and the tree is in each
/// label ("level 2 of 4"); zones and the legend follow, then the canvas's own actions.
///
/// As on the Mac, elements are made only when an assistive app (or a UI test) asks, are
/// reused per topic so VoiceOver keeps its place across edits, and labels and frames are
/// computed when read.
@MainActor
final class TouchAccessibility {
    weak var view: TouchCanvasView?
    private var topics: [NodeID: TopicItem] = [:]
    private var zones: [String: ZoneItem] = [:]
    private var edges: [String: ElementItem] = [:]
    private var boxes: [String: ElementItem] = [:]
    private var endItems: [RelationshipEnd: ElementItem] = [:]
    private var legend: LegendItem?
    private lazy var canvasItem = CanvasItem(tree: self)
    private var revision = -1
    private var depths: [NodeID: Int] = [:]
    private var maxDepth = 0
    private var parents: [NodeID: NodeID] = [:]
    private var order: [NodeID] = []

    init(view: TouchCanvasView) { self.view = view }

    var controller: CanvasController? { view?.controller }

    /// Recomputes depths, parents and the reading order once per scene, and forgets topics
    /// that left it.
    func refresh() {
        guard let c = controller, c.sceneRevision != revision else { return }
        revision = c.sceneRevision
        let d = Spoken.depths(c.canvas)
        depths = d.depths
        maxDepth = d.max
        parents = c.canvas.parentMap()
        var out: [NodeID] = []
        for top in c.canvas.tops {
            c.canvas.walk(from: top) { id, _, _ in
                out.append(id)
                // AI suggestions read after the topic they'd join.
                if let g = c.ghosts, g.anchor == id { out += g.ideas.indices.map(CanvasController.ghostID) }
            }
        }
        order = out.filter { c.scene.nodes[$0] != nil }
        for id in topics.keys where c.scene.nodes[id] == nil { topics[id] = nil }
    }

    func element(_ id: NodeID) -> TopicItem? {
        refresh()
        guard let v = view, controller?.scene.nodes[id] != nil else { return nil }
        if let e = topics[id] { return e }
        let e = TopicItem(id: id, tree: self, container: v)
        topics[id] = e
        return e
    }

    /// The canvas's elements: topics, zones, the legend when it shows, the canvas.
    func elements() -> [Any] {
        refresh()
        var out: [Any] = order.compactMap { element($0) }
        out += zoneItems()
        if let l = legendItem() { out.append(l) }
        out.append(canvasItem)
        return out
    }

    // MARK: Labels and frames

    func label(_ id: NodeID) -> String {
        guard let c = controller, let s = c.scene.nodes[id] else { return "" }
        if let i = CanvasController.ghostIndex(id) {
            return i == c.ghosts?.highlighted
                ? Loc.f("Suggested topic: %@. Highlighted. Control-Return accepts it.", s.displayText)
                : Loc.f("Suggested topic: %@. Control-Return accepts it.", s.displayText)
        }
        var text = Spoken.describe(
            id, in: c.canvas, prefs: c.prefs, branchColor: Spoken.colorName(s.branchColor), depth: depths[id],
            maxDepth: maxDepth)
        if let k = c.connect, let cand = k.candidates.first(where: { $0.node == id }) {
            text = Loc.f("Hint %@. ", cand.hint.uppercased()) + text
        }
        return text
    }

    /// A world rectangle on screen, through the camera.
    func screenRect(_ world: CGRect) -> CGRect {
        guard let v = view, !world.isNull else { return .zero }
        return UIAccessibility.convertToScreenCoordinates(v.camera.toView(world), in: v)
    }

    func frame(_ id: NodeID) -> CGRect { screenRect(controller?.scene.nodes[id]?.frame.rect ?? .null) }

    func isSelected(_ id: NodeID) -> Bool { controller?.selection.nodes.contains(id) ?? false }

    // MARK: Zones and the legend

    func zoneItems() -> [ZoneItem] {
        guard let c = controller, let v = view else { return [] }
        let ids = c.scene.zones.map(\.zone.id)
        for id in zones.keys where !ids.contains(id) { zones[id] = nil }
        return ids.map { id in
            let e = zones[id] ?? ZoneItem(id: id, tree: self, container: v)
            zones[id] = e
            return e
        }
    }

    func zoneItem(_ id: String) -> ZoneItem? { zoneItems().first { $0.id == id } }

    /// "Ideas. Zone around 2 topics. Selected, 1 of 2 selected zones."
    func zoneLabel(_ id: String) -> String {
        guard let c = controller, let z = c.canvas.zones.first(where: { $0.id == id }) else { return "" }
        let title = z.title.isEmpty ? Loc.t("Zone") : z.title
        let count = z.members.reduce(0) { $0 + c.canvas.subtree($1).count }
        var text = Loc.f("%@. Zone around %@.", title, Loc.n("%lld topic", "%lld topics", count))
        if z.collapsed { text += " " + Loc.t("Collapsed.") }
        let selected = c.selectedZones
        if let i = selected.firstIndex(of: id), selected.count > 1 {
            text += " " + Loc.f("%lld of %lld selected zones.", i + 1, selected.count)
        }
        return text
    }

    func zoneFrame(_ id: String) -> CGRect {
        screenRect(controller?.scene.zones.first(where: { $0.zone.id == id })?.rect ?? .null)
    }

    func legendItem() -> LegendItem? {
        guard let l = controller?.scene.legend, let v = view else { return nil }
        let e = legend ?? LegendItem(tree: self, container: v)
        legend = e
        e.text = l.spoken
        return e
    }

    // MARK: Actions (the same commands as the keys, so each is one undo step)

    func select(_ id: NodeID) {
        guard let c = controller else { return }
        if let i = CanvasController.ghostIndex(id) {
            c.ghosts?.highlighted = i
            _ = c.perform(.aiAccept)
            return
        }
        c.select(id)
        c.onReveal?(id)
    }

    func run(_ command: CommandID, on id: NodeID) -> Bool {
        guard let c = controller else { return false }
        c.select(id)
        return c.perform(command)
    }

    func edit(_ id: NodeID) {
        controller?.select(id)
        controller?.beginEditing(id)
    }

    /// The target's context-menu items as custom actions, minus commands an element
    /// already offers and the structures (⌥⌘1–9 and the Format panel cover them) (D179).
    func menuActions(_ target: CanvasMenuTarget, skipping: Set<CommandID> = []) -> [UIAccessibilityCustomAction] {
        guard let c = controller else { return [] }
        var entries = c.contextMenu(previewing: target)
        if case .topic(let id) = target, c.canvas.nodes[id]?.image != nil {
            entries += c.contextMenu(previewing: .image(id))
        }
        var seen: [CanvasMenuAction] = []
        return entries.flatMap(\.items).compactMap { item in
            if let id = item.action.command, skipping.contains(id) || id.rawValue.hasPrefix("structure.") { return nil }
            if case .structure = item.action { return nil }
            guard !seen.contains(item.action) else { return nil }
            seen.append(item.action)
            return UIAccessibilityCustomAction(name: item.title) { [weak self] _ in
                self?.runMenu(item.action, on: target) ?? false
            }
        }
    }

    /// Selects the target, then runs the item. A zone in the selected group keeps the
    /// group, as a long press on it does (D228, D262).
    func runMenu(_ action: CanvasMenuAction, on target: CanvasMenuTarget) -> Bool {
        guard let c = controller else { return false }
        switch target {
        case .topic(let id), .image(let id): c.select(id)
        case .element(.zone(let id)) where c.selectedZones.count > 1 && c.selectedZones.contains(id):
            c.selectElement(.zone(id), zones: c.selectedZones)
        case .element(let ref): c.selectElement(ref)
        case .legend, .canvas: break
        }
        if case .command(let id) = action, !c.canPerform(id), view?.onWindowCommand?(id) == true { return true }
        return c.runMenuAction(action)
    }

    /// Actions for the whole canvas: the empty-canvas menu at the view's centre.
    func canvasActions() -> [UIAccessibilityCustomAction] {
        guard let v = view else { return [] }
        return menuActions(.canvas(v.camera.toWorld(CGPoint(x: v.bounds.midX, y: v.bounds.midY))))
    }

    // MARK: Edges and boundaries

    func edgeItems() -> [ElementItem] {
        guard let c = controller, let v = view else { return [] }
        return c.scene.relationships.filter { !$0.isVirtual }.map { r in
            let id = r.relationship.id
            let e = edges[id] ?? ElementItem(ref: .relationship(id), tree: self, container: v)
            edges[id] = e
            let from = c.canvas.spokenName(r.relationship.from)
            let to = c.canvas.spokenName(r.relationship.to)
            e.text =
                r.relationship.label.isEmpty
                ? Loc.f("%@ to %@. Relationship.", from, to)
                : Loc.f("%@ to %@, %@. Relationship.", from, to, r.relationship.label)
            let a = c.scene.rect(of: r.relationship.from) ?? .null
            let b = c.scene.rect(of: r.relationship.to) ?? .null
            e.world = a.union(b)
            return e
        }
    }

    func boundaryItems() -> [ElementItem] {
        guard let c = controller, let v = view else { return [] }
        return c.scene.boundaries.map { b in
            let id = b.boundary.id
            let e = boxes[id] ?? ElementItem(ref: .boundary(id), tree: self, container: v)
            boxes[id] = e
            let title = b.boundary.title.isEmpty ? Loc.t("Boundary") : b.boundary.title
            e.text =
                Loc.f("%@. Boundary around %@.", title, Loc.n("%lld topic", "%lld topics", b.boundary.nodes.count))
            e.world = b.rect
            return e
        }
    }

    /// A Connect candidate: its topic's element, or an item for a zone, boundary or summary.
    func connectItem(_ cand: ConnectCandidate) -> UIAccessibilityElement? {
        guard let c = controller, let v = view else { return nil }
        let ref: ElementRef
        let spoken: String
        switch cand.end {
        case .topic(let id): return element(id)
        case .zone(let id):
            let title = c.canvas.zones.first { $0.id == id }?.title ?? ""
            ref = .zone(id)
            spoken = Loc.f("%@. Zone.", title.isEmpty ? Loc.t("Zone") : title)
        case .boundary(let id):
            let title = c.canvas.boundaries.first { $0.id == id }.map(c.canvas.boundaryTitle) ?? ""
            ref = .boundary(id)
            spoken = Loc.f("%@. Boundary.", title.isEmpty ? Loc.t("Boundary") : title)
        case .summary(let id):
            let text = c.canvas.summaries.first { $0.id == id }.flatMap { c.canvas.nodes[$0.topic]?.text } ?? ""
            ref = .summary(id)
            spoken = Loc.f("%@. Summary.", text.isEmpty ? Loc.t("Summary") : text)
        }
        guard let rect = c.scene.rect(of: cand.end) else { return nil }
        let e = endItems[cand.end] ?? ElementItem(ref: ref, tree: self, container: v)
        endItems[cand.end] = e
        e.text = Loc.f("Hint %@. ", cand.hint.uppercased()) + spoken
        e.world = rect
        return e
    }

    // MARK: Rotors

    enum RotorKind: CaseIterable {
        case topics, notes, comments, edges, boundaries, zones, suggestions, connect

        var title: String {
            switch self {
            case .topics: Loc.t("Topics")
            case .notes: Loc.t("Notes")
            case .comments: Loc.t("Comments")
            case .edges: Loc.t("Edges")
            case .boundaries: Loc.t("Boundaries")
            case .zones: Loc.t("Zones")
            case .suggestions: Loc.t("AI suggestions")
            case .connect: Loc.t("Connect targets")
            }
        }
    }

    func items(_ kind: RotorKind) -> [UIAccessibilityElement] {
        guard let c = controller else { return [] }
        refresh()
        let topics = order.filter { CanvasController.ghostIndex($0) == nil }
        switch kind {
        case .topics: return topics.compactMap { element($0) }
        case .notes: return topics.filter { c.canvas.nodes[$0]?.note != nil }.compactMap { element($0) }
        case .comments:
            return topics.filter { !(c.canvas.nodes[$0]?.comments.isEmpty ?? true) }.compactMap { element($0) }
        case .edges: return edgeItems()
        case .boundaries: return boundaryItems()
        case .zones: return zoneItems()
        case .suggestions:
            return (c.ghosts?.ideas.indices).map { $0.compactMap { element(CanvasController.ghostID($0)) } } ?? []
        case .connect: return c.connect?.candidates.compactMap(connectItem) ?? []
        }
    }

    func rotors() -> [UIAccessibilityCustomRotor] {
        RotorKind.allCases.map { kind in
            UIAccessibilityCustomRotor(name: kind.title) { [weak self] search in
                guard let self else { return nil }
                let list = self.items(kind)
                guard !list.isEmpty else { return nil }
                let current = search.currentItem.targetElement as? UIAccessibilityElement
                let i = current.flatMap { cur in list.firstIndex { $0 === cur } }
                let next =
                    search.searchDirection == .previous ? i.map { $0 - 1 } ?? list.count - 1 : i.map { $0 + 1 } ?? 0
                guard list.indices.contains(next) else { return nil }
                return UIAccessibilityCustomRotorItemResult(targetElement: list[next], targetRange: nil)
            }
        }
    }
}

/// One topic (or AI suggestion).
@MainActor
final class TopicItem: UIAccessibilityElement {
    let id: NodeID
    unowned let tree: TouchAccessibility

    init(id: NodeID, tree: TouchAccessibility, container: Any) {
        self.id = id
        self.tree = tree
        super.init(accessibilityContainer: container)
        accessibilityIdentifier = "topic-\(id.rawValue)"
    }

    override var accessibilityLabel: String? {
        get { tree.label(id) }
        set {}
    }
    override var accessibilityFrame: CGRect {
        get { tree.frame(id) }
        set {}
    }
    override var accessibilityTraits: UIAccessibilityTraits {
        get { tree.isSelected(id) ? [.button, .selected] : .button }
        set {}
    }
    override var accessibilityHint: String? {
        get { CanvasController.ghostIndex(id) == nil ? Loc.t("Double-tap to select. Actions to edit.") : nil }
        set {}
    }
    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        tree.select(id)
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard CanvasController.ghostIndex(id) == nil else { return nil }
            let node = tree.controller?.canvas.nodes[id]
            func action(_ name: String, _ body: @escaping @MainActor (TopicItem) -> Bool) -> UIAccessibilityCustomAction
            {
                UIAccessibilityCustomAction(name: name) { [weak self] _ in self.map(body) ?? false }
            }
            var actions = [
                action(Loc.t("Edit")) {
                    $0.tree.edit($0.id)
                    return true
                },
                action(Loc.t("Add child")) { $0.tree.run(.addChild, on: $0.id) },
                action(Loc.t("Add sibling")) { $0.tree.run(.addSiblingAfter, on: $0.id) },
                action(Loc.t("Connect from here")) { $0.tree.run(.connect, on: $0.id) },
                action(Loc.t("Comments")) { $0.tree.run(.comment, on: $0.id) },
            ]
            if !(node?.children.isEmpty ?? true) {
                actions.append(
                    action((node?.folded ?? false) ? Loc.t("Unfold") : Loc.t("Fold")) { $0.tree.run(.fold, on: $0.id) })
            }
            return actions + tree.menuActions(.topic(id), skipping: Self.ownActions)
        }
        set {}
    }

    /// Commands the actions above already cover.
    static let ownActions: Set<CommandID> = [.editKeepText, .addChild, .addSiblingAfter, .connect, .comment, .fold]
}

/// A zone (M34, D262): read with its place among the selected zones.
@MainActor
final class ZoneItem: UIAccessibilityElement {
    let id: String
    unowned let tree: TouchAccessibility

    init(id: String, tree: TouchAccessibility, container: Any) {
        self.id = id
        self.tree = tree
        super.init(accessibilityContainer: container)
        accessibilityIdentifier = "zone-\(id)"
    }

    override var accessibilityLabel: String? {
        get { tree.zoneLabel(id) }
        set {}
    }
    override var accessibilityFrame: CGRect {
        get { tree.zoneFrame(id) }
        set {}
    }
    override var accessibilityTraits: UIAccessibilityTraits {
        get { (tree.controller?.selectedZones.contains(id) ?? false) ? [.button, .selected] : .button }
        set {}
    }
    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        tree.controller?.selectElement(.zone(id))
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let selected = tree.controller?.selectedZones.contains(id) ?? false
            let toggle = UIAccessibilityCustomAction(
                name: selected ? Loc.t("Remove from Selection") : Loc.t("Add to Selection")
            ) { [weak self] _ in
                guard let self, let c = self.tree.controller else { return false }
                c.toggleZone(self.id)
                return true
            }
            return [toggle] + tree.menuActions(.element(.zone(id)))
        }
        set {}
    }
}

/// The legend box (M14): read as one element; activating it opens Edit Legend….
@MainActor
final class LegendItem: UIAccessibilityElement {
    unowned let tree: TouchAccessibility
    var text = ""

    init(tree: TouchAccessibility, container: Any) {
        self.tree = tree
        super.init(accessibilityContainer: container)
        accessibilityIdentifier = "legend"
    }

    override var accessibilityLabel: String? {
        get { text }
        set {}
    }
    override var accessibilityFrame: CGRect {
        get { tree.screenRect(tree.controller?.scene.legend?.rect ?? .null) }
        set {}
    }
    override var accessibilityTraits: UIAccessibilityTraits {
        get { .button }
        set {}
    }
    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        tree.controller?.editLegend()
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            var actions = [
                UIAccessibilityCustomAction(name: Loc.t("Hide Legend")) { [weak self] _ in
                    self?.tree.controller?.toggleLegend()
                    return true
                }
            ]
            // The same steps as the arrow keys, one undo step each (M21, D203).
            let moves: [(String, Double, Double)] = [
                (Loc.t("Move Legend Left"), -1, 0), (Loc.t("Move Legend Right"), 1, 0),
                (Loc.t("Move Legend Up"), 0, -1), (Loc.t("Move Legend Down"), 0, 1),
            ]
            for (name, dx, dy) in moves {
                actions.append(
                    UIAccessibilityCustomAction(name: name) { [weak self] _ in
                        self?.tree.controller?.nudgeLegend(dx: dx, dy: dy)
                        return true
                    })
            }
            if tree.controller?.canvas.legend?.position != nil {
                actions.append(
                    UIAccessibilityCustomAction(name: Loc.t("Reset Legend Position")) { [weak self] _ in
                        self?.tree.controller?.moveLegend(to: nil)
                        return true
                    })
            }
            return actions
        }
        set {}
    }
}

/// A relationship, boundary or Connect target, reached through the rotors.
@MainActor
final class ElementItem: UIAccessibilityElement {
    let ref: ElementRef
    unowned let tree: TouchAccessibility
    var text = ""
    var world = CGRect.null

    init(ref: ElementRef, tree: TouchAccessibility, container: Any) {
        self.ref = ref
        self.tree = tree
        super.init(accessibilityContainer: container)
    }

    override var accessibilityLabel: String? {
        get { text }
        set {}
    }
    override var accessibilityFrame: CGRect {
        get { tree.screenRect(world) }
        set {}
    }
    override var accessibilityTraits: UIAccessibilityTraits {
        get { .button }
        set {}
    }
    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        tree.controller?.selectElement(ref)
        return true
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { tree.menuActions(.element(ref)) }
        set {}
    }
}

/// The canvas itself, last in reading order: what's selected, and the empty-canvas menu
/// (paste, a floating topic, a zone, select all, fit, export) as actions (M17, D179).
@MainActor
final class CanvasItem: UIAccessibilityElement {
    unowned let tree: TouchAccessibility

    init(tree: TouchAccessibility) {
        self.tree = tree
        super.init(accessibilityContainer: tree.view as Any)
        accessibilityIdentifier = "canvas-actions"
    }

    override var accessibilityLabel: String? {
        get { Loc.t("Canvas") }
        set {}
    }
    override var accessibilityValue: String? {
        get {
            guard let c = tree.controller else { return nil }
            if case .zone(let id)? = c.selectedElement { return tree.zoneLabel(id) }
            return tree.label(c.selection.primary)
        }
        set {}
    }
    override var accessibilityFrame: CGRect {
        get { tree.view.map { UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0) } ?? .zero }
        set {}
    }
    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { tree.canvasActions() }
        set {}
    }
}

extension TouchCanvasView {
    func installAccessibility() {
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = Loc.t("Canvas")
    }

    /// Topics, zones, the legend and the canvas's actions, then the editor while typing.
    public override var accessibilityElements: [Any]? {
        get { accessibilityTree.elements() + (editor.isHidden ? [] : [editor]) }
        set {}
    }

    public override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get { accessibilityTree.rotors() }
        set {}
    }

    /// VoiceOver follows the selection, the selected zone and the legend; Connect mode
    /// reads its targets (only work done while an assistive app runs).
    func accessibilityChanged() {
        guard assistiveAppRunning, controller.canvas.nodes[controller.selection.primary] != nil else {
            if controller.connect == nil { announced.connect = false }
            return
        }
        let tree = accessibilityTree
        var focus: Any?
        if controller.legendActive != announced.legend {
            announced.legend = controller.legendActive
            if announced.legend { focus = tree.legendItem() } else { announced.primary = nil }
        }
        let zones = controller.selectedZones
        if focus == nil, !announced.legend, zones != announced.zones {
            announced.zones = zones
            if case .zone(let id)? = controller.selectedElement {
                focus = tree.zoneItem(id)
            } else {
                announced.primary = nil
            }
        }
        if focus == nil, !announced.legend, zones.isEmpty, announced.primary != controller.selection.primary {
            announced.primary = controller.selection.primary
            focus = tree.element(controller.selection.primary)
        }
        if let focus { UIAccessibility.post(notification: .layoutChanged, argument: focus) }
        if let s = controller.connect, !announced.connect {
            announced.connect = true
            if controller.prefs.bool("accessibility.announceConnect") {
                let texts = controller.connectTexts
                let targets = s.candidates.prefix(6).compactMap { cand in
                    texts[cand.end].map { "\(cand.hint.uppercased()), \($0)" }
                }
                UIAccessibility.post(
                    notification: .announcement, argument: Loc.t("Connect mode. ") + targets.joined(separator: "; "))
            }
        } else if controller.connect == nil {
            announced.connect = false
        }
    }
}

/// What VoiceOver was last told about.
struct Announced {
    var primary: NodeID?
    var legend = false
    var zones: [String] = []
    var connect = false
}
#endif
