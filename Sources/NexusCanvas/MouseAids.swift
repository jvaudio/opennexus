import AppKit
import NexusKeys
import SwiftUI

/// Settings › Editing › Mouse & trackpad (artboard 36): the floating toolbar above the
/// selected topic and the Add Topic + buttons. Neither appears while typing or with a
/// multiple selection; every button also counts towards a key tip.
struct FloatingToolbarView: View {
    var controller: CanvasController

    var body: some View {
        HStack(spacing: 2) {
            button(Loc.t("✦ Ideas"), Loc.t("Suggest ideas (⌥Space)"), .aiGhosts, accent: true) {
                controller.requestGhosts()
            }
            button("⇢", Loc.t("Connect"), .connect) { _ = controller.perform(.connect) }
            button("↗", Loc.t("Link"), nil) { controller.onRequest?(.link(controller.selection.primary)) }
            button("▣", Loc.t("Image"), nil) { controller.onRequest?(.image(controller.selection.primary)) }
            button("≡", Loc.t("Note"), .note) { controller.onRequest?(.note(controller.selection.primary)) }
            button("☐", "To-do", .toggleTodo) { _ = controller.perform(.toggleTodo) }
            button(Loc.t("Aa"), Loc.t("Style (⌘I)"), .inspector) { controller.onExternalCommand?(.inspector) }
        }
        .padding(.horizontal, 6).frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)).shadow(
                color: .black.opacity(0.14), radius: 8, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.6)))
    }

    func button(_ label: String, _ help: String, _ id: CommandID?, accent: Bool = false, _ action: @escaping () -> Void)
        -> some View
    {
        Button {
            if let id { controller.noteMouseUse(id) }
            action()
        } label: {
            Text(label).font(.chrome(13, weight: accent ? .semibold : .regular)).foregroundStyle(
                accent ? Color.teal : .primary
            )
            .padding(.horizontal, 7).frame(minWidth: 26, minHeight: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A round + that adds a child (right) or a sibling (below).
struct AddTopicButton: View {
    var controller: CanvasController
    var child: Bool

    var body: some View {
        Button {
            controller.noteMouseUse(child ? .addChild : .addSiblingAfter)
            _ = controller.perform(child ? .addChild : .addSiblingAfter)
        } label: {
            Text("+").font(.chrome(14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Color(hex: "#5850EC")))
        }
        .buttonStyle(.plain)
        .help(child ? Loc.t("Add a child (⇥)") : Loc.t("Add a sibling (↩)"))
        .accessibilityLabel(child ? Loc.t("Add child topic") : Loc.t("Add sibling topic"))
    }
}
