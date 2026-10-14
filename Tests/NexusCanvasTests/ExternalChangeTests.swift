import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// M9: a map changed on disk (an agent, the CLI, Git) arrives as one undoable edit,
/// merged with whatever the user hasn't saved.
@MainActor
@Suite struct ExternalChangeTests {
    func node(_ c: Canvas, _ t: String) -> NodeID { c.nodes.first { $0.value.text == t }!.key }

    func agentEdit(_ base: DocumentModel, _ body: (inout CanvasEditor) throws -> Void) rethrows -> DocumentModel {
        var d = base
        var e = CanvasEditor(d.canvases["c1"]!)
        try body(&e)
        d.canvases["c1"] = e.canvas
        return d
    }

    @Test func cleanDocumentTakesTheDiskVersionAsOneUndo() throws {
        let base = launchPlanDocument()
        let store = DocumentStore(model: base)
        let undo = StackUndoRegistrar()
        store.undoRegistrar = undo
        let risks = node(base.canvases["c1"]!, "Risks")
        let disk = try agentEdit(base) { e in
            let id = try e.addChild(of: risks, text: "Churn")
            e.update(id) { $0.ai = true }
            _ = e.connect(id, to: risks, label: "raises")
        }
        let conflicts = store.mergeExternal(disk, base: base, focus: "c1")
        #expect(conflicts.isEmpty && store.model.canvases == disk.canvases)
        #expect(undo.stack.undoStack.count == 1 && undo.stack.undoStack[0].actionName == "Change on Disk")
        undo.undo(store)
        #expect(store.model.canvases == base.canvases)
    }

    @Test func unsavedEditsMergeWithTheAgentsAndConflictsKeepTheUsers() throws {
        let base = launchPlanDocument()
        let c = base.canvases["c1"]!
        let store = DocumentStore(model: base)
        // The user renames Pricing and edits Pro; the agent adds under Risks and edits Pro too.
        store.commit(
            {
                var e = CanvasEditor(c)
                e.setText(node(c, "Pricing"), "Pricing model")
                e.setText(node(c, "Pro"), "Pro (user)")
                return e.patch(actionName: "Typing")
            }())
        let disk = try agentEdit(base) { e in
            _ = try e.addChild(of: node(c, "Risks"), text: "Churn")
            e.setText(node(c, "Pro"), "Pro (agent)")
        }
        let conflicts = store.mergeExternal(disk, base: base, focus: "c1")
        let m = store.model.canvases["c1"]!
        #expect(m.nodes.values.contains { $0.text == "Churn" }, "the agent's new topic arrives")
        #expect(m.nodes[node(c, "Pricing")]?.text == "Pricing model", "the user's rename stays")
        #expect(m.nodes[node(c, "Pro")]?.text == "Pro (user)" && conflicts == ["“Pro (user)”"])
        #expect(m.validate().isEmpty)
    }

    @Test func canvasesAddedOrRemovedOnDisk() {
        let base = launchPlanDocument()
        var disk = base
        disk.canvases["c9"] = Canvas(id: "c9", title: "From the CLI", rootText: "CLI")
        disk.canvasOrder.append("c9")
        disk.canvases["c2"] = nil
        disk.canvasOrder.removeAll { $0 == "c2" }
        let merged = DocumentMerge(base: base, current: base, disk: disk).model
        #expect(merged.canvasOrder.count == disk.canvasOrder.count && merged.canvases["c2"] == nil)
        #expect(merged.orderedCanvases.contains { $0.title == "From the CLI" })
    }
}
