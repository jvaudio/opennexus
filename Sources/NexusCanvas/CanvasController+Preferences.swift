import AppKit
import NexusCore
import NexusKeys
import NexusTheme

/// Settings that change how the canvas behaves, applied live (M8).
extension CanvasController {
    func observePreferences() {
        if let o = prefsObserver { NotificationCenter.default.removeObserver(o) }
        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: prefs, queue: .main
        ) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        applyPreferences()
    }

    /// Re-reads every preference the canvas depends on.
    public func applyPreferences() {
        let cjk = prefs.string("appearance.cjkFont")
        if NodeTextStyle.cjkFamily != cjk {
            NodeTextStyle.cjkFamily = cjk
            builder.measurer.clearCache()
        }
        let custom = keyCustomization
        let reg = custom.apply(to: baseRegistry)
        registry = reg
        var p = custom.keyProfile
        p.typingReplacesSelection = p.typingReplacesSelection && prefs.string("editing.typing") != "off"
        profile = p
        customBindings = custom.custom
        prefsRevision += 1
        rebuildScene()
        onSceneChange?(false)
    }

    // MARK: Keyboard

    /// The user's shortcut changes (Settings › Shortcuts).
    public var keyCustomization: KeyCustomization {
        get {
            var c = prefs.data("shortcuts.custom").flatMap(KeyCustomization.decode) ?? KeyCustomization()
            c.profile = prefs.string("shortcuts.profile")
            return c
        }
        set {
            prefs.setData("shortcuts.custom", newValue.json)
            if newValue.profile != prefs.string("shortcuts.profile") {
                prefs.set("shortcuts.profile", newValue.profile)
            }
        }
    }

    /// Typing on a selected node appends instead of replacing (Settings › Editing).
    public var typingAppends: Bool { prefs.string("editing.typing") == "append" }

    // MARK: New topics

    var slashOnEmptyNode: Bool { prefs.bool("editing.slashEmpty") }

    /// "+name:Type" → "+ name: Type" (Settings › Editing › Auto-format UML members).
    static func formatUMLMember(_ s: String) -> String {
        guard let m = s.wholeMatch(of: /\s*([+\-#~])\s*([A-Za-z_][\w]*(?:\([^)]*\))?)\s*:\s*(\S.*)/) else { return s }
        return "\(m.1) \(m.2): \(m.3)"
    }
    var umlAutoFormat: Bool { prefs.bool("editing.umlFormat") }

    // MARK: View state from preferences

    func applyPreferenceView(_ v: inout SceneViewState) {
        v.background = prefs.string("appearance.background")
        let a = Double(prefs.string("appearance.minText")) ?? 0
        let b = Double(prefs.string("accessibility.minText")) ?? 0
        v.minFontSize = max(a, b)
        v.patterns = prefs.bool("accessibility.patterns")
        v.taskDetails = prefs.bool("editing.taskDetails")
        v.today = todayDate
    }

    /// High Contrast replaces the theme while macOS's Increase Contrast is on.
    func contrastTheme(_ theme: Theme) -> Theme {
        if prefs.bool("accessibility.highContrast"), NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            return Theme.named("highContrast")
        }
        return theme
    }

    /// Settings › Appearance › Follow system light / dark: themes with a paired variant
    /// switch with the system appearance (outside Present, which has its own setting).
    func followSystemTheme(_ theme: Theme) -> Theme {
        guard present == nil, !rendersThemeAsNamed, prefs.bool("appearance.followSystem"), let pair = theme.counterpart
        else { return theme }
        let dark = systemIsDark ?? (NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        return dark != theme.isDark ? Theme.named(pair, custom: library.themes) : theme
    }

    /// ZEN appearance: light, dark, ultra light or ultra dark while in ZEN.
    func zenTheme(_ theme: Theme) -> Theme {
        guard zen else { return theme }
        switch prefs.string("appearance.zen") {
        case "dark": return theme.isDark ? theme : Theme.named(theme.counterpart ?? "graphite", custom: library.themes)
        case "ultraLight": return Theme.named("whiteboard")
        case "ultraDark": return Theme.named("skeletonDark")
        default: return theme.isDark ? Theme.named(theme.counterpart ?? "classic", custom: library.themes) : theme
        }
    }

    /// Seconds spent in ZEN today.
    public var zenToday: TimeInterval {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let stored = prefs.defaults.double(forKey: "zen.day") == day ? prefs.defaults.double(forKey: "zen.seconds") : 0
        return stored + (zen ? zenStarted.map { Date().timeIntervalSince($0) } ?? 0 : 0)
    }

    func addZenTime(_ t: TimeInterval) {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let stored = prefs.defaults.double(forKey: "zen.day") == day ? prefs.defaults.double(forKey: "zen.seconds") : 0
        prefs.defaults.set(day, forKey: "zen.day")
        prefs.defaults.set(stored + t, forKey: "zen.seconds")
        zenStarted = nil
    }

    /// Selection ring width (Settings › Accessibility).
    public var ringWidth: CGFloat { CGFloat(Double(prefs.string("accessibility.ring")) ?? 3) }

    /// Animations: Settings › Appearance (full, reduced, off) and Accessibility (system,
    /// on, off). Off and reduced both cross-fade instead of moving.
    public var reduceMotionPreference: Bool? {
        switch prefs.string("accessibility.reduceMotion") {
        case "on": return true
        case "off": return prefs.string("appearance.animations") != "full"
        default: return prefs.string("appearance.animations") == "full" ? nil : true
        }
    }

    public var animateReflow: Bool {
        prefs.bool("editing.animateReflow") && prefs.string("appearance.animations") != "off"
    }

    // MARK: Pointer

    public var scrollZooms: Bool { prefs.string("editing.scroll") == "zoom" }
    public var rightDragPans: Bool { prefs.bool("editing.rightDragPan") }
    public var dragToFloat: Bool { prefs.bool("editing.dragToFloat") }
    public var doubleClickAction: String { prefs.string("editing.doubleClick") }
    public var snapDistance: CGFloat { CGFloat(prefs.number("editing.snapDistance")) }
    public var gridSnap: CGFloat? {
        prefs.bool("editing.snapGrid") ? CGFloat(max(prefs.number("editing.gridSize"), 1)) : nil
    }
    public var alwaysShowGuides: Bool { prefs.bool("editing.guides") }
    public var cheatSheetDelay: TimeInterval { max(0.2, prefs.number("accessibility.cheatDelay")) }

    // MARK: New documents and canvases

    /// A new document's first canvas, from Settings › Editing › New documents and
    /// Appearance › Default look (or the last document's look).
    public static func newDocumentModel(prefs: Preferences, type: DiagramType = .mindmap) -> DocumentModel {
        var c = Canvas(id: "c1", title: "", type: type, rootText: DiagramDescriptor[type].rootText)
        applyDefaults(&c, prefs: prefs)
        return DocumentModel(canvases: [c])
    }

    public static func applyDefaults(_ c: inout Canvas, prefs: Preferences) {
        if prefs.bool("editing.useLast"), let data = prefs.data("editing.lastLook"),
            let v = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        {
            if let t = v["theme"] { c.style.theme = t }
            if let s = v["nodeStyle"] { c.style.nodeStyle = s }
            if let t = v["colorTheme"] { c.style.colorTheme = t }
            if let s = v["structure"], c.type == .mindmap { c.layout.structure = LayoutStructure(rawValue: s) }
        } else {
            c.style.theme = prefs.string("appearance.theme")
            c.style.nodeStyle = prefs.string("appearance.nodeStyle")
            c.style.colorTheme = prefs.string("appearance.colorTheme")
            let font = prefs.string("appearance.font")
            if font != "system" { c.style.font = font }
            if c.type == .mindmap {
                c.layout.structure = LayoutStructure(rawValue: prefs.string("editing.defaultStructure"))
            }
        }
        if prefs.string("editing.newCanvasLayout") == "free" { c.layout.mode = .free }
    }

    /// Remembers this canvas's look for "Use last skeleton, node style and colour theme".
    public func rememberLook() {
        let c = canvas
        let v = [
            "theme": c.style.theme, "nodeStyle": c.style.nodeStyle, "colorTheme": c.style.colorTheme,
            "structure": c.layout.structure.rawValue,
        ]
        prefs.defaults.set(try? JSONSerialization.data(withJSONObject: v), forKey: "editing.lastLook")
    }

    public var startsInEditMode: Bool { prefs.bool("editing.startInEdit") }

    /// The zoom new documents open at (nil: fit).
    public var defaultZoom: CGFloat? {
        let z = prefs.string("editing.defaultZoom")
        return z == "fit" ? nil : CGFloat((Double(z) ?? 100) / 100)
    }

    // MARK: Tips

    /// Called when a command is run with the mouse (menu, toolbar, context menu, palette
    /// click). The third time, a quiet toast suggests its key.
    public func noteMouseUse(_ id: CommandID) {
        guard prefs.bool("general.tips"), let key = bindings(for: id).first, let title = registry[id]?.title else {
            return
        }
        let n = (mouseUses[id] ?? 0) + 1
        mouseUses[id] = n
        guard n == 3 else { return }
        tip = Tip(keys: key.glyphs, does: Tip.phrase(title))
        let shown = tip
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated { if self?.tip == shown { self?.tip = nil } }
        }
    }

    /// Faint ⇥ · ↩ · / hints on a fresh canvas, until the first key press.
    public var showsEmptyHints: Bool {
        prefs.bool("general.hintKeycaps") && !hasPressedKey && tour == nil && canvas.nodes.count == 1 && present == nil
    }
}

public struct Tip: Equatable, Sendable {
    public var keys: String
    public var does: String

    /// "Add Child Topic" → "adds a child topic".
    static func phrase(_ title: String) -> String {
        let words = title.split(separator: " ").map(String.init)
        guard let verb = words.first else { return title }
        let rest = words.dropFirst().joined(separator: " ").lowercased()
        let v = verb.lowercased()
        let third =
            v.hasSuffix("s") || v.hasSuffix("sh") || v.hasSuffix("ch")
            ? v + "es" : v.hasSuffix("y") && !v.hasSuffix("ay") ? String(v.dropLast()) + "ies" : v + "s"
        let article =
            rest.isEmpty ? "" : (rest.hasPrefix("a ") || rest.hasPrefix("the ") || rest.hasSuffix("s") ? " " : " a ")
        return third + article + rest
    }
}
