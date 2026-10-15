import AppKit
import NexusCore
import NexusTheme
import SwiftUI
import UniformTypeIdentifiers

/// The theme builder (artboard 03): start from a theme, change font, palette, canvas,
/// root and branch line, with a live contrast badge; export `.nexustheme` or save.
struct ThemeBuilder: View {
    var controller: CanvasController
    @State var theme: Theme
    var done: () -> Void
    @State private var selectedColor = 0
    @State private var accent = Color(.sRGB, red: 0.88, green: 0.48, blue: 0.37)

    init(controller: CanvasController, theme: Theme, done: @escaping () -> Void) {
        self.controller = controller
        _theme = State(initialValue: theme)
        self.done = done
    }

    var report: ContrastChecker.Report { ContrastChecker.check(theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(theme.id.isEmpty ? "New Theme" : "Edit Theme").font(.title3.bold())
                Spacer()
                Text(report.badge)
                    .font(.chrome(11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(report.passes ? Color.green : Color.red)
                    .background(
                        (report.passes ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 5)
                    )
                    .help(
                        report.passes
                            ? Loc.f("Every node style meets the target") : Loc.f("Lowest: %@", report.worst)
                    )
                    .accessibilityLabel(Loc.f("Contrast %@", report.badge))
            }
            Divider()
            LabeledContent("Name") { TextField("Name", text: $theme.name).textFieldStyle(.roundedBorder) }
            HStack(spacing: 16) {
                LabeledContent("Start from") {
                    Picker("", selection: Binding(get: { "" }, set: { id in start(from: id) })) {
                        Text("Choose…").tag("")
                        ForEach(Theme.builtIn) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
                LabeledContent("Diagram font") {
                    Picker("", selection: $theme.font) {
                        Text("New York").tag("serif")
                        Text("SF Pro").tag("system")
                        Text("SF Mono").tag("mono")
                        Text("Handwriting").tag("hand")
                    }
                    .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Branch palette").font(.chrome(13))
                HStack(spacing: 8) {
                    ForEach(Array(theme.palette.enumerated()), id: \.offset) { i, c in
                        Swatch(color: c, selected: i == selectedColor, size: 30) { selectedColor = i }
                    }
                }
                HStack {
                    ColorPicker(
                        "Selected colour",
                        selection: Binding(
                            get: { theme.palette[min(selectedColor, theme.palette.count - 1)].color },
                            set: { theme.palette[min(selectedColor, theme.palette.count - 1)] = RGBA(color: $0) }))
                    Spacer()
                    ColorPicker("", selection: $accent).labelsHidden()
                        .accessibilityLabel("Custom colour")
                    Button("Generate from one accent…") {
                        let g = ColorPalette.generated(from: RGBA(color: accent))
                        theme.palette = g.colors + Array(g.colors.prefix(2))
                    }
                }
                .font(.chrome(12))
            }
            HStack(spacing: 16) {
                LabeledContent("Canvas") {
                    ColorPicker(
                        "", selection: Binding(get: { theme.canvas.color }, set: { theme.canvas = RGBA(color: $0) })
                    )
                    .labelsHidden()
                    .accessibilityLabel("Custom colour")
                    Picker("", selection: Binding(get: { gridName }, set: { setGrid($0) })) {
                        Text("Plain").tag("plain")
                        Text("Dots").tag("dots")
                        Text("Lines").tag("lines")
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                LabeledContent("Root") {
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { theme.root.background.color }, set: { theme.root.background = RGBA(color: $0) })
                    )
                    .labelsHidden()
                    .accessibilityLabel("Custom colour")
                    Picker(
                        "",
                        selection: Binding(
                            get: { theme.rootRadius >= 99 ? "pill" : "rounded" },
                            set: { theme.rootRadius = $0 == "pill" ? 999 : Tokens.Radius.root })
                    ) {
                        Text("Filled · Rounded").tag("rounded")
                        Text("Filled · Pill").tag("pill")
                    }
                    .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Branch line").font(.chrome(13))
                Segments(
                    options: [
                        ("curved", "Curved"), ("straight", "Straight"), ("elbow", "Elbow"), ("rounded", "Rounded"),
                        ("zigzag", "Zigzag"),
                    ],
                    selection: theme.lineShape
                ) { theme.lineShape = $0 }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Per diagram type").font(.chrome(13, weight: .semibold))
                    modeRow("Mind maps", "mindmap", ["branch": "Colour by branch"])
                    modeRow("DFD · Architecture", "dfd", ["type": "Colour by node type", "branch": "Colour by branch"])
                    modeRow("Threat model", "threatModel", ["risk": "Colour by risk", "type": "Colour by node type"])
                }
                .font(.chrome(12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            HStack {
                Button("Cancel", role: .cancel) { done() }
                Spacer()
                Button("Export .nexustheme") { export() }
                Button("Save Theme") {
                    if theme.id.isEmpty {
                        controller.saveCurrentAsTheme(named: theme.name.isEmpty ? "My Theme" : theme.name, base: theme)
                    } else {
                        controller.saveTheme(theme)
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 640)
    }

    func modeRow(_ label: String, _ key: String, _ options: [String: String]) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Picker(
                "",
                selection: Binding(
                    get: { theme.colorModes[key] ?? options.keys.first! },
                    set: { v in
                        theme.colorModes[key] = v
                        if key == "dfd" { theme.colorModes["architecture"] = v }
                    })
            ) {
                ForEach(options.sorted(by: { $0.key < $1.key }), id: \.key) { Text($0.value).tag($0.key) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    var gridName: String {
        switch theme.grid {
        case .none: "plain"
        case .dots: "dots"
        case .lines: "lines"
        }
    }

    func setGrid(_ name: String) {
        let c = theme.grid.color ?? theme.ink.alpha(0.12)
        theme.grid =
            name == "plain" ? .none : name == "dots" ? .dots(color: c, spacing: 22) : .lines(color: c, spacing: 24)
    }

    func start(from id: String) {
        guard !id.isEmpty else { return }
        let keepID = theme.id
        let keepName = theme.name
        theme = Theme.named(id)
        theme.id = keepID
        theme.name = keepName
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeCodec.fileExtension) ?? .json]
        panel.nameFieldStringValue = (theme.name.isEmpty ? "Theme" : theme.name) + "." + ThemeCodec.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var t = theme
        if t.id.isEmpty { t.id = "custom-" + t.name.lowercased().replacingOccurrences(of: " ", with: "-") }
        try? ThemeCodec.encode(t).write(to: url)
    }
}

/// The custom colour theme editor (FMT-3 › New colour theme): six branch colours, a
/// root colour and a live contrast check.
struct ColourThemeEditor: View {
    var controller: CanvasController
    @State var palette: ColorPalette
    var done: () -> Void
    @State private var selected = 0
    @State private var hex = ""

    init(controller: CanvasController, palette: ColorPalette, done: @escaping () -> Void) {
        self.controller = controller
        var p = palette
        while p.colors.count < 6 { p.colors.append(p.colors.last ?? .white) }
        _palette = State(initialValue: p)
        self.done = done
    }

    var check: (passing: Int, total: Int) { ContrastChecker.paletteCount(palette.colors, on: controller.theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(palette.id.isEmpty ? "New colour theme" : "Edit colour theme").font(.title3.bold())
            Divider()
            LabeledContent("Name") { TextField("Name", text: $palette.name).textFieldStyle(.roundedBorder) }
            Text("6 BRANCH COLOURS · REORDER WITH THE ARROWS").font(.chrome(11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(palette.colors.enumerated()), id: \.offset) { i, c in
                    Swatch(color: c, selected: i == selected, size: 44) {
                        selected = i
                        hex = c.hex
                    }
                }
            }
            HStack {
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "arrow.left")
                }.disabled(selected == 0)
                Button {
                    move(1)
                } label: {
                    Image(systemName: "arrow.right")
                }.disabled(selected == palette.colors.count - 1)
                ColorPicker(
                    "",
                    selection: Binding(
                        get: { palette.colors[selected].color },
                        set: {
                            palette.colors[selected] = RGBA(color: $0)
                            hex = palette.colors[selected].hex
                        })
                )
                .labelsHidden()
                .accessibilityLabel("Custom colour")
                TextField("#RRGGBB", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.chrome(12, design: .monospaced))
                    .onSubmit { if let c = RGBA(hexString: hex) { palette.colors[selected] = c } }
            }
            PanelRow(label: "Root colour") {
                ColorPicker(
                    "",
                    selection: Binding(
                        get: { (palette.root ?? controller.theme.root.background).color },
                        set: { palette.root = RGBA(color: $0) })
                )
                .labelsHidden()
                .accessibilityLabel("Custom colour")
            }
            PanelRow(label: "Contrast check") {
                let ok = check.passing == check.total
                Text(ok ? "AA on all \(check.total)" : "AA on \(check.passing) of \(check.total)")
                    .font(.chrome(11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(ok ? Color.green : Color.orange)
                    .background((ok ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            Spacer()
            HStack {
                Button("Cancel", role: .cancel) { done() }
                Spacer()
                Button("Preview") { controller.previewPalette(palette) }
                Button("Save") {
                    var p = palette
                    if p.id.isEmpty { p.id = "custom-" + p.name.lowercased().replacingOccurrences(of: " ", with: "-") }
                    controller.savePalette(p)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 470)
        .onAppear { hex = palette.colors.first?.hex ?? "" }
    }

    func move(_ d: Int) {
        let j = selected + d
        guard palette.colors.indices.contains(j) else { return }
        palette.colors.swapAt(selected, j)
        selected = j
    }
}
