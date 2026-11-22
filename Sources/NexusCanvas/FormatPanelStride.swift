import NexusCore
import NexusScene
import NexusTheme
import SwiftUI

/// The STRIDE tab for threat-model canvases (artboard 21, inspector).
struct StrideTab: View {
    var controller: CanvasController

    var body: some View {
        let c = controller.canvas
        let id = controller.selection.primary
        let type = DiagramCatalog.effectiveType(id, in: c)
        let number = DFDRules.numbers(c)[id]
        let threats = Stride.threats(c).filter { $0.element == id }
        let suggestions = Stride.suggestions(for: id, in: c)
        let applicable = Stride.applicable(to: type)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    ([type.flatMap { DiagramCatalog.info($0, in: c.type)?.caption }, number].compactMap { $0 })
                        .joined(separator: " · ")
                )
                .font(.chrome(11, weight: .semibold)).foregroundStyle(.chromeSecondary)
                Text(c.nodes[id]?.text ?? "").font(.chrome(18, weight: .semibold))
            }
            if applicable.isEmpty {
                Text("Select a process, data store or external entity to see its STRIDE checklist.")
                    .font(.chrome(12)).foregroundStyle(.chromeSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Stride.allCases, id: \.self) { s in
                        row(
                            s, threat: threats.first { $0.category == s }, suggestion: suggestions.first { $0.0 == s },
                            applies: applicable.contains(s), element: id)
                        if s != .elevation { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                if !suggestions.isEmpty {
                    Button(
                        Loc.n("✦ Accept %lld suggestion · ⌃⇧↩", "✦ Accept %lld suggestions · ⌃⇧↩", suggestions.count)
                    ) {
                        for (s, t, r) in suggestions { controller.acceptStride(s, t, r, on: id) }
                    }
                }
            }
            Divider()
            ForEach(
                [("Owner", Loc.t("Owner")), ("Data class.", Loc.t("Data class.")), ("Protocol", Loc.t("Protocol"))],
                id: \.0
            ) { key, title in
                HStack {
                    Text(title).font(.chrome(12.5)).foregroundStyle(.chromeSecondary).frame(
                        width: 82, alignment: .leading)
                    TextField(
                        "—",
                        text: Binding(
                            get: { c.nodes[id].flatMap { Stride.field($0, key) } ?? "" },
                            set: { v in controller.setThreatField(id, key, v) })
                    )
                    .textFieldStyle(.plain)
                    .font(.chrome(12.5, design: key == "Protocol" ? .monospaced : .default))
                }
            }
            Toggle(
                "Colour by risk",
                isOn: Binding(get: { c.diagram.colorByRisk }, set: { _ in controller.toggleColorByRisk() })
            )
            .toggleStyle(.switch)
            .font(.chrome(12.5))
            HStack {
                Button("Threat table") { controller.threatTableVisible.toggle() }
                Button("✦ Suggest for all") { controller.suggestStrideEverywhere() }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    func row(_ s: Stride, threat: Stride.Threat?, suggestion: (Stride, String, String)?, applies: Bool, element: NodeID)
        -> some View
    {
        HStack(spacing: 10) {
            Text(s.rawValue)
                .font(.chrome(12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(applies ? 0.85 : 0.25)))
            VStack(alignment: .leading, spacing: 1) {
                Text(Loc.t(s.name)).font(.chrome(13, weight: .medium))
                if let threat {
                    Text(threat.title).font(.chrome(11.5)).foregroundStyle(.chromeSecondary).lineLimit(1)
                } else if let suggestion {
                    Text(Loc.f("✦ Suggested · %@", suggestion.1)).font(.chrome(11.5)).foregroundStyle(
                        Color(cgColor: controller.theme.ai.cgColor)
                    ).lineLimit(1)
                } else {
                    Text(applies ? Loc.t("No threat recorded") : Loc.t("Not applicable")).font(.chrome(11.5))
                        .foregroundStyle(
                            .tertiary)
                }
            }
            Spacer()
            if let threat {
                // The pill is the menu's label, so the risk reads in its colour and still changes in place.
                Menu {
                    ForEach(Stride.risks, id: \.self) { r in
                        Button(Loc.t(r)) { controller.setThreatField(threat.node, Stride.riskKey, r) }
                    }
                } label: {
                    RiskPill(risk: threat.risk, dark: controller.theme.isDark)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Loc.t("Risk"))
                .accessibilityValue(Loc.t(threat.risk))
            } else if let suggestion {
                Button("+") { controller.acceptStride(s, suggestion.1, suggestion.2, on: element) }
                    .help("Add this threat")
            } else if applies {
                // Applicable but unrecorded: a dash, so "N/A" keeps meaning "doesn't apply".
                Text(verbatim: "—").font(.chrome(11, design: .monospaced)).foregroundStyle(.chromeTertiary)
                    .accessibilityLabel(Loc.t("No threat recorded"))
            } else {
                RiskPill(risk: "N/A", dark: controller.theme.isDark)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(threat?.risk == "High" ? Color.red.opacity(0.05) : .clear)
    }
}

/// A threat's risk as a solid pill (artboard 21): red High, amber Med, green-tint Low and
/// grey N/A, each with its word in mono, so colour is never the only signal.
struct RiskPill: View {
    let risk: String
    var dark = false

    /// Fill and ink per risk. High and Med are solid in both appearances; Low and N/A are
    /// tints, inverted in dark so they stay quiet against a dark surface.
    var colors: (fill: String, ink: String) {
        switch risk {
        case "High": ("#C62F35", "#FFFFFF")
        case "Med": ("#E08A00", "#17171C")
        case "Low": dark ? ("#1E6B41", "#E6F5EC") : ("#E6F5EC", "#1E6B41")
        default: dark ? ("#2B2C33", "#B4B4BE") : ("#F1F1F4", "#4A4A55")
        }
    }

    var body: some View {
        Text(Loc.t(risk))
            .font(.chrome(11, weight: .bold, design: .monospaced))
            .foregroundStyle(RGBA(hex: colors.ink).color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(RGBA(hex: colors.fill).color))
    }
}
