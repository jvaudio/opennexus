import AppKit
import NexusCore
import NexusKeys

// The Present strip's controls from the keyboard (M35, D266): ⇥ and ⇧⇥ walk them, ↩ or
// Space uses the one in focus, and Esc hands the keys back to the slides. The strip
// draws its chips from the same list, so the keyboard, VoiceOver and the mouse agree.

/// One control on the Present strip: a chip, a pop-up (aspect, theme) or an export.
public struct StripControl: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case chip, menu, export }
    public var id: String
    /// What the strip shows.
    public var title: String
    /// What VoiceOver reads (no ✓ glyphs; the state is `on`, or `value` for a pop-up).
    public var label: String
    public var value: String?
    /// Chosen or turned on.
    public var on: Bool
    public var kind: Kind
}

@MainActor
extension CanvasController {
    static let slideAspects = ["16:9", "16:10", "4:3", "1:1"]
    static let slideThemes = ["canvas", "dark", "light"]
    static let slideExports = ["PDF", "PowerPoint", "Keynote", "Video"]
    static let slideDepths = ["main", "all"]

    static func styleTitle(_ s: String) -> String {
        switch s {
        case "calm": Loc.t("Calm")
        case "showtime": Loc.t("Showtime")
        default: Loc.t("Dynamic")
        }
    }

    static func depthTitle(_ d: String) -> String { d == "all" ? Loc.t("Every branch") : Loc.t("Main topics") }

    /// A strip pop-up's choices: (value, title).
    public func stripMenuChoices(_ id: String) -> [(String, String)] {
        switch id {
        case "aspect": Self.slideAspects.map { ($0, $0) }
        case "theme": Self.slideThemes.map { ($0, $0.capitalized) }
        case "style": PresentationSettings.styles.map { ($0, Self.styleTitle($0)) }
        case "depth": Self.slideDepths.map { ($0, Self.depthTitle($0)) }
        default: []
        }
    }

    /// Picks a strip pop-up's choice.
    public func chooseStripMenu(_ id: String, _ value: String) {
        switch id {
        case "aspect": setPresentation(Loc.t("Aspect")) { $0.aspect = value }
        case "theme": setPresentation(Loc.t("Slide Theme")) { $0.theme = value }
        case "style": setPresentation(Loc.t("Presentation Style")) { $0.style = value }
        case "depth": setPresentation(Loc.t("Slide Depth")) { $0.depth = value }
        default: break
        }
    }

    /// The strip's controls in the order ⇥ visits them: the header's chips and pop-ups, then
    /// the export buttons. Chips that don't apply (Step through flow on a mind map, Legend
    /// without a canvas legend, Timeline slides without dated tasks) aren't there.
    public var stripControls: [StripControl] {
        let s = canvas.presentation
        var out: [StripControl] = [
            StripControl(
                id: "transition.glide", title: Loc.t("Glide"), label: Loc.t("Glide transition"),
                on: s.transition == "glide", kind: .chip),
            StripControl(
                id: "transition.zoom", title: Loc.t("Zoom"), label: Loc.t("Zoom transition"),
                on: s.transition == "zoom", kind: .chip),
            StripControl(
                id: "transition.cut", title: Loc.t("Cut"), label: Loc.t("Cut transition"), on: s.transition == "cut",
                kind: .chip),
        ]
        if DiagramCatalog.isTechnical(canvas.type) {
            out.append(
                StripControl(
                    id: "flow", title: Loc.t("Step through flow") + (s.stepThroughFlow ? " ✓" : ""),
                    label: Loc.t("Step through flow"), on: s.stepThroughFlow, kind: .chip))
        }
        if canvas.legend?.visible == true {
            out.append(
                StripControl(
                    id: "legend", title: Loc.t("Legend") + (s.legend ? " ✓" : ""), label: Loc.t("Legend on slides"),
                    on: s.legend, kind: .chip))
        }
        if canvasHasScheduledTasks {
            out.append(
                StripControl(
                    id: "timeline", title: Loc.t("Timeline slides") + (s.timeline ? " ✓" : ""),
                    label: Loc.t("Timeline slides"), on: s.timeline, kind: .chip))
        }
        // The deck's style (M42), and for hierarchies how deep the slides go and whether an
        // overview comes between branches.
        let style = Self.styleTitle(s.style)
        out.append(StripControl(id: "style", title: style, label: Loc.t("Style"), value: style, on: false, kind: .menu))
        if !DiagramCatalog.isTechnical(canvas.type) {
            let depth = Self.depthTitle(s.depth)
            out.append(
                StripControl(id: "depth", title: depth, label: Loc.t("Depth"), value: depth, on: false, kind: .menu))
            out.append(
                StripControl(
                    id: "overview", title: Loc.t("Overviews") + (s.overview ? " ✓" : ""),
                    label: Loc.t("Overview between branches"), on: s.overview, kind: .chip))
        }
        out.append(
            StripControl(id: "aspect", title: s.aspect, label: Loc.t("Aspect"), value: s.aspect, on: false, kind: .menu)
        )
        out.append(
            StripControl(
                id: "theme", title: s.theme.capitalized, label: Loc.t("Slide Theme"), value: s.theme.capitalized,
                on: false, kind: .menu))
        out.append(
            StripControl(
                id: "keys", title: Loc.t("? keys"), label: Loc.t("Present keys"), on: present?.showKeys == true,
                kind: .chip))
        for f in Self.slideExports {
            let title = f == "Video" ? Loc.t("Video") : f
            out.append(
                StripControl(
                    id: "export.\(f)", title: title, label: Loc.f("Export slides as %@", title), on: false,
                    kind: .export
                ))
        }
        return out
    }

