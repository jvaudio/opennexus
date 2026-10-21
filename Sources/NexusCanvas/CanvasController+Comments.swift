import AppKit
import NexusCore

/// Topic comments (M14): a review thread beside a topic. Each change is one undo step.
@MainActor
extension CanvasController {
    /// The name on new comments: Settings › Editing › Comment author, else this Mac's
    /// account name (D163).
    public var commentAuthor: String {
        let s = prefs.string("editing.commentAuthor").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    /// Adds a comment by `commentAuthor` at `now` (tests inject a time).
    public func addComment(_ text: String, on id: NodeID, now: Date = Date()) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, canvas.nodes[id] != nil else { return }
        let c = TopicComment(author: commentAuthor, at: now, text: t)
        perform(Loc.t("Add Comment")) { e in e.update(id) { $0.comments.append(c) } }
    }

    /// Replaces a comment's text; an empty text deletes it.
    public func editComment(_ index: Int, text: String, on id: NodeID) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = canvas.nodes[id], n.comments.indices.contains(index) else { return }
        if t.isEmpty { return deleteComment(index, on: id) }
        guard t != n.comments[index].text else { return }
        perform(Loc.t("Edit Comment")) { e in e.update(id) { $0.comments[index].text = t } }
    }

    public func deleteComment(_ index: Int, on id: NodeID) {
        guard canvas.nodes[id]?.comments.indices.contains(index) == true else { return }
        perform(Loc.t("Delete Comment")) { e in e.update(id) { $0.comments.remove(at: index) } }
    }

    /// "Ana · 20 Oct 2026, 14:03", in the reader's time zone.
    public static func commentByline(_ c: TopicComment) -> String {
        let when = c.instant.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return [c.author, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
