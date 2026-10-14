import Foundation

/// Settings as data (README §10: "Generate the panes from a declarative schema … so the
/// search field in Settings can find every row"). Mirrors the sources' `sec()` and
/// `T S G R B K I` helpers: Toggle, Segmented, Grid (custom card), Range (number),
/// Button, Keycaps, Info.
public struct SettingRow: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case toggle
        case segmented([Option])
        case menu([Option])
        case number(unit: String, min: Double, max: Double, step: Double)
        case text
        case button(String)
        case keycaps([String])
        case info(String)
        /// A preview or composite control drawn by the pane (theme grid, frames …).
        case card(String)
    }

    public struct Option: Sendable, Hashable {
        public var value: String
        public var label: String
        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public var key: String
    public var title: String
    public var detail: String?
    public var kind: Kind
    public var defaultValue: PrefValue?
    public var keywords: [String] = []
    /// Shown instead of the control's effect: why the row is unavailable in v1.
    public var locked: String?
    public var id: String { key }
}

public struct SettingSection: Identifiable, Sendable, Hashable {
    public var title: String
    public var rows: [SettingRow]
    public var footnote: String?
    /// 0 left, 1 right.
    public var column = 0
    public var id: String { title + "\(column)" + (rows.first?.key ?? "") }
}

public struct SettingPane: Identifiable, Sendable, Hashable {
    public var id: String
    public var glyph: String
    public var title: String
    /// Sidebar icon tint (README §10).
    public var tint: String
    public var subtitle: String
    public var sections: [SettingSection]
}

// MARK: Builders (T S G R B K I)

private func O(_ pairs: [(String, String)]) -> [SettingRow.Option] { pairs.map { SettingRow.Option($0.0, $0.1) } }
private func T(
    _ key: String, _ title: String, _ on: Bool, _ detail: String? = nil, _ kw: [String] = [], locked: String? = nil
)
    -> SettingRow
{
    SettingRow(
        key: key, title: title, detail: detail, kind: .toggle, defaultValue: .bool(on), keywords: kw, locked: locked)
}
private func S(
    _ key: String, _ title: String, _ options: [(String, String)], _ def: String, _ detail: String? = nil,
    _ kw: [String] = [], locked: String? = nil
)
    -> SettingRow
{
    SettingRow(
        key: key, title: title, detail: detail, kind: .segmented(O(options)), defaultValue: .string(def), keywords: kw,
        locked: locked)
}
private func M(
    _ key: String, _ title: String, _ options: [(String, String)], _ def: String, _ detail: String? = nil,
    _ kw: [String] = []
)
    -> SettingRow
{
    SettingRow(
        key: key, title: title, detail: detail, kind: .menu(O(options)), defaultValue: .string(def), keywords: kw)
}
private func R(
    _ key: String, _ title: String, _ def: Double, _ unit: String, _ min: Double, _ max: Double, _ step: Double,
    _ detail: String? = nil
)
    -> SettingRow
{
    SettingRow(
        key: key, title: title, detail: detail, kind: .number(unit: unit, min: min, max: max, step: step),
        defaultValue: .number(def))
}
private func X(_ key: String, _ title: String, _ def: String, _ detail: String? = nil) -> SettingRow {
    SettingRow(key: key, title: title, detail: detail, kind: .text, defaultValue: .string(def))
}
private func B(_ key: String, _ title: String, _ button: String, _ detail: String? = nil, _ kw: [String] = [])
    -> SettingRow
{
    SettingRow(key: key, title: title, detail: detail, kind: .button(button), defaultValue: nil, keywords: kw)
}
private func K(_ key: String, _ title: String, _ keys: [String], _ detail: String? = nil) -> SettingRow {
    SettingRow(key: key, title: title, detail: detail, kind: .keycaps(keys), defaultValue: nil)
}
private func I(_ key: String, _ title: String, _ value: String, _ detail: String? = nil, locked: String? = nil)
    -> SettingRow
{
    SettingRow(key: key, title: title, detail: detail, kind: .info(value), defaultValue: nil, locked: locked)
}
private func G(_ key: String, _ title: String = "", _ card: String, _ def: PrefValue? = nil, _ kw: [String] = [])
    -> SettingRow
{
    SettingRow(key: key, title: title, kind: .card(card), defaultValue: def, keywords: kw)
}
private func sec(_ title: String, _ column: Int = 0, _ rows: [SettingRow], footnote: String? = nil) -> SettingSection {
    SettingSection(title: title, rows: rows, footnote: footnote, column: column)
}

