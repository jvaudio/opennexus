import Foundation

/// A selectable non-topic element.
public enum ElementRef: Hashable, Sendable {
    case relationship(String)
    case boundary(String)
    case summary(String)
    case callout(String)
    case zone(String)

    public var isCallout: Bool {
        if case .callout = self { return true }
        return false
    }

    public var id: String {
        switch self {
        case .relationship(let i), .boundary(let i), .summary(let i), .callout(let i), .zone(let i): i
        }
    }
}

public enum ElementRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case summaryNeedsSiblings
    case wouldCreateCycle
    case notFloating
    case cannotMoveRoot
    case belongsToElement

    public var description: String {
        switch self {
        case .summaryNeedsSiblings: "A summary brackets topics that share a parent"
        case .wouldCreateCycle: "A topic can’t move inside its own branch"
        case .notFloating: "Only floating topics move freely"
        case .cannotMoveRoot: "The central topic stays put"
        case .belongsToElement: "Summary and callout topics stay with their element"
        }
    }
}

/// Elements (relationships, boundaries, summaries, callouts, zones) and direct
/// manipulation, as reversible edits.
extension CanvasEditor {
    private func freshID(_ prefix: String, used: [String]) -> String {
        let set = Set(used)
        var i = used.count + 1
        while set.contains("\(prefix)\(i)") { i += 1 }
        return "\(prefix)\(i)"
    }

    // MARK: Boundary

    /// ⇧⌘B: one boundary around the branches of the given topics.
    @discardableResult
    public mutating func addBoundary(around ids: [NodeID], title: String = "") throws -> String {
        let targets = ids.filter { self[$0] != nil }
        guard !targets.isEmpty else { throw TreeOperationRefusal.missingNode }
        let id = freshID("b", used: canvas.boundaries.map(\.id))
        updateMeta { $0.boundaries.append(Boundary(id: id, nodes: targets, title: title)) }
        return id
    }

    public mutating func updateBoundary(_ id: String, _ body: (inout Boundary) -> Void) {
        guard let i = canvas.boundaries.firstIndex(where: { $0.id == id }) else { return }
        updateMeta { body(&$0.boundaries[i]) }
    }

    // MARK: Summary

    /// ⇧⌘]: brackets the range spanned by the selected siblings and creates its topic.
    @discardableResult
    public mutating func addSummary(over ids: [NodeID], text: String = "Summary") throws -> NodeID {
        let parents = canvas.parentMap()
        guard let first = ids.first, let parent = parents[first],
            ids.allSatisfy({ parents[$0] == parent }), let kids = self[parent]?.children
        else { throw ElementRefusal.summaryNeedsSiblings }
        let indices = ids.compactMap { kids.firstIndex(of: $0) }.sorted()
        guard let lo = indices.first, let hi = indices.last else { throw ElementRefusal.summaryNeedsSiblings }
        let topic = makeNodeID()
        insert(Node(text: text, kind: .summary), as: topic)
        let id = freshID("s", used: canvas.summaries.map(\.id))
        updateMeta {
            $0.summaries.append(Summary(id: id, parent: parent, from: kids[lo], to: kids[hi], topic: topic))
        }
        return topic
    }

    public mutating func updateSummary(_ id: String, _ body: (inout Summary) -> Void) {
        guard let i = canvas.summaries.firstIndex(where: { $0.id == id }) else { return }
        updateMeta { body(&$0.summaries[i]) }
    }

    // MARK: Callout

    /// ⇧⌘C: a bubble bound to `host`.
    @discardableResult
    public mutating func addCallout(on host: NodeID, text: String = "Callout") throws -> NodeID {
        guard self[host] != nil else { throw TreeOperationRefusal.missingNode }
        let topic = makeNodeID()
        insert(Node(text: text, kind: .callout), as: topic)
        let id = freshID("k", used: canvas.callouts.map(\.id))
        updateMeta { $0.callouts.append(Callout(id: id, host: host, topic: topic)) }
        return topic
    }

    public mutating func updateCallout(_ id: String, _ body: (inout Callout) -> Void) {
        guard let i = canvas.callouts.firstIndex(where: { $0.id == id }) else { return }
        updateMeta { body(&$0.callouts[i]) }
    }

    // MARK: Relationship

    public mutating func updateRelationship(_ id: String, _ body: (inout Relationship) -> Void) {
        guard let i = canvas.relationships.firstIndex(where: { $0.id == id }) else { return }
        updateMeta { body(&$0.relationships[i]) }
    }

