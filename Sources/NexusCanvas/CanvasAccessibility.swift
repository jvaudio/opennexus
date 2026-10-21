import AppKit
import NexusCore
import NexusKeys
import NexusTheme

/// The canvas as VoiceOver sees it (M10, README §12): a tree of topics under the central
/// topic, each read as "Pricing. Main topic, level 2 of 4. 3 children, collapsed…",
/// with frames that follow the camera, actions that run the same commands as the keys,
/// and rotors for topics, notes, edges, boundaries, AI suggestions and Connect targets.
///
/// Elements are made only when an assistive app asks, reused per topic (VoiceOver keeps
/// its place across edits), and labels are computed when read, so a 5k map costs nothing
/// until VoiceOver walks it.
@MainActor
final class CanvasAccessibility: NSObject, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    weak var view: CanvasView?
    private var topics: [NodeID: TopicElement] = [:]
    private var edges: [String: ElementItem] = [:]
    private var boxes: [String: ElementItem] = [:]
    /// Connect targets that aren't topics.
    private var endItems: [RelationshipEnd: ElementItem] = [:]
    private var revision = -1
    private var depths: [NodeID: Int] = [:]
    private var maxDepth = 0
    private var parents: [NodeID: NodeID] = [:]

    init(view: CanvasView) {
        self.view = view
        super.init()
        Self.adoptElementProtocol
    }

    /// NSAccessibilityElement adopts only `NSAccessibility`; rotor results need the
    /// `NSAccessibilityElement` protocol, whose two required methods these classes have.
    /// Swift can't declare it on a subclass (the inherited `accessibilityIdentifier`
    /// signature clashes), so the runtime adds it once.
    private static let adoptElementProtocol: Void = {
        guard let proto = objc_getProtocol("NSAccessibilityElement") else { return }
        class_addProtocol(TopicElement.self, proto)
        class_addProtocol(ElementItem.self, proto)
        class_addProtocol(LegendItem.self, proto)
    }()

    var controller: CanvasController? { view?.controller }

    /// Recomputes depths and parents once per scene, and forgets topics that left it.
    func refresh() {
        guard let c = controller, c.sceneRevision != revision else { return }
        revision = c.sceneRevision
        let d = Spoken.depths(c.canvas)
        depths = d.depths
        maxDepth = d.max
        parents = c.canvas.parentMap()
        for id in topics.keys where c.scene.nodes[id] == nil { topics[id] = nil }
    }

    func element(_ id: NodeID) -> TopicElement? {
        refresh()
        guard controller?.scene.nodes[id] != nil else { return nil }
        if let e = topics[id] { return e }
        let e = TopicElement(id: id, tree: self)
        topics[id] = e
        return e
    }

    /// The canvas's children: the central topic, then floating, summary and callout tops,
    /// then the legend when it shows (M14).
    func roots() -> [Any] {
        guard let c = controller else { return [] }
        var out: [Any] = c.canvas.tops.compactMap { element($0) }
        if let l = legendItem() { out.append(l) }
        return out
    }

    private var legend: LegendItem?

    func legendItem() -> LegendItem? {
        guard let l = controller?.scene.legend else { return nil }
        let e = legend ?? LegendItem(tree: self)
        legend = e
        e.text = l.spoken
        e.world = l.rect
        return e
    }

    func children(of id: NodeID) -> [Any] {
        guard let c = controller else { return [] }
        var out: [Any] = (c.canvas.nodes[id]?.children ?? []).compactMap { element($0) }
        // AI suggestions show under the topic they'd join.
        if let g = c.ghosts, g.anchor == id {
            out += g.ideas.indices.compactMap { element(CanvasController.ghostID($0)) }
        }
        return out
    }

    func parent(of id: NodeID) -> Any? {
        if CanvasController.ghostIndex(id) != nil, let a = controller?.ghosts?.anchor { return element(a) }
        if let p = parents[id], let e = element(p) { return e }
        return view
    }

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
        guard let v = view, let w = v.window else { return .zero }
        return w.convertToScreen(v.convert(v.camera.toView(world), to: nil))
    }

    func frame(_ id: NodeID) -> CGRect {
        guard let r = controller?.scene.nodes[id]?.frame.rect else { return .zero }
        return screenRect(r)
    }

    func isSelected(_ id: NodeID) -> Bool { controller?.selection.nodes.contains(id) ?? false }
    func isPrimary(_ id: NodeID) -> Bool { controller?.selection.primary == id }

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

    // MARK: Context menus as actions (M17, D179)

    /// The target's context-menu items as custom actions, minus commands an element
    /// already offers and the Structure submenu (⌥⌘1–9 and the Format panel cover it).
    func menuActions(_ target: CanvasMenuTarget, skipping: Set<CommandID> = []) -> [NSAccessibilityCustomAction] {
        guard let c = controller else { return [] }
        var entries = c.contextMenu(previewing: target)
        if case .topic(let id) = target, c.canvas.nodes[id]?.image != nil {
            entries += c.contextMenu(previewing: .image(id))
        }
        var seen: [CanvasMenuAction] = []
        return entries.flatMap(\.items).compactMap { item in
            if let id = item.action.command, skipping.contains(id) || id.rawValue.hasPrefix("structure.") { return nil }
            // Replace Image… is Insert › Image… again.
            guard !seen.contains(item.action) else { return nil }
            seen.append(item.action)
            return NSAccessibilityCustomAction(name: item.title) { [weak self] in
                self?.runMenu(item.action, on: target) ?? false
            }
        }
    }

    /// Selects the target (that topic alone, or the element), then runs the item.
    func runMenu(_ action: CanvasMenuAction, on target: CanvasMenuTarget) -> Bool {
        guard let c = controller else { return false }
        switch target {
        case .topic(let id), .image(let id): c.select(id)
        case .element(let ref): c.selectElement(ref)
        case .legend, .canvas: break
        }
        return c.runMenuAction(action)
    }

    /// VoiceOver's Show Menu (VO-Shift-M): the same menu a right-click opens.
    func showMenu(_ target: CanvasMenuTarget, world: CGRect) -> Bool {
        guard let v = view, !world.isNull else { return false }
        return v.showContextMenu(target, at: v.camera.toView(world))
    }

    // MARK: Edges and boundaries

    func edgeItems() -> [ElementItem] {
        guard let c = controller else { return [] }
        return c.scene.relationships.filter { !$0.isVirtual }.map { r in
            let id = r.relationship.id
            let e = edges[id] ?? ElementItem(ref: .relationship(id), tree: self)
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

    /// A Connect candidate: its topic's element, or an item for a zone, boundary or summary.
    func connectItem(_ cand: ConnectCandidate) -> NSAccessibilityElement? {
        guard let c = controller else { return nil }
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
        let e = endItems[cand.end] ?? ElementItem(ref: ref, tree: self)
        endItems[cand.end] = e
        e.text = Loc.f("Hint %@. ", cand.hint.uppercased()) + spoken
        e.world = rect
        return e
    }

    func boundaryItems() -> [ElementItem] {
        guard let c = controller else { return [] }
        return c.scene.boundaries.map { b in
            let id = b.boundary.id
            let e = boxes[id] ?? ElementItem(ref: .boundary(id), tree: self)
            boxes[id] = e
            let title = b.boundary.title.isEmpty ? Loc.t("Boundary") : b.boundary.title
            e.text =
                Loc.f("%@. Boundary around %@.", title, Loc.n("%lld topic", "%lld topics", b.boundary.nodes.count))
            e.world = b.rect
            return e
        }
    }

    // MARK: Rotors

    enum RotorKind: String, CaseIterable {
        case topics = "Topics", notes = "Notes", comments = "Comments", edges = "Edges", boundaries = "Boundaries"
        case suggestions = "AI suggestions", connect = "Connect targets"

        var title: String {
            switch self {
            case .topics: Loc.t("Topics")
            case .notes: Loc.t("Notes")
            case .comments: Loc.t("Comments")
            case .edges: Loc.t("Edges")
            case .boundaries: Loc.t("Boundaries")
            case .suggestions: Loc.t("AI suggestions")
            case .connect: Loc.t("Connect targets")
            }
        }
    }

    private var rotorKinds: [ObjectIdentifier: RotorKind] = [:]

    func rotors() -> [NSAccessibilityCustomRotor] {
        RotorKind.allCases.map { k in
            let r = NSAccessibilityCustomRotor(label: k.title, itemSearchDelegate: self)
            rotorKinds[ObjectIdentifier(r)] = k
            return r
        }
    }

    /// The rotor's items, in reading order.
    func items(_ kind: RotorKind) -> [NSAccessibilityElement] {
        guard let c = controller else { return [] }
        func preorder() -> [NodeID] {
            var out: [NodeID] = []
            for top in c.canvas.tops { c.canvas.walk(from: top) { id, _, _ in out.append(id) } }
            return out.filter { c.scene.nodes[$0] != nil }
        }
        switch kind {
        case .topics: return preorder().compactMap { element($0) }
        case .notes: return preorder().filter { c.canvas.nodes[$0]?.note != nil }.compactMap { element($0) }
        case .comments:
            return preorder().filter { !(c.canvas.nodes[$0]?.comments.isEmpty ?? true) }.compactMap { element($0) }
        case .edges: return edgeItems()
        case .boundaries: return boundaryItems()
        case .suggestions:
            return (c.ghosts?.ideas.indices).map { $0.compactMap { element(CanvasController.ghostID($0)) } } ?? []
        case .connect: return c.connect?.candidates.compactMap(connectItem) ?? []
        }
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let kind = rotorKinds[ObjectIdentifier(rotor)] else { return nil }
        let list = items(kind)
        guard !list.isEmpty else { return nil }
        let current = searchParameters.currentItem?.targetElement as? NSAccessibilityElement
        let i = current.flatMap { cur in list.firstIndex { $0 === cur } }
        let next: Int
        switch searchParameters.searchDirection {
        case .previous: next = i.map { $0 - 1 } ?? list.count - 1
        default: next = i.map { $0 + 1 } ?? 0
        }
        // Checked at runtime (see adoptElementProtocol).
        guard list.indices.contains(next), let target = (list[next] as AnyObject) as? any NSAccessibilityElementProtocol
        else {
            return nil
        }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: target)
        result.customLabel = list[next].accessibilityLabel()
        return result
    }
}

