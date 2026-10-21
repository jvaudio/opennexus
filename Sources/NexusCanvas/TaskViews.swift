import NexusCore
import SwiftUI

// MARK: Task editor (⌃⌘T, M11)

struct TaskEditorSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.taskEditor {
            TaskEditorSheet(controller: controller, state: s)
        }
    }
}

private struct TaskEditorSheet: View {
    var controller: CanvasController
    let state: TaskEditorState
    @FocusState private var focus: Field?

    enum Field: Hashable { case start, due, duration, owner, dependency }

    func set(_ body: (inout TaskEditorState) -> Void) {
        var s = state
        body(&s)
        s.error = nil
        controller.setTaskEditor(s)
    }

    func text(_ key: WritableKeyPath<TaskEditorState, String>) -> Binding<String> {
        Binding(get: { state[keyPath: key] }, set: { v in set { $0[keyPath: key] = v } })
    }

    var title: String { controller.canvas.nodes[state.node]?.text ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Task").font(.chrome(18, weight: .semibold))
                Text(title).font(.chrome(15)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("Topic › Task…  ⌃⌘T").font(.chrome(12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Start").font(.chrome(14, weight: .medium))
                        Text("Due").font(.chrome(14, weight: .medium))
                        Text("Working days").font(.chrome(14, weight: .medium))
                    }
                    GridRow {
                        TextField("", text: text(\.start)).textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Loc.t("Start")).focused($focus, equals: .start).frame(width: 150)
                        TextField("", text: text(\.due)).textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Loc.t("Due")).focused($focus, equals: .due).frame(width: 150)
                        TextField(
                            "",
                            text: Binding(
                                get: { state.duration },
                                set: { v in
                                    set {
                                        $0.duration = v
                                        $0.durationEdited = true
                                    }
                                })
                        )
                        .textFieldStyle(.roundedBorder).accessibilityLabel(Loc.t("Working days"))
                        .focused($focus, equals: .duration).frame(width: 90)
                    }
                }
                Text(
                    "Type a date, today, tomorrow, +3 (working days), fri or 2 Nov. Only a due date makes a milestone."
                )
                .font(.chrome(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Owner").font(.chrome(14, weight: .medium)).padding(.top, 4)
                TextField("", text: text(\.owner)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Loc.t("Owner")).focused($focus, equals: .owner)
                let names = controller.ownerSuggestions.filter {
                    $0 != state.owner && (state.owner.isEmpty || $0.lowercased().hasPrefix(state.owner.lowercased()))
                }
                if !names.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(names.prefix(6), id: \.self) { n in
                            Button(n) { set { $0.owner = n } }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                HStack(spacing: 14) {
                    Text("Progress").font(.chrome(14, weight: .medium))
                    Slider(
                        value: Binding(
                            get: { Double(state.progress) },
                            set: { v in
                                set {
                                    $0.progress = Int(v.rounded())
                                    if $0.progress < 100 { $0.done = false }
                                }
                            }),
                        in: 0...100, step: 5
                    )
                    .frame(width: 220)
                    .accessibilityLabel(Loc.t("Progress"))
                    Text(Loc.f("%lld%%", state.progress)).font(.chrome(13, design: .monospaced)).frame(width: 44)
                    Toggle(
                        "Done",
                        isOn: Binding(
                            get: { state.done },
                            set: { v in
                                set {
                                    $0.done = v
                                    if v { $0.progress = 100 }
                                }
                            })
                    )
                    .toggleStyle(.checkbox)
                    Picker(
                        "Priority",
                        selection: Binding(get: { state.priority }, set: { v in set { $0.priority = v } })
                    ) {
                        Text("None").tag(0)
                        ForEach(1...9, id: \.self) { n in Text(verbatim: "\(n)").tag(n) }
                    }
                    .frame(width: 150)
                }
                Text("Depends on").font(.chrome(14, weight: .medium)).padding(.top, 4)
                dependencies
                if let e = state.error {
                    Text(e).font(.chrome(13)).foregroundStyle(.red)
                }
            }
            .padding(20)
            Divider()
            HStack {
                if controller.canvas.nodes[state.node]?.todo != nil {
                    Button("Clear Dates") {
                        set {
                            $0.start = ""
                            $0.due = ""
                            $0.duration = ""
                            $0.durationEdited = false
                        }
                    }
                    .buttonStyle(FileButtonStyle())
                }
                Spacer()
                Button("Cancel") { controller.closeTaskEditor() }.buttonStyle(FileButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { controller.applyTaskEditor() }.buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear { focus = .start }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Loc.t("Task"))
    }

    @ViewBuilder var dependencies: some View {
        let c = controller.canvas
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(state.after.enumerated()), id: \.offset) { i, d in
                HStack(spacing: 10) {
                    Text(c.nodes[d.task]?.text ?? "?").font(.chrome(13.5)).lineLimit(1)
                        .frame(width: 210, alignment: .leading)
                    Picker(
                        "Kind",
                        selection: Binding(
                            get: { d.type },
                            set: { v in set { $0.after[i].type = v } })
                    ) {
                        Text("Finish to start").tag(DependencyType.finishToStart)
                        Text("Start to start").tag(DependencyType.startToStart)
                        Text("Finish to finish").tag(DependencyType.finishToFinish)
                        Text("Start to finish").tag(DependencyType.startToFinish)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel(Loc.t("Kind"))
                    Stepper(
                        Loc.n("Lag %lld day", "Lag %lld days", d.lag),
                        value: Binding(get: { d.lag }, set: { v in set { $0.after[i].lag = v } }), in: -365...365
                    )
                    .font(.chrome(13))
                    Spacer()
                    Button {
                        set { $0.after.remove(at: i) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.f("Remove dependency on %@", c.nodes[d.task]?.text ?? ""))
                }
            }
            TextField("", text: text(\.query), prompt: Text("Add a task it waits for…"))
                .textFieldStyle(.roundedBorder).accessibilityLabel(Loc.t("Add a dependency"))
                .focused($focus, equals: .dependency)
            let found = controller.dependencyCandidates(state.query)
            if !found.isEmpty && (focus == .dependency || !state.query.isEmpty) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(found, id: \.self) { id in
                        Button {
                            set {
                                $0.after.append(TaskDependency(task: id))
                                $0.query = ""
                            }
                        } label: {
                            Text(c.nodes[id]?.text ?? "").font(.chrome(13.5)).frame(
                                maxWidth: .infinity, alignment: .leading
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            }
        }
    }
}
