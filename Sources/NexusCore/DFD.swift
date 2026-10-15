import Foundation

/// The flows of a technical canvas: tree edges (parent → child, labelled by the child's
/// `edgeLabel`) plus relationships. In title-rooted types the root's own edges are not
/// flows; the root is the diagram's title.
public struct FlowGraph: Sendable {
    public struct Flow: Sendable, Equatable, Identifiable {
        /// `t:<child>` for a tree edge, the relationship id otherwise.
        public var id: String
        public var from: NodeID
        public var to: NodeID
        public var label: String
        public var isTree: Bool
    }

    public var elements: [NodeID] = []
    public var types: [NodeID: NodeType] = [:]
    public var flows: [Flow] = []

    public static func treeFlowID(_ child: NodeID) -> String { "t:\(child.rawValue)" }

    public init(_ canvas: Canvas) {
        let parents = canvas.parentMap()
        let titleRoot = DiagramCatalog.rootIsTitle(canvas.type)
        for top in canvas.tops where !(canvas.summaries.contains { $0.topic == top }) {
            for id in canvas.subtree(top) {
                if titleRoot && id == canvas.root { continue }
                elements.append(id)
                if let t = DiagramCatalog.effectiveType(id, in: canvas, parents: parents) { types[id] = t }
                if let p = parents[id], !(titleRoot && p == canvas.root) {
                    flows.append(
                        Flow(
                            id: Self.treeFlowID(id), from: p, to: id, label: canvas.nodes[id]?.edgeLabel ?? "",
                            isTree: true))
                }
            }
        }
        let present = Set(elements)
        for r in canvas.relationships where present.contains(r.from) && present.contains(r.to) {
            flows.append(Flow(id: r.id, from: r.from, to: r.to, label: r.label, isTree: false))
        }
    }

    public func isProcess(_ id: NodeID) -> Bool { types[id] == .process }
}

/// DFD rule checks (artboard 20). Decided rule set: see D52.
public enum DFDRules {
    public enum Rule: String, Sendable, CaseIterable {
        case touchesProcess, storeWritten, processIO, labelled, levelsBalanced
    }

    public enum Severity: Sendable { case error, warning }

    public enum Subject: Sendable, Equatable {
        case flow(String)
        case node(NodeID)
    }

    public enum Fix: Sendable, Equatable {
        case insertProcess(flow: String)
        case rerouteVia(flow: String, process: NodeID)
        case ignore
    }

    public struct Violation: Sendable, Equatable, Identifiable {
        /// Stable across edits so "Ignore" sticks: rule plus subject.
        public var id: String
        public var rule: Rule
        public var severity: Severity
        public var subject: Subject
        public var title: String
        public var detail: String
        public var fixes: [Fix]
    }

