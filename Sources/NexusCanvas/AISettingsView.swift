import AppKit
import NexusCore
import SwiftUI

struct AISettingsPane: View {
    var availability: AIAvailability

    /// The three model rows (the rest of the AI pane comes from the schema).
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelRow(
                selected: true, title: "Apple on-device model", badge: "Default",
                detail: "Foundation Models framework. Text and images, tool calling for diagram actions. No download.",
                status: availability)
            modelRow(
                selected: false, title: "Local model via MLX / Core AI", badge: nil,
                detail:
                    "Bring an open-weights model. Stored in ~/Library/Application Support/OpenNexus/Models. Arrives in a later release.",
                status: nil
            ) {
                HStack(spacing: 10) {
                    Button("Choose model folder…") {}.disabled(true)
                    Text("[MODEL NAME] · [SIZE]").foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            }
            .opacity(0.55)
            modelRow(
                selected: false, title: "Local server on this Mac", badge: nil,
                detail:
                    "An OpenAI-compatible endpoint on localhost, such as Ollama or LM Studio. Needs a network permission OpenNexus doesn’t request in v1.",
                status: nil
            ) {
                HStack(spacing: 10) {
                    Text("http://localhost:11434").font(.chrome(13, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Text("Test connection").foregroundStyle(.secondary)
                }
            }
            .opacity(0.55)
        }
    }

    func modelRow(
        selected: Bool, title: String, badge: String?, detail: String, status: AIAvailability?,
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.chrome(18))
                .foregroundStyle(selected ? Color.teal : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.chrome(16, weight: .semibold))
                    if let badge {
                        Text(badge).font(.chrome(12, weight: .medium)).foregroundStyle(.teal)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.12)))
                    }
                }
                Text(detail).font(.chrome(13.5)).foregroundStyle(.secondary)
                extra().font(.chrome(13)).padding(.top, 6)
            }
            Spacer()
            if let status {
                HStack(spacing: 6) {
                    Circle().fill(status.canRun ? Color.green : .orange).frame(width: 7, height: 7)
                    Text(
                        status.canRun
                            ? "ready"
                            : status == .off
                                ? "Apple Intelligence off" : status == .downloading ? "downloading" : "unavailable"
                    )
                    .font(.chrome(13, design: .monospaced))
                    .foregroundStyle(status.canRun ? Color.green : .orange)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
                selected ? Color.teal : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
    }

    func row(_ title: String, divider: Bool = true, @ViewBuilder _ trailing: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.chrome(14))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            if divider { Divider().padding(.leading, 18) }
        }
    }
}
