import AppKit
import NexusCore
import NexusLayout
import NexusTheme
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Map tab (FMT-3)

/// A skeleton pairs a structure with a node style and a branch line.
public struct Skeleton: Sendable, Identifiable, Equatable {
    public var id: String { "\(structure.rawValue)|\(nodeStyle.rawValue)|\(line)" }
    public var name: String
    public var structure: LayoutStructure
    public var nodeStyle: NodeStyle
    public var line: String
    public var icon: String

    static let icons: [String: String] = [
        "mindmap":
            "M28 20 m-6 0 a6 4 0 1 0 12 0 a6 4 0 1 0 -12 0 M34 20 L46 10 M34 20 L48 20 M34 20 L46 30 M22 20 L10 10 M22 20 L8 30",
        "logic": "M4 20 h10 M14 20 V8 h10 M14 20 h10 M14 20 V32 h10 M28 8 h20 M28 20 h20 M28 32 h20",
        "org":
            "M22 4 h12 v8 h-12 z M28 12 v6 M10 18 h36 M10 18 v6 M28 18 v6 M46 18 v6 M4 24 h12 v8 H4 z M22 24 h12 v8 H22 z M40 24 h12 v8 H40 z",
        "timeline": "M4 20 h48 M10 14 h10 v12 h-10 z M26 14 h10 v12 h-10 z M42 14 h10 v12 h-10 z",
        "fishbone": "M4 20 h38 M42 14 L50 20 L42 26 M16 20 L10 6 M30 20 L24 6 M16 20 L10 34 M30 20 L24 34",
        "matrix": "M4 4 h22 v14 H4 z M30 4 h22 v14 H30 z M4 22 h22 v14 H4 z M30 22 h22 v14 H30 z",
        "brace": "M10 20 q-6 0 -6 -6 v-6 M10 20 q-6 0 -6 6 v6 M14 6 h14 M14 20 h14 M14 34 h14 M32 6 h18",
        "tree": "M28 4 v32 M28 10 h-16 M28 20 h18 M28 30 h-14",
        "treeTable": "M8 6 h40 v28 H8 z M8 14 h40 M20 6 v28",
    ]

    /// FMT-3's nine, in its order.
    public static let featured: [Skeleton] = [
        Skeleton(
            name: "Mind Map", structure: .mindmapBalanced, nodeStyle: .outline, line: "curved", icon: icons["mindmap"]!),
        Skeleton(name: "Logic Chart", structure: .logicRight, nodeStyle: .soft, line: "curved", icon: icons["logic"]!),
        Skeleton(name: "Org Chart", structure: .orgDown, nodeStyle: .outline, line: "elbow", icon: icons["org"]!),
        Skeleton(
            name: "Timeline", structure: .timelineHorizontal, nodeStyle: .capsule, line: "straight",
            icon: icons["timeline"]!),
        Skeleton(
            name: "Fishbone", structure: .fishboneLeft, nodeStyle: .outline, line: "straight", icon: icons["fishbone"]!),
        Skeleton(name: "Matrix", structure: .matrix, nodeStyle: .solid, line: "straight", icon: icons["matrix"]!),
        Skeleton(name: "Brace Map", structure: .braceRight, nodeStyle: .minimal, line: "curved", icon: icons["brace"]!),
        Skeleton(name: "Tree Chart", structure: .treeDown, nodeStyle: .underline, line: "elbow", icon: icons["tree"]!),
        Skeleton(
            name: "Tree Table", structure: .treeTable, nodeStyle: .brutal, line: "elbow", icon: icons["treeTable"]!),
    ]

