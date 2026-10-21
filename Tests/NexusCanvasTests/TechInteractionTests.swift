import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusKeys

@MainActor
@Suite(.serialized) struct TechInteractionTests {
    func node(_ h: CanvasHarness, _ text: String) -> NodeID {
        h.canvas.nodes.first { $0.value.text == text }!.key
    }

    func harness(_ c: Canvas) -> CanvasHarness { CanvasHarness(model: DocumentModel(canvases: [c])) }

    /// F3: ⌥⌘T, a number key converts a hierarchy type at once; ⌘Z returns in one step.
    @Test func convertByKeyboard() {
        let h = CanvasHarness(model: launchPlanDocument())
        let before = h.canvas
        h.press("opt+cmd+t")
        #expect(h.controller.convert != nil)
        h.press("esc")
        #expect(h.controller.convert == nil && h.canvas == before)
        h.press("opt+cmd+t")
        h.type("5")
        #expect(h.canvas.type == .flowchart)
        #expect(h.controller.scene.relationships.contains { $0.isVirtual })
        #expect(h.undo.undo(h.store))
        #expect(h.canvas == before)
    }

    /// Technical types confirm first-level node types (with ✦ suggestions) first.
    @Test func convertConfirmsNodeTypes() {
        let h = CanvasHarness(model: launchPlanDocument())
        h.press("opt+cmd+t")
        h.type("6")  // Data Flow
        let s = try! #require(h.controller.convert)
        #expect(s.step == .confirm)
        #expect(s.rows == h.canvas.nodes[h.canvas.root]!.children)
        #expect(s.suggested.count == s.rows.count)
        // → cycles the highlighted row's type.
        let first = s.proposals[s.rows[0]]
        h.press("right")
        #expect(h.controller.convert?.proposals[s.rows[0]] != first)
        h.press("return")
        #expect(h.canvas.type == .dfd)
        #expect(s.rows.allSatisfy { h.canvas.nodes[$0]?.nodeType != nil })
        // Back to a map restores the structure.
        h.press("opt+cmd+t")
        h.type("1")
        #expect(h.canvas.type == .mindmap && h.canvas.layout.structure == .mindmapBalanced)
    }

    @Test func slashMenuInSelectMode() {
        var c = TechSamples.architecture()
        c.nodes[c.nodes.first { $0.value.text == "orders" }!.key]!.nodeType = nil
        let h = harness(c)
        let orders = node(h, "orders")
        h.controller.select(orders)
        h.press("/")
        #expect(h.controller.slash != nil && h.controller.mode == .select)
        h.type("cach")
        #expect(h.controller.slashResults.first?.slug == "cache")
        h.press("return")
        #expect(h.controller.slash == nil)
        #expect(h.canvas.nodes[orders]?.nodeType == "cache")
        #expect(h.canvas.nodes[orders]?.text == "orders", "Select-mode slash never touches the text")
    }

    /// `/` at the start of a new topic opens the menu over the editor; `/math` typesets it.
    @Test func slashMenuInEditor() {
        let h = CanvasHarness(model: launchPlanDocument())
        h.controller.select(node(h, "Pricing"))
        h.press("tab")
        #expect(h.controller.mode == .edit)
        h.type("/mat")
        #expect(h.controller.slash?.inEditor == true)
        #expect(h.controller.slashResults.first?.slug == "math")
        h.press("return")
        #expect(h.controller.slash == nil && h.controller.mode == .edit)
        let id = h.controller.edit!.node
        #expect(h.canvas.nodes[id]?.textFormat == "math")
        h.type("x^2 + \\alpha")
        h.press("return")
        #expect(h.canvas.nodes[id]?.text == "x^2 + \\alpha")
        let rendered = h.controller.scene.nodes[id]!.textStyle.attributed(
            "x^2 + \\alpha", marks: [], color: .black)
        #expect(rendered.string.contains("α"))
    }

