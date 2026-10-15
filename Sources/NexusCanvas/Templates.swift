import Foundation
import NexusCore

/// The template shelf on Home (artboard 16), filtered by the role picked in onboarding.
/// Each template builds a real document through the same editor operations a user would.
public struct MapTemplate: Identifiable, Sendable {
    public var id: String
    public var kicker: String
    public var title: String
    public var detail: String
    public var category: Category
    public var type: DiagramType
    let build: @Sendable () -> Canvas

    public enum Category: String, CaseIterable, Sendable {
        case engineering = "Engineering", architecture = "Architecture", security = "Security", planning = "Planning",
            learning = "Learning"

        public var title: String {
            switch self {
            case .engineering: Loc.t("Engineering")
            case .architecture: Loc.t("Architecture")
            case .security: Loc.t("Security")
            case .planning: Loc.t("Planning")
            case .learning: Loc.t("Learning")
            }
        }
    }

    public func document() -> DocumentModel { DocumentModel(canvases: [build()]) }
}

/// The roles from the role picker (artboard 15).
public enum Role: String, CaseIterable, Sendable {
    case engineer, architect, security, planner

    public var title: String {
        switch self {
        case .engineer: Loc.t("Engineer")
        case .architect: Loc.t("Architect")
        case .security: Loc.t("Security")
        case .planner: "Planner · Student"
        }
    }

    public var blurb: String {
        switch self {
        case .engineer: Loc.t("Systems, APIs, incidents and sprints")
        case .architect: Loc.t("Platforms, migrations and decisions")
        case .security: Loc.t("Threats, data and access")
        case .planner: Loc.t("Projects, notes and ideas")
        }
    }

    /// The tour's example topic.
    public var tourExample: String {
        switch self {
        case .engineer: "Checkout service"
        case .architect: "Cloud migration"
        case .security: "Payment flow"
        case .planner: "Weekend trip"
        }
    }

    /// Lesson 5 converts the tour map to this.
    public var tourConversion: DiagramType {
        switch self {
        case .engineer: .flowchart
        case .architect: .architecture
        case .security: .dfd
        case .planner: .timeline
        }
    }

    public var conversionTitle: String {
        switch self {
        case .engineer: Loc.t("Flowchart")
        case .architect: Loc.t("Architecture")
        case .security: Loc.t("Data Flow + STRIDE")
        case .planner: "Timeline"
        }
    }

    public var shelfSummary: String {
        switch self {
        case .engineer: Loc.t("C4, API flow, retro")
        case .architect: Loc.t("Reference arch, ADR, capability map")
        case .security: Loc.t("Threat model, attack tree, IR runbook")
        case .planner: Loc.t("Roadmap, SWOT, book notes")
        }
    }

    public var shelf: MapTemplate.Category {
        switch self {
        case .engineer: .engineering
        case .architect: .architecture
        case .security: .security
        case .planner: .planning
        }
    }

    /// "Templates for engineers".
    public var shelfTitle: String {
        switch self {
        case .engineer: Loc.t("Templates for engineers")
        case .architect: Loc.t("Templates for architects")
        case .security: Loc.t("Templates for security")
        case .planner: Loc.t("Templates for planners")
        }
    }
}

public enum TemplateLibrary {
    /// Builds a canvas from an outline: `"Text"` or `"Text >type"`, indented with two spaces.
    static func outline(
        _ id: CanvasID, _ title: String, _ type: DiagramType, _ lines: String, edges: [(String, String, String)] = []
    ) -> Canvas {
        let rows = lines.split(separator: "\n").map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let rootText =
            rows.first?.trimmingCharacters(in: .whitespaces).split(separator: ">").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? title
        var c = Canvas(id: id, title: title, type: type, rootText: rootText)
        var undo = UndoStack()
        c.edit("Template", undo: &undo) { e in
            var stack: [(Int, NodeID)] = [(0, e.canvas.root)]
            if let t = rows.first?.split(separator: ">").dropFirst().first {
                e.update(e.canvas.root) { $0.nodeType = NodeType(rawValue: t.trimmingCharacters(in: .whitespaces)) }
            }
            for r in rows.dropFirst() {
                let depth = r.prefix { $0 == " " }.count / 2
                let parts = r.trimmingCharacters(in: .whitespaces).split(separator: ">", maxSplits: 1)
                let text = parts[0].trimmingCharacters(in: .whitespaces)
                while let last = stack.last, last.0 >= depth { stack.removeLast() }
                let parent = stack.last?.1 ?? e.canvas.root
                guard let id = try? e.addChild(of: parent, text: text) else { continue }
                if parts.count > 1 {
                    e.update(id) { $0.nodeType = NodeType(rawValue: parts[1].trimmingCharacters(in: .whitespaces)) }
                }
                stack.append((depth, id))
            }
            for (a, b, label) in edges {
                if let x = e.canvas.nodes.first(where: { $0.value.text == a })?.key,
                    let y = e.canvas.nodes.first(where: { $0.value.text == b })?.key
                {
                    _ = e.connect(x, to: y, label: label)
                }
            }
        }
        if type == .flowchart || type == .dfd || type == .architecture || type == .threatModel {
            c.layout.structure = type.defaultStructure
        }
        return c
    }