    // MARK: Zone

    /// ⌥⌘Z: a zone at `origin`, taking in the given floating topics.
    @discardableResult
    public mutating func addZone(
        title: String = "Zone", origin: CanvasPoint, width: Double = 420,
        height: Double = 240, members: [NodeID] = []
    ) -> String {
        let id = freshID("z", used: canvas.zones.map(\.id))
        var z = Zone(id: id, title: title, origin: origin, width: width, height: height)
        z.members = members.filter { canvas.floating.contains($0) }
        updateMeta { c in
            for i in c.zones.indices { c.zones[i].members.removeAll { z.members.contains($0) } }
            c.zones.append(z)
        }
        return id
    }

    public mutating func updateZone(_ id: String, _ body: (inout Zone) -> Void) {
        guard let i = canvas.zones.firstIndex(where: { $0.id == id }) else { return }
        updateMeta { body(&$0.zones[i]) }
    }

    /// Moves a zone and everything inside it.
    public mutating func moveZone(_ id: String, by dx: Double, _ dy: Double) {
        guard let z = canvas.zones.first(where: { $0.id == id }) else { return }
        for m in z.members {
            update(m) { n in
                let p = n.position ?? CanvasPoint(x: 0, y: 0)
                n.position = CanvasPoint(x: p.x + dx, y: p.y + dy)
            }
        }
        updateZone(id) { $0.origin = CanvasPoint(x: $0.origin.x + dx, y: $0.origin.y + dy) }
    }

    /// Remove zone (keep content).
    public mutating func removeZone(_ id: String) {
        updateMeta { $0.zones.removeAll { $0.id == id } }
    }

    // MARK: Z-order (zones and floating topics)

    public enum ZOrder: Sendable { case front, forward, backward, back }

    public mutating func reorderZone(_ id: String, _ order: ZOrder) {
        updateMeta { c in Self.move(&c.zones, where: { $0.id == id }, order) }
    }

    public mutating func reorderFloating(_ id: NodeID, _ order: ZOrder) {
        updateMeta { c in Self.move(&c.floating, where: { $0 == id }, order) }
    }

    private static func move<T>(_ a: inout [T], where match: (T) -> Bool, _ order: ZOrder) {
        guard let i = a.firstIndex(where: match) else { return }
        let item = a.remove(at: i)
        switch order {
        case .front: a.append(item)
        case .back: a.insert(item, at: 0)
        case .forward: a.insert(item, at: min(i + 1, a.count))
        case .backward: a.insert(item, at: max(i - 1, 0))
        }
    }

    // MARK: Remove

    public mutating func removeElement(_ ref: ElementRef) {
        switch ref {
        case .relationship(let id): updateMeta { $0.relationships.removeAll { $0.id == id } }
        case .boundary(let id): updateMeta { $0.boundaries.removeAll { $0.id == id } }
        case .zone(let id): removeZone(id)
        case .summary(let id):
            guard let s = canvas.summaries.first(where: { $0.id == id }) else { return }
            let gone = Set(canvas.subtree(s.topic))
            updateMeta { $0.summaries.removeAll { $0.id == id } }
            for d in gone { remove(d) }
            cleanUpElements(removed: gone)
        case .callout(let id):
            guard let k = canvas.callouts.first(where: { $0.id == id }) else { return }
            let gone = Set(canvas.subtree(k.topic))
            updateMeta { $0.callouts.removeAll { $0.id == id } }
            for d in gone { remove(d) }
            cleanUpElements(removed: gone)
        }
    }

    /// After topics are deleted, drops or trims elements that pointed at them.
    mutating func cleanUpElements(removed: Set<NodeID>) {
        guard !removed.isEmpty else { return }
        let c = canvas
        let deadSummaries = c.summaries.filter {
            removed.contains($0.parent) || removed.contains($0.from) || removed.contains($0.to)
                || removed.contains($0.topic)
        }
        let deadCallouts = c.callouts.filter { removed.contains($0.host) || removed.contains($0.topic) }
        let touchesBoundaries = c.boundaries.contains { $0.nodes.contains(where: removed.contains) }
        let touchesZones = c.zones.contains { $0.members.contains(where: removed.contains) }
        let touchesRels = c.relationships.contains { removed.contains($0.from) || removed.contains($0.to) }
        if !deadSummaries.isEmpty || !deadCallouts.isEmpty || touchesBoundaries || touchesZones || touchesRels {
            updateMeta { m in
                m.summaries.removeAll { s in deadSummaries.contains(s) }
                m.callouts.removeAll { k in deadCallouts.contains(k) }
                for i in m.boundaries.indices { m.boundaries[i].nodes.removeAll(where: removed.contains) }
                m.boundaries.removeAll { $0.nodes.isEmpty }
                for i in m.zones.indices { m.zones[i].members.removeAll(where: removed.contains) }
                m.relationships.removeAll { removed.contains($0.from) || removed.contains($0.to) }
            }
        }
        // Summary and callout topics whose element died go too.
        var orphans = Set<NodeID>()
        for s in deadSummaries where !removed.contains(s.topic) { orphans.formUnion(canvas.subtree(s.topic)) }
        for k in deadCallouts where !removed.contains(k.topic) { orphans.formUnion(canvas.subtree(k.topic)) }
        for o in orphans { remove(o) }
        if !orphans.isEmpty { cleanUpElements(removed: orphans) }
    }

