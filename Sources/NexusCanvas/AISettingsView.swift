import AppKit
import NexusCore
import SwiftUI

/// Settings with the AI pane (artboard 29). The other nine panes arrive in M8; the
/// sidebar already lists them so the window has its final shape.
public struct SettingsView: View {
    var availability: AIAvailability
    @State private var pane = "ai"
    public init(availability: AIAvailability) { self.availability = availability }

    static let panes: [(String, String, String, Color)] = [
        ("general", "G", "General", .gray), ("editing", "E", "Editing", .blue),
        ("appearance", "A", "Appearance", .pink),
        ("files", "F", "Files & Backup", .orange), ("ai", "✦", "AI", .teal), ("shortcuts", "⌘", "Shortcuts", .indigo),
        ("export", "↗", "Export", .orange), ("integrations", "⇄", "Integrations", .purple),
        ("privacy", "◐", "Privacy & Data", .black), ("accessibility", "◎", "Accessibility", .blue),
    ]

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.panes, id: \.0) { id, glyph, title, color in
                    Button {
                        pane = id
                    } label: {
                        HStack(spacing: 10) {
                            Text(glyph)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6).fill(color))
                            Text(title).font(.system(size: 14))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(pane == id ? Color.white : .primary)
                        .background(RoundedRectangle(cornerRadius: 8).fill(pane == id ? Color.teal : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(14)
            .frame(width: 230)
            .background(.regularMaterial)
            Divider()
            ScrollView {
                if pane == "ai" {
                    AISettingsPane(availability: availability).padding(28)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.panes.first { $0.0 == pane }?.2 ?? "").font(.system(size: 26, weight: .bold))
                        Text("This pane arrives with Settings in a later milestone.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

struct AISettingsPane: View {
    var availability: AIAvailability
    @AppStorage(AISettingsKeys.suggestAfterPause) private var suggestAfterPause = false
    @AppStorage(AISettingsKeys.depth) private var depth = "balanced"
    @AppStorage(AISettingsKeys.discussionDefault) private var discussion = false
    @AppStorage(AISettingsKeys.markAI) private var markAI = true
    @AppStorage(AISettingsKeys.statusChip) private var statusChip = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI").font(.system(size: 26, weight: .bold))
            Text("Every model runs on this Mac. OpenNexus v1 offers no cloud models, including Private Cloud Compute.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("MODEL").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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
                    Text("http://localhost:11434").font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Text("Test connection").foregroundStyle(.secondary)
                }
            }
            .opacity(0.55)
            VStack(spacing: 0) {
                row("Suggest ideas after a pause when creating nodes") {
                    Toggle("", isOn: $suggestAfterPause).toggleStyle(.switch)
                }
                row("AI panel depth") {
                    Picker("", selection: $depth) {
                        Text("Quick").tag("quick")
                        Text("Balanced").tag("balanced")
                        Text("Deep").tag("deep")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
                row("Start AI chats in Discussion mode (never edits the map)") {
                    Toggle("", isOn: $discussion).toggleStyle(.switch)
                }
                row("Image Playground for stickers · Translation for maps") {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("on-device").foregroundStyle(.green)
                    }
                }
                row("Mark AI-created nodes with ✦ until edited") { Toggle("", isOn: $markAI).toggleStyle(.switch) }
                row("Show model status chip in the toolbar") { Toggle("", isOn: $statusChip).toggleStyle(.switch) }
                row("Ghost suggestions", divider: false) {
                    HStack(spacing: 6) {
                        Keycap(text: "⌥Space")
                        Text("✦ Space").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black))
                    }
                }
            }
            .labelsHidden()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    func modelRow(
        selected: Bool, title: String, badge: String?, detail: String, status: AIAvailability?,
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(selected ? Color.teal : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    if let badge {
                        Text(badge).font(.system(size: 12, weight: .medium)).foregroundStyle(.teal)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.12)))
                    }
                }
                Text(detail).font(.system(size: 13.5)).foregroundStyle(.secondary)
                extra().font(.system(size: 13)).padding(.top, 6)
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
                    .font(.system(size: 13, design: .monospaced))
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
                Text(title).font(.system(size: 14))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            if divider { Divider().padding(.leading, 18) }
        }
    }
}