/// Accessibility calls arrive on the main thread; this asserts it and carries the
/// (non-Sendable) result out.
nonisolated func onMain<T>(_ body: @MainActor () -> T) -> T {
    nonisolated(unsafe) var result: T?
    MainActor.assumeIsolated { result = body() }
    return result!
}

/// One topic (or AI suggestion) on the canvas.
@MainActor
final class TopicElement: NSAccessibilityElement {
    let id: NodeID
    unowned let tree: CanvasAccessibility

    init(id: NodeID, tree: CanvasAccessibility) {
        self.id = id
        self.tree = tree
        super.init()
        setAccessibilityIdentifier("topic-\(id.rawValue)")
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? {
        CanvasController.ghostIndex(id) != nil ? "suggestion" : "topic"
    }
    override func accessibilityLabel() -> String? { tree.label(id) }
    override func accessibilityFrame() -> NSRect { tree.frame(id) }
    override func accessibilityParent() -> Any? {
        let (t, i) = (tree, id)
        return onMain { t.parent(of: i) }
    }
    override func accessibilityChildren() -> [Any]? {
        let (t, i) = (tree, id)
        return onMain { t.children(of: i) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilitySelected() -> Bool { tree.isSelected(id) }
    override func isAccessibilityFocused() -> Bool { tree.isPrimary(id) }
    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        tree.select(id)
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard CanvasController.ghostIndex(id) == nil else { return nil }
        let folded = tree.controller?.canvas.nodes[id]?.folded ?? false
        let hasChildren = !(tree.controller?.canvas.nodes[id]?.children.isEmpty ?? true)
        var actions = [
            NSAccessibilityCustomAction(name: Loc.t("Edit")) { [weak self] in
                guard let self else { return false }
                self.tree.edit(self.id)
                return true
            },
            NSAccessibilityCustomAction(name: Loc.t("Add child")) { [weak self] in
                guard let self else { return false }
                return self.tree.run(.addChild, on: self.id)
            },
            NSAccessibilityCustomAction(name: Loc.t("Add sibling")) { [weak self] in
                guard let self else { return false }
                return self.tree.run(.addSiblingAfter, on: self.id)
            },
            NSAccessibilityCustomAction(name: Loc.t("Connect from here")) { [weak self] in
                guard let self else { return false }
                return self.tree.run(.connect, on: self.id)
            },
            NSAccessibilityCustomAction(name: Loc.t("Comments")) { [weak self] in
                guard let self else { return false }
                return self.tree.run(.comment, on: self.id)
            },
        ]
        if hasChildren {
            actions.append(
                NSAccessibilityCustomAction(name: folded ? Loc.t("Unfold") : Loc.t("Fold")) { [weak self] in
                    guard let self else { return false }
                    return self.tree.run(.fold, on: self.id)
                })
        }
        // The rest of the topic's context menu (D179).
        let (t, i) = (tree, id)
        return actions + onMain { t.menuActions(.topic(i), skipping: Self.ownActions) }
    }

    /// Commands the actions above already cover.
    static let ownActions: Set<CommandID> = [.editKeepText, .addChild, .addSiblingAfter, .connect, .comment, .fold]

    override func accessibilityPerformShowMenu() -> Bool {
        guard CanvasController.ghostIndex(id) == nil, let r = tree.controller?.scene.nodes[id]?.frame.rect else {
            return false
        }
        return tree.showMenu(.topic(id), world: r)
    }
}

/// The legend box (M14): read as one element; pressing it opens Edit Legend….
@MainActor
final class LegendItem: NSAccessibilityElement {
    unowned let tree: CanvasAccessibility
    var text = ""
    var world = CGRect.null

    init(tree: CanvasAccessibility) {
        self.tree = tree
        super.init()
        setAccessibilityIdentifier("legend")
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { Loc.t("legend") }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityFrame() -> NSRect { world.isNull ? .zero : tree.screenRect(world) }
    override func accessibilityParent() -> Any? {
        let t = tree
        return onMain { t.view }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        tree.controller?.editLegend()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [
            NSAccessibilityCustomAction(name: Loc.t("Edit Legend")) { [weak self] in
                self?.tree.controller?.editLegend()
                return true
            },
            NSAccessibilityCustomAction(name: Loc.t("Hide Legend")) { [weak self] in
                self?.tree.controller?.toggleLegend()
                return true
            },
        ]
    }
    override func accessibilityPerformShowMenu() -> Bool { tree.showMenu(.legend, world: world) }
}

/// A relationship or boundary, reached through the rotors.
@MainActor
final class ElementItem: NSAccessibilityElement {
    let ref: ElementRef
    unowned let tree: CanvasAccessibility
    var text = ""
    var world = CGRect.null

    init(ref: ElementRef, tree: CanvasAccessibility) {
        self.ref = ref
        self.tree = tree
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? {
        switch ref {
        case .boundary: return "boundary"
        case .zone: return "zone"
        case .summary: return "summary"
        default: return "relationship"
        }
    }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityFrame() -> NSRect { world.isNull ? .zero : tree.screenRect(world) }
    override func accessibilityParent() -> Any? {
        let t = tree
        return onMain { t.view }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        tree.controller?.selectElement(ref)
        return true
    }
    /// Edit, style and delete, as on the element's context menu (D179).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let (t, r) = (tree, ref)
        return onMain { t.menuActions(.element(r)) }
    }
    override func accessibilityPerformShowMenu() -> Bool { tree.showMenu(.element(ref), world: world) }
}
