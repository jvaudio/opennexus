import Foundation
import FoundationModels
import NexusCore

// MARK: Guided generation types

@Generable(description: "New child topics for a mind-map branch")
struct IdeaList {
    @Guide(description: "Three to five new child topics. Each is a short title of one to five words.", .count(3...5))
    var ideas: [String]
}

@Generable(description: "A work breakdown: phases with priority and duration, each with a few steps")
struct Breakdown {
    @Guide(
        description:
            "The first phase's start date as yyyy-MM-dd when the request or the map names one; otherwise an empty string"
    )
    var start: String
    @Guide(description: "Two to four phases in order", .count(2...4))
    var phases: [Phase]
}

@Generable(description: "One phase of work")
struct Phase {
    @Guide(description: "Short phase title, such as 'Content' or 'QA & launch'")
    var title: String
    @Guide(description: "Priority from 1 (highest) to 3", .range(1...3))
    var priority: Int
    @Guide(description: "Duration in weeks", .range(1...12))
    var weeks: Int
    @Guide(description: "Zero to three short sub-steps", .count(0...3))
    var steps: [String]
}

@Generable(description: "Checkable to-do steps")
struct TodoSteps {
    @Guide(description: "Three to seven short imperative steps, such as 'Write role brief'", .count(3...7))
    var steps: [String]
}

@Generable(description: "An answer about the map and, unless discussing, a plan of edits")
struct DraftReply {
    @Guide(description: "A short, direct answer in one to three sentences, naming topics in the map")
    var answer: String
    @Guide(description: "New topics to add. Use an empty list when no edits are needed.", .count(0...8))
    var adds: [AddOp]
    @Guide(description: "Topics to rename. Use an empty list when nothing should be renamed.", .count(0...4))
    var renames: [RenameOp]
}

@Generable(description: "Add a new topic under a parent topic")
struct AddOp {
    @Guide(description: "The exact title of an existing topic, or of another topic being added")
    var parent: String
    @Guide(description: "The new topic's title, one to six words")
    var text: String
}

@Generable(description: "Rename an existing topic")
struct RenameOp {
    @Guide(description: "The exact current title")
    var from: String
    @Guide(description: "The new title")
    var to: String
}

/// The default engine: Apple's on-device model through Foundation Models. Nothing leaves
/// this Mac (no Private Cloud Compute, no network).
public final class AppleEngine: AIEngine, @unchecked Sendable {
    private let model = SystemLanguageModel.default
    private let lock = NSLock()
    private var warm: LanguageModelSession?

    public init() {}