    /// `level(canvas)` resolves a process's drilled-down canvas, for the balance rule.
    public static func check(_ canvas: Canvas, level: (CanvasID) -> Canvas? = { _ in nil }) -> [Violation] {
        guard canvas.type == .dfd || canvas.type == .threatModel else { return [] }
        let g = FlowGraph(canvas)
        let names = numberedNames(canvas, graph: g)
        func name(_ id: NodeID) -> String { names[id] ?? canvas.nodes[id]?.text ?? id.rawValue }
        let dataTypes: Set<NodeType> = [.entity, .process, .store]
        var out: [Violation] = []

        for f in g.flows {
            guard let ta = g.types[f.from], let tb = g.types[f.to], dataTypes.contains(ta), dataTypes.contains(tb)
            else { continue }
            if ta != .process && tb != .process {
                let why: String =
                    switch (ta, tb) {
                    case (.entity, .store): CoreText.t("Entities can’t write to stores directly.")
                    case (.store, .entity): CoreText.t("Entities can’t read stores directly.")
                    case (.store, .store): CoreText.t("Stores can’t move data between themselves.")
                    default: CoreText.t("Entities exchange data through a process.")
                    }
                let label = f.label.isEmpty ? CoreText.t("A flow") : CoreText.f("“%@”", f.label)
                var fixes: [Fix] = [.insertProcess(flow: f.id)]
                // A process the source already feeds (or the target already reads from).
                let via =
                    g.flows.first { $0.from == f.from && g.isProcess($0.to) }?.to
                    ?? g.flows.first { $0.to == f.to && g.isProcess($0.from) }?.from
                if let via { fixes.append(.rerouteVia(flow: f.id, process: via)) }
                fixes.append(.ignore)
                out.append(
                    Violation(
                        id: "touchesProcess:\(f.id)", rule: .touchesProcess, severity: .error, subject: .flow(f.id),
                        title: CoreText.t("A data flow must touch a process"),
                        detail: CoreText.f("%@ goes from %@ straight to %@. %@", label, name(f.from), name(f.to), why),
                        fixes: fixes))
            }
            if f.label.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(
                    Violation(
                        id: "labelled:\(f.id)", rule: .labelled, severity: .warning, subject: .flow(f.id),
                        title: CoreText.t("Name every data flow"),
                        detail: CoreText.f("The flow from %@ to %@ has no label.", name(f.from), name(f.to)),
                        fixes: [.ignore]))
            }
        }
        for id in g.elements {
            switch g.types[id] {
            case .store?:
                if !g.flows.contains(where: { $0.to == id }) {
                    out.append(
                        Violation(
                            id: "storeWritten:\(id.rawValue)", rule: .storeWritten, severity: .error,
                            subject: .node(id), title: CoreText.t("A data store is never written"),
                            detail: CoreText.f("%@ has no incoming flow, so nothing ever writes to it.", name(id)),
                            fixes: [.ignore]))
                }
            case .process?:
                // Only data flows count (threat, mitigation and asset links don't).
                func data(_ n: NodeID) -> Bool { g.types[n].map(dataTypes.contains) ?? false }
                let ins = g.flows.contains { $0.to == id && data($0.from) }
                let outs = g.flows.contains { $0.from == id && data($0.to) }
                if !ins || !outs {
                    out.append(
                        Violation(
                            id: "processIO:\(id.rawValue)", rule: .processIO, severity: .error, subject: .node(id),
                            title: ins ? CoreText.t("A process with no output") : CoreText.t("A process with no input"),
                            detail: ins
                                ? CoreText.f("%@ receives data but sends none on (a black hole).", name(id))
                                : CoreText.f("%@ sends data it never receives (a miracle).", name(id)),
                            fixes: [.ignore]))
                }
                if let sub = canvas.nodes[id]?.subCanvas, let child = level(sub) {
                    let mine = Set(g.flows.filter { $0.from == id || $0.to == id }.map(\.label).filter { !$0.isEmpty })
                    let cg = FlowGraph(child)
                    let theirs = Set(
                        cg.flows.filter { f in
                            (cg.isProcess(f.from) != cg.isProcess(f.to))
                        }.map(\.label).filter { !$0.isEmpty })
                    if mine != theirs {
                        let missing = mine.subtracting(theirs).sorted()
                        let extra = theirs.subtracting(mine).sorted()
                        var parts: [String] = []
                        if !missing.isEmpty { parts.append(CoreText.f("missing %@", missing.joined(separator: ", "))) }
                        if !extra.isEmpty { parts.append(CoreText.f("extra %@", extra.joined(separator: ", "))) }
                        out.append(
                            Violation(
                                id: "levelsBalanced:\(id.rawValue)", rule: .levelsBalanced, severity: .error,
                                subject: .node(id), title: CoreText.t("Levels aren’t balanced"),
                                detail: CoreText.f("%@’s next level has %@.", name(id), parts.joined(separator: "; ")),
                                fixes: [.ignore]))
                    }
                }
            default:
                break
            }
        }
        let ignored = Set(canvas.diagram.ignoredRules)
        return out.filter { !ignored.contains($0.id) }
    }

    /// The rule-checks list (artboard 20, left panel): one row per rule.
    public static func summary(_ violations: [Violation]) -> [(rule: Rule, ok: Bool, text: String)] {
        func count(_ r: Rule) -> Int { violations.filter { $0.rule == r }.count }
        let n = count(.touchesProcess)
        let s = count(.storeWritten)
        let p = count(.processIO)
        let l = count(.labelled)
        let b = count(.levelsBalanced)
        return [
            (
                .touchesProcess, n == 0,
                n == 0
                    ? CoreText.t("Flows all touch a process")
                    : CoreText.n("%lld flow skips a process", "%lld flows skip a process", n)
            ),
            (
                .storeWritten, s == 0,
                s == 0
                    ? CoreText.t("Stores all written")
                    : CoreText.n("%lld store never written", "%lld stores never written", s)
            ),
            (
                .processIO, p == 0,
                p == 0
                    ? CoreText.t("Processes have inputs and outputs")
                    : CoreText.n("%lld process missing a flow", "%lld processes missing a flow", p)
            ),
            (
                .labelled, l == 0,
                l == 0
                    ? CoreText.t("Flows all labelled") : CoreText.n("%lld unlabelled flow", "%lld unlabelled flows", l)
            ),
            (
                .levelsBalanced, b == 0,
                b == 0
                    ? CoreText.t("Levels balanced") : CoreText.n("%lld level unbalanced", "%lld levels unbalanced", b)
            ),
        ]
    }

    /// DFD numbering: processes 1.0, 2.0 … (2.1, 2.2 … inside a drilled level), stores
    /// D1, D2 … in tree order.
    public static func numbers(_ canvas: Canvas, graph: FlowGraph? = nil) -> [NodeID: String] {
        let g = graph ?? FlowGraph(canvas)
        var out: [NodeID: String] = [:]
        var p = 0
        var d = 0
        let prefix = canvas.diagram.levelNumber
        // Breadth-first, so numbers follow distance along the flow (1.0 feeds 2.0).
        var order: [NodeID] = []
        var queue = canvas.tops
        var seen = Set<NodeID>()
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard seen.insert(id).inserted else { continue }
            order.append(id)
            queue.append(contentsOf: canvas.nodes[id]?.children ?? [])
        }
        for id in order where g.types[id] != nil {
            switch g.types[id] {
            case .process?:
                p += 1
                out[id] = prefix.map { "\($0).\(p)" } ?? "\(p).0"
            case .store?:
                d += 1
                out[id] = "D\(d)"
            default:
                break
            }
        }
        return out
    }

    static func numberedNames(_ canvas: Canvas, graph: FlowGraph) -> [NodeID: String] {
        var out: [NodeID: String] = [:]
        for (id, n) in numbers(canvas, graph: graph) {
            out[id] = "\(n) \(canvas.nodes[id]?.text ?? "")"
        }
        return out
    }
}