    /// The full gallery of 24 (README §14: derived from structures × node styles × lines).
    public static let gallery: [Skeleton] =
        featured + [
            Skeleton(
                name: "Mind Map · Soft", structure: .mindmapBalanced, nodeStyle: .soft, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: "Mind Map · Underline", structure: .mindmapBalanced, nodeStyle: .underline, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: "Mind Map · Sketch", structure: .mindmapBalanced, nodeStyle: .sketch, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: "Mind Map · Glow", structure: .mindmapBalanced, nodeStyle: .glow, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: "Mind Map · Minimal", structure: .mindmapBalanced, nodeStyle: .minimal, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: "Right Map · Capsule", structure: .mindmapRight, nodeStyle: .capsule, line: "curved",
                icon: icons["mindmap"]!),
            Skeleton(
                name: "Logic · Outline", structure: .logicRight, nodeStyle: .outline, line: "rounded",
                icon: icons["logic"]!),
            Skeleton(
                name: "Logic · Brutal", structure: .logicRight, nodeStyle: .brutal, line: "elbow", icon: icons["logic"]!
            ),
            Skeleton(
                name: "Logic · Underline", structure: .logicRight, nodeStyle: .underline, line: "curved",
                icon: icons["logic"]!),
            Skeleton(
                name: "Logic Left · Solid", structure: .logicLeft, nodeStyle: .solid, line: "curved",
                icon: icons["logic"]!),
            Skeleton(name: "Org · Solid", structure: .orgDown, nodeStyle: .solid, line: "rounded", icon: icons["org"]!),
            Skeleton(
                name: "Org · Capsule", structure: .orgDown, nodeStyle: .capsule, line: "elbow", icon: icons["org"]!),
            Skeleton(
                name: "Tree · Minimal", structure: .treeDown, nodeStyle: .minimal, line: "straight",
                icon: icons["tree"]!),
            Skeleton(
                name: "Timeline · Solid", structure: .timelineHorizontal, nodeStyle: .solid, line: "straight",
                icon: icons["timeline"]!),
            Skeleton(
                name: "Fishbone · Brutal", structure: .fishboneLeft, nodeStyle: .brutal, line: "straight",
                icon: icons["fishbone"]!),
        ]
}

struct MapTab: View {
    var controller: CanvasController
    @State private var showingGallery = false
    @State private var editingTheme: Theme?
    @State private var editingPalette: ColorPalette?
    @State private var renaming: Theme?
    @State private var newName = ""

    var style: CanvasStyle { controller.canvas.style }
    var layout: CanvasLayout { controller.canvas.layout }

    func setStyle(_ name: String, _ body: @escaping (inout CanvasStyle) -> Void) {
        controller.updateCanvasStyle(name, body)
    }

    func apply(_ s: Skeleton) {
        controller.applySkeleton(s)
    }

    var body: some View {
        skeleton
        Divider()
        nodeStyles
        Divider()
        themes
        Divider()
        colourTheme
        Divider()
        canvasSection
        Divider()
        mapStyle
        Divider()
        advanced
    }

    var skeleton: some View {
        PanelSection(
            "Skeleton", key: "skeleton",
            accessory: {
                Button("All \(Skeleton.gallery.count) ›") { showingGallery = true }
                    .buttonStyle(.plain)
                    .font(.chrome(12))
                    .foregroundStyle(Color.accentColor)
            }
        ) {
            skeletonGrid(Skeleton.featured)
                .sheet(isPresented: $showingGallery) {
                    VStack(alignment: .leading) {
                        Text("Skeletons").font(.title2.bold())
                        Text("Structure + node style + branch line.").foregroundStyle(.secondary)
                        ScrollView { skeletonGrid(Skeleton.gallery, labels: true) }
                        HStack {
                            Spacer()
                            Button("Done") { showingGallery = false }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(20)
                    .frame(width: 520, height: 560)
                }
        }
    }

    func skeletonGrid(_ items: [Skeleton], labels: Bool = false) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(items) { s in
                let on = layout.structure == s.structure && style.nodeStyle == s.nodeStyle.rawValue
                Tile(selected: on, height: labels ? 76 : 60) {
                    apply(s)
                } content: {
                    VStack(spacing: 4) {
                        PathIcon(d: s.icon, lineWidth: 1.4).frame(width: 52, height: 36)
                        if labels { Text(s.name).font(.chrome(11)).lineLimit(1) }
                    }
                }
                .help(s.name)
                .accessibilityLabel(s.name)
            }
        }
    }

