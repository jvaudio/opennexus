import AppKit
import NexusCore
import NexusTheme
import SwiftUI

/// Present mode chrome (artboard 32): kicker and title over the stage, progress dots, and
/// the slide strip with its controls.
struct PresentOverlayView: View {
    var controller: CanvasController

    var body: some View {
        if let p = controller.present {
            let slides = controller.slides
            let slide = p.index < slides.count ? slides[p.index] : nil
            let ink = Color(nsColor: NSColor(cgColor: controller.scene.theme.ink.cgColor) ?? .labelColor)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(slide?.kicker ?? "").font(.chrome(13, weight: .medium, design: .monospaced))
                        .kerning(1.6).foregroundStyle(ink.opacity(0.6))
                    Text(slide.map(controller.slideTitle) ?? "").font(.chrome(40, weight: .bold)).foregroundStyle(ink)
                        .lineLimit(2)
                    // The slide's own task line, as on its topic (M21, D201).
                    if let line = slide.flatMap(controller.slideTaskLine) {
                        Text(line).font(.chrome(16, design: .monospaced)).foregroundStyle(ink.opacity(0.72))
                    }
                    if let slide, let chart = controller.timelineChart(for: slide) {
                        TimelineCard(chart: chart, spoken: controller.timelineSpoken(slide))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 24)
                            .padding(.trailing, 56)
                            .padding(.bottom, p.stageOnly ? 64 : 304)
                    }
                }
                .padding(.leading, 56)
                .padding(.top, 36)
                .allowsHitTesting(false)
                // The slide's legend in its corner (M21, D200) and the progress dots share
                // a line just above the strip, where the framing expects them (M28, D232).
                let placement = PresentLegendPlacement.screen(stageOnly: p.stageOnly)
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        if let l = controller.presentLegend(for: slide) {
                            PresentLegendCorner(
                                legend: l, theme: controller.scene.theme, canvas: controller.scene.canvasColor,
                                placement: placement
                            )
                            .padding(.leading, placement.leading)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(Array(slides.enumerated()), id: \.offset) { i, s in
                                Capsule()
                                    .fill(i == p.index ? Color.accentColor : ink.opacity(s.skipped ? 0.15 : 0.35))
                                    .frame(width: i == p.index ? 22 : 7, height: 7)
                            }
                        }
                        .padding(.trailing, 56)
                    }
                    .padding(.bottom, placement.bottom)
                }
                .allowsHitTesting(false)
                VStack {
                    Spacer()
                    if !p.stageOnly { SlideStripView(controller: controller, state: p, slides: slides) }
                }
                if p.showKeys { PresentKeysView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }
}

struct SlideStripView: View {
    var controller: CanvasController
    let state: PresentState
    let slides: [Slide]
    /// The strip's height; the corner legend and the dots sit above it (D232).
    static let height: CGFloat = 236

    var body: some View {
        let settings = controller.canvas.presentation
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("SLIDES · AUTO-GENERATED · DRAG TO REORDER")
                    .font(.chrome(11.5, weight: .semibold, design: .monospaced)).kerning(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Transition").font(.chrome(12.5)).foregroundStyle(.secondary)
                ForEach([("glide", Loc.t("Glide")), ("zoom", Loc.t("Zoom")), ("cut", Loc.t("Cut"))], id: \.0) {
                    id, title in
                    chip(title, on: settings.transition == id) {
                        controller.setPresentation(Loc.t("Transition")) { $0.transition = id }
                    }
                }
                if DiagramCatalog.isTechnical(controller.canvas.type) {
                    chip(Loc.t("Step through flow") + (settings.stepThroughFlow ? " ✓" : ""), on: false) {
                        controller.setPresentation(Loc.t("Step Through Flow")) { $0.stepThroughFlow.toggle() }
                    }
                }
                // M21: the legend in each slide's corner, and Timeline slides for dated tasks.
                if controller.canvas.legend?.visible == true {
                    chip(Loc.t("Legend") + (settings.legend ? " ✓" : ""), on: false) {
                        controller.togglePresentLegend()
                    }
                }
                if controller.canvasHasScheduledTasks {
                    chip(Loc.t("Timeline slides") + (settings.timeline ? " ✓" : ""), on: false) {
                        controller.togglePresentTimeline()
                    }
                }
                Menu(settings.aspect) {
                    ForEach(["16:9", "16:10", "4:3", "1:1"], id: \.self) { a in
                        Button(a) { controller.setPresentation(Loc.t("Aspect")) { $0.aspect = a } }
                    }
                }
                .fixedSize()
                Menu(settings.theme.capitalized) {
                    ForEach(["canvas", "dark", "light"], id: \.self) { t in
                        Button(t.capitalized) { controller.setPresentation(Loc.t("Slide Theme")) { $0.theme = t } }
                    }
                }
                .fixedSize()
                chip(Loc.t("? keys"), on: state.showKeys) { controller.present?.showKeys.toggle() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { i, s in
                        thumb(s, i)
                            .accessibleTap { controller.goToSlide(i) }
                            .draggable(s.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let moved = ids.first else { return false }
                                controller.perform(Loc.t("Reorder Slides")) {
                                    $0.moveSlide(moved, to: i, in: slides.map(\.id))
                                }
                                return true
                            }
                    }
                }
            }
            .accessibilityLabel(Loc.t("Slides"))
            HStack(spacing: 14) {
                key("→", Loc.t("next step"))
                key("S", "skip")
                key("M", Loc.t("merge with next"))
                key("H", Loc.t("hide topic from slides"))
                key("F", Loc.t("stage only"))
                key("esc", "end")
                Spacer()
                Text("Export:").foregroundStyle(.secondary)
                ForEach(["PDF", "PowerPoint", "Keynote", "Video"], id: \.self) { f in
                    Button(f == "Video" ? Loc.t("Video") : f) { controller.onExportSlides?(f) }.buttonStyle(.plain)
                }
            }
            .font(.chrome(12.5))
        }
        .padding(16)
        .frame(height: Self.height)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    func chip(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.chrome(12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(on ? Color.white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.secondary.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    func key(_ k: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Keycap(text: k)
            Text(label).foregroundStyle(.secondary)
        }
    }

    func thumb(_ s: Slide, _ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SlideWireframe(scene: controller.scene, slide: s)
                .frame(width: 170, height: 80)
                .overlay(alignment: .bottomLeading) {
                    Text(String(format: "%02d", i + 1)).font(.chrome(10, design: .monospaced))
                        .foregroundStyle(.secondary).padding(5)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        i == state.index ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: i == state.index ? 2 : 1))
            Text(controller.slideTitle(s) + (s.skipped ? Loc.t(" · skipped") : ""))
                .font(.chrome(12))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
                .foregroundStyle(s.skipped ? .tertiary : .primary)
        }
        .opacity(s.skipped ? 0.55 : 1)
        .accessibilityLabel(
            s.skipped
                ? Loc.f("Slide %lld: %@, skipped", i + 1, controller.slideTitle(s))
                : Loc.f("Slide %lld: %@", i + 1, controller.slideTitle(s)))
    }
}

