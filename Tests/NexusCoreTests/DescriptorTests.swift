import Testing

@testable import NexusCore

/// The descriptor table (M39, D286) answers every question the per-type switches it
/// replaced answered, with the same answers.
@Suite struct DescriptorTests {
    /// What the switches returned before M39, type by type: default structure, name, root
    /// text, new-topic text at depths 0, 1 and 2, then technical, asks for node types, root
    /// is title.
    static let before: [(DiagramType, LayoutStructure, String, String, [String], Bool, Bool, Bool)] = [
        (
            .mindmap, .mindmapBalanced, "Mind Map", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"], false,
            false, false
        ),
        (
            .logic, .logicRight, "Logic Chart", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"], false, false,
            false
        ),
        (
            .brace, .braceRight, "Brace Map", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"], false, false,
            false
        ),
        (.org, .orgDown, "Org Chart", "Central Topic", ["Member", "Lead", "Member"], false, false, false),
        (
            .tree, .treeIndented, "Tree Chart", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"], false, false,
            false
        ),
        (
            .treeTable, .treeTable, "Tree Table", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"], false,
            false, false
        ),
        (
            .timeline, .timelineHorizontal, "Timeline", "Timeline", ["Main Topic", "Event", "Subtopic"], false, false,
            false
        ),
        (
            .fishbone, .fishboneLeft, "Fishbone", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"], false,
            false, false
        ),
        (.matrix, .matrix, "Matrix", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"], false, false, false),
        (.flowchart, .flowDown, "Flowchart", "Start", ["Step", "Step", "Step"], true, false, false),
        (.swimlane, .swimlanes, "Swimlane", "Central Topic", ["Step", "Step", "Step"], true, false, false),
        (.dfd, .graphRight, "Data Flow", "Context", ["Data", "Process", "Data"], true, true, true),
        (
            .threatModel, .graphRight, "Threat Model", "System", ["Main Topic", "Main Topic", "Subtopic"], true, true,
            true
        ),
        (
            .architecture, .graphRight, "Architecture", "Platform", ["Main Topic", "Main Topic", "Subtopic"], true,
            true, true
        ),
        (.sequence, .sequence, "Sequence", "Sequence", ["Main Topic", "Main Topic", "Subtopic"], true, false, true),
        (
            .whiteboard, .mindmapBalanced, "Whiteboard", "Central Topic", ["Main Topic", "Main Topic", "Subtopic"],
            false, false, false
        ),
    ]

    @Test func everyTypeKeepsItsAnswers() {
        #expect(DiagramDescriptor.all.map(\.type) == Self.before.map(\.0), "one descriptor per type, in order")
        for (t, structure, name, root, topics, technical, asks, title) in Self.before {
            #expect(t.defaultStructure == structure, "\(t.rawValue)")
            #expect(t.displayName == name, "\(t.rawValue)")
            #expect(DiagramDescriptor[t].rootText == root, "\(t.rawValue)")
            #expect((0...2).map { defaultTopicText(type: t, depth: $0) } == topics, "\(t.rawValue)")
            #expect(DiagramCatalog.isTechnical(t) == technical, "\(t.rawValue)")
            #expect(DiagramCatalog.asksForNodeTypes(t) == asks, "\(t.rawValue)")
            #expect(DiagramCatalog.rootIsTitle(t) == title, "\(t.rawValue)")
        }
        #expect(defaultTopicText(type: .dfd, depth: 3) == "Data" && defaultTopicText(type: .org, depth: 5) == "Member")
    }

    @Test func palettesAndInferenceMatchTheTypes() {
        #expect(
            DiagramCatalog.nodeTypes(for: .flowchart).map(\.id) == [.start, .process, .decision, .io, .document, .end])
        #expect(
            DiagramCatalog.nodeTypes(for: .swimlane).map(\.id) == DiagramCatalog.nodeTypes(for: .flowchart).map(\.id))
        #expect(DiagramCatalog.nodeTypes(for: .dfd).map(\.id) == [.entity, .process, .store])
        #expect(DiagramCatalog.nodeTypes(for: .threatModel).count == 6)
        #expect(DiagramCatalog.nodeTypes(for: .architecture).count == 32)
        #expect(DiagramCatalog.nodeTypes(for: .sequence).count == 6)
        #expect(DiagramCatalog.nodeTypes(for: .mindmap).isEmpty)
        // Untyped nodes: flowcharts infer, mind maps don't.
        var flow = Canvas(id: "c1", title: "", type: .flowchart, rootText: "Begin")
        var undo = UndoStack()
        var step: NodeID = "n1"
        flow.edit("x", undo: &undo) { e in step = try! e.addChild(of: e.canvas.root, text: "Valid?") }
        #expect(DiagramCatalog.effectiveType(flow.root, in: flow) == .start)
        #expect(DiagramCatalog.effectiveType(step, in: flow) == .decision)
        flow.type = .mindmap
        #expect(DiagramCatalog.effectiveType(step, in: flow) == nil)
    }

    @Test func unknownTypesReadAsMindMaps() {
        let future = DiagramType(rawValue: "kanban")
        #expect(future.displayName == "kanban" && future.defaultStructure == .mindmapBalanced)
        #expect(!DiagramCatalog.isTechnical(future) && DiagramCatalog.nodeTypes(for: future).isEmpty)
        #expect(defaultTopicText(type: future, depth: 2) == "Subtopic")
    }

    /// ⌥⌘1–9 name a structure by the hierarchy type laid out in its family.
    @Test func structureFamiliesNameTheirHierarchyType() {
        let expected: [(LayoutStructure, DiagramType)] = [
            (.mindmapBalanced, .mindmap), (.mindmapLeft, .mindmap), (.logicLeft, .logic), (.braceLeft, .brace),
            (.orgDown, .org), (.treeDown, .tree), (.treeIndented, .tree), (.treeTable, .treeTable),
            (.timelineAlternating, .timeline), (.fishboneRight, .fishbone), (.matrix, .matrix), (.flowDown, .mindmap),
            (.graphRight, .mindmap), (.swimlanes, .mindmap), (.sequence, .mindmap),
        ]
        for (s, t) in expected { #expect(DiagramDescriptor.hierarchyType(for: s) == t, "\(s.rawValue)") }
    }

    @Test func pickerDataIsComplete() {
        for d in DiagramDescriptor.all {
            #expect(!d.summary.isEmpty && !d.aliases.isEmpty, "\(d.type.rawValue)")
            #expect(d.tint.count == 7 && d.tint.hasPrefix("#"), "\(d.type.rawValue)")
        }
        #expect(Set(DiagramDescriptor.all.map(\.category)) == Set(StarterCategory.allCases))
    }
}
