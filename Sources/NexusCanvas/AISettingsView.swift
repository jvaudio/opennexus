import NexusCore
import NexusScene
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AISettingsPane: View {
    var availability: AIAvailability
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The iPhone's: the model's status goes under its description, not beside it.
    var compact: Bool { sizeClass == .compact }
    #else
    let compact = false
    #endif

    /// The three model rows (the rest of the AI pane comes from the schema).
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelRow(
                selected: true, title: Loc.t("Apple on-device model"), badge: Loc.t("Default"),
                detail: Loc.t(
                    "Foundation Models framework. Text and images, tool calling for diagram actions. No download."),
                status: availability)
            #if os(macOS)
            // Placeholders for later releases, both about the Mac's own files and ports.
            modelRow(
                selected: false, title: Loc.t("Local model via MLX / Core AI"), badge: nil,
                detail:
                    "Bring an open-weights model. Stored in ~/Library/Application Support/OpenNexus/Models. Arrives in a later release.",
                status: nil
            ) {
                HStack(spacing: 10) {
                    Button("Choose model folder…") {}.disabled(true)
                    Text("[MODEL NAME] · [SIZE]").foregroundStyle(.chromeSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            }
            .opacity(0.55)
            modelRow(
                selected: false, title: Loc.t("Local server on this Mac"), badge: nil,
                detail:
                    Loc.t(
                        "An OpenAI-compatible endpoint on localhost, such as Ollama or LM Studio. Needs a network permission OpenNexus doesn’t request in v1."
                    ),
                status: nil
            ) {
                HStack(spacing: 10) {
                    Text(verbatim: "http://localhost:11434").font(.chrome(13, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Text("Test connection").foregroundStyle(.chromeSecondary)
                }
            }
            .opacity(0.55)
            #endif
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
                #if os(macOS)
                HStack(spacing: 8) { name(title, badge: badge) }
                #else
                // The badge goes under a name that needs the row (a phone at a large text size).
                FlowLayout(spacing: 8) { name(title, badge: badge) }
                #endif
                Text(detail).font(.chrome(13.5)).foregroundStyle(.chromeSecondary)
                extra().font(.chrome(13)).padding(.top, 6)
                if compact, let status { chip(status).padding(.top, 4) }
            }
            Spacer()
            if !compact, let status { chip(status) }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.controlBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
                selected ? Color.teal : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
    }

    @ViewBuilder func name(_ title: String, badge: String?) -> some View {
        Text(title).font(.chrome(16, weight: .semibold))
        if let badge {
            Text(badge).font(.chrome(12, weight: .medium)).foregroundStyle(Color.statusTeal)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.12)))
        }
    }

    func chip(_ status: AIAvailability) -> some View {
        HStack(spacing: 6) {
            Circle().fill(status.canRun ? Color.green : .orange).frame(width: 7, height: 7)
            Text(
                status.canRun
                    ? "ready"
                    : status == .off
                        ? Loc.t("Apple Intelligence off")
                        : status == .downloading ? Loc.t("downloading") : Loc.t("unavailable")
            )
            .font(.chrome(13, design: .monospaced))
            .foregroundStyle(status.canRun ? Color.statusGreen : .orange)
        }
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