public enum SettingsSchema {
    /// OpenNexus v1 makes no network requests (README §12); rows that would are shown, off.
    public static let noNetwork = "OpenNexus v1 makes no network requests"

    public static let panes: [SettingPane] = [
        general, editing, appearance, files, ai, shortcuts, export, integrations, privacy, accessibility,
    ]

    public static func pane(_ id: String) -> SettingPane? { panes.first { $0.id == id } }

    public static let allRows: [(SettingPane, SettingSection, SettingRow)] = panes.flatMap { p in
        p.sections.flatMap { s in s.rows.map { (p, s, $0) } }
    }

    public static let defaults: [String: PrefValue] = Dictionary(
        allRows.compactMap { r in r.2.defaultValue.map { (r.2.key, $0) } }, uniquingKeysWith: { a, _ in a })

    /// Search: every word of the query must appear in the row's title, detail, keywords,
    /// section or pane (case- and accent-insensitive).
    public static func search(_ query: String) -> [(SettingPane, SettingSection, SettingRow)] {
        let words = query.lowercased().folding(options: .diacriticInsensitive, locale: nil).split(separator: " ").map(
            String.init)
        guard !words.isEmpty else { return [] }
        return allRows.filter { p, s, r in
            var hay = [r.title, r.detail ?? "", s.title, p.title] + r.keywords
            switch r.kind {
            case .segmented(let o), .menu(let o): hay += o.map(\.label)
            case .button(let b): hay.append(b)
            case .info(let v): hay.append(v)
            default: break
            }
            let text = hay.joined(separator: " ").lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return words.allSatisfy { text.contains($0) }
        }
    }

    // MARK: 1 General (artboard 35)

