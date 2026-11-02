import NexusCore
import NexusLayout
import NexusScene
import NexusTheme
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Map tab (FMT-3)

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
            Loc.t("Skeleton"), key: "skeleton",
            accessory: {
                Button(Loc.f("All %lld ›", Skeleton.gallery.count)) { showingGallery = true }
                    .buttonStyle(.plain)
                    .font(.chrome(12))
                    .foregroundStyle(Color.accentColor)
            }
        ) {
            skeletonGrid(Skeleton.featured)
                .sheet(isPresented: $showingGallery) {
                    VStack(alignment: .leading) {
                        Text("Skeletons").font(.title2.bold())
                        Text("Structure + node style + branch line.").foregroundStyle(.chromeSecondary)
                        ScrollView { skeletonGrid(Skeleton.gallery, labels: true) }.accessibilityLabel(
                            Loc.t("Skeletons"))
                        HStack {
                            Spacer()
                            Button("Done") { showingGallery = false }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(20)
                    .fixedWidth(520, height: 560)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skeleton")
    }

    var nodeStyles: some View {
        PanelSection(
            Loc.t("Node style"), key: "nodestyle",
            accessory: {
                Text(Loc.f("%@ cycles", controller.bindings(for: .cycleNodeStyle).first?.glyphs ?? ""))
                    .font(.chrome(11)).foregroundStyle(.chromeSecondary)
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Node style")
        }
    }

    var themes: some View {
        let lib = controller.library
        return PanelSection(Loc.t("Themes"), key: "themes") {
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
                    .accessibilityLabel(Loc.f("Theme %@", t.name))
                    .accessibilityAddTraits(style.theme == t.id ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Themes")
            if !lib.themes.isEmpty {
                Text("CUSTOM THEMES").font(.chrome(11, weight: .semibold)).foregroundStyle(.chromeSecondary).padding(
                    .top, 6)
                ForEach(lib.themes) { t in
                    HStack {
                        ThemeSwatch(theme: t).frame(width: 18, height: 18).clipShape(Circle())
                        Text(t.name).font(.chrome(13))
                        Spacer()
                        Button("Edit") { editingTheme = t }.buttonStyle(.plain).foregroundStyle(.chromeSecondary)
                        Button("Rename") {
                            renaming = t
                            newName = t.name
                        }
                        .buttonStyle(.plain).foregroundStyle(.chromeSecondary)
                        Button("Duplicate") { controller.saveCurrentAsTheme(named: t.name + " copy", base: t) }
                            .buttonStyle(.plain).foregroundStyle(.chromeSecondary)
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
        let types = [UTType(filenameExtension: ThemeCodec.fileExtension) ?? .json, .json]
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importTheme(from: url)
        #else
        PlatformOpen.choose(types) { urls in
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importTheme(from: url)
        }
        #endif
    }

    func importTheme(from url: URL) {
        guard let data = try? Data(contentsOf: url), var t = try? ThemeCodec.decode(data) else { return }
        if Theme.builtIn.contains(where: { $0.id == t.id }) { t.id = "custom-\(t.id)" }
        controller.saveTheme(t)
        controller.setTheme(t.id)
    }

    var colourTheme: some View {
        let lib = controller.library
        let palettes = ColorPalette.builtIn + lib.palettes
        return PanelSection(Loc.t("Colour theme"), key: "colour") {
            Segments(options: ColorThemeMode.allCases.map { ($0.rawValue, $0.title) }, selection: style.colorTheme) {
                v in
                setStyle(Loc.t("Colour Theme")) { $0.colorTheme = v }
            }
            Button {
                setStyle(Loc.t("Colour Theme")) { $0.palette = "theme" }
            } label: {
                paletteRow(name: Loc.t("Theme colours"), colors: controller.theme.palette, on: style.palette == "theme")
            }
            .buttonStyle(.plain)
            // An imported map's own branch colours (D210).
            let own = style.colors.compactMap(RGBA.init(hexString:))
            if !own.isEmpty {
                Button {
                    setStyle(Loc.t("Colour Theme")) { $0.palette = "canvas" }
                } label: {
                    paletteRow(name: Loc.t("This map’s colours"), colors: own, on: style.palette == "canvas")
                }
                .buttonStyle(.plain)
            }
            ForEach(palettes) { p in
                Button {
                    setStyle(Loc.t("Colour Theme")) { $0.palette = p.id }
                } label: {
                    paletteRow(name: p.name, colors: p.colors, on: style.palette == p.id)
                }
                .buttonStyle(.plain)
            }
            PanelToggle(label: Loc.t("Colored branch"), isOn: style.coloredBranch) { v in
                setStyle(Loc.t("Colored Branch")) { $0.coloredBranch = v }
            }
            PanelRow(label: Loc.t("Single branch colour when off")) {
                ColorPicker(
                    Loc.t("Ink"),
                    selection: hexBinding(style.singleColor, fallback: controller.theme.ink2) { hex in
                        setStyle(Loc.t("Single Colour")) { $0.singleColor = hex }
                    }
                )
                .font(.chrome(12))
            }
            PanelRow(label: Loc.t("Reshuffle")) {
                Button {
                    controller.perform(.smartColor)
                } label: {
                    Keycap(text: controller.bindings(for: .smartColor).first?.glyphs ?? "⇧⌘R")
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("MY COLOURS").font(.chrome(11, weight: .semibold)).foregroundStyle(.chromeSecondary)
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
            RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.accentColor : Color.separatorLine)
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
                            setStyle(Loc.t("Background")) { $0.background = hex }
                        } label: {
                            Circle().fill(c.color).frame(width: 20, height: 20)
                                .overlay(
                                    Circle().strokeBorder(
                                        style.background == hex ? Color.primary : Color.separatorLine,
                                        lineWidth: style.background == hex ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex.map { Loc.f("Background %@", $0) } ?? Loc.t("Theme background"))
                    }
                    ColorPicker(
                        "",
                        selection: hexBinding(style.background, fallback: controller.theme.canvas) { hex in
                            setStyle(Loc.t("Background")) { $0.background = hex }
                        }
                    )
                    .labelsHidden()
                    .accessibilityLabel("Custom colour")
                }
            }
            PanelRow(label: Loc.t("Pattern")) {
                Segments(
                    options: [("plain", Loc.t("Plain")), ("dots", Loc.t("Dots")), ("lines", Loc.t("Lines"))],
                    selection: style.pattern ?? patternName
                ) { v in
                    setStyle(Loc.t("Pattern")) { $0.pattern = v }
                }
                .frame(maxWidth: 170)
            }
            PanelRow(label: Loc.t("Global font")) {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.font ?? "system" },
                        set: { v in setStyle(Loc.t("Global Font")) { $0.font = v == "system" ? nil : v } })
                ) {
                    ForEach(StyleTab.fonts, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            PanelRow(label: Loc.t("CJK font")) {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.cjkFont ?? Loc.t("PingFang SC") },
                        set: { v in setStyle(Loc.t("CJK Font")) { $0.cjkFont = v } })
                ) {
                    ForEach(Self.cjkFonts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            PanelRow(label: Loc.t("Branch line width")) {
                Segments(
                    options: [
                        ("thin", Loc.t("Thin")), ("regular", Loc.t("Regular")), ("bold", Loc.t("Bold")),
                        ("taper", Loc.t("Taper")),
                    ],
                    selection: style.lineWidth ?? "regular"
                ) { v in
                    setStyle(Loc.t("Branch Line Width")) { $0.lineWidth = v == "regular" ? nil : v }
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
        PanelSection(Loc.t("Map style"), key: "mapstyle") {
            PanelToggle(label: Loc.t("Auto balance map"), isOn: style.autoBalance) { v in
                setStyle(Loc.t("Auto Balance")) { $0.autoBalance = v }
            }
            PanelToggle(label: Loc.t("Compact map"), isOn: style.compact) { v in
                setStyle(Loc.t("Compact Map")) { $0.compact = v }
            }
            PanelToggle(label: Loc.t("Justify topic alignment"), isOn: style.justify) { v in
                setStyle(Loc.t("Justify")) { $0.justify = v }
            }
        }
    }

    var advanced: some View {
        PanelSection(Loc.t("Advanced layout"), key: "advanced") {
            PanelToggle(label: Loc.t("Free layout for this canvas"), isOn: layout.mode == .free) { v in
                controller.updateLayout(Loc.t("Free Layout")) { $0.mode = v ? .free : .auto }
            }
            PanelToggle(label: Loc.t("Branch free-positioning"), isOn: layout.branchFreePositioning) { v in
                controller.updateLayout(Loc.t("Branch Free-Positioning")) { $0.branchFreePositioning = v }
            }
            PanelToggle(label: Loc.t("Flexible floating topics"), isOn: layout.flexibleFloating) { v in
                controller.updateLayout(Loc.t("Flexible Floating Topics")) { $0.flexibleFloating = v }
            }
            PanelToggle(label: Loc.t("Allow topic overlap"), isOn: layout.allowOverlap) { v in
                controller.updateLayout(Loc.t("Allow Overlap")) { $0.allowOverlap = v }
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

    /// The selected topic's semantic type, from the canvas's palette (M41): what guides,
    /// rule checks and STRIDE read. Automatic shows what inference makes of it.
    @ViewBuilder var typeSection: some View {
        let c = controller.canvas
        let palette = DiagramCatalog.nodeTypes(for: c.type)
        let id = controller.selection.primary
        if !palette.isEmpty, let node = c.nodes[id] {
            PanelSection(Loc.t("Type"), key: "nodeType") {
                let inferred = node.nodeType == nil ? DiagramCatalog.effectiveType(id, in: c) : nil
                let auto = inferred.flatMap { t in palette.first { $0.id == t } }.map {
                    Loc.f("Automatic · %@", Loc.t($0.name))
                }
                Picker(
                    "Type",
                    selection: Binding(
                        get: { node.nodeType?.rawValue ?? "" },
                        set: { controller.setNodeType($0.isEmpty ? nil : NodeType(rawValue: $0)) })
                ) {
                    Text(auto ?? Loc.t("Automatic")).tag("")
                    ForEach(palette, id: \.id) { Text(Loc.t($0.name)).tag($0.id.rawValue) }
                    if let t = node.nodeType, !palette.contains(where: { $0.id == t }) {
                        Text(t.rawValue).tag(t.rawValue)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Node type")
            }
            Divider()
        }
    }

    var fields: [MetadataField] { controller.canvas.nodes[controller.selection.primary]?.metadata ?? [] }

    func update(_ body: @escaping (inout [MetadataField]) -> Void) {
        let id = controller.selection.primary
        controller.perform(Loc.t("Edit Fields")) { e in e.update(id) { body(&$0.metadata) } }
    }

    var body: some View {
        typeSection
        PanelSection(Loc.t("Task"), key: "task") {
            let id = controller.selection.primary
            let c = controller.canvas
            if let line = TaskFormat.line(c, id, today: controller.todayDate) {
                Text(line).font(.chrome(12.5)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No dates, owner or progress yet.").font(.chrome(12)).foregroundStyle(.chromeSecondary)
            }
            let after = c.nodes[id]?.todo?.after.compactMap { c.nodes[$0.task]?.text } ?? []
            if !after.isEmpty {
                Text(Loc.f("After %@", after.joined(separator: ", "))).font(.chrome(12)).foregroundStyle(
                    .chromeSecondary)
            }
            Button("Edit Task…  ⌃⌘T") { controller.openTaskEditor() }.buttonStyle(.bordered)
        }
        Divider()
        PanelSection(Loc.t("Metadata · pin to show on node"), key: "metadata") {
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
                    .accessibilityLabel(f.pinned ? Loc.t("Unpin") : Loc.t("Pin"))
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
        PanelSection(Loc.t("Links & attachments"), key: "links") {
            let n = controller.canvas.nodes[controller.selection.primary]
            if let link = n?.link {
                Text(link).font(.chrome(12)).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Add a hyperlink with ⇧⌘K or drop a file on the topic.")
                    .font(.chrome(12)).foregroundStyle(.chromeSecondary)
            }
        }
    }
}
