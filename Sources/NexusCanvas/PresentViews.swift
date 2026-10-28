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
            GeometryReader { geo in
                stage(p, size: geo.size)
            }
        }
    }

    @ViewBuilder
    func stage(_ p: PresentState, size: CGSize) -> some View {
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
            }
            .padding(.leading, 56)
            .padding(.top, 36)
            .allowsHitTesting(false)
            // A Timeline slide's chart, where the framing expects it (M35, D264).
            if let slide, let chart = controller.timelineChart(for: slide) {
                let place = TimelinePlacement.screen(controller, slide, size: size, stageOnly: p.stageOnly)
                TimelineCard(chart: chart, spoken: controller.timelineSpoken(slide), maxScale: place.maxScale)
                    .frame(width: place.target.width, height: place.target.height)
                    .offset(x: place.target.minX, y: place.target.minY)
                    .allowsHitTesting(false)
            }
            // The slide's legend in its corner (M21, D200) and the progress dots share
            // a line just above the strip, where the framing expects them (M28, D232), and
            // the dots never meet the legend (M35, D265).
            let placement = PresentLegendPlacement.screen(
                stageOnly: p.stageOnly, viewWidth: size.width, slides: slides.count)
            let legend = controller.presentLegend(for: slide)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if let l = legend {
                        PresentLegendCorner(
                            legend: l, theme: controller.scene.theme, canvas: controller.scene.canvasColor,
                            placement: placement
                        )
                        .padding(.leading, placement.leading)
                    }
                    Spacer(minLength: 0)
                    let room = PresentProgress.room(
                        viewWidth: size.width, legend: legend.map { placement.rect($0, in: size) })
                    PresentDots(
                        slides: slides, index: p.index, style: PresentProgress.style(count: slides.count, room: room),
                        ink: ink
                    )
                    .padding(.trailing, PresentProgress.trailing)
                }
                .padding(.bottom, placement.bottom)
            }
            .allowsHitTesting(false)
            VStack {
                Spacer()
                if !p.stageOnly { SlideStripView(controller: controller, state: p, slides: slides) }
            }
            if p.showKeys { PresentKeysView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if p.overview {
                Text("OVERVIEW · O RETURNS TO THE SLIDE").font(.chrome(12, weight: .semibold, design: .monospaced))
                    .kerning(1.2).foregroundStyle(ink.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .topTrailing).padding(.top, 40).padding(.trailing, 56)
                    .allowsHitTesting(false)
            }
            if !p.typed.isEmpty {
                Text(Loc.f("Go to slide %@ ↩", p.typed)).font(.chrome(22, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Loc.f("Go to slide %@", p.typed))
            }
            // B and W: the screen goes black or white until the next key (M42).
            if let b = p.blank {
                (b == "white" ? Color.white : Color.black).ignoresSafeArea()
                    .accessibilityLabel(b == "white" ? Loc.t("White screen") : Loc.t("Black screen"))
            }
        }
    }
}

/// The progress dots, condensed or as a counter when the legend leaves them less room
/// (D265). VoiceOver reads "Slide 3 of 12" either way.
struct PresentDots: View {
    let slides: [Slide]
    let index: Int
    let style: PresentProgress.Style
    let ink: Color

    var body: some View {
        Group {
            switch style {
            case .dots(let size, let spacing, let current):
                HStack(spacing: spacing) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { i, s in
                        Capsule()
                            .fill(i == index ? Color.accentColor : ink.opacity(s.skipped ? 0.15 : 0.35))
                            .frame(width: i == index ? current : size, height: size)
                    }
                }
            case .counter:
                Text(PresentProgress.counter(index, of: slides.count))
                    .font(.chrome(13, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.6))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PresentProgress.counter(index, of: slides.count))
    }
}

struct SlideStripView: View {
    var controller: CanvasController
    let state: PresentState
    let slides: [Slide]
    /// The strip's height; the corner legend and the dots sit above it (D232).
    static let height: CGFloat = 236