    // MARK: Direct manipulation

    /// Summary and callout topics are owned by their element and never re-parented.
    func isElementTopic(_ id: NodeID) -> Bool {
        canvas.summaries.contains { $0.topic == id } || canvas.callouts.contains { $0.topic == id }
    }

    /// Drag a topic onto another: becomes its child at `index` (end when nil).
    public mutating func move(_ id: NodeID, toParent parent: NodeID, at index: Int? = nil) throws {
        guard self[id] != nil, self[parent] != nil else { throw TreeOperationRefusal.missingNode }
        guard id != canvas.root else { throw ElementRefusal.cannotMoveRoot }
        guard !isElementTopic(id) else { throw ElementRefusal.belongsToElement }
        guard !canvas.subtree(id).contains(parent) else { throw ElementRefusal.wouldCreateCycle }
        guard canvas.depth(of: parent) + 1 + canvas.height(of: id) < Canvas.maxDepth else {
            throw TreeOperationRefusal.tooDeep
        }
        let oldParent = canvas.parent(of: id)
        var insertAt = index
        if let op = oldParent {
            if op == parent, let i = self[op]?.children.firstIndex(of: id), let ix = insertAt, ix > i {
                insertAt = ix - 1
            }
            update(op) { $0.children.removeAll { $0 == id } }
        } else {
            // Was floating: attach.
            updateMeta { c in
                c.floating.removeAll { $0 == id }
                for i in c.zones.indices { c.zones[i].members.removeAll { $0 == id } }
            }
            update(id) {
                $0.kind = .topic
                $0.position = nil
            }
        }
        update(parent) {
            $0.folded = false
            let i = min(insertAt ?? $0.children.count, $0.children.count)
            $0.children.insert(id, at: max(0, i))
        }
    }

    /// ⇧-drag or drag out: the branch becomes a floating topic at `point`.
    public mutating func detach(_ id: NodeID, at point: CanvasPoint) throws {
        guard id != canvas.root else { throw ElementRefusal.cannotMoveRoot }
        guard !isElementTopic(id) else { throw ElementRefusal.belongsToElement }
        guard let p = canvas.parent(of: id) else {
            try moveFloating(id, to: point)
            return
        }
        update(p) { $0.children.removeAll { $0 == id } }
        update(id) {
            $0.kind = .floating
            $0.position = point
        }
        updateMeta { $0.floating.append(id) }
    }

    /// Drag a floating topic (or a zone member) to a new position; zones adopt topics
    /// dropped inside them.
    public mutating func moveFloating(_ id: NodeID, to point: CanvasPoint) throws {
        guard canvas.floating.contains(id) else { throw ElementRefusal.notFloating }
        update(id) { $0.position = point }
        let inside = canvas.zones.last { z in
            !z.collapsed && point.x >= z.origin.x && point.x <= z.origin.x + z.width && point.y >= z.origin.y
                && point.y <= z.origin.y + z.height
        }
        let current = canvas.zones.first { $0.members.contains(id) }
        if inside?.id != current?.id {
            updateMeta { c in
                for i in c.zones.indices {
                    c.zones[i].members.removeAll { $0 == id }
                    if c.zones[i].id == inside?.id { c.zones[i].members.append(id) }
                }
            }
        }
    }

    /// ⌥-drag: a copy of the branch lands under `parent`.
    @discardableResult
    public mutating func duplicate(_ id: NodeID, toParent parent: NodeID, at index: Int? = nil) throws -> NodeID {
        let copy = try duplicate(id)
        try move(copy, toParent: parent, at: index)
        return copy
    }
}
