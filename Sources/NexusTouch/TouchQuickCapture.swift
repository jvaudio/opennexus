#if os(iOS)
import NexusCanvas
import NexusScene
import SwiftUI

/// Quick Capture on the iPhone and iPad (M47c): the Mac's panel as a sheet, opened by the
/// Inbox widget's capture button and the Lock Screen widget (`opennexus://inbox/add`). One
/// field and the map it goes to; Save files the idea and clears the field for the next,
/// as ↩ does on the Mac.
public struct TouchQuickCaptureView: View {
    @Bindable var model: QuickCaptureModel
    @FocusState private var focused: Bool

    public init(model: QuickCaptureModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Loc.t("Jot an idea"), text: $model.text, axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focused)
                        .accessibilityIdentifier("capture-text")
                } footer: {
                    if let saved = model.saved {
                        Text(verbatim: saved).accessibilityIdentifier("capture-saved")
                    }
                }
                Picker(Loc.t("Save to"), selection: $model.targets.index) {
                    ForEach(Array(model.targets.targets.enumerated()), id: \.offset) { i, t in
                        Text(verbatim: t.url == nil ? Loc.t("Inbox map") : t.title).tag(i)
                    }
                }
            }
            .navigationTitle(Loc.t("Quick Capture"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.t("Done")) { model.onClose() }
                        .accessibilityIdentifier("capture-done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.t("Save")) { model.save() }
                        .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("capture-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
        .onChange(of: model.text) { if !model.text.isEmpty { model.saved = nil } }
    }
}
#endif
