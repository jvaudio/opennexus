import Foundation

/// Why a tree operation did nothing. The canvas shows these as quiet toasts.
public enum TreeOperationRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case rootHasNoParent
    case cannotDeleteRoot
    case alreadyMainTopic
    case noPreviousSibling
    case nothingToFold
    case cannotDuplicateRoot
    case atEdge
    case missingNode
    case tooDeep

    public var description: String {
        switch self {
        case .rootHasNoParent: "The central topic has no parent"
        case .cannotDeleteRoot: "The central topic can’t be deleted"
        case .alreadyMainTopic: "Already a main topic"
        case .noPreviousSibling: "No previous sibling to move under"
        case .nothingToFold: "Nothing to fold"
        case .cannotDuplicateRoot: "Duplicate works on branches, not the root"
        case .atEdge: "Already at the end"
        case .missingNode: "That topic no longer exists"
        case .tooDeep: "Topics can nest \(Canvas.maxDepth) levels deep"
        }
    }
}

/// Default text for a new topic, by diagram type and depth (matches P0).
public func defaultTopicText(type: DiagramType, depth: Int) -> String {
    switch type {
    case .flowchart, .swimlane: "Step"
    case .dfd: depth == 1 ? "Process" : "Data"
    case .timeline where depth == 1: "Event"
    case .org: depth == 1 ? "Lead" : "Member"
    default: depth <= 1 ? "Main Topic" : "Subtopic"
    }
}

/// Xmind's restructuring vocabulary, as reversible edits.
extension CanvasEditor {
    private func parentOf(_ id: NodeID) -> NodeID? {
        canvas.parent(of: id)
    }

    private func newTopic(under parent: NodeID) -> Node {
        let depth = canvas.depth(of: parent) + 1
        return Node(text: defaultTopicText(type: canvas.type, depth: depth))
    }

    /// Tab: appends a child and unfolds the parent.
    @discardableResult
    public mutating func addChild(of parent: NodeID, text: String? = nil) throws -> NodeID {
        guard self[parent] != nil else { throw TreeOperationRefusal.missingNode }
        guard canvas.depth(of: parent) + 1 < Canvas.maxDepth else { throw TreeOperationRefusal.tooDeep }
        var node = newTopic(under: parent)
        if let text { node.text = text }
        let id = makeNodeID()
        insert(node, as: id)
        update(parent) {
            $0.folded = false
            $0.children.append(id)
        }
        return id
    }

    /// Return / Shift-Return: a sibling after or before. On the root (or a floating
    /// top) there is no sibling, so it adds a child, as Xmind does.
    @discardableResult
    public mutating func addSibling(of id: NodeID, before: Bool = false, text: String? = nil) throws -> NodeID {
        guard self[id] != nil else { throw TreeOperationRefusal.missingNode }
        guard let parent = parentOf(id) else { return try addChild(of: id, text: text) }
        var node = newTopic(under: parent)
        if let text { node.text = text }
        let nid = makeNodeID()
        insert(node, as: nid)
        update(parent) {
            let i = $0.children.firstIndex(of: id) ?? $0.children.count - 1
            $0.children.insert(nid, at: before ? i : i + 1)
        }
        return nid
    }

    /// Command-Return: inserts a new node between the selection and its parent.
    @discardableResult
    public mutating func addParent(of id: NodeID, text: String? = nil) throws -> NodeID {
        guard self[id] != nil else { throw TreeOperationRefusal.missingNode }
        guard let parent = parentOf(id) else { throw TreeOperationRefusal.rootHasNoParent }
        guard canvas.depth(of: id) + 1 + canvas.height(of: id) < Canvas.maxDepth else {
            throw TreeOperationRefusal.tooDeep
        }
        var node = newTopic(under: parent)
        if let text { node.text = text }
        node.children = [id]
        let nid = makeNodeID()
        insert(node, as: nid)
        update(parent) {
            if let i = $0.children.firstIndex(of: id) { $0.children[i] = nid }
        }
        return nid
    }

    /// Option-Command-Return or double-click: a topic not attached to the tree.
    @discardableResult
    public mutating func addFloating(at point: CanvasPoint, text: String = "Floating Topic") -> NodeID {
        var node = Node(text: text, kind: .floating)
        node.position = point
        let id = makeNodeID()
        insert(node, as: id)
        updateMeta { $0.floating.append(id) }
        return id
    }

    public mutating func setText(_ id: NodeID, _ text: String) {
        update(id) {
            guard $0.text != text else { return }
            $0.text = text
            $0.ai = false
        }
    }

    /// Delete: removes nodes and their branches. Returns the node to select next.
    @discardableResult
    public mutating func delete(_ ids: [NodeID]) throws -> NodeID {
        let parents = canvas.parentMap()
        let targets = ids.filter { self[$0] != nil && $0 != canvas.root }
        guard let first = targets.first else { throw TreeOperationRefusal.cannotDeleteRoot }

        let firstParent = parents[first]
        let firstIndex = firstParent.flatMap { self[$0]?.children.firstIndex(of: first) } ?? 0

        var removed = Set<NodeID>()
        for id in targets where !removed.contains(id) && self[id] != nil {
            if let p = parents[id] {
                update(p) { $0.children.removeAll { $0 == id } }
            } else {
                updateMeta { $0.floating.removeAll { $0 == id } }
            }
            for d in canvas.subtree(id) {
                removed.insert(d)
                remove(d)
            }
        }
        cleanUpElements(removed: removed)

        if let p = firstParent, let siblings = self[p]?.children, !siblings.isEmpty {
            return siblings[max(0, min(firstIndex - 1, siblings.count - 1))]
        }
        return firstParent ?? canvas.root
    }