    public static let all: [MapTemplate] = [
        // Engineering
        MapTemplate(
            id: "c4", kicker: "C4 · L1–L2", title: Loc.t("System context"),
            detail: Loc.t("People, systems and containers"),
            category: .engineering, type: .architecture
        ) {
            outline(
                "c1", "System context", .architecture,
                """
                Online shop
                  Customer >actor
                    Web app >client
                      API gateway >gateway
                        Orders service >service
                          Orders DB >db
                        Payments service >service
                          Payment provider >external
                """)
        },
        MapTemplate(
            id: "apiFlow", kicker: "FLOW", title: Loc.t("API request flow"),
            detail: Loc.t("Client → gateway → services"),
            category: .engineering, type: .flowchart
        ) {
            outline(
                "c1", "API request flow", .flowchart,
                """
                Client request >start
                  Gateway authenticates
                    Token valid? >decision
                      Route to service
                        Service responds
                          Return 200 >end
                      Return 401 >end
                """)
        },
        MapTemplate(
            id: "incident", kicker: "TIMELINE", title: Loc.t("Incident timeline"),
            detail: Loc.t("Detect, mitigate, resolve"),
            category: .engineering, type: .timeline
        ) {
            var c = outline(
                "c1", "Incident timeline", .timeline,
                """
                Incident · checkout errors
                  Detect · 09:12
                    Alert fires on error rate
                  Mitigate · 09:30
                    Roll back release
                  Resolve · 10:05
                    Error rate back to baseline
                  Review · next day
                    Blameless retro
                """)
            c.layout.structure = .timelineHorizontal
            return c
        },
        MapTemplate(
            id: "retro", kicker: "MATRIX", title: Loc.t("Sprint retro"),
            detail: Loc.t("Went well · to improve · actions"),
            category: .engineering, type: .matrix
        ) {
            var c = outline(
                "c1", "Sprint retro", .matrix,
                """
                Sprint 42 retro
                  Went well
                    Shipped search
                  To improve
                    Flaky CI
                  Actions
                    Quarantine flaky tests
                """)
            c.layout.structure = .matrix
            return c
        },
        MapTemplate(
            id: "oauth", kicker: "SEQUENCE", title: Loc.t("OAuth handshake"),
            detail: Loc.t("Lifelines with return messages"),
            category: .engineering, type: .sequence
        ) {
            var c = outline(
                "c1", "OAuth handshake", .sequence,
                """
                OAuth handshake
                  User >actor
                  App >participant
                  Auth server >participant
                """)
            var undo = UndoStack()
            let ids = c.nodes[c.root]!.children
            c.edit("Messages", undo: &undo) { e in
                for (a, b, l, ret) in [
                    (0, 1, "Sign in", false), (1, 2, "Authorize", false), (2, 1, "Code", true),
                    (1, 2, "Exchange code", false), (2, 1, "Access token", true),
                ] {
                    let r = e.connect(ids[a], to: ids[b], label: l)
                    if ret { e.updateRelationship(r) { $0.kind = "return" } }
                }
            }
            return c
        },
        // Architecture
        MapTemplate(
            id: "refArch", kicker: "ARCHITECTURE", title: Loc.t("Reference architecture"),
            detail: Loc.t("Edge, services, data, observability"), category: .architecture, type: .architecture
        ) {
            outline(
                "c1", "Reference architecture", .architecture,
                """
                Platform
                  CDN >cdn
                    Load balancer >lb
                      Service A >service
                        Primary DB >db
                      Service B >service
                        Cache >cache
                      Queue >queue
                  Monitoring >monitor
                """)
        },
        MapTemplate(
            id: "adr", kicker: "DECISION", title: Loc.t("Architecture decision record"),
            detail: Loc.t("Context, options, decision, consequences"), category: .architecture, type: .mindmap
        ) {
            outline(
                "c1", "ADR-012 · Event bus", .mindmap,
                """
                ADR-012 · Event bus
                  Context
                    Services poll each other
                  Options
                    Kafka
                    SNS + SQS
                    Stay with polling
                  Decision
                    SNS + SQS
                  Consequences
                    At-least-once delivery
                """)
        },
        MapTemplate(
            id: "capability", kicker: "TREE", title: Loc.t("Capability map"),
            detail: Loc.t("Business capabilities by level"),
            category: .architecture, type: .org
        ) {
            var c = outline(
                "c1", "Capability map", .org,
                """
                Retail
                  Sell
                    Catalogue
                    Checkout
                  Fulfil
                    Warehouse
                    Delivery
                  Support
                    Returns
                """)
            c.layout.structure = .orgDown
            return c
        },
        MapTemplate(
            id: "migration", kicker: "TIMELINE", title: Loc.t("Cloud migration"),
            detail: Loc.t("Waves from assess to decommission"),
            category: .architecture, type: .timeline
        ) {
            var c = outline(
                "c1", "Cloud migration", .timeline,
                """
                Cloud migration
                  Assess
                  Wave 1 · stateless
                  Wave 2 · data
                  Cut over
                  Decommission
                """)
            c.layout.structure = .timelineHorizontal
            return c
        },
        MapTemplate(
            id: "fishbone", kicker: "FISHBONE", title: Loc.t("Root cause analysis"),
            detail: Loc.t("People, process, tools, environment"), category: .architecture, type: .fishbone
        ) {
            var c = outline(
                "c1", "Slow deploys", .fishbone,
                """
                Slow deploys
                  People
                    Manual approvals
                  Process
                    Big batches
                  Tools
                    Serial test runs
                  Environment
                    Shared staging
                """)
            c.layout.structure = .fishboneLeft
            return c
        },
        // Security
        MapTemplate(
            id: "threat", kicker: Loc.t("THREAT MODEL"), title: Loc.t("Threat model"),
            detail: Loc.t("Data flow with STRIDE per element"),
            category: .security, type: .threatModel
        ) {
            outline(
                "c1", "Payments threat model", .threatModel,
                """
                Payments
                  Customer >entity
                    Checkout >process
                      Card vault >store
                      Payment provider >entity
                """)
        },
        MapTemplate(
            id: "dfd", kicker: Loc.t("DATA FLOW"), title: Loc.t("Data flow diagram"),
            detail: Loc.t("Entities, processes and stores"),
            category: .security, type: .dfd
        ) {
            outline(
                "c1", "Login data flow", .dfd,
                """
                Login
                  User >entity
                    Authenticate >process
                      Credentials >store
                      Session store >store
                """)
        },
        MapTemplate(
            id: "attackTree", kicker: "TREE", title: Loc.t("Attack tree"),
            detail: Loc.t("Goals, paths and mitigations"),
            category: .security, type: .logic
        ) {
            var c = outline(
                "c1", "Steal session", .logic,
                """
                Steal session
                  Phish credentials
                    Fake login page
                  Hijack token
                    XSS on profile page
                    Token in logs
                  Brute force
                    No rate limit
                """)
            c.layout.structure = .logicRight
            return c
        },
        MapTemplate(
            id: "runbook", kicker: "FLOW", title: Loc.t("Incident response runbook"),
            detail: Loc.t("Triage, contain, recover"),
            category: .security, type: .flowchart
        ) {
            outline(
                "c1", "IR runbook", .flowchart,
                """
                Alert received >start
                  Triage severity
                    Sev 1? >decision
                      Page on-call
                        Contain
                          Recover
                            Post-incident review >end
                      Ticket and monitor >end
                """)
        },
        MapTemplate(
            id: "access", kicker: "MATRIX", title: Loc.t("Access review"), detail: Loc.t("Roles, systems and owners"),
            category: .security, type: .matrix
        ) {
            var c = outline(
                "c1", "Access review", .matrix,
                """
                Access review
                  Admins
                    Prod console
                  Engineers
                    Staging
                  Support
                    Read-only CRM
                """)
            c.layout.structure = .matrix
            return c
        },
        // Planning
        MapTemplate(
            id: "roadmap", kicker: "TIMELINE", title: Loc.t("Roadmap"), detail: Loc.t("Now, next, later"),
            category: .planning,
            type: .timeline
        ) {
            var c = outline(
                "c1", "Product roadmap", .timeline,
                """
                Product roadmap
                  Now · Q1
                    Onboarding revamp
                  Next · Q2
                    Team plans
                  Later · H2
                    Integrations
                """)
            c.layout.structure = .timelineHorizontal
            return c
        },
        MapTemplate(
            id: "swot", kicker: "MATRIX", title: "SWOT", detail: Loc.t("Strengths, weaknesses, opportunities, threats"),
            category: .planning, type: .matrix
        ) {
            var c = outline(
                "c1", "SWOT", .matrix,
                """
                SWOT
                  Strengths
                    Loyal users
                  Weaknesses
                    Small team
                  Opportunities
                    New market
                  Threats
                    Competitor pricing
                """)
            c.layout.structure = .matrix
            return c
        },
        MapTemplate(
            id: "trip", kicker: Loc.t("MIND MAP"), title: Loc.t("Weekend trip"), detail: Loc.t("Plan, pack, book"),
            category: .planning,
            type: .mindmap
        ) {
            outline(
                "c1", "Weekend trip", .mindmap,
                """
                Weekend trip
                  Plan
                    Route
                    Budget
                  Pack
                    Passport
                    Charger
                  Book
                    Hotel
                    Train
                """)
        },
        MapTemplate(
            id: "project", kicker: Loc.t("TREE TABLE"), title: Loc.t("Project plan"),
            detail: Loc.t("Workstreams and tasks"),
            category: .planning, type: .treeTable
        ) {
            var c = outline(
                "c1", "Project plan", .treeTable,
                """
                Project plan
                  Discovery
                    Interviews
                  Build
                    Prototype
                  Launch
                    Announcement
                """)
            c.layout.structure = .treeTable
            return c
        },
        MapTemplate(
            id: "meeting", kicker: Loc.t("MIND MAP"), title: Loc.t("Meeting notes"),
            detail: Loc.t("Agenda, decisions, actions"),
            category: .planning, type: .mindmap
        ) {
            outline(
                "c1", "Weekly sync", .mindmap,
                """
                Weekly sync
                  Agenda
                  Decisions
                  Actions
                """)
        },
        // Learning
        MapTemplate(
            id: "bookNotes", kicker: Loc.t("MIND MAP"), title: Loc.t("Book notes"),
            detail: Loc.t("Ideas, quotes and questions"),
            category: .learning, type: .mindmap
        ) {
            outline(
                "c1", "Thinking in Systems", .mindmap,
                """
                Thinking in Systems
                  Ideas
                    Stocks and flows
                    Feedback loops
                  Quotes
                  Questions
                """)
        },
        MapTemplate(
            id: "course", kicker: "TREE", title: Loc.t("Course outline"), detail: Loc.t("Modules and lessons"),
            category: .learning,
            type: .tree
        ) {
            var c = outline(
                "c1", "Course outline", .tree,
                """
                Intro to Swift
                  Basics
                    Values
                    Functions
                  Types
                    Structs
                    Enums
                """)
            c.layout.structure = .treeIndented
            return c
        },
        MapTemplate(
            id: "concept", kicker: Loc.t("MIND MAP"), title: Loc.t("Concept map"),
            detail: Loc.t("Terms and how they relate"),
            category: .learning, type: .mindmap
        ) {
            outline(
                "c1", "Photosynthesis", .mindmap,
                """
                Photosynthesis
                  Light
                  Water
                  Carbon dioxide
                  Glucose
                """, edges: [("Light", "Glucose", "powers")])
        },
        MapTemplate(
            id: "essay", kicker: "LOGIC", title: Loc.t("Essay plan"), detail: Loc.t("Thesis, arguments, evidence"),
            category: .learning, type: .logic
        ) {
            var c = outline(
                "c1", "Essay plan", .logic,
                """
                Thesis
                  Argument 1
                    Evidence
                  Argument 2
                    Evidence
                  Counter-argument
                """)
            c.layout.structure = .logicRight
            return c
        },
        MapTemplate(
            id: "revision", kicker: Loc.t("TREE TABLE"), title: Loc.t("Revision tracker"),
            detail: Loc.t("Topics, confidence and dates"),
            category: .learning, type: .treeTable
        ) {
            var c = outline(
                "c1", "Revision", .treeTable,
                """
                Revision
                  Algebra
                  Geometry
                  Statistics
                """)
            c.layout.structure = .treeTable
            return c
        },
    ]

    public static func shelf(_ category: MapTemplate.Category) -> [MapTemplate] {
        all.filter { $0.category == category }
    }

    /// The tour's starting document for a role (lesson 1 names the root).
    public static func tourDocument(_ role: Role) -> DocumentModel {
        DocumentModel(canvases: [Canvas(id: "c1", title: "My first map", rootText: "")])
    }
}