    var nodeStyles: some View {
        PanelSection(
            "Node style", key: "nodestyle",
            accessory: {
                Text("\(controller.bindings(for: .cycleNodeStyle).first?.glyphs ?? "") cycles")
                    .font(.chrome(11)).foregroundStyle(.secondary)
            }
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(NodeStyle.allCases) { ns in
                    Tile(selected: style.nodeStyle == ns.rawValue, height: 56) {
                        controller.setNodeStyle(ns)
                    } content: {
                        VStack(spacing: 6) {
                            NodeStyleSwatch(style: ns, theme: controller.theme).frame(width: 48, height: 16)
                            Text(ns.name).font(.chrome(11))
                        }
                    }
                    .help(ns.summary)
                }
            }
        }
    }

    var themes: some View {
        let lib = controller.library
        return PanelSection("Themes", key: "themes") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Theme.builtIn + lib.themes) { t in
                    Button {
                        controller.setTheme(t.id)
                    } label: {
                        VStack(spacing: 4) {
                            ThemeSwatch(theme: t)
                                .frame(height: 30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(style.theme == t.id ? Color.accentColor : .clear, lineWidth: 2))
                            Text(t.name).font(.chrome(10)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Theme \(t.name)")
                    .accessibilityAddTraits(style.theme == t.id ? .isSelected : [])
                }
            }
            if !lib.themes.isEmpty {
                Text("CUSTOM THEMES").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary).padding(
                    .top, 6)
                ForEach(lib.themes) { t in
                    HStack {
                        ThemeSwatch(theme: t).frame(width: 18, height: 18).clipShape(Circle())
                        Text(t.name).font(.chrome(13))
                        Spacer()
                        Button("Edit") { editingTheme = t }.buttonStyle(.plain).foregroundStyle(.secondary)
                        Button("Rename") {
                            renaming = t
                            newName = t.name
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        Button("Duplicate") { controller.saveCurrentAsTheme(named: t.name + " copy", base: t) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Button("Delete") { controller.deleteTheme(t.id) }.buttonStyle(.plain).foregroundStyle(
                            .secondary)
                    }
                    .font(.chrome(11))
                }
            }
            HStack {
                Button("+ Save current as theme") {
                    var t = controller.theme
                    t.id = ""
                    t.name = "New Theme"
                    t.palette = controller.styleEnvironment.palette
                    editingTheme = t
                }
                .buttonStyle(.bordered)
                Button("Import…") { importTheme() }.buttonStyle(.bordered)
            }
            .sheet(item: $editingTheme) { t in
                ThemeBuilder(controller: controller, theme: t) { editingTheme = nil }
            }
            .alert("Rename Theme", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if var t = renaming {
                        t.name = newName
                        controller.saveTheme(t)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeCodec.fileExtension) ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
            var t = try? ThemeCodec.decode(data)
        else { return }
        if Theme.builtIn.contains(where: { $0.id == t.id }) { t.id = "custom-\(t.id)" }
        controller.saveTheme(t)
        controller.setTheme(t.id)
    }

    var colourTheme: some View {
        let lib = controller.library
        let palettes = ColorPalette.builtIn + lib.palettes
        return PanelSection("Colour theme", key: "colour") {
            Segments(options: ColorThemeMode.allCases.map { ($0.rawValue, $0.title) }, selection: style.colorTheme) {
                v in
                setStyle("Colour Theme") { $0.colorTheme = v }
            }
            Button {
                setStyle("Colour Theme") { $0.palette = "theme" }
            } label: {
                paletteRow(name: "Theme colours", colors: controller.theme.palette, on: style.palette == "theme")
            }
            .buttonStyle(.plain)
            ForEach(palettes) { p in
                Button {
                    setStyle("Colour Theme") { $0.palette = p.id }
                } label: {
                    paletteRow(name: p.name, colors: p.colors, on: style.palette == p.id)
                }
                .buttonStyle(.plain)
            }
            PanelToggle(label: "Colored branch", isOn: style.coloredBranch) { v in
                setStyle("Colored Branch") { $0.coloredBranch = v }
            }
            PanelRow(label: "Single branch colour when off") {
                ColorPicker(
                    "Ink",
                    selection: hexBinding(style.singleColor, fallback: controller.theme.ink2) { hex in
                        setStyle("Single Colour") { $0.singleColor = hex }
                    }
                )
                .font(.chrome(12))
            }
            PanelRow(label: "Reshuffle") {
                Button {
                    controller.perform(.smartColor)
                } label: {
                    Keycap(text: controller.bindings(for: .smartColor).first?.glyphs ?? "⇧⌘R")
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("MY COLOURS").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    editingPalette = ColorPalette(
                        id: "", name: "My colours", colors: Array(controller.styleEnvironment.palette.prefix(6)))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("New colour theme")
            }
            .padding(.top, 4)
            ForEach(lib.palettes) { p in
                Button {
                    editingPalette = p
                } label: {
                    paletteRow(name: p.name, colors: p.colors, on: false)
                }
                .buttonStyle(.plain)
            }
            .sheet(item: $editingPalette) { p in
                ColourThemeEditor(controller: controller, palette: p) { editingPalette = nil }
            }
        }
    }

    func paletteRow(name: String, colors: [RGBA], on: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(colors.prefix(6).enumerated()), id: \.offset) { _, c in Rectangle().fill(c.color) }
            }
            .frame(width: 150, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name).font(.chrome(13))
            Spacer()
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.1) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.accentColor : Color(nsColor: .separatorColor))
        )
        .contentShape(Rectangle())
    }

    static let backgrounds: [String?] = [nil, "#F4EFE4", "#121317", "#0D3560"]
    static let cjkFonts = ["PingFang SC", "PingFang TC", "Hiragino Sans", "Apple SD Gothic Neo", "Songti SC"]

    var canvasSection: some View {
        PanelSection("Canvas", key: "canvas") {
            PanelRow(label: "Background") {
                HStack(spacing: 6) {
                    ForEach(Array(Self.backgrounds.enumerated()), id: \.offset) { _, hex in
                        let c = hex.flatMap(RGBA.init(hexString:)) ?? controller.theme.canvas
                        Button {
                            setStyle("Background") { $0.background = hex }
                        } label: {
                            Circle().fill(c.color).frame(width: 20, height: 20)
                                .overlay(
                                    Circle().strokeBorder(
                                        style.background == hex ? Color.primary : Color(nsColor: .separatorColor),
                                        lineWidth: style.background == hex ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex == nil ? "Theme background" : "Background \(hex!)")
                    }
                    ColorPicker(
                        "",
                        selection: hexBinding(style.background, fallback: controller.theme.canvas) { hex in
                            setStyle("Background") { $0.background = hex }
                        }
                    )
                    .labelsHidden()
                }
            }
            PanelRow(label: "Pattern") {
                Segments(
                    options: [("plain", "Plain"), ("dots", "Dots"), ("lines", "Lines")],
                    selection: style.pattern ?? patternName
                ) { v in
                    setStyle("Pattern") { $0.pattern = v }
                }
                .frame(maxWidth: 170)
            }
            PanelRow(label: "Global font") {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.font ?? "system" },
                        set: { v in setStyle("Global Font") { $0.font = v == "system" ? nil : v } })
                ) {
                    ForEach(StyleTab.fonts, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            PanelRow(label: "CJK font") {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.cjkFont ?? "PingFang SC" }, set: { v in setStyle("CJK Font") { $0.cjkFont = v } })
                ) {
                    ForEach(Self.cjkFonts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            PanelRow(label: "Branch line width") {
                Segments(
                    options: [("thin", "Thin"), ("regular", "Regular"), ("bold", "Bold"), ("taper", "Taper")],
                    selection: style.lineWidth ?? "regular"
                ) { v in
                    setStyle("Branch Line Width") { $0.lineWidth = v == "regular" ? nil : v }
                }
                .frame(maxWidth: 200)
            }
        }
    }

    var patternName: String {
        switch controller.theme.grid {
        case .none: "plain"
        case .dots: "dots"
        case .lines: "lines"
        }
    }

    var mapStyle: some View {
        PanelSection("Map style", key: "mapstyle") {
            PanelToggle(label: "Auto balance map", isOn: style.autoBalance) { v in
                setStyle("Auto Balance") { $0.autoBalance = v }
            }
            PanelToggle(label: "Compact map", isOn: style.compact) { v in setStyle("Compact Map") { $0.compact = v } }
            PanelToggle(label: "Justify topic alignment", isOn: style.justify) { v in
                setStyle("Justify") { $0.justify = v }
            }
        }
    }

    var advanced: some View {
        PanelSection("Advanced layout", key: "advanced") {
            PanelToggle(label: "Free layout for this canvas", isOn: layout.mode == .free) { v in
                controller.updateLayout("Free Layout") { $0.mode = v ? .free : .auto }
            }
            PanelToggle(label: "Branch free-positioning", isOn: layout.branchFreePositioning) { v in
                controller.updateLayout("Branch Free-Positioning") { $0.branchFreePositioning = v }
            }
            PanelToggle(label: "Flexible floating topics", isOn: layout.flexibleFloating) { v in
                controller.updateLayout("Flexible Floating Topics") { $0.flexibleFloating = v }
            }
            PanelToggle(label: "Allow topic overlap", isOn: layout.allowOverlap) { v in
                controller.updateLayout("Allow Overlap") { $0.allowOverlap = v }
            }
        }
    }
}

/// A miniature of a node style (FMT-3 node style grid).
struct NodeStyleSwatch: View {
    let style: NodeStyle
    let theme: Theme

    var body: some View {
        let env = StyleEnvironment(
            theme: theme,
            canvasStyle: {
                var c = CanvasStyle(); c.nodeStyle = style.rawValue; return c
            }())
        let a = StyleResolver.appearance(
            role: .main, depth: 1, node: nil, branch: theme.palette.first ?? theme.ring, env: env)
        let fill: Color = a.fill.representative?.color ?? .clear
        Group {
            if a.isUnderline {
                VStack {
                    Spacer(); Rectangle().fill(a.borderColor.color).frame(height: 2)
                }
            } else if a.border == .none && a.fill == .none {
                VStack {
                    Spacer(); Rectangle().fill(a.text.color).frame(height: 1).opacity(0.5)
                }
            } else {
                RoundedRectangle(cornerRadius: min(8, a.cornerRadius / 2))
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: min(8, a.cornerRadius / 2))
                            .strokeBorder(
                                a.border == .none ? .clear : a.borderColor.color, lineWidth: min(2, a.borderWidth))
                    )
                    .shadow(
                        color: a.shadow?.color.color ?? .clear, radius: (a.shadow?.radius ?? 0) / 3,
                        x: (a.shadow?.dx ?? 0) / 2, y: (a.shadow?.dy ?? 0) / 2)
            }
        }
    }
}

