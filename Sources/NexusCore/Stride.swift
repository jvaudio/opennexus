import Foundation

/// STRIDE for threat-model canvases (artboard 21). Threats are nodes (type `threat`)
/// under the element they threaten; a `mitigation` child records the mitigation. Their
/// category, risk and status are metadata fields, so they show in the Data tab too.
public enum Stride: String, Sendable, CaseIterable {
    case spoofing = "S", tampering = "T", repudiation = "R", infoDisclosure = "I", denialOfService = "D",
        elevation = "E"

    public var name: String {
        switch self {
        case .spoofing: "Spoofing"
        case .tampering: "Tampering"
        case .repudiation: "Repudiation"
        case .infoDisclosure: "Info disclosure"
        case .denialOfService: "Denial of service"
        case .elevation: "Elevation"
        }
    }

    public init?(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let hit = Stride.allCases.first(where: { $0.rawValue.lowercased() == n || $0.name.lowercased() == n })
        else { return nil }
        self = hit
    }

    /// STRIDE-per-element: which categories apply to each DFD element type.
    public static func applicable(to type: NodeType?) -> [Stride] {
        switch type {
        case .process?: Stride.allCases
        case .store?: [.tampering, .repudiation, .infoDisclosure, .denialOfService]
        case .entity?: [.spoofing, .repudiation]
        default: []
        }
    }

    // MARK: Fields

    public static let categoryKey = "STRIDE"
    public static let riskKey = "Risk"
    public static let statusKey = "Status"
    public static let risks = ["High", "Med", "Low", "N/A"]
    public static let statuses = ["Open", "In review", "Mitigated", "Accepted"]

    public static func field(_ node: Node, _ key: String) -> String? {
        node.metadata.first { $0.key == key }?.value
    }

    // MARK: Threats on a canvas

    public struct Threat: Sendable, Equatable, Identifiable {
        public var id: String
        public var node: NodeID
        public var element: NodeID?
        public var elementName: String
        public var category: Stride?
        public var title: String
        public var risk: String
        public var mitigation: String?
        public var status: String
    }

    /// Every threat node in tree order, numbered T-01, T-02 …
    public static func threats(_ canvas: Canvas) -> [Threat] {
        let parents = canvas.parentMap()
        let numbers = DFDRules.numbers(canvas)
        var out: [Threat] = []
        for top in canvas.tops {
            for id in canvas.subtree(top) {
                guard let n = canvas.nodes[id],
                    DiagramCatalog.effectiveType(id, in: canvas, parents: parents) == .threat
                else { continue }
                let element = parents[id]
                let elementName =
                    element.flatMap { e in
                        canvas.nodes[e].map { node in [numbers[e], node.text].compactMap { $0 }.joined(separator: " ") }
                    } ?? "—"
                let mitigation = n.children.compactMap { canvas.nodes[$0] }.first { $0.nodeType == .mitigation }?.text
                let status = field(n, statusKey) ?? (mitigation == nil ? "Open" : "Mitigated")
                out.append(
                    Threat(
                        id: String(format: "T-%02d", out.count + 1), node: id, element: element,
                        elementName: elementName, category: field(n, categoryKey).flatMap(Stride.init(name:)),
                        title: n.text, risk: field(n, riskKey) ?? "Med", mitigation: mitigation, status: status))
            }
        }
        return out
    }

    /// Suggested threats for an element: one per applicable category it doesn't cover yet.
    /// Deterministic templates; M6 adds the on-device model.
    public static func suggestions(for id: NodeID, in canvas: Canvas) -> [(Stride, String, String)] {
        guard let node = canvas.nodes[id] else { return [] }
        let type = DiagramCatalog.effectiveType(id, in: canvas)
        let covered = Set(
            threats(canvas).filter { $0.element == id }.compactMap(\.category))
        let name = node.text
        let sensitive = NodeTypeSuggester.matches(
            name, ["payment", "payments", "card", "cards", "auth", "token", "tokens", "password", "secret", "pci"])
        return applicable(to: type).filter { !covered.contains($0) }.map { s in
            let (text, risk): (String, String) =
                switch (s, type) {
                case (.spoofing, .entity?): ("Someone impersonates \(name)", "Med")
                case (.spoofing, _): ("Spoofed caller of \(name)", sensitive ? "High" : "Med")
                case (.tampering, .store?): ("\(name) edited outside its service", "Med")
                case (.tampering, _): ("Input to \(name) altered in transit", "Med")
                case (.repudiation, .entity?): ("\(name) disputes an action without evidence", "Med")
                case (.repudiation, .store?): ("Changes to \(name) aren’t attributable", "Low")
                case (.repudiation, _): ("No signed audit log for \(name)", "Med")
                case (.infoDisclosure, .store?): ("\(name) readable by other services", sensitive ? "High" : "Med")
                case (.infoDisclosure, _): ("\(name) leaks data in logs or errors", sensitive ? "High" : "Med")
                case (.denialOfService, .store?): ("\(name) fills up or locks", "Low")
                case (.denialOfService, _): ("Retry storms overwhelm \(name)", "Low")
                case (.elevation, _): ("\(name) runs with more privilege than it needs", "Med")
                }
            return (s, text, risk)
        }
    }

    // MARK: Table output

    public static let tableHeader = ["ID", "Element", "STRIDE", "Threat", "Risk", "Mitigation", "Status"]

    static func row(_ t: Threat) -> [String] {
        [t.id, t.elementName, t.category?.name ?? "—", t.title, t.risk, t.mitigation ?? "—", t.status]
    }

    /// RFC 4180 CSV.
    public static func csv(_ threats: [Threat]) -> String {
        func esc(_ s: String) -> String {
            s.contains(where: { ",\"\n\r".contains($0) })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([tableHeader] + threats.map(row)).map { $0.map(esc).joined(separator: ",") }.joined(separator: "\r\n")
            + "\r\n"
    }

    /// A GitHub-flavoured Markdown table.
    public static func markdown(_ threats: [Threat]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| " + tableHeader.joined(separator: " | ") + " |"]
        lines.append("|" + tableHeader.map { _ in " --- |" }.joined())
        for t in threats { lines.append("| " + row(t).map(esc).joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension CanvasEditor {
    /// Adds a threat card under an element.
    @discardableResult
    public mutating func addThreat(
        on element: NodeID, category: Stride, title: String, risk: String, suggested: Bool = false
    ) throws -> NodeID {
        let t = try addChild(of: element, text: title)
        update(t) {
            $0.nodeType = .threat
            $0.ai = suggested
            $0.metadata = [
                MetadataField(key: Stride.categoryKey, value: category.name),
                MetadataField(key: Stride.riskKey, value: risk),
                MetadataField(key: Stride.statusKey, value: "Open"),
            ]
        }
        return t
    }

    /// Sets one STRIDE field (category, risk or status) on a threat.
    public mutating func setThreatField(_ id: NodeID, _ key: String, _ value: String) {
        update(id) { n in
            if let i = n.metadata.firstIndex(where: { $0.key == key }) {
                n.metadata[i].value = value
            } else {
                n.metadata.append(MetadataField(key: key, value: value))
            }
        }
    }
}
