import AppKit
import NexusAI
import NexusCore
import NexusKeys
import Observation

/// The first-run tour (F5, artboard 31): a real canvas the user builds in six lessons.
/// It watches the commands the canvas runs and the edits that land, so every lesson is
/// completed by doing the real thing; nothing is simulated.
@MainActor
@Observable
public final class TourController {
    public struct Step: Equatable, Sendable {
        /// Keycaps shown by the coach ("⇥", "⌥⌘T").
        public var keys: [String]
        public var prompt: String
        /// Commands that complete the step.
        public var expects: Set<CommandID>
        /// A completion checked against the document instead (a label typed, an edge drawn).
        public var check: Check?
        public enum Check: Equatable, Sendable { case rootNamed, edgeDrawn, edgeLabelled }
    }

    public struct Lesson: Sendable {
        public var title: String
        public var seconds: Int
        public var steps: [Step]
    }

    public enum Coach: Equatable, Sendable {
        case prompt
        case success
        /// A different key: what it did, and that ⌘Z undoes it.
        case wrong(String)
    }

    public let role: Role
    public private(set) var lesson = 0
    public private(set) var step = 0
    public private(set) var coach: Coach = .prompt
    public private(set) var paused = false
    public private(set) var finished = false
    public private(set) var started = Date()
    public private(set) var finishedAt: Date?
    /// Steps completed in a row (the coach speeds up as you succeed).
    public private(set) var streak = 0
    @ObservationIgnored weak var controller: CanvasController?
    @ObservationIgnored var edgesAtStart = 0
    /// The central topic's text when the tour began: lesson 1 needs a name the user typed.
    @ObservationIgnored var initialRootText = ""

    public static let structural: Set<CommandID> = [
        .addChild, .addSiblingAfter, .addSiblingBefore, .addParent, .commitAndAddChild, .commitAndAddParent, .delete,
        .moveUp, .moveDown,
        .fold, .convert, .connect, .aiGhosts, .aiAccept, .aiAcceptAll, .duplicate, .addFloating,
    ]

    public static func lessons(_ role: Role) -> [Lesson] {
        [
            Lesson(
                title: "Type", seconds: 20,
                steps: [Step(keys: ["↩"], prompt: "Name your idea, then ↩", expects: [], check: .rootNamed)]),
            Lesson(
                title: "Tab and Return", seconds: 40,
                steps: [
                    Step(keys: ["⇥"], prompt: "Tab adds a child", expects: [.addChild, .commitAndAddChild]),
                    Step(keys: ["↩"], prompt: "Return adds a sibling", expects: [.addSiblingAfter]),
                    Step(keys: ["⇧", "↩"], prompt: "Shift-Return adds one before", expects: [.addSiblingBefore]),
                    Step(
                        keys: ["⌘", "↩"], prompt: "Command-Return adds a parent",
                        expects: [.addParent, .commitAndAddParent]),
                ]),
            Lesson(
                title: "Move around", seconds: 30,
                steps: [
                    Step(
                        keys: ["↑", "↓"], prompt: "Use the arrows to move",
                        expects: [.selectUp, .selectDown, .selectLeft, .selectRight]),
                    Step(keys: ["⌥⌘↑↓"], prompt: "Option-Command-Up or Down reorders", expects: [.moveUp, .moveDown]),
                    Step(keys: ["⌘/"], prompt: "Command-/ folds a branch", expects: [.fold]),
                ]),
            Lesson(
                title: "Connect", seconds: 30,
                steps: [
                    Step(keys: ["⇧⌘L"], prompt: "Shift-Command-L opens Connect mode", expects: [.connect]),
                    Step(keys: ["A"], prompt: "Pick a hint letter, then ↩", expects: [], check: .edgeDrawn),
                    Step(keys: ["↩"], prompt: "Name the edge, then ↩", expects: [], check: .edgeLabelled),
                ]),
            Lesson(
                title: "Transform", seconds: 40,
                steps: [
                    Step(
                        keys: ["⌥⌘T"],
                        prompt: Loc.f("Option-Command-T turns your map into a %@", role.conversionTitle.lowercased()),
                        expects: [.convert])
                ]),
            Lesson(
                title: "Ask AI", seconds: 30,
                steps: [
                    Step(
                        keys: ["⌥", "Space"], prompt: "Option-Space suggests ideas on this branch", expects: [.aiGhosts]
                    ),
                    Step(keys: ["⌃", "↩"], prompt: "Control-Return accepts one", expects: [.aiAccept, .aiAcceptAll]),
                ]),
        ]
    }