    public var availability: AIAvailability {
        switch model.availability {
        case .available: return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .off
            case .modelNotReady: return .downloading
            case .deviceNotEligible: return .unsupported
            @unknown default: return .unsupported
            }
        }
    }

    static let base = """
        You help people build mind maps and technical diagrams in OpenNexus. Be concrete and concise. \
        Write topic titles in the language of the map, in title or sentence case, without numbering or \
        trailing punctuation. Never repeat a topic that already exists.
        """

    /// A session ready for the next ghost request (prewarmed, so the first idea is quick).
    private func takeSession() -> LanguageModelSession {
        lock.lock()
        defer { lock.unlock() }
        if let w = warm {
            warm = nil
            return w
        }
        return LanguageModelSession(model: model, instructions: Self.base)
    }

    public func prewarm() {
        guard availability.canRun else { return }
        lock.lock()
        defer { lock.unlock() }
        if warm == nil {
            let s = LanguageModelSession(model: model, instructions: Self.base)
            s.prewarm()
            warm = s
        }
    }

    static func context(_ r: AIRequest) -> String {
        var parts: [String] = []
        if !r.outline.isEmpty { parts.append("The map:\n\(r.outline)") }
        if !r.anchorPath.isEmpty { parts.append("Selected branch: \(r.anchorPath)") }
        if !r.existingChildren.isEmpty {
            parts.append("Existing children of “\(r.anchorText)”: \(r.existingChildren.joined(separator: "; "))")
        }
        return parts.joined(separator: "\n\n")
    }

    public func ideas(_ r: AIRequest) -> AsyncThrowingStream<GhostIdea, any Error> {
        let session = takeSession()
        let context = Self.context(r)
        let anchor = r.anchorText
        let extra = r.prompt
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch r.action {
                    case .breakdown, .sprintPlan:
                        let prompt =
                            "\(context)\n\nToday is \(TaskDate.today()). Break “\(anchor)” down into phases of work\(r.action == .sprintPlan ? " (sprints)" : ""). \(extra)"
                        let out = try await session.respond(to: prompt, generating: Breakdown.self).content
                        // Phases become tasks: the first starts on the plan's date, if it has
                        // one, and each later phase follows the one before (D209).
                        let start = TaskDate(out.start.trimmingCharacters(in: .whitespaces))
                        for (i, p) in out.phases.enumerated() {
                            let weeks = min(max(p.weeks, 1), 12)
                            continuation.yield(
                                GhostIdea(
                                    text: p.title, markers: ["priority-\(min(max(p.priority, 1), 3))"],
                                    labels: ["\(weeks) wk"], start: i == 0 ? start : nil, workingDays: weeks * 5))
                        }
                    case .todos:
                        let prompt = "\(context)\n\nTurn “\(anchor)” into checkable to-do steps. \(extra)"
                        let out = try await session.respond(to: prompt, generating: TodoSteps.self).content
                        for s in out.steps { continuation.yield(GhostIdea(text: s, todo: true)) }
                    default:
                        let ask: String =
                            switch r.action {
                            case .findGaps: "What is missing under “\(anchor)”? Suggest the gaps as new child topics."
                            case .threats: "Suggest security threats to “\(anchor)” as short child topics."
                            default: "Suggest new child topics for “\(anchor)”."
                            }
                        let prompt = "\(context)\n\n\(ask) \(extra)"
                        // Stream: each idea becomes a ghost as soon as the next one starts.
                        var emitted = 0
                        var last: [String] = []
                        for try await partial in session.streamResponse(to: prompt, generating: IdeaList.self) {
                            let titles = (partial.content.ideas ?? []).compactMap { $0 }
                            last = titles
                            while emitted < titles.count - 1 {
                                continuation.yield(GhostIdea(text: titles[emitted]))
                                emitted += 1
                            }
                        }
                        while emitted < last.count {
                            continuation.yield(GhostIdea(text: last[emitted]))
                            emitted += 1
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self.prewarm()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func draft(_ r: AIRequest) async throws -> PlanDraft {
        let depth = r.depth == .quick ? "Answer briefly." : r.depth == .deep ? "Think it through carefully." : ""
        let instructions =
            Self.base
            + (r.discussion
                ? " This is Discussion mode: answer the question and never propose edits (leave adds and renames empty)."
                : " When edits would help, propose them as adds and renames using exact topic titles.")
        let session = LanguageModelSession(model: model, instructions: instructions)
        var history = ""
        for m in r.history.suffix(6) { history += "\(m.role == "user" ? "User" : "You"): \(m.text)\n" }
        let task: String =
            switch r.action {
            case .rewrite: "Rewrite the topic titles under “\(r.anchorText)” to be shorter and clearer, as renames."
            case .reorganize: "Reorganize “\(r.anchorText)” so related topics group together; propose adds and renames."
            case .generateMap: "Generate a map about: \(r.prompt). Add topics under “\(r.anchorText)”."
            case .importToMap: "Turn this text into topics under “\(r.anchorText)”:\n\(r.prompt)"
            case .describeToDiagram: "Describe this as a diagram under “\(r.anchorText)”: \(r.prompt)"
            default: r.prompt
            }
        let prompt = "\(Self.context(r))\n\n\(history)\(task)\n\(depth)"
        let out = try await session.respond(to: prompt, generating: DraftReply.self).content
        return PlanDraft(
            answer: out.answer,
            adds: r.discussion ? [] : out.adds.map { PlanDraft.Add(parent: $0.parent, text: $0.text) },
            renames: r.discussion ? [] : out.renames.map { PlanDraft.Rename(from: $0.from, to: $0.to) })
    }

    public func text(_ r: AIRequest) -> AsyncThrowingStream<String, any Error> {
        let session = LanguageModelSession(model: model, instructions: Self.base)
        let ask: String =
            switch r.action {
            case .summarize: "Summarize “\(r.anchorText)” in two or three sentences."
            case .explain: "Explain “\(r.anchorText)” to someone new to it, in a short paragraph."
            case .writeUp: "Write the map up as a short document with headings, in Markdown."
            case .diagramAsCode: "Write this map as a Mermaid mindmap diagram. Reply with the code only."
            default: r.prompt
            }
        let prompt = "\(Self.context(r))\n\n\(ask) \(r.action == .summarize || r.action == .explain ? r.prompt : "")"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// When AI can't run, every request explains why instead of doing anything.
public struct UnavailableEngine: AIEngine {
    public var availability: AIAvailability
    public init(_ availability: AIAvailability) { self.availability = availability }
    public func prewarm() {}
    struct Unavailable: LocalizedError {
        var errorDescription: String?
    }
    public func ideas(_ r: AIRequest) -> AsyncThrowingStream<GhostIdea, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Unavailable(errorDescription: availability.explanation)) }
    }
    public func draft(_ r: AIRequest) async throws -> PlanDraft {
        throw Unavailable(errorDescription: availability.explanation)
    }
    public func text(_ r: AIRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: Unavailable(errorDescription: availability.explanation)) }
    }
}
