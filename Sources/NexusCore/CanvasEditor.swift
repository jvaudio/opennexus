import Foundation

/// Mutates a canvas while recording the before-image of everything it touches, so
/// the result is a reversible `Patch`. All model changes go through an editor.
public struct CanvasEditor {
    public private(set) var canvas: Canvas
    private var before: [NodeID: Node?] = [:]
    private var metaBefore: Canvas?

    public init(_ canvas: Canvas) {
        self.canvas = canvas
    }

    public subscript(id: NodeID) -> Node? { canvas.nodes[id] }

    private mutating func touch(_ id: NodeID) {
        if before[id] == nil { before[id] = .some(canvas.nodes[id]) }
    }

    public mutating func update(_ id: NodeID, _ body: (inout Node) -> Void) {
        guard canvas.nodes[id] != nil else { return }
        touch(id)
        body(&canvas.nodes[id]!)
    }

    public mutating func insert(_ node: Node, as id: NodeID) {
        touch(id)
        canvas.nodes[id] = node
    }

    public mutating func remove(_ id: NodeID) {
        touch(id)
        canvas.nodes[id] = nil
    }

    /// Changes non-node fields (title, type, layout, style, floating list, relationships…).
    public mutating func updateMeta(_ body: (inout Canvas) -> Void) {
        if metaBefore == nil {
            var m = canvas
            m.nodes = [:]
            metaBefore = m
        }
        let nodes = canvas.nodes
        body(&canvas)
        assert(canvas.nodes == nodes, "updateMeta must not change nodes; use update/insert/remove")
    }

    public mutating func makeNodeID() -> NodeID {
        canvas.makeNodeID()
    }

    public func patch(actionName: String, selectionBefore: Selection? = nil, selectionAfter: Selection? = nil) -> Patch
    {
        var changes: [NodeID: Patch.NodeChange] = [:]
        for (id, b) in before where b != canvas.nodes[id] {
            changes[id] = Patch.NodeChange(before: b, after: canvas.nodes[id])
        }
        var metaAfter: Canvas?
        var mb = metaBefore
        if mb != nil {
            var m = canvas
            m.nodes = [:]
            metaAfter = m
            if mb == metaAfter {
                mb = nil
                metaAfter = nil
            }
        }
        return Patch(
            canvasID: canvas.id, nodes: changes, metaBefore: mb, metaAfter: metaAfter,
            selectionBefore: selectionBefore, selectionAfter: selectionAfter, actionName: actionName)
    }
}