    static let general = SettingPane(
        id: "general", glyph: "G", title: "General", tint: "#8E8E96",
        subtitle: "App-wide behaviour. Per-document look lives in the Format panel (⌘I).",
        sections: [
            sec(
                "App", 0,
                [
                    S(
                        "general.appearance", "Appearance", [("auto", "Auto"), ("light", "Light"), ("dark", "Dark")],
                        "auto", nil, ["dark mode", "light mode"]),
                    M(
                        "general.language", "Language",
                        [
                            ("system", "System (English)"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"),
                            ("es", "Español"), ("ja", "日本語"), ("zh-Hans", "简体中文"),
                        ], "system", "Restart applies the change"),
                    M(
                        "general.launch", "At launch, open",
                        [("last", "Last documents"), ("home", "Home"), ("new", "A new document")], "last"),
                    S("general.openIn", "Open documents in", [("tabs", "Tabs"), ("windows", "Windows")], "tabs"),
                    T("general.restoreWindows", "Restore windows when reopening", true),
                ]),
            sec(
                "Writing", 0,
                [
                    T("general.spelling", "Check spelling while typing", true),
                    T("general.autocorrect", "Correct spelling automatically", false),
                    T("general.smartQuotes", "Smart quotes and dashes", true, "Off inside code blocks and metadata"),
                    S(
                        "general.units", "Units", [("pt", "pt"), ("px", "px"), ("mm", "mm")], "pt",
                        "Used by export, print and layout fields"),
                ]),
            sec(
                "Updates", 1,
                [
                    T(
                        "general.updatesCheck", "Check for updates automatically", false, nil, ["update"],
                        locked: noNetwork),
                    T(
                        "general.updatesInstall", "Install updates automatically", false, nil, ["update"],
                        locked: noNetwork),
                    S(
                        "general.updatesChannel", "Channel", [("stable", "Stable"), ("beta", "Beta")], "stable", nil,
                        [], locked: noNetwork),
                    I("general.updatesWhere", "Updates come from where you installed OpenNexus", "App Store or GitHub"),
                ], footnote: "OpenNexus v1 makes no network requests, so it never checks for updates itself."),
            sec(
                "Help & tips", 1,
                [
                    T(
                        "general.tips", "Progressive tips", true,
                        "Suggest a key after you mouse to the same command 3 times"),
                    T(
                        "general.hintKeycaps", "Hint keycaps on empty canvases", true,
                        "Tab · Return · / fade after the first keystroke"),
                    I("general.cheatSheet", "Hold ⌘ cheat sheet", "", "Always on"),
                    M(
                        "general.role", "Template shelf and tour example",
                        [
                            ("engineer", "Engineer"), ("architect", "Architect"), ("security", "Security"),
                            ("planner", "Planner · Student"),
                        ], "engineer", nil, ["role", "world"]),
                    B(
                        "general.replayTour", "First-run tour", "Replay tour", nil,
                        ["tutorial", "onboarding", "welcome"]),
                    B("general.whatsNew", "What’s new in this version", "Show"),
                ]),
            sec("", 1, [G("general.about", "OpenNexus", "about", nil, ["version", "licence", "source code"])]),
        ])

    // MARK: 2 Editing (artboard 36)

    static let editing = SettingPane(
        id: "editing", glyph: "E", title: "Editing", tint: "#1E8BE0",
        subtitle: "How keys, the pointer and the layout engine behave while you build.",
        sections: [
            sec(
                "Typing", 0,
                [
                    S(
                        "editing.typing", "Typing on a selected node",
                        [("replace", "Replaces text"), ("append", "Appends")], "replace"),
                    I("editing.space", "Space", "Edit, keep text"),
                    S(
                        "editing.newTopic", "New topics start with",
                        [("placeholder", "Placeholder"), ("empty", "Empty")], "placeholder"),
                    S(
                        "editing.placeholderText", "Placeholder text",
                        [("generic", "Main Topic"), ("byType", "By type")], "byType"),
                    T("editing.umlFormat", "Auto-format UML members", true, "“+ name: Type” formats itself"),
                    T("editing.slashEmpty", "Slash menu at start of an empty node", true),
                ]),
            sec(
                "Layout & guides", 0,
                [
                    S(
                        "editing.newCanvasLayout", "New canvases use",
                        [("auto", "Auto-layout"), ("free", "Free layout")], "auto"),
                    T(
                        "editing.guides", "Always show alignment guides", false,
                        "Smart guidelines while dragging, in any layout"),
                    T("editing.snapGrid", "Snap to grid in free layout", true),
                    R("editing.gridSize", "Grid size", 8, "pt", 2, 64, 2),
                    R("editing.snapDistance", "Snap distance", 6, "pt", 1, 24, 1),
                    T("editing.animateReflow", "Animate reflow", true, "Turn off for instant layout on huge maps"),
                ],
                footnote:
                    "Branch Free-Positioning, Flexible Floating Topics and Topic Overlap are per-canvas, in Format › Map."
            ),
            sec(
                "Mouse & trackpad", 1,
                [
                    S(
                        "editing.floatingToolbar", "Floating toolbar",
                        [("rest", "After pointer rests"), ("click", "Click again"), ("never", "Never")], "rest"),
                    T(
                        "editing.addButtons", "Add Topic + buttons", true,
                        "Hidden while typing and with multiple selection"),
                    M(
                        "editing.doubleClick", "Double-click empty canvas",
                        [
                            ("floating", "New floating topic"), ("fit", "Fit map to window"),
                            ("nothing", "Does nothing"),
                        ], "floating"),
                    S("editing.scroll", "Scroll wheel", [("pan", "Pans"), ("zoom", "Zooms")], "pan"),
                    T("editing.rightDragPan", "Right-drag pans the canvas", true),
                    T("editing.dragToFloat", "Drag a node off its branch to float it", true),
                ]),
            sec(
                "New documents", 1,
                [
                    T("editing.useLast", "Use last skeleton, node style and colour theme", false),
                    M(
                        "editing.defaultStructure", "Default structure",
                        [
                            ("mindmap.balanced", "Mind Map · balanced"), ("mindmap.right", "Mind Map · right"),
                            ("logic.right", "Logic chart"), ("org.down", "Org chart"), ("tree.indented", "Tree"),
                            ("timeline.horizontal", "Timeline"),
                        ], "mindmap.balanced"),
                    M(
                        "editing.defaultZoom", "Default zoom",
                        [("fit", "Fit"), ("75", "75%"), ("100", "100%"), ("125", "125%"), ("150", "150%")], "100"),
                    T("editing.startInEdit", "Start in Edit mode on the root", true),
                ]),
            sec("Preview · mouse aids", 1, [G("editing.preview", "", "mouseAids")]),
        ])

    // MARK: 3 Appearance (artboard 37)

    static let appearance = SettingPane(
        id: "appearance", glyph: "A", title: "Appearance", tint: "#D6408B",
        subtitle: "Defaults for new documents and the app’s chrome. Change a single document from Format › Map.",
        sections: [
            sec(
                "Default look for new documents", 0,
                [
                    G(
                        "appearance.theme", "Theme", "themeGrid", .string("classic"),
                        [
                            "theme", "classic", "paper", "graphite", "blueprint", "pastel", "neon", "solarized",
                            "high contrast",
                        ]),
                    M(
                        "appearance.nodeStyle", "Node style",
                        [
                            ("outline", "Outline"), ("soft", "Soft"), ("solid", "Solid"), ("underline", "Underline"),
                            ("capsule", "Capsule"), ("sketch", "Sketch"), ("brutal", "Brutal"), ("glow", "Glow"),
                            ("minimal", "Minimal"),
                        ], "soft"),
                    G("appearance.lookPreview", "", "lookPreview"),
                ]),
            sec(
                "Theme", 0,
                [
                    T(
                        "appearance.followSystem", "Follow system light / dark", true,
                        "Themes with paired variants switch automatically"),
                    M(
                        "appearance.colorTheme", "Colour theme",
                        [
                            ("rainbow", "Rainbow · Classic"), ("multi", "Multi-colour"), ("mono", "Mono"),
                            ("gradient", "Gradient"),
                        ], "rainbow", "Rainbow, multi-colour, mono or gradient"),
                    M(
                        "appearance.font", "Diagram font",
                        [
                            ("system", "SF Pro"), ("rounded", "SF Pro Rounded"), ("serif", "New York"),
                            ("mono", "SF Mono"), ("hand", "Hand"),
                        ], "system"),
                    M(
                        "appearance.cjkFont", "CJK font",
                        [
                            ("PingFang SC", "PingFang SC"), ("PingFang TC", "PingFang TC"),
                            ("Hiragino Sans", "Hiragino Sans"), ("Apple SD Gothic Neo", "Apple SD Gothic Neo"),
                        ], "PingFang SC", "Used only for Chinese, Japanese and Korean text"),
                ]),
            sec(
                "Canvas", 1,
                [
                    S(
                        "appearance.background", "Background",
                        [("plain", "Plain"), ("dots", "Dots"), ("lines", "Lines")], "dots", nil, ["grid"]),
                    S(
                        "appearance.minimap", "Minimap",
                        [("panning", "While panning"), ("always", "Always"), ("never", "Never")], "panning"),
                    M(
                        "appearance.minText", "Minimum text at 100%",
                        [("10", "10 pt"), ("11", "11 pt"), ("12", "12 pt"), ("13", "13 pt"), ("14", "14 pt")], "12"),
                    T("appearance.adaptText", "Adapt text colour to background", true),
                ]),
            sec(
                "Motion & effects", 1,
                [
                    S(
                        "appearance.animations", "Animations",
                        [("full", "Full"), ("reduced", "Reduced"), ("off", "Off")], "full",
                        "Reduce Motion in macOS overrides this"),
                    T("appearance.glowTrail", "Glow trail on new edges", true),
                    T("appearance.sparkle", "Done sparkle", true, "When every to-do in a branch is checked"),
                    T("appearance.parallax", "Depth parallax when zoomed out", false),
                    T("appearance.flowDots", "Flow dots in Present mode", true),
                ]),
            sec(
                "ZEN & chrome", 1,
                [
                    S(
                        "appearance.zen", "ZEN appearance",
                        [
                            ("light", "Light"), ("dark", "Dark"), ("ultraLight", "Ultra light"),
                            ("ultraDark", "Ultra dark"),
                        ], "light"),
                    T("appearance.zenTimer", "“Today” focus timer in ZEN", false),
                    T("appearance.zenCount", "Topic & word count in ZEN", true),
                    T(
                        "appearance.glass", "Liquid Glass chrome", true,
                        "Off uses opaque bars; Reduce Transparency forces off"),
                    S("appearance.toolbar", "Toolbar", [("iconsText", "Icons + text"), ("icons", "Icons")], "icons"),
                ]),
        ])

    // MARK: 4 Files & Backup (artboard 38)

    static let files = SettingPane(
        id: "files", glyph: "F", title: "Files & Backup", tint: "#E08A00",
        subtitle: "Plain files on your disk, saved continuously, with snapshots you can always go back to.",
        sections: [
            sec(
                "Saving", 0,
                [
                    I("files.autosave", "Autosave", "Always on", "Every change, always on"),
                    I(
                        "files.versions", "Keep versions", "Hourly, 30 days",
                        "macOS keeps them; browse with File › Revert To…"),
                    T("files.askBeforeClosing", "Ask before closing unsaved new documents", true),
                    M(
                        "files.location", "Default location for new documents",
                        [("icloud", "iCloud Drive › OpenNexus"), ("documents", "Documents"), ("ask", "Ask each time")],
                        "icloud"),
                ], footnote: "Xmind saves only when you press ⌘S; OpenNexus never loses work to a forgotten save."),
            sec(
                "File format", 0,
                [
                    S(
                        "files.saveAs", "Save as", [("package", "Package (.nexus)"), ("json", "Single JSON")], "package"
                    ),
                    S(
                        "files.jsonLayout", "JSON layout", [("pretty", "Pretty"), ("compact", "Compact")], "pretty",
                        "Stable key order either way, so Git diffs stay clean"),
                    M(
                        "files.embedLimit", "Embed images up to",
                        [("1", "1 MB"), ("5", "5 MB"), ("10", "10 MB"), ("50", "50 MB"), ("0", "No limit")], "10",
                        "Larger files are linked, not copied"),
                    T(
                        "files.optimiseImages", "Optimise images on import", true,
                        "HEIC → JPEG, strip location metadata"),
                ]),
            sec(
                "Recovery", 0,
                [
                    T("files.snapshots", "Crash recovery snapshots", true, "Replaces Xmind’s File Cache"),
                    M(
                        "files.snapshotEvery", "Snapshot every",
                        [
                            ("30", "30 seconds of editing"), ("120", "2 minutes of editing"),
                            ("300", "5 minutes of editing"),
                        ], "30"),
                    M(
                        "files.snapshotKeep", "Keep snapshots for",
                        [("1", "1 day"), ("7", "7 days"), ("30", "30 days")], "7"),
                    G("files.usage", "Using", "snapshotUsage"),
                    B("files.openRecovery", "Open Recovery…", "Open"),
                    B("files.deleteSnapshots", "Delete all snapshots", "Delete…"),
                ]),
            sec(
                "Security", 1,
                [
                    T("files.keychain", "Store document passwords in Keychain", true),
                    M(
                        "files.lockAfter", "Lock encrypted documents after",
                        [("0", "Never"), ("5", "5 min idle"), ("15", "15 min idle"), ("60", "1 hour idle")], "15"),
                    T("files.touchID", "Require Touch ID to open encrypted documents", false),
                ], footnote: "Encryption is AES-256 per package. A forgotten password cannot be recovered."),
            sec("", 1, [G("files.recoveryList", "", "recoveryList")]),
        ])

    // MARK: 5 AI (artboard 29)

    static let ai = SettingPane(
        id: "ai", glyph: "✦", title: "AI", tint: "#0F7F7A",
        subtitle: "Every model runs on this Mac. OpenNexus v1 offers no cloud models, including Private Cloud Compute.",
        sections: [
            sec(
                "Model", 0,
                [G("ai.models", "", "aiModels", nil, ["apple", "on-device", "mlx", "local server", "ollama"])]),
            sec(
                "", 0,
                [
                    T("ai.suggestAfterPause", "Suggest ideas after a pause when creating nodes", false),
                    S(
                        "ai.depth", "AI panel depth", [("quick", "Quick"), ("balanced", "Balanced"), ("deep", "Deep")],
                        "balanced"),
                    T("ai.discussionDefault", "Start AI chats in Discussion mode (never edits the map)", false),
                    I("ai.frameworks", "Image Playground for stickers · Translation for maps", "on-device"),
                    T("ai.markAI", "Mark AI-created nodes with ✦ until edited", true),
                    T("ai.statusChip", "Show model status chip in the toolbar", true),
                    K("ai.ghostKeys", "Ghost suggestions", ["⌥Space", "✦ Space"]),
                ]),
        ])

    // MARK: 6 Shortcuts (artboard 08)

    static let shortcuts = SettingPane(
        id: "shortcuts", glyph: "⌘", title: "Shortcuts", tint: "#5850EC",
        subtitle: "",
        sections: [
            sec(
                "Profile", 0,
                [
                    G(
                        "shortcuts.profile", "Profile", "profiles", .string("opennexus"),
                        ["opennexus", "hyper-first", "vim", "outliner", "xmind"]),
                    T(
                        "shortcuts.hyper", "Hyper key", true,
                        "Caps Lock acts as ⌃⌥⇧⌘ pressed together, giving OpenNexus a clash-free namespace.",
                        ["caps lock"]),
                    M(
                        "shortcuts.hyperKey", "Hyper key source",
                        [("capsLock", "Caps Lock"), ("rightOption", "Right Option")], "capsLock"),
                    S("shortcuts.hyperTap", "Tap Hyper alone", [("esc", "Esc"), ("nothing", "Nothing")], "esc"),
                ]),
            sec(
                "Shortcuts", 0,
                [
                    G(
                        "shortcuts.table", "", "shortcutsTable", nil,
                        ["keys", "keyboard", "bindings", "conflict", "record"])
                ]),
        ])

    // MARK: 7 Export (artboard 39)

    static let export = SettingPane(
        id: "export", glyph: "↗", title: "Export", tint: "#C25E00",
        subtitle: "Defaults the Export sheet (⇧⌘E) opens with. Every export remembers its last settings per format.",
        sections: [
            sec(
                "Image frame · PNG & JPEG", 0,
                [
                    G(
                        "export.frame", "Frame", "frames", .string("none"),
                        ["none", "soft shadow", "window", "gradient mat", "paper", "dark mat"]),
                    S(
                        "export.aspect", "Aspect ratio",
                        [("fit", "Fit"), ("1:1", "1:1"), ("4:3", "4:3"), ("16:9", "16:9"), ("9:16", "9:16")], "fit"),
                    G("export.matColor", "Mat colour", "matColor", .string("#E9E6FF")),
                ]),
            sec(
                "Images", 0,
                [
                    S("export.scale", "Scale", [("1", "1×"), ("2", "2×"), ("3", "3×"), ("4", "4×")], "2"),
                    S(
                        "export.background", "Background",
                        [("theme", "Theme"), ("white", "White"), ("transparent", "Transparent")], "theme"),
                    R("export.padding", "Padding", 48, "px", 0, 400, 4),
                    T("export.split", "Split by main branch", false, "One image per first-level branch"),
                    M(
                        "export.colorProfile", "Colour profile", [("sRGB", "sRGB"), ("displayP3", "Display P3")],
                        "displayP3"),
                ]),
            sec(
                "PDF & print", 1,
                [
                    S(
                        "export.pdfContent", "Content",
                        [("canvas", "Canvas"), ("outline", "Outline"), ("slides", "Slides")], "canvas"),
                    M(
                        "export.pageSize", "Page size",
                        [("A4", "A4"), ("Letter", "Letter"), ("A3", "A3"), ("Legal", "Legal")],
                        Locale.current.region?.identifier == "US" ? "Letter" : "A4", "Follows your region"),
                    S("export.pdfFit", "Fit", [("fit", "Fit to page"), ("tile", "Tile at actual size")], "fit"),
                    T("export.notesAppendix", "Notes as appendix", true),
                    T("export.pdfLinks", "Clickable topic links", true),
                ]),
            sec(
                "Text & structure", 1,
                [
                    S(
                        "export.markdown", "Markdown", [("headings", "Headings"), ("bullets", "Nested bullets")],
                        "headings"),
                    T("export.markdownNotes", "Include notes", true),
                    T("export.markdownMermaid", "Add a Mermaid block", false),
                    M(
                        "export.flavour", "Mermaid / PlantUML flavour",
                        [
                            ("auto", "Auto from type"), ("mindmap", "mindmap"), ("flowchart", "flowchart"),
                            ("sequence", "sequence"), ("class", "class"),
                        ], "auto"),
                    S("export.json", "JSON", [("pretty", "Pretty"), ("compact", "Compact")], "pretty"),
                ]),
            sec(
                "Before anything leaves", 1,
                [
                    S(
                        "export.masking", "Data masking", [("ask", "Ask"), ("always", "Always"), ("never", "Never")],
                        "ask", "Hides emails, keys and names in the export"),
                    T("export.stripAI", "Strip AI provenance metadata", false),
                    I(
                        "export.watermark", "Watermark", "Never",
                        "Xmind adds “Presented with Xmind” unless removed. OpenNexus exports never carry a watermark."),
                ]),
        ])

    // MARK: 8 Integrations (artboard 40)

    static let integrations = SettingPane(
        id: "integrations", glyph: "⇄", title: "Integrations", tint: "#7A4CC2",
        subtitle: "Ways in and out of OpenNexus without leaving the Mac.",
        sections: [
            sec(
                "Quick Capture", 0,
                [
                    K("integrations.captureKey", "Global shortcut", ["✦ N"]),
                    T("integrations.captureAtLogin", "Start at login", false, "Lives in the menu bar"),
                    M(
                        "integrations.captureTarget", "Send captures to",
                        [("inbox", "Inbox map"), ("last", "Last document"), ("ask", "Ask each time")], "inbox"),
                    S(
                        "integrations.captureMultiline", "Multi-line text becomes",
                        [("items", "Inbox items"), ("map", "A new map")], "items", "Indented lines keep their hierarchy"
                    ),
                ]),
            sec(
                "macOS", 0,
                [
                    T(
                        "integrations.shortcuts", "Shortcuts & Siri actions", true,
                        "Create from clipboard, add to inbox, export, convert"),
                    T("integrations.services", "Services menu: New Map from Selection", true),
                    T("integrations.share", "Share extension", true, "Send text, links and images to a map"),
                    T(
                        "integrations.clipper", "Safari web clipper", true,
                        "Summarises the page on-device into a branch"),
                    T("integrations.spotlight", "Spotlight indexing of node text", true),
                    M(
                        "integrations.codeLinks", "Open code links in",
                        [
                            ("xcode", "Xcode"), ("vscode", "Visual Studio Code"), ("cursor", "Cursor"), ("zed", "Zed"),
                            ("default", "Default app"),
                        ], "xcode"),
                ]),
            sec(
                "Agents · MCP & CLI", 1,
                [
                    T("integrations.mcp", "Local MCP server", false, "Off by default. No network port; stdio only"),
                    B("integrations.folders", "Allowed folders", "Edit…", "No folders yet"),
                    S(
                        "integrations.mcpRead", "Read maps", [("allow", "Allow"), ("ask", "Ask"), ("block", "Block")],
                        "allow"),
                    S(
                        "integrations.mcpEdit", "Edit maps", [("allow", "Allow"), ("ask", "Ask"), ("block", "Block")],
                        "ask"),
                    S(
                        "integrations.mcpFiles", "Create & export files",
                        [("allow", "Allow"), ("ask", "Ask"), ("block", "Block")], "ask"),
                    B("integrations.cli", "Command-line tool", "Install…", "Installs /usr/local/bin/nexus"),
                ],
                footnote:
                    "Every agent edit is one undo step and is marked with the ✦ provenance sparkle."
            ),
            sec(
                "", 1,
                [
                    G(
                        "integrations.agentCard", "Connect an agent", "agentCard", nil,
                        ["claude", "codex", "cursor", "mcp client", "connect an agent"])
                ]),
        ])

    // MARK: 9 Privacy & Data (artboard 41)

    static let privacy = SettingPane(
        id: "privacy", glyph: "◐", title: "Privacy & Data", tint: "#17171C",
        subtitle:
            "Local by default. Everything that could leave the Mac is listed here and is off unless you turn it on.",
        sections: [
            sec(
                "Network activity · last 7 days", 0,
                [G("privacy.networkLog", "", "networkLog", nil, ["network", "requests", "telemetry"])]),
            sec(
                "Diagnostics", 0,
                [
                    T(
                        "privacy.usageStats", "Share anonymous usage statistics", false,
                        "Off by default. Never includes document content", ["telemetry", "analytics"], locked: noNetwork
                    ),
                    S(
                        "privacy.crashReports", "Crash reports",
                        [("ask", "Ask"), ("send", "Send"), ("never", "Never")], "never", nil, [], locked: noNetwork),
                    T(
                        "privacy.linkPreviews", "Fetch link previews and favicons", false,
                        "Makes a web request per link", [], locked: noNetwork),
                ], footnote: "Unavailable by design: OpenNexus v1 has no network permission."),
            sec(
                "AI data", 0,
                [
                    T("privacy.aiReadNotes", "Let AI read notes and attachments", true),
                    S(
                        "privacy.keepChats", "Keep AI chats",
                        [("document", "In document"), ("mac", "This Mac"), ("none", "Don’t keep")], "document"),
                    T("privacy.removeChatsOnExport", "Remove AI chats when exporting", true),
                    B("privacy.clearChats", "Clear all AI chats", "Clear…"),
                ]),
            sec(
                "Data masking", 1,
                [
                    T("privacy.maskEmails", "Email addresses", true),
                    T("privacy.maskPhones", "Phone numbers", true),
                    T("privacy.maskKeys", "API keys, tokens and secrets", true),
                    T("privacy.maskNames", "Person names", false),
                    X(
                        "privacy.maskPatterns", "Custom patterns", "",
                        "Regex, e.g. ticket or account IDs (one per line)"),
                    M(
                        "privacy.maskGlyph", "Replace with",
                        [("••••", "••••"), ("████", "████"), ("[redacted]", "[redacted]")], "••••"),
                ]),
            sec("Data masking preview", 1, [G("privacy.maskPreview", "", "maskPreview")]),
        ])

    // MARK: 10 Accessibility (artboard 42)

    static let accessibility = SettingPane(
        id: "accessibility", glyph: "◎", title: "Accessibility", tint: "#1E6FB8",
        subtitle: "OpenNexus follows macOS settings first; these refine or override them.",
        sections: [
            sec(
                "Vision", 0,
                [
                    T(
                        "accessibility.systemTextSize", "Follow system text size in chrome", true,
                        "Dynamic Type for sidebars, panels and menus"),
                    M(
                        "accessibility.minText", "Canvas text never smaller than",
                        [
                            ("10", "10 pt at 100%"), ("12", "12 pt at 100%"), ("14", "14 pt at 100%"),
                            ("16", "16 pt at 100%"),
                        ], "12"),
                    T("accessibility.highContrast", "Use High Contrast theme with Increase Contrast", true),
                    T(
                        "accessibility.patterns", "Patterns as well as colour", true,
                        "Trust levels, node types and risk get shapes or hatching"),
                    S("accessibility.ring", "Selection ring", [("2", "2 pt"), ("3", "3 pt"), ("4", "4 pt")], "3"),
                ]),
            sec(
                "Motion & transparency", 0,
                [
                    S(
                        "accessibility.reduceMotion", "Reduce motion",
                        [("system", "System"), ("on", "On"), ("off", "Off")], "system",
                        "150 ms cross-fades replace movement"),
                    S(
                        "accessibility.reduceTransparency", "Reduce transparency",
                        [("system", "System"), ("on", "On"), ("off", "Off")], "system",
                        "Opaque chrome instead of Liquid Glass"),
                    T("accessibility.pauseShimmer", "Pause shimmer on AI ghosts", false),
                ]),
            sec(
                "VoiceOver", 0,
                [
                    T("accessibility.announceLevel", "Announce level and child count", true),
                    T("accessibility.announceConnect", "Announce Connect mode targets", true),
                    T("accessibility.speakHints", "Speak shortcut hints", false, "e.g. “Tab adds a child”"),
                    S(
                        "accessibility.readEdges", "Read edges", [("source", "With source"), ("demand", "On demand")],
                        "source"),
                ]),
            sec(
                "Keyboard", 1,
                [
                    T("accessibility.fullKeyboard", "Full keyboard access to panels", true),
                    T("accessibility.stickyHyper", "Sticky Hyper", false, "Press Hyper, release, then the key"),
                    R("accessibility.cheatDelay", "Hold ⌘ cheat sheet delay", 1.0, "s", 0.3, 3, 0.1),
                    S(
                        "accessibility.coachSize", "Keycap coach size", [("regular", "Regular"), ("large", "Large")],
                        "regular"),
                ]),
            sec("VoiceOver preview", 1, [G("accessibility.voPreview", "", "voiceOverPreview")]),
        ])
}