/// A theme swatch: canvas with three branch dots (theme sheet launch set).
struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(theme.canvas.color)
            .overlay(
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(theme.branchColor(index: i).color).frame(
                            width: 7, height: 7)
                    }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
    }
}

// MARK: - Data tab

struct DataTab: View {
    var controller: CanvasController

    var fields: [MetadataField] { controller.canvas.nodes[controller.selection.primary]?.metadata ?? [] }

    func update(_ body: @escaping (inout [MetadataField]) -> Void) {
        let id = controller.selection.primary
        controller.perform("Edit Fields") { e in e.update(id) { body(&$0.metadata) } }
    }

    var body: some View {
        PanelSection("Metadata · pin to show on node", key: "metadata") {
            ForEach(Array(fields.enumerated()), id: \.offset) { i, f in
                HStack {
                    TextField("key", text: Binding(get: { f.key }, set: { v in update { $0[i].key = v } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.chrome(12, design: .monospaced))
                        .frame(width: 100)
                    TextField("value", text: Binding(get: { f.value }, set: { v in update { $0[i].value = v } }))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        update { $0[i].pinned.toggle() }
                    } label: {
                        Image(systemName: f.pinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(f.pinned ? "Unpin" : "Pin")
                    Button {
                        update { $0.remove(at: i) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove field")
                }
            }
            Button("+ Add field") { update { $0.append(MetadataField(key: "owner", value: "")) } }
                .buttonStyle(.bordered)
        }
        Divider()
        PanelSection("Links & attachments", key: "links") {
            let n = controller.canvas.nodes[controller.selection.primary]
            if let link = n?.link {
                Text(link).font(.chrome(12)).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Add a hyperlink with ⇧⌘K or drop a file on the topic.")
                    .font(.chrome(12)).foregroundStyle(.secondary)
            }
        }
    }
}