    var body: some View {
        let controls = controller.stripControls
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("SLIDES · AUTO-GENERATED · DRAG TO REORDER")
                    .font(.chrome(11.5, weight: .semibold, design: .monospaced)).kerning(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Transition").font(.chrome(12.5)).foregroundStyle(.secondary)
                // One list for the mouse, ⇥ and VoiceOver (M35, D266).
                ForEach(controls.filter { $0.kind != .export }) { c in
                    switch c.kind {
                    case .menu: menu(c)
                    default: chip(c)
                    }
                }
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
                key("⇥", Loc.t("controls"))
                key("esc", "end")
                Spacer()
                Text("Export:").foregroundStyle(.secondary)
                ForEach(controls.filter { $0.kind == .export }) { c in
                    Button(c.title) { controller.activateStripControl(c.id) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 3)
                        .overlay(focusRing(c))
                        .accessibilityLabel(c.label)
                }
            }
            .font(.chrome(12.5))
        }
        .padding(16)
        .frame(height: Self.height)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    /// A chip: filled when chosen (a transition), ✓ when turned on, ringed when ⇥ is on it.
    func chip(_ c: StripControl) -> some View {
        let filled = c.on && (c.id.hasPrefix("transition.") || c.id == "keys")
        return Button {
            controller.activateStripControl(c.id)
        } label: {
            Text(c.title).font(.chrome(12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(filled ? Color.white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(filled ? Color.accentColor : Color.secondary.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .overlay(focusRing(c))
        .accessibilityLabel(c.label)
        .accessibilityAddTraits(c.on ? .isSelected : [])
    }

    /// Style, depth, aspect and theme: a pop-up for the mouse; ↩ steps to the next choice.
    func menu(_ c: StripControl) -> some View {
        Menu(c.title) {
            ForEach(controller.stripMenuChoices(c.id), id: \.0) { v, title in
                Button(title) { controller.chooseStripMenu(c.id, v) }
            }
        }
        .fixedSize()
        .overlay(focusRing(c))
        .accessibilityLabel(c.label)
        .accessibilityValue(c.value ?? "")
    }

    /// The keyboard focus ring on the control ⇥ moved to (D266).
    @ViewBuilder
    func focusRing(_ c: StripControl) -> some View {
        if state.stripFocus == c.id {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5)
                .padding(-3)
                .allowsHitTesting(false)
        }
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
                        (Loc.t("→ / Space / click"), Loc.t("Next step")), ("←", Loc.t("Previous step")),
                        (Loc.t("1 2 3 … ↩"), Loc.t("Go to that slide")),
                        ("O", Loc.t("Overview of the whole map")),
                        (Loc.t("B / W"), Loc.t("Black or white screen")),
                        (Loc.t("hold ⇧"), Loc.t("Laser pointer")),
                        ("S", Loc.t("Skip this slide")),
                        ("M", Loc.t("Merge with the next slide")), ("H", Loc.t("Hide the topic from slides")),
                        ("F", Loc.t("Stage only (hide the strip)")), ("P", Loc.t("Presenter view")),
                        ("L", Loc.t("Legend on slides")), ("T", Loc.t("Timeline slides")),
                        (Loc.t("⇥ / ⇧⇥"), Loc.t("The strip's controls (↩ or Space uses one)")),
                        ("?", Loc.t("This list")),
                        ("esc", Loc.t("End on this slide's topic")),
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

/// Presenter view (display 2, full screen there; M42): the current and next slides as they
/// play, the topic's note in large type, the time since Present began, and the clock.
public struct PresenterView: View {
    var controller: CanvasController
    /// Slides drawn so far. An observable object, not `@State`: the cards read it inside
    /// the TimelineView's content, where a state change wouldn't redraw them.
    @State private var drawn = PresenterSlides()
    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let p = controller.present
            let slides = controller.slides
            let index = p?.index ?? 0
            let nextIndex = slides.indices.dropFirst(index + 1).first { !slides[$0].skipped }
            let next = nextIndex.map { slides[$0] }
            let current = slides.indices.contains(index) ? slides[index] : nil
            let elapsed = Int(ctx.date.timeIntervalSince(p?.started ?? ctx.date))
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PRESENTER VIEW").font(.chrome(12, weight: .semibold, design: .monospaced)).kerning(1.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ctx.date.formatted(date: .omitted, time: .shortened))
                        .font(.chrome(22, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        .accessibilityLabel(Loc.f("Time: %@", ctx.date.formatted(date: .omitted, time: .shortened)))
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(.chrome(34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 16)
                        .accessibilityLabel(Loc.f("Elapsed: %lld minutes %lld seconds", elapsed / 60, elapsed % 60))
                }
                let pair = Set([current, next].compactMap { $0.map(cardKey) })
                HStack(alignment: .top, spacing: 18) {
                    slideCard(
                        current, index: index, label: Loc.f("Slide %lld of %lld", index + 1, slides.count), keep: pair
                    )
                    .frame(maxWidth: .infinity)
                    slideCard(
                        next, index: nextIndex, label: next == nil ? Loc.t("End of deck") : Loc.t("Next"), keep: pair
                    )
                    .frame(maxWidth: .infinity)
                    .opacity(0.85)
                }
                ScrollView {
                    Text(current?.note ?? Loc.t("No note on this slide's topic."))
                        .font(.chrome(24))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel(Loc.t("Speaker note"))
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                HStack {
                    Spacer()
                    Button("◀︎") { controller.stepSlide(-1) }.accessibilityLabel(Loc.t("Previous step"))
                    Button("▶︎") { controller.stepSlide(1) }.accessibilityLabel(Loc.t("Next step"))
                }
            }
            .padding(24)
            .frame(minWidth: 720, minHeight: 520)
        }
    }

    /// A drawn slide's cache key: the document revision, canvas and slide.
    func cardKey(_ slide: Slide) -> String {
        "\(controller.store.revision)|\(controller.canvasID.rawValue)|\(slide.id)"
    }

    /// A slide drawn as it plays, its title under it; a placeholder until it's drawn.
    /// `keep`: the current pair's keys, which the cache never drops.
    func slideCard(_ slide: Slide?, index: Int?, label: String, keep: Set<String>) -> some View {
        let key = slide.map(cardKey)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
                if let key, let img = drawn.images[key] {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if let slide {
                    SlideWireframe(scene: controller.scene, slide: slide).padding(10)
                }
            }
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
            .accessibilityHidden(true)
            Text(label).font(.chrome(13)).foregroundStyle(.secondary)
            Text(slide.map(controller.slideTitle) ?? "").font(.chrome(19, weight: .semibold)).lineLimit(2)
        }
        .task(id: key) {
            guard let key, let index, drawn.images[key] == nil else { return }
            await Task.yield()
            if let img = SlideExporter.renderSlide(
                controller.store.model, canvas: controller.canvasID, index: index,
                size: CGSize(width: 960, height: 540),
                prefs: controller.prefs)
            {
                // Keep the deck's current pair, not every revision's.
                if drawn.images.count > 8 { drawn.images = drawn.images.filter { keep.contains($0.key) } }
                drawn.images[key] = img
            }
        }
    }
}

/// The presenter view's drawn slides, by revision, canvas and slide.
@MainActor
@Observable
final class PresenterSlides {
    var images: [String: CGImage] = [:]
}