    /// S5: Tab from a decision opens the branch's label pre-filled "Yes", then "No".
    @Test func decisionBranchesAreLabelled() {
        let h = harness(TechSamples.flowchart())
        let q = node(h, "Account exists?")
        let start = h.canvas.nodes[q]!.children.count
        // Use a fresh decision so the first branch is "Yes".
        h.controller.select(node(h, "Done"))
        h.press("tab")
        h.type("Retry?")
        h.press("return")
        let retry = node(h, "Retry?")
        #expect(DiagramCatalog.effectiveType(retry, in: h.canvas) == .decision)
        h.press("tab")
        #expect(h.controller.edit?.element == .relationship(FlowGraph.treeFlowID(h.canvas.nodes[retry]!.children[0])))
        #expect(h.controller.edit?.text == "Yes")
        h.press("return")  // keep "Yes"
        #expect(h.controller.mode == .edit && h.controller.edit?.element == nil)
        h.type("Wait")
        h.press("return")
        h.controller.select(retry)
        h.press("tab")
        #expect(h.controller.edit?.text == "No")
        h.press("return")
        h.press("esc")
        let kids = h.canvas.nodes[retry]!.children
        #expect(kids.map { h.canvas.nodes[$0]!.edgeLabel } == ["Yes", "No"])
        #expect(h.canvas.nodes[q]!.children.count == start)
    }

    @Test func lanesMoveWithOptionArrows() {
        let h = harness(TechSamples.swimlane())
        let review = node(h, "Review")
        h.controller.select(review)
        h.press("opt+down")
        #expect(h.canvas.nodes[review]?.lane == "finance")
        h.press("opt+up")
        h.press("opt+up")
        #expect(h.canvas.nodes[review]?.lane == "customer")
        // The band follows: the node now sits in the first lane's band.
        guard case .band(let r, _, _)? = h.controller.scene.decor.first else {
            Issue.record("no lanes")
            return
        }
        #expect(r.contains(h.controller.scene.nodes[review]!.frame.rect))
    }

