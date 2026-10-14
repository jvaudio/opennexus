import Foundation

/// A headless undo/redo stack of patches, used by the CLI, MCP server and tests.
/// The app bridges the same patches to `NSUndoManager`.
///
/// Consecutive patches with the same coalescing key merge into one step (typing
/// into one node, nudging, repeated style cycling).
public struct UndoStack: Sendable {
    public private(set) var undoStack: [Patch] = []
    public private(set) var redoStack: [Patch] = []
    private var lastKey: String?
    public var limit: Int

    public init(limit: Int = 500) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ patch: Patch, coalescingKey: String? = nil) {
        guard !patch.isEmpty else { return }
        redoStack.removeAll()
        if let key = coalescingKey, key == lastKey, let last = undoStack.last, last.canvasID == patch.canvasID {
            undoStack[undoStack.count - 1] = last.merged(with: patch)
        } else {
            undoStack.append(patch)
            if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        }
        lastKey = coalescingKey
    }

    /// Ends coalescing so the next patch starts a new undo step.
    public mutating func breakCoalescing() { lastKey = nil }

    /// Pops the last step and returns the patch to apply (already inverted).
    public mutating func undo() -> Patch? {
        guard let p = undoStack.popLast() else { return nil }
        redoStack.append(p)
        lastKey = nil
        return p.inverted
    }

    public mutating func redo() -> Patch? {
        guard let p = redoStack.popLast() else { return nil }
        undoStack.append(p)
        lastKey = nil
        return p
    }
}

/// Convenience: run an edit against a canvas, apply it and record it in one call.
extension Canvas {
    @discardableResult
    public mutating func edit<T>(
        _ actionName: String, undo: inout UndoStack, coalescingKey: String? = nil,
        _ body: (inout CanvasEditor) throws -> T
    ) rethrows -> T {
        var editor = CanvasEditor(self)
        let result = try body(&editor)
        let patch = editor.patch(actionName: actionName)
        self = editor.canvas
        undo.record(patch, coalescingKey: coalescingKey)
        return result
    }
}