/// A slide thumbnail: the scene's outlines with the slide's topics emphasised.
struct SlideWireframe: View {
    let scene: Scene
    let slide: Slide

    var body: some View {
        Canvas { ctx, size in
            let ids = slide.focus.isEmpty ? Array(scene.nodes.keys) : slide.focus
            let rects = ids.compactMap { scene.nodes[$0]?.frame.rect }
            let b = rects.reduce(CGRect.null) { $0.union($1) }
            guard !b.isNull, b.width > 0 else { return }
            let k = min((size.width - 16) / b.width, (size.height - 16) / b.height)
            let dx = (size.width - b.width * k) / 2 - b.minX * k
            let dy = (size.height - b.height * k) / 2 - b.minY * k
            let hi = Set(slide.highlight)
            for id in ids {
                guard let n = scene.nodes[id] else { continue }
                let r = n.frame.rect
                let t = CGRect(x: r.minX * k + dx, y: r.minY * k + dy, width: r.width * k, height: r.height * k)
                let on = hi.isEmpty || hi.contains(id)
                ctx.stroke(
                    Path(roundedRect: t, cornerRadius: min(t.height / 2, 4)),
                    with: .color(on ? .accentColor : .secondary.opacity(0.5)), lineWidth: on ? 1.4 : 0.8)
            }
        }
        .accessibilityHidden(true)
    }
}

struct PresentKeysView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Present keys").font(.chrome(17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(
                    [
                        (Loc.t("→ / Space"), Loc.t("Next step")), ("←", Loc.t("Previous step")),
                        ("S", Loc.t("Skip this slide")),
                        ("M", Loc.t("Merge with the next slide")), ("H", Loc.t("Hide the topic from slides")),
                        ("F", Loc.t("Stage only (hide the strip)")), ("P", Loc.t("Presenter view")),
                        ("L", Loc.t("Legend on slides")), ("T", Loc.t("Timeline slides")),
                        ("?", Loc.t("This list")),
                        ("esc", Loc.t("End")),
                    ], id: \.0
                ) { k, v in
                    GridRow {
                        Keycap(text: k)
                        Text(v).font(.chrome(13))
                    }
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
    }
}

/// Presenter view (display 2): timer, next slide and the topic's note.
public struct PresenterView: View {
    var controller: CanvasController
    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let p = controller.present
            let slides = controller.slides
            let index = p?.index ?? 0
            let next = slides.indices.contains(index + 1) ? slides[index + 1] : nil
            let current = slides.indices.contains(index) ? slides[index] : nil
            let elapsed = Int(ctx.date.timeIntervalSince(p?.started ?? ctx.date))
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("PRESENTER VIEW").font(.chrome(12, weight: .semibold, design: .monospaced)).kerning(1.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(.chrome(30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
                Text(current.map(controller.slideTitle) ?? "").font(.chrome(20, weight: .semibold))
                HStack(alignment: .top, spacing: 14) {
                    if let next {
                        SlideWireframe(scene: controller.scene, slide: next)
                            .frame(width: 200, height: 112)
                            .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next").foregroundStyle(.secondary)
                        Text(next.map(controller.slideTitle) ?? Loc.t("End of deck")).font(.chrome(15))
                    }
                }
                ScrollView {
                    Text(current?.note ?? Loc.t("No note on this slide's topic."))
                        .font(.chrome(16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel(Loc.t("Speaker note"))
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                HStack {
                    Text(Loc.f("Slide %lld of %lld", index + 1, slides.count)).foregroundStyle(.secondary)
                    Spacer()
                    Button("◀︎") { controller.stepSlide(-1) }
                    Button("▶︎") { controller.stepSlide(1) }
                }
            }
            .padding(22)
            .frame(minWidth: 520, minHeight: 420)
        }
    }
}