    public let lessons: [Lesson]

    public init(role: Role) {
        self.role = role
        self.lessons = Self.lessons(role)
    }

    public var current: Step? { finished ? nil : lessons[lesson].steps[step] }
    public var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(started) }

    /// Attaches to a canvas: the root opens in Edit mode, and AI uses scripted ideas when
    /// Apple Intelligence is off (so lesson 6 always works).
    public func attach(_ c: CanvasController) {
        controller = c
        c.tour = self
        started = Date()
        initialRootText = c.canvas.nodes[c.canvas.root]?.text ?? ""
        if !c.ai.availability.canRun {
            c.ai = ScriptedEngine(defaultIdeas: Self.ideas(role).map { GhostIdea(text: $0) })
        }
        c.beginEditing(replacingWith: "")
    }

    static func ideas(_ role: Role) -> [String] {
        switch role {
        case .engineer: ["Guest checkout", "Saved cards", "Address lookup"]
        case .architect: ["Lift and shift", "Re-platform", "Retire"]
        case .security: ["Tokenise card data", "Rate limiting", "Audit log"]
        case .planner: ["Pack light", "Book trains", "Rainy-day plan"]
        }
    }

    // MARK: Following the user

    /// Called by the canvas after it runs a command.
    func didRun(_ id: CommandID) {
        guard !paused, !finished, let s = current else { return }
        if s.expects.contains(id) {
            advance()
        } else if Self.structural.contains(id), s.check == nil {
            let title = controller?.registry[id]?.title ?? Loc.t("that")
            coach = .wrong(Loc.f("That was %@ · ⌘Z undoes it", title))
            streak = 0
        }
        // Lesson 4 counts edges from when Connect opened.
        if id == .connect { edgesAtStart = controller?.canvas.relationships.count ?? 0 }
    }

    /// Called after every edit lands (document checks).
    func didChange() {
        guard !paused, !finished, let s = current, let c = controller else { return }
        switch s.check {
        case .rootNamed?:
            let name = c.canvas.nodes[c.canvas.root]?.text ?? ""
            // An empty commit brings back the central topic's default text: not a name.
            let placeholder = CanvasController.defaultRootText(c.canvas.type)
            if c.mode == .select, !name.isEmpty, name != initialRootText, name != placeholder { advance() }
        case .edgeDrawn?:
            if c.canvas.relationships.count > edgesAtStart { advance() }
        case .edgeLabelled?:
            if c.mode == .select, let r = c.canvas.relationships.last, !r.label.isEmpty { advance() }
            if c.mode == .select, c.edit == nil, c.canvas.relationships.last?.label.isEmpty == true,
                c.selectedElement == nil
            {
                advance()
            }
        case nil:
            break
        }
    }

    /// Lesson 5: ⌥⌘T converts straight to the role's diagram type (the full animation).
    func convertForTour() -> Bool {
        guard !paused, !finished, current?.expects.contains(.convert) == true, let c = controller else { return false }
        c.openConvert()
        c.chooseConvertType(role.tourConversion)
        let proposals = c.convert?.proposals ?? [:]
        c.performConvert(role.tourConversion, nodeTypes: proposals)
        c.closeConvert()
        advance()
        return true
    }

    func advance() {
        coach = .success
        streak += 1
        if step + 1 < lessons[lesson].steps.count {
            step += 1
        } else if lesson + 1 < lessons.count {
            lesson += 1
            step = 0
            if lessons[lesson].steps.first?.expects.contains(.connect) == true {
                edgesAtStart = controller?.canvas.relationships.count ?? 0
            }
        } else {
            finished = true
            finishedAt = Date()
        }
        // The tick shows briefly, then the next prompt (sooner as the streak grows).
        let delay = max(0.25, 0.9 - Double(streak) * 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { if self?.coach == .success { self?.coach = .prompt } }
        }
    }

    // MARK: Controls

    public func skipLesson() {
        guard !finished else { return }
        if lesson + 1 < lessons.count {
            lesson += 1
            step = 0
            coach = .prompt
        } else {
            finished = true
            finishedAt = Date()
        }
    }

    public func pause() { if !finished { paused = true } }
    public func resume() {
        paused = false
        coach = .prompt
    }

    /// Finish (or skip the tour): the map stays as the user's first document.
    public func end() {
        controller?.tour = nil
        controller?.onTourEnded?(self)
    }

    /// "You built your first map in 3:41".
    public var elapsedText: String {
        let s = Int(elapsed.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
