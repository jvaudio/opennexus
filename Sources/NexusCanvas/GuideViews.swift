import AppKit
import NexusCore
import NexusTheme
import SwiftUI

/// The trailing slot: the guide or the AI panel, never both, so the canvas never squeezes
/// between three panels (M41).
struct TrailingPanelView: View {
    var controller: CanvasController

    var body: some View {
        if controller.guideVisible, !controller.zen, controller.present == nil {
            GuidePanelView(controller: controller)
        } else {
            AIPanelView(controller: controller)
        }
    }
}

/// Guide mode (⌃⌘G): where the canvas stands in its type's guide, one tip, and Skip. It
/// suggests only: nothing here edits the map, apart from Skip.
struct GuidePanelView: View {
    var controller: CanvasController
    /// A step clicked that has nothing to select yet: its tip shows instead of the current one.
    @State private var focused: Int?
    @State private var pulse = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme

    static let accent = Color(hex: "#5850EC")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let g = controller.guide, let p = controller.guideProgress {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !g.example.isEmpty { example(g) }
                        steps(g, p)
                        if p.complete { completion } else { tipCard(g, p) }
                    }
                    .padding(16)
                }
            } else {
                comingSoon
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guide")
        .onChange(of: controller.guideProgress?.current) { _, _ in
            focused = nil
            pulse = true
            withAnimation(UIMotion.animation(.easeOut(duration: Motion.focus))) { pulse = false }
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Guide").font(.chrome(15, weight: .semibold))
                Text(HomeView.typeName(controller.canvas.type)).font(.chrome(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = controller.guideProgress {
                Text(Loc.f("%lld of %lld", p.done, p.total)).font(.chrome(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Loc.f("%lld of %lld steps done", p.done, p.total))
            }
            Button {
                controller.guideVisible = false
            } label: {
                Image(systemName: "xmark").font(.chrome(11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Hide Guide (⌃⌘G)")
            .accessibilityLabel("Hide Guide")
        }
        .padding(16)
    }

    /// For tree types: the shape to aim for, drawn by the real layout engine.
    func example(_ g: Guide) -> some View {
        let s = Starter(
            id: "guide.\(g.id)", name: g.id, summary: "", kicker: "", category: DiagramDescriptor[g.type].category,
            shelf: nil, aliases: [], type: g.type, title: "", outline: g.example, relationships: [], order: 0)
        return Group {
            if let img = StarterThumbnails.image(s, prefs: controller.prefs, dark: scheme == .dark, scale: displayScale)
            {
                Image(decorative: img, scale: displayScale).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Example")
            }
        }
    }

    func steps(_ g: Guide, _ p: GuideProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(p.steps.enumerated()), id: \.offset) { i, s in
                let step = g.steps[i]
                Button {
                    if !controller.selectGuideStep(i) { focused = i }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        mark(s).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Loc.t(step.title)).font(
                                .chrome(13, weight: s.state == .current ? .semibold : .regular)
                            )
                            .strikethrough(s.state == .skipped)
                            .foregroundStyle(s.state == .skipped ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            if let detail = detail(step, s) {
                                Text(detail).font(.chrome(11.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if let t = step.match.glyph,
                            let info = DiagramCatalog.nodeTypes(for: g.type).first(where: { $0.id == t })
                        {
                            Text(Loc.t(info.name).uppercased()).font(
                                .chrome(9.5, weight: .semibold, design: .monospaced)
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(
                            s.state == .current || focused == i ? Self.accent.opacity(0.1) : .clear)
                    )
                    .scaleEffect(s.state == .current && pulse ? 1.03 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc.t(step.title))
                .accessibilityValue(stateName(s))
            }
        }
    }

    func mark(_ s: GuideProgress.Step) -> some View {
        ZStack {
            switch s.state {
            case .skipped:
                Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            case _ where s.met:
                Circle().fill(Color(hex: "#2E9E6A"))
                Image(systemName: "checkmark").font(.chrome(9, weight: .bold)).foregroundStyle(.white)
            case .current:
                Circle().strokeBorder(Self.accent, lineWidth: 2)
                Circle().fill(Self.accent).padding(5)
            default:
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }

    func detail(_ step: Guide.Step, _ s: GuideProgress.Step) -> String? {
        if step.optional && !s.met { return Loc.t("Optional") }
        if step.match.rules != nil { return s.count > 0 ? Loc.n("%lld issue", "%lld issues", s.count) : nil }
        if step.match.each { return s.needed > 0 ? Loc.f("%lld of %lld", s.count, s.needed) : nil }
        if step.min > 1 { return Loc.f("%lld of %lld", min(s.count, step.min), step.min) }
        return nil
    }

    func stateName(_ s: GuideProgress.Step) -> String {
        switch s.state {
        case .skipped: Loc.t("Skipped")
        case _ where s.met: Loc.t("Done")
        case .current: Loc.t("Current step")
        default: Loc.t("To do")
        }
    }

    /// The current step's tip (or the clicked one's), keys in the active profile, and Skip.
    func tipCard(_ g: Guide, _ p: GuideProgress) -> some View {
        let i = focused ?? p.current ?? 0
        let step = g.steps[i]
        let skipped = p.steps[i].state == .skipped
        return VStack(alignment: .leading, spacing: 10) {
            Text(Loc.t(step.title)).font(.chrome(13.5, weight: .semibold))
            if !step.tip.isEmpty { tipText(step.tip).font(.chrome(13)).fixedSize(horizontal: false, vertical: true) }
            strideSuggestions(g, step)
            HStack {
                Spacer()
                Button(skipped ? "Restore Step" : "Skip Step") { controller.toggleGuideSkip(step.id) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Self.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.accent.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tip")
    }

    func tipText(_ tip: String) -> Text {
        controller.guideTipParts(tip).reduce(Text("")) { t, part in
            switch part {
            case .text(let s): t + Text(s)
            case .key(let k):
                t
                    + Text(k).font(.chrome(12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.accent)
            }
        }
    }

    /// A threat model's threats step: STRIDE ideas for the selected element.
    @ViewBuilder
    func strideSuggestions(_ g: Guide, _ step: Guide.Step) -> some View {
        let sel = controller.selection.primary
        if g.type == .threatModel, step.match.nodeTypes.contains(.threat), sel != controller.canvas.root {
            let ideas = Stride.suggestions(for: sel, in: controller.canvas).prefix(3)
            if !ideas.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(ideas.enumerated()), id: \.offset) { _, idea in
                        Text("\(idea.0.rawValue) · \(idea.1)").font(.chrome(12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var completion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every step is done").font(.chrome(13.5, weight: .semibold))
            Text("Present it, or hide the guide and keep going.").font(.chrome(13)).foregroundStyle(.secondary)
            HStack {
                Button("Present") {
                    controller.guideVisible = false
                    controller.perform(.present)
                }
                .controlSize(.small)
                Button("Hide Guide") { controller.guideVisible = false }.controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#2E9E6A").opacity(0.08)))
    }

    var comingSoon: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.f("A guide for %@ is coming soon.", HomeView.typeName(controller.canvas.type)))
                .font(.chrome(13.5, weight: .semibold))
            Text("Guides cover mind maps, flowcharts, data flows, architecture and threat models so far.")
                .font(.chrome(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}