extension CanvasEditor {
    /// Applies a DFD fix as one edit. Returns the node to edit next, if any.
    @discardableResult
    public mutating func apply(_ fix: DFDRules.Fix, violation: String) throws -> NodeID? {
        switch fix {
        case .ignore:
            updateMeta { if !$0.diagram.ignoredRules.contains(violation) { $0.diagram.ignoredRules.append(violation) } }
            return nil
        case .insertProcess(let flowID):
            if flowID.hasPrefix("t:") {
                let child = NodeID(String(flowID.dropFirst(2)))
                let label = self[child]?.edgeLabel
                let p = try addParent(of: child, text: "New process")
                update(p) {
                    $0.nodeType = .process
                    $0.edgeLabel = label
                }
                return p
            }
            guard let r = canvas.relationships.first(where: { $0.id == flowID }) else { return nil }
            let p = try addChild(of: r.from, text: "New process")
            update(p) {
                $0.nodeType = .process
                $0.edgeLabel = r.label.isEmpty ? nil : r.label
            }
            updateRelationship(flowID) { $0.from = p }
            return p
        case .rerouteVia(let flowID, let process):
            if flowID.hasPrefix("t:") {
                try move(NodeID(String(flowID.dropFirst(2))), toParent: process)
            } else if let r = canvas.relationships.first(where: { $0.id == flowID }) {
                if r.from != process && canvas.relationships.contains(where: { $0.from == r.from && $0.to == process })
                    || canvas.parent(of: process) == r.from
                {
                    updateRelationship(flowID) { $0.from = process }
                } else {
                    updateRelationship(flowID) { $0.to = process }
                }
            }
            return nil
        }
    }
}