    /// S9: Tab = message to the next participant, ⌥↩ = return message, ↩ = next message.
    @Test func sequenceKeys() {
        var c = TechSamples.sequence()
        c.relationships = []
        let h = harness(c)
        let user = node(h, "User")
        let web = node(h, "Web app")
        h.controller.select(user)
        h.press("tab")
        #expect(h.controller.edit?.element != nil)
        h.type("Sign in")
        h.press("return")
        let m1 = h.canvas.relationships[0]
        #expect(m1.from == .topic(user) && m1.to == .topic(web) && m1.label == "Sign in" && m1.kind == "message")
        #expect(h.controller.selectedElement == .relationship(m1.id))
        h.press("opt+return")
        h.type("dashboard")
        h.press("return")
        #expect(h.canvas.relationships.count == 2)
        let ret = h.canvas.relationships[1]
        #expect(ret.from == .topic(web) && ret.to == .topic(user) && ret.kind == "return")
        // Tab from the first message continues the chain to the next participant, inserted in time.
        h.controller.selectElement(.relationship(m1.id))
        h.press("tab")
        h.type("POST /token")
        h.press("return")
        #expect(h.canvas.relationships.map(\.label) == ["Sign in", "POST /token", "dashboard"])
        #expect(h.canvas.relationships[1].to == .topic(node(h, "Auth service")))
        #expect(Mermaid.sequence(h.canvas).contains("P2->>P3: POST /token"))
        // The scene numbers calls and draws activation bars.
        #expect(
            h.controller.scene.relationships.first { $0.relationship.id == m1.id }?.relationship.label == "1 · Sign in")
        #expect(h.controller.scene.decor.contains { if case .activation = $0 { true } else { false } })
    }

    /// Acceptance: DFD rule violations show the shake and a badge.
    @Test func dfdViolationsAreFlaggedAndFixable() throws {
        let h = harness(TechSamples.dfd())
        let receipt = h.canvas.relationships.first { $0.label == "receipt" }!.id
        let flagged = h.controller.scene.relationships.first { $0.relationship.id == receipt }!
        #expect(flagged.flagged)
        #expect(flagged.relationship.dash == "dashed")
        let v = try #require(h.controller.shownViolation)
        #expect(v.title == "A data flow must touch a process")
        h.controller.applyFix(v.fixes[0], violation: v.id)
        #expect(!h.controller.scene.relationships.contains { $0.flagged })
        #expect(h.controller.mode == .edit, "the inserted process opens for naming")
        h.press("esc")
        #expect(h.undo.undo(h.store))
        #expect(h.controller.scene.relationships.contains { $0.flagged })
    }

    @Test func dfdDrillsIntoAProcessAndBack() {
        let h = harness(TechSamples.dfd())
        let auth = node(h, "Authorize payment")
        h.controller.select(auth)
        h.press("cmd+.")
        #expect(h.store.model.canvases.count == 2)
        let level = h.canvas
        #expect(level.diagram.parent?.node == auth)
        #expect(level.diagram.levelNumber == "2")
        #expect(DFDRules.numbers(level).values.contains("2.1"))
        #expect(h.controller.levelPath.map(\.title) == ["Level 1", "2.0 Authorize payment"])
        h.press("cmd+[")
        #expect(h.canvas.id == "c1" && h.controller.selection.primary == auth)
        // ⌘. again opens the same level instead of a new one.
        h.press("cmd+.")
        #expect(h.store.model.canvases.count == 2)
    }

    @Test func strideSuggestionsAcceptAll() {
        let h = harness(TechSamples.threatModel())
        let auth = node(h, "Authorize payment")
        h.controller.select(auth)
        let s = h.controller.strideSuggestionsForSelection
        #expect(!s.isEmpty)
        let before = h.controller.threats.count
        h.press("ctrl+shift+return")
        #expect(h.controller.threats.count == before + s.count)
        #expect(h.controller.strideSuggestionsForSelection.isEmpty)
        #expect(h.undo.undo(h.store))
        #expect(h.controller.threats.count == before)
    }

    /// S8: a new dependency's edge label defaults to its protocol.
    @Test func architectureProtocolDefaults() {
        let h = harness(TechSamples.architecture())
        let orders = node(h, "orders")
        h.controller.select(orders)
        h.press("tab")
        h.type("redis cache")
        h.press("return")
        let id = node(h, "redis cache")
        #expect(h.canvas.nodes[id]?.edgeLabel == "RESP")
        #expect(DiagramCatalog.effectiveType(id, in: h.canvas) == "cache")
        // Editing the label offers protocol suggestions, best first.
        h.controller.beginEditingElement(.relationship(FlowGraph.treeFlowID(id)))
        #expect(h.controller.protocolSuggestions.first == "RESP")
        h.press("esc")
    }

    /// ⌥⌘1–9 follow artboard 18; on the central topic the canvas type follows.
    @Test func structureKeysFollowTheArtboard() {
        let h = CanvasHarness(model: launchPlanDocument())
        for (n, s, t) in [
            (3, LayoutStructure.orgDown, DiagramType.org), (4, .timelineHorizontal, .timeline),
            (5, .fishboneLeft, .fishbone),
            (6, .matrix, .matrix), (7, .braceRight, .brace), (8, .treeTable, .treeTable), (9, .treeIndented, .tree),
        ] {
            h.press("opt+cmd+\(n)")
            #expect(h.canvas.layout.structure == s && h.canvas.type == t, "⌥⌘\(n)")
        }
        h.press("opt+cmd+1")
        #expect(h.canvas.type == .mindmap)
    }

    @Test func codeHighlighting() {
        let s = CodeText.render(
            "func retry(op) { // again\n  for i in 0..<3 { }\n}", size: 12, color: .white,
            paragraph: NSParagraphStyle.default)
        let kw = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(kw == CodeText.keyword)
        let ns = s.string as NSString
        let comment =
            s.attribute(.foregroundColor, at: ns.range(of: "// again").location, effectiveRange: nil) as? NSColor
        #expect(comment == CodeText.comment)
        let m = MathText.render("E[X] = \\sum_i x_i \\cdot p(x_i)", size: 16, color: .black, paragraph: .default)
        #expect(m.string.contains("Σ") && m.string.contains("·") && !m.string.contains("\\"))
    }
}

@Suite struct TechSchemaTests {
    /// Every artboard sample (types, edge labels, lanes, threats, levels) passes the schema.
    @Test func samplesValidate() {
        var dfd = TechSamples.dfd()
        dfd.diagram.ignoredRules = ["labelled:t:n2"]
        dfd.diagram.parent = LevelLink(canvas: "c0", node: "n1")
        dfd.diagram.levelNumber = "2"
        var math = TechSamples.structures(.matrix)
        math.nodes[math.root]!.textFormat = "math"
        for c in [
            TechSamples.flowchart(), TechSamples.swimlane(), dfd, TechSamples.threatModel(), TechSamples.architecture(),
            TechSamples.sequence(), math,
        ] {
            let issues = SchemaValidator.bundled.validate(c.json, definition: "canvas")
            #expect(issues.isEmpty, "\(c.title): \(issues)")
        }
        // …and the schema really checks the new keys.
        var bad = TechSamples.flowchart()
        bad.nodes[bad.root]!.textFormat = "latex"
        #expect(!SchemaValidator.bundled.validate(bad.json, definition: "canvas").isEmpty)
    }
}