    /// Uses a strip control, as a click does. A pop-up steps to its next choice.
    public func activateStripControl(_ id: String) {
        let s = canvas.presentation
        switch id {
        case "transition.glide", "transition.zoom", "transition.cut":
            let t = String(id.dropFirst("transition.".count))
            setPresentation(Loc.t("Transition")) { $0.transition = t }
        case "flow": setPresentation(Loc.t("Step Through Flow")) { $0.stepThroughFlow.toggle() }
        case "legend": togglePresentLegend()
        case "timeline": togglePresentTimeline()
        case "aspect":
            let all = Self.slideAspects
            let next = all[((all.firstIndex(of: s.aspect) ?? -1) + 1) % all.count]
            setPresentation(Loc.t("Aspect")) { $0.aspect = next }
        case "theme":
            let all = Self.slideThemes
            let next = all[((all.firstIndex(of: s.theme) ?? -1) + 1) % all.count]
            setPresentation(Loc.t("Slide Theme")) { $0.theme = next }
        case "style", "depth":
            let all = stripMenuChoices(id).map(\.0)
            let current = id == "style" ? s.style : s.depth
            chooseStripMenu(id, all[((all.firstIndex(of: current) ?? -1) + 1) % all.count])
        case "overview": setPresentation(Loc.t("Overviews")) { $0.overview.toggle() }
        case "keys": present?.showKeys.toggle()
        default:
            if id.hasPrefix("export.") { onExportSlides?(String(id.dropFirst("export.".count))) }
        }
    }

    /// ⇥ / ⇧⇥ in Present: the next (or previous) strip control, and past the last one back
    /// to the slides. With the stage alone, ⇥ brings the strip back first.
    func moveStripFocus(back: Bool) {
        guard var p = present else { return }
        if p.stageOnly {
            p.stageOnly = false
            present = p
            showSlide()
        }
        let ids = stripControls.map(\.id)
        guard !ids.isEmpty else { return }
        let i = p.stripFocus.flatMap { ids.firstIndex(of: $0) }
        let next: Int? =
            switch (i, back) {
            case (nil, false): 0
            case (nil, true): ids.count - 1
            case (let i?, false): i + 1 < ids.count ? i + 1 : nil
            case (let i?, true): i > 0 ? i - 1 : nil
            }
        present?.stripFocus = next.map { ids[$0] }
        announceStripFocus()
    }

    /// The strip control in focus, if it's still on the strip.
    public var focusedStripControl: StripControl? {
        guard let id = present?.stripFocus else { return nil }
        return stripControls.first { $0.id == id }
    }

    /// VoiceOver reads the control ⇥ moved to (or that the slides have the keys again).
    func announceStripFocus() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = NSApp.keyWindow else { return }
        let text =
            focusedStripControl.map { c in [c.label, c.value].compactMap { $0 }.joined(separator: ", ") }
            ?? Loc.t("Slides")
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
