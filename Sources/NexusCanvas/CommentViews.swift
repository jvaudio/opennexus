import AppKit
import NexusCore
import SwiftUI

/// A topic's comment thread (M14): oldest first, each with Edit and Delete, and a field
/// to add one. ⌘↩ adds; Esc closes.
struct CommentsPopover: View {
    var controller: CanvasController
    let node: NodeID
    var close: () -> Void
    @State private var draft = ""
    @State private var editing: Int?
    @State private var editText = ""
    @FocusState private var focus: Field?

    enum Field: Hashable { case draft, edit }

    var comments: [TopicComment] { controller.canvas.nodes[node]?.comments ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Comments").font(.headline)
                Text(controller.canvas.nodes[node]?.text ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if comments.isEmpty {
                        Text("No comments yet.").foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Array(comments.enumerated()), id: \.offset) { i, c in
                        row(i, c)
                        Divider()
                    }
                }
            }
            .accessibilityLabel(Loc.t("Comment thread"))
            TextField(Loc.f("Comment as %@", controller.commentAuthor), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .focused($focus, equals: .draft)
                .accessibilityLabel(Loc.t("New comment"))
            HStack {
                Text("⌘↩ adds the comment").font(.chrome(11)).foregroundStyle(.secondary)
                Spacer()
                Button("Add Comment", action: add)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .onAppear { focus = .draft }
    }

    @ViewBuilder
    func row(_ i: Int, _ c: TopicComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CanvasController.commentByline(c)).font(.chrome(11.5, weight: .semibold)).foregroundStyle(.secondary)
            if editing == i {
                TextField("", text: $editText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($focus, equals: .edit)
                    .onSubmit(save)
                    .accessibilityLabel(Loc.t("Comment text"))
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            } else {
                Text(c.text).font(.chrome(13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Spacer()
                    Button("Edit") {
                        editing = i
                        editText = c.text
                        focus = .edit
                    }
                    .accessibilityLabel(Loc.f("Edit comment by %@", c.author))
                    Button("Delete", role: .destructive) { controller.deleteComment(i, on: node) }
                        .accessibilityLabel(Loc.f("Delete comment by %@", c.author))
                }
                .buttonStyle(.link)
                .font(.chrome(11.5))
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.spoken(c))
    }

    /// "Comment by Ana, 20 Oct 2026 at 14:03: Drop the annual tier?"
    static func spoken(_ c: TopicComment) -> String {
        Loc.f("Comment by %@: %@", CanvasController.commentByline(c), c.text)
    }

    func add() {
        controller.addComment(draft, on: node)
        draft = ""
        focus = .draft
    }

    func save() {
        if let i = editing { controller.editComment(i, text: editText, on: node) }
        editing = nil
        focus = .draft
    }
}
