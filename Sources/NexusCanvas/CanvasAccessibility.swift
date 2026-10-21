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
    private var zoneItems: [String: ElementItem] = [:]
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

    // MARK: Edges and boundaries

    func edgeItems() -> [ElementItem] {
        guard let c = controller else { return [] }
        return c.scene.relationships.filter { !$0.isVirtual }.map { r in
            let id = r.relationship.id
            let e = edges[id] ?? ElementItem(ref: .relationship(id), tree: self)
            edges[id] = e
            let canvas = c.canvas
            func name(_ end: RelationshipEnd) -> String {
                switch end {
                case .topic(let t): return canvas.nodes[t]?.text ?? Loc.t("a topic")
                case .zone(let z):
                    let title = canvas.zones.first { $0.id == z }?.title ?? ""
                    return title.isEmpty ? Loc.t("a zone") : Loc.f("zone %@", title)
                }
            }
            let from = name(r.relationship.from)
            let to = name(r.relationship.to)
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

    /// A Connect candidate: its topic's element, or an item for a zone.
    func connectItem(_ cand: ConnectCandidate) -> NSAccessibilityElement? {
        guard let c = controller else { return nil }
        switch cand.end {
        case .topic(let id): return element(id)
        case .zone(let id):
            guard let z = c.scene.zones.first(where: { $0.zone.id == id }) else { return nil }
            let e = zoneItems[id] ?? ElementItem(ref: .zone(id), tree: self)
            zoneItems[id] = e
            let title = z.zone.title.isEmpty ? Loc.t("Zone") : z.zone.title
            e.text = Loc.f("Hint %@. ", cand.hint.uppercased()) + Loc.f("%@. Zone.", title)
            e.world = z.rect
            return e
        }
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
        return actions
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
    override func accessibilityFrame() -> NSRect {
        // Live, so a move action's new place is reported at once (M21).
        let r = tree.controller?.scene.legend?.rect ?? world
        return r.isNull ? .zero : tree.screenRect(r)
    }
    override func accessibilityParent() -> Any? {
        let t = tree
        return onMain { t.view }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        tree.controller?.editLegend()
        return true
    }
    /// Keyboard focus on the legend selects it, so the arrow keys move it (M21).
    override func isAccessibilityFocused() -> Bool { tree.controller?.legendSelected ?? false }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { tree.controller?.selectLegend() } else { tree.controller?.deselectLegend() }
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = [
            NSAccessibilityCustomAction(name: Loc.t("Edit Legend")) { [weak self] in
                self?.tree.controller?.editLegend()
                return true
            },
            NSAccessibilityCustomAction(name: Loc.t("Hide Legend")) { [weak self] in
                self?.tree.controller?.toggleLegend()
                return true
            },
        ]
        // Move actions (M21, D203): the same steps as the arrow keys, one undo step each.
        let moves: [(String, Double, Double)] = [
            (Loc.t("Move Legend Left"), -1, 0), (Loc.t("Move Legend Right"), 1, 0),
            (Loc.t("Move Legend Up"), 0, -1), (Loc.t("Move Legend Down"), 0, 1),
        ]
        for (name, dx, dy) in moves {
            actions.append(
                NSAccessibilityCustomAction(name: name) { [weak self] in
                    guard let self else { return false }
                    self.tree.controller?.nudgeLegend(dx: dx, dy: dy)
                    NSAccessibility.post(element: self, notification: .moved)
                    return true
                })
        }
        if tree.controller?.canvas.legend?.position != nil {
            actions.append(
                NSAccessibilityCustomAction(name: Loc.t("Reset Legend Position")) { [weak self] in
                    guard let self else { return false }
                    self.tree.controller?.moveLegend(to: nil)
                    NSAccessibility.post(element: self, notification: .moved)
                    return true
                })
        }
        return actions
    }
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
}