    /// Option-Delete: removes one node; its children move up a level.
    @discardableResult
    public mutating func deleteKeepingChildren(_ id: NodeID) throws -> NodeID {
        guard let node = self[id] else { throw TreeOperationRefusal.missingNode }
        guard id != canvas.root else { throw TreeOperationRefusal.cannotDeleteRoot }
        if let p = parentOf(id) {
            update(p) {
                let i = $0.children.firstIndex(of: id) ?? 0
                $0.children.remove(at: i)
                $0.children.insert(contentsOf: node.children, at: i)
            }
            remove(id)
            cleanUpElements(removed: [id])
            return node.children.first ?? p
        } else {
            // A floating top: its children become floating topics in its place.
            let origin = node.position ?? CanvasPoint(x: 0, y: 0)
            for (i, c) in node.children.enumerated() {
                update(c) {
                    $0.kind = .floating
                    $0.position = CanvasPoint(x: origin.x, y: origin.y + Double(i) * 40)
                }
            }
            updateMeta {
                let i = $0.floating.firstIndex(of: id) ?? $0.floating.count
                $0.floating.removeAll { $0 == id }
                $0.floating.insert(contentsOf: node.children, at: min(i, $0.floating.count))
            }
            remove(id)
            cleanUpElements(removed: [id])
            return node.children.first ?? canvas.root
        }
    }

    /// Option-Command-Up/Down: swaps with the previous or next sibling.
    public mutating func reorder(_ id: NodeID, by offset: Int) throws {
        guard let p = parentOf(id), let siblings = self[p]?.children, let i = siblings.firstIndex(of: id) else {
            throw TreeOperationRefusal.atEdge
        }
        let j = i + offset
        guard siblings.indices.contains(j) else { throw TreeOperationRefusal.atEdge }
        update(p) { $0.children.swapAt(i, j) }
    }

    /// Shift-Tab: moves the node out one level, after its old parent.
    public mutating func promote(_ id: NodeID) throws {
        guard let p = parentOf(id), let gp = parentOf(p) else { throw TreeOperationRefusal.alreadyMainTopic }
        update(p) { $0.children.removeAll { $0 == id } }
        update(gp) {
            let i = $0.children.firstIndex(of: p) ?? $0.children.count - 1
            $0.children.insert(id, at: i + 1)
        }
    }

    /// Option-Command-Right: moves the node under its previous sibling.
    public mutating func demote(_ id: NodeID) throws {
        guard let p = parentOf(id), let siblings = self[p]?.children, let i = siblings.firstIndex(of: id), i > 0
        else { throw TreeOperationRefusal.noPreviousSibling }
        guard canvas.depth(of: id) + 1 + canvas.height(of: id) < Canvas.maxDepth else {
            throw TreeOperationRefusal.tooDeep
        }
        let prev = siblings[i - 1]
        update(p) { $0.children.remove(at: i) }
        update(prev) {
            $0.children.append(id)
            $0.folded = false
        }
    }

    /// Command-D: copies the branch; the copy lands after the original.
    @discardableResult
    public mutating func duplicate(_ id: NodeID) throws -> NodeID {
        guard self[id] != nil else { throw TreeOperationRefusal.missingNode }
        guard let p = parentOf(id) else { throw TreeOperationRefusal.cannotDuplicateRoot }
        func copy(_ src: NodeID) -> NodeID {
            var node = self[src]!
            let kids = node.children
            node.children = []
            let nid = makeNodeID()
            insert(node, as: nid)
            let copies = kids.map(copy)
            update(nid) { $0.children = copies }
            return nid
        }
        let nid = copy(id)
        update(p) {
            let i = $0.children.firstIndex(of: id) ?? $0.children.count - 1
            $0.children.insert(nid, at: i + 1)
        }
        return nid
    }

    /// Command-/: folds or unfolds one branch.
    public mutating func toggleFold(_ id: NodeID) throws {
        guard let node = self[id], !node.children.isEmpty else { throw TreeOperationRefusal.nothingToFold }
        update(id) { $0.folded.toggle() }
    }

    /// Option-Command-/: if anything is folded, unfold everything; otherwise fold every branch.
    public mutating func toggleFoldAll() throws {
        let candidates = canvas.nodes.filter { $0.key != canvas.root && !$0.value.children.isEmpty }.map(\.key)
        guard !candidates.isEmpty else { throw TreeOperationRefusal.nothingToFold }
        let anyFolded = candidates.contains { self[$0]!.folded }
        for id in candidates.sorted() { update(id) { $0.folded = !anyFolded } }
    }

    /// Control-1…9 toggles a priority marker; Control-0 adds or toggles a to-do.
    public mutating func toggleMarker(_ id: NodeID, priority n: Int) {
        update(id) {
            if n == 0 {
                if let t = $0.todo { $0.todo = Todo(done: !t.done) } else { $0.todo = Todo(done: false) }
            } else {
                $0.priority = $0.priority == n ? nil : n
            }
        }
    }

    /// Adds a relationship and returns its id.
    @discardableResult
    public mutating func connect(_ from: NodeID, to: NodeID, label: String = "") -> String {
        let used = Set(canvas.relationships.map(\.id))
        var i = canvas.relationships.count + 1
        while used.contains("r\(i)") { i += 1 }
        let rel = Relationship(id: "r\(i)", from: from, to: to, label: label)
        updateMeta { $0.relationships.append(rel) }
        return rel.id
    }
}
