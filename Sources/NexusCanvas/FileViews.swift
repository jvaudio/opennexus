import AppKit
import NexusCore
import NexusFormat
import NexusInterchange
import NexusTheme
import PDFKit
import SwiftUI

/// The indigo accent of artboards 30 and 50.
let fileAccent = Color(red: 0.345, green: 0.314, blue: 0.925)

/// A segmented control in the artboards' style (lavender selection, indigo text).
struct FileSegments<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button {
                    selection = item.0
                } label: {
                    Text(item.1)
                        .font(.chrome(13.5, weight: selection == item.0 ? .medium : .regular))
                        .foregroundStyle(selection == item.0 ? fileAccent : .primary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(selection == item.0 ? fileAccent.opacity(0.1) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
                if i < items.count - 1 { Divider().frame(height: 30) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct FileButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.chrome(14, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : .primary)
            .padding(.horizontal, 16)
            .frame(minHeight: 32)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 8).fill(fileAccent)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 8).stroke(.separator)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The checkerboard behind a transparent preview.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.08)))
                }
            }
        }
    }
}

// MARK: Export sheet (⇧⌘E, artboard 30)

struct ExportSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.exportState {
            ExportSheet(controller: controller, state: s)
        }
    }
}

private struct ExportSheet: View {
    var controller: CanvasController
    let state: ExportState
    @State private var preview: CGImage?
    @State private var text: String?
    @State private var sizeLine = ""

    func set(_ body: (inout ExportState) -> Void) {
        var s = state
        body(&s)
        controller.setExport(s)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                formatList.frame(width: 260)
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    previewArea
                    options
                }
                .padding(24)
                .frame(width: 940)
            }
            Divider()
            HStack(spacing: 10) {
                let hits = state.askMask ? controller.maskHits.count : 0
                if hits > 0 {
                    Toggle(
                        Loc.n(
                            "Mask %lld email, key or name in this export",
                            "Mask %lld emails, keys or names in this export", hits),
                        isOn: Binding(get: { state.mask }, set: { v in set { $0.mask = v } })
                    )
                    .toggleStyle(.checkbox)
                    .font(.chrome(13))
                } else {
                    Text("Preview updates as options change · last used settings remembered per format")
                        .font(.chrome(13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { controller.copyExport(state) }.buttonStyle(FileButtonStyle())
                Button("Cancel") { controller.closeExport() }.buttonStyle(FileButtonStyle()).keyboardShortcut(
                    .cancelAction)
                Button("Export…") { controller.runExport(state) }.buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 1200)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .task(id: state) { refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export")
    }

    func refresh() {
        text =
            (state.format.isText && state.format != .svg) || state.format == .excel ? controller.exportText(state) : nil
        preview = text == nil ? controller.exportPreview(state) : nil
        if state.format == .svg { text = nil }
        sizeLine = controller.exportSizeLine(state)
    }

    var formatList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ExportFormat.Group.allCases, id: \.self) { g in
                    Text(g.rawValue).font(.chrome(12.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, g == .visual ? 4 : 18).padding(.bottom, 6)
                    ForEach(ExportFormat.allCases.filter { $0.group == g }) { f in
                        Button {
                            set { $0.format = f }
                        } label: {
                            HStack {
                                Text(f.title).font(.chrome(15, weight: state.format == f ? .semibold : .regular))
                                Spacer()
                                Text(".\(f.ext)").font(.chrome(11.5, design: .monospaced)).opacity(0.75)
                            }
                            .foregroundStyle(state.format == f ? Color.white : .primary)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(state.format == f ? fileAccent : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(state.format == f ? .isSelected : [])
                    }
                }
            }
            .padding(10)
        }
        .accessibilityLabel(Loc.t("Formats"))
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    var previewArea: some View {
        ZStack(alignment: .bottomTrailing) {
            if let text {
                ScrollView([.vertical, .horizontal]) {
                    Text(text).font(.chrome(13, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
                .accessibilityLabel(Loc.t("Preview"))
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.11, green: 0.11, blue: 0.13)))
            } else {
                ZStack {
                    Checkerboard()
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                            .padding(40)
                    } else if state.format == .svg {
                        ProgressView()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .task(id: state) {
                    if state.format == .svg { preview = controller.exportPreview(svgAsPNG(state)) }
                }
            }
            if !sizeLine.isEmpty {
                Text(sizeLine).font(.chrome(12.5, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
                    )
                    .padding(12)
            }
        }
        .frame(height: 520)
    }

    /// Xmind (M15): which Xmind (M18), what the file holds, and what doesn't carry over.
    var xmindOptions: some View {
        let r = controller.xmindReport(state)
        return VStack(alignment: .leading, spacing: 6) {
            FileSegments(
                items: [(false, Loc.t("Xmind 2020 or later")), (true, Loc.t("XMind 8"))],
                selection: Binding(get: { state.xmind8 }, set: { v in set { $0.xmind8 = v } })
            )
            .frame(width: 320)
            .accessibilityLabel(Loc.t("Xmind version"))
            Text(
                state.xmind8
                    ? Loc.t(
                        "Every canvas as an XMind 8 sheet (content.xml): topics, structure, notes, labels, markers, relationships, boundaries, summaries, images, comments, the legend, task info and styles."
                    )
                    : Loc.t(
                        "Every canvas as an Xmind sheet, for Xmind 2020 or later: topics, structure, notes, labels, markers, relationships, boundaries, summaries, images, comments, the legend, task info, styles and the theme."
                    )
            )
            .font(.chrome(13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !r.lines.isEmpty {
                Text("NOT CARRIED OVER").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(r.lines, id: \.self) { Text("· " + $0).font(.chrome(12.5)) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    func svgAsPNG(_ s: ExportState) -> ExportState {
        var x = s
        x.format = .png
        return x
    }

    @ViewBuilder var options: some View {
        switch state.format.group {
        case .tasks:
            taskOptions
        case .visual:
            visualOptions
            if state.format == .svg {
                HStack(spacing: 18) {
                    FileSegments(
                        items: [(false, Loc.t("Embed fonts")), (true, Loc.t("Outline text"))],
                        selection: Binding(get: { state.svg.outlineText }, set: { v in set { $0.svg.outlineText = v } })
                    )
                    .frame(width: 300)
                    Toggle(
                        "Include metadata (types, fields)",
                        isOn: Binding(get: { state.svg.metadata }, set: { v in set { $0.svg.metadata = v } })
                    )
                    .toggleStyle(.switch)
                }
            }
            if state.format == .jpeg {
                HStack {
                    Text("Quality").frame(width: 70, alignment: .leading)
                    Slider(
                        value: Binding(get: { state.jpegQuality }, set: { v in set { $0.jpegQuality = v } }),
                        in: 0.3...1
                    )
                    .frame(width: 260)
                    .accessibilityLabel(Loc.t("Quality"))
                    Text("\(Int(state.jpegQuality * 100))%").font(.chrome(12.5, design: .monospaced))
                }
            }
            if state.image.scope == .zone {
                labelled(Loc.t("Zones")) {
                    FileSegments(
                        items: [
                            (ExportState.ZoneExport.one, Loc.t("This zone")),
                            (.each, Loc.t("Each zone as its own file")),
                        ] + (state.format == .pdf ? [(.pages, Loc.t("One PDF, a page per zone"))] : []),
                        selection: Binding(get: { state.zones }, set: { v in set { $0.zones = v } })
                    )
                    .frame(width: state.format == .pdf ? 560 : 380)
                }
            } else if state.format == .pdf {
                labelled(Loc.t("Pages")) {
                    FileSegments(
                        items: [
                            ("canvas", Loc.t("This canvas")), ("all", Loc.t("All canvases")),
                            ("presentation", Loc.t("Presentation")),
                        ],
                        selection: Binding(get: { state.pdfScope }, set: { v in set { $0.pdfScope = v } })
                    )
                    .frame(width: 440)
                }
            }
        case .structural:
            if state.format == .mermaid {
                labelled(Loc.t("Flavour · auto-chosen from type")) {
                    FileSegments(
                        items: MermaidFormat.Flavour.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { state.mermaid ?? MermaidFormat.flavour(for: controller.canvas) },
                            set: { v in set { $0.mermaid = v } })
                    )
                    .frame(width: 480)
                }
                Text("Round-trips: paste Mermaid back to rebuild").font(.chrome(13)).foregroundStyle(.secondary)
            } else if state.format == .json {
                HStack(spacing: 18) {
                    FileSegments(
                        items: [(false, "JSON"), (true, "YAML")],
                        selection: Binding(get: { state.yaml }, set: { v in set { $0.yaml = v } })
                    )
                    .frame(width: 220)
                    if !state.yaml {
                        Toggle(
                            "Pretty", isOn: Binding(get: { state.prettyJSON }, set: { v in set { $0.prettyJSON = v } })
                        ).toggleStyle(.switch)
                    }
                    Text("OpenNexus schema · the whole document · assets stay in the .nexus package").font(
                        .chrome(13)
                    ).foregroundStyle(.secondary)
                }
            } else if state.format == .xmind {
                xmindOptions
            } else if state.format == .drawio {
                Text("Keeps positions and branch colours from the canvas layout.").font(.chrome(13))
                    .foregroundStyle(.secondary)
            } else {
                scopeOnly
            }
        case .document:
            if state.format == .markdown {
                HStack(spacing: 18) {
                    FileSegments(
                        items: [(true, Loc.t("Headings")), (false, Loc.t("Nested bullets"))],
                        selection: Binding(
                            get: { state.markdown.headings }, set: { v in set { $0.markdown.headings = v } })
                    )
                    .frame(width: 300)
                    Toggle(
                        "Notes",
                        isOn: Binding(get: { state.markdown.notes }, set: { v in set { $0.markdown.notes = v } })
                    ).toggleStyle(.switch)
                    Toggle(
                        "Comments",
                        isOn: Binding(
                            get: { state.markdown.comments }, set: { v in set { $0.markdown.comments = v } })
                    ).toggleStyle(.switch)
                    Toggle(
                        "Mermaid block",
                        isOn: Binding(
                            get: { state.markdown.mermaidBlock }, set: { v in set { $0.markdown.mermaidBlock = v } })
                    ).toggleStyle(.switch)
                }
                scopeOnly
            } else if state.format == .csv {
                Text(
                    controller.canvas.type == .threatModel || !Stride.threats(controller.canvas).isEmpty
                        ? Loc.t("Threat table: element, STRIDE category, risk, mitigation, status.")
                        : Loc.t(
                            "Every topic, with its task fields: status, priority, owner, dates, progress, dependencies."
                        )
                )
                .font(.chrome(13)).foregroundStyle(.secondary)
            } else if state.format == .excel {
                Text(
                    DiagramCatalog.isTechnical(controller.canvas.type)
                        ? Loc.t(
                            "One sheet per canvas, a row per topic in outline order: level, path, topic, note, labels, markers, to-do, type, STRIDE, risk and status."
                        )
                        : Loc.t(
                            "One sheet per canvas, a row per topic in outline order: level, path, topic, note, labels, markers and to-do."
                        )
                )
                .font(.chrome(13)).foregroundStyle(.secondary)
            } else {
                Text(
                    state.format == .word
                        ? Loc.t("The outline as headings, notes as paragraphs, each canvas's diagram as an image.")
                        : state.format == .keynote
                            ? Loc.t("A PowerPoint deck Keynote opens directly, one slide per step.")
                            : Loc.t("One slide per step, as in Present.")
                )
                .font(.chrome(13)).foregroundStyle(.secondary)
            }
        }
    }

    /// Gantt image and PDF options, and notes for the task formats (M11).
    @ViewBuilder var taskOptions: some View {
        if state.format.isGantt {
            HStack(spacing: 24) {
                labelled(Loc.t("Rows")) {
                    FileSegments(
                        items: [(false, Loc.t("All tasks")), (true, Loc.t("Selected branches"))],
                        selection: Binding(
                            get: { state.gantt.selectionOnly }, set: { v in set { $0.gantt.selectionOnly = v } })
                    )
                    .frame(width: 300)
                }
                if state.format == .ganttPDF {
                    labelled(Loc.t("Pages")) {
                        FileSegments(
                            items: [("fit", Loc.t("One page")), ("a4", "A4"), ("letter", Loc.t("Letter"))],
                            selection: Binding(get: { state.gantt.paper }, set: { v in set { $0.gantt.paper = v } })
                        )
                        .frame(width: 300)
                    }
                } else {
                    labelled(Loc.t("Scale")) {
                        FileSegments(
                            items: [(1.0, "1×"), (2.0, "2×"), (4.0, "4×")],
                            selection: Binding(get: { state.gantt.scale }, set: { v in set { $0.gantt.scale = v } })
                        )
                        .frame(width: 200)
                    }
                }
            }
            if state.format == .ganttJPEG {
                HStack {
                    Text("Quality").frame(width: 70, alignment: .leading)
                    Slider(
                        value: Binding(get: { state.jpegQuality }, set: { v in set { $0.jpegQuality = v } }),
                        in: 0.3...1
                    )
                    .frame(width: 260)
                    .accessibilityLabel(Loc.t("Quality"))
                    Text("\(Int(state.jpegQuality * 100))%").font(.chrome(12.5, design: .monospaced))
                }
            }
            Text("The timeline scale follows the Gantt view (⌘= and ⌘- while it shows).").font(.chrome(13))
                .foregroundStyle(.secondary)
        } else {
            Text(
                state.format == .ics
                    ? Loc.t("One all-day event per dated task, for Calendar or any calendar app.")
                    : Loc.t(
                        "Only to-dos and tasks: status, priority, owner, dates, working days, progress, dependencies.")
            )
            .font(.chrome(13)).foregroundStyle(.secondary)
        }
    }

    var scopeOnly: some View {
        labelled(Loc.t("Scope")) {
            FileSegments(
                items: [(ImageExporter.Scope.canvas, Loc.t("Canvas")), (.branch, Loc.t("Branch"))],
                selection: Binding(
                    get: {
                        state.image.scope == .selection
                            ? .branch : state.image.scope == .zone ? .canvas : state.image.scope
                    },
                    set: { v in set { $0.image.scope = v } })
            )
            .frame(width: 300)
        }
    }

    var visualOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Text("Scope").font(.chrome(14, weight: .medium))
                Text("Scale").font(.chrome(14, weight: .medium))
            }
            GridRow {
                FileSegments(
                    items: ImageExporter.Scope.allCases.filter { $0 != .zone || state.image.zone != nil }.map {
                        ($0, $0.title)
                    },
                    selection: Binding(get: { state.image.scope }, set: { v in set { $0.image.scope = v } }))
                FileSegments(
                    items: [(1.0, "1×"), (2.0, "2×"), (3.0, "3×"), (4.0, "4×")],
                    selection: Binding(get: { state.image.scale }, set: { v in set { $0.image.scale = v } }))
            }
            GridRow {
                Text("Background").font(.chrome(14, weight: .medium)).padding(.top, 10)
                Text("Padding · Theme override").font(.chrome(14, weight: .medium)).padding(.top, 10)
            }
            GridRow {
                FileSegments(
                    items: ImageExporter.Background.allCases.filter { state.format != .jpeg || $0 != .transparent }.map
                    { ($0, $0.title) },
                    selection: Binding(get: { state.image.background }, set: { v in set { $0.image.background = v } }))
                HStack(spacing: 10) {
                    // Settings › General › Units (padding is stored in points).
                    let unit = controller.prefs.string("general.units")
                    let k = unit == "mm" ? 0.352_778 : 1
                    TextField(
                        "",
                        value: Binding(
                            get: { (state.image.padding * k * 10).rounded() / 10 },
                            set: { v in set { $0.image.padding = max(0, min(v / k, 400)) } }),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .accessibilityLabel(Loc.f("Padding in %@", unit))
                    Text(unit).foregroundStyle(.secondary)
                    Menu(
                        state.image.theme.map { Loc.f("Use %@", Theme.named($0).name) }
                            ?? Loc.f("Keep %@", controller.theme.name)
                    ) {
                        Button(Loc.f("Keep %@", controller.theme.name)) { set { $0.image.theme = nil } }
                        Divider()
                        ForEach(Theme.builtIn, id: \.id) { t in Button(t.name) { set { $0.image.theme = t.id } } }
                    }
                    .frame(width: 240)
                }
            }
        }
    }

    func labelled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.chrome(14, weight: .medium))
            content()
        }
    }
}

// MARK: Map Shot toolbar (⌃⌘M, artboard 51)

struct MapShotBar: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.mapShot {
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ForEach(MapShotState.Aspect.allCases, id: \.self) { a in
                        Button(a.rawValue) { controller.setMapShotAspect(a) }
                            .buttonStyle(.plain)
                            .font(.chrome(14, weight: s.aspect == a ? .semibold : .regular))
                            .foregroundStyle(s.aspect == a ? Color.black : .white)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(s.aspect == a ? Color.white : .clear))
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                Divider().frame(height: 24).overlay(Color.white.opacity(0.2))
                Text("Frame").foregroundStyle(.white)
                ForEach(
                    [
                        ("canvas", Color.white), ("gradient", Color(red: 0.75, green: 0.8, blue: 0.95)),
                        ("black", Color(white: 0.1)),
                    ], id: \.0
                ) { id, c in
                    Button {
                        var x = s
                        x.frame = id
                        controller.setMapShot(x)
                    } label: {
                        RoundedRectangle(cornerRadius: 5).fill(c).frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5).stroke(
                                    s.frame == id ? fileAccent : Color.white.opacity(0.3),
                                    lineWidth: s.frame == id ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.f("Frame %@", id))
                }
                Stepper(
                    value: Binding(
                        get: { s.padding },
                        set: { v in
                            var x = s; x.padding = v; controller.setMapShot(x)
                        }), in: 0...96, step: 4
                ) {
                    Text(Loc.f("%lld pt", Int(s.padding))).foregroundStyle(.white).monospacedDigit()
                }
                Toggle(
                    isOn: Binding(
                        get: { s.shadow },
                        set: { v in
                            var x = s; x.shadow = v; controller.setMapShot(x)
                        })
                ) {
                    Text("Shadow").foregroundStyle(.white)
                }
                .toggleStyle(.checkbox)
                Divider().frame(height: 24).overlay(Color.white.opacity(0.2))
                Button("Copy & Save ↩") { controller.commitMapShot() }
                    .buttonStyle(.plain)
                    .font(.chrome(14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.62, green: 0.6, blue: 1)))
            }
            .font(.chrome(14))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .environment(\.colorScheme, .dark)
        }
    }
}

struct MapShotHintHost: View {
    var controller: CanvasController
    var body: some View { if controller.mapShot != nil { MapShotHint() } }
}

struct MapShotHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Map Shot").font(.chrome(14, weight: .semibold)).foregroundStyle(.white)
            Text("⌃⌘M").font(.chrome(11, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.6)))
            Text("drag to move · handles resize · ⇧ keeps ratio · arrows nudge · ⌥↩ copy only · esc cancels")
                .font(.chrome(13.5)).foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: Print (⌘P, artboard 50)

struct PrintSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let o = controller.printState { PrintSheet(controller: controller, options: o) }
    }
}

private struct PrintSheet: View {
    var controller: CanvasController
    @State var options: PrintLayout.Options
    @State private var pages: [NSImage] = []
    @State private var count = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Print").font(.chrome(18, weight: .semibold))
                Spacer()
                Text("⌘P").font(.chrome(11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    let cols = max(1, min(4, Int(Double(pages.count).squareRoot().rounded(.up))))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: cols), spacing: 3) {
                        ForEach(Array(pages.prefix(16).enumerated()), id: \.offset) { i, img in
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                .background(Color.white)
                                .overlay(alignment: .bottomTrailing) {
                                    Text("\(i + 1)").font(.chrome(9)).foregroundStyle(.secondary).padding(4)
                                }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Page previews")
                    .frame(maxWidth: 340)
                    Text(
                        count > 1 && options.tile && !options.fitPage
                            ? Loc.n("%lld page · cut marks on", "%lld pages · cut marks on", count)
                            : Loc.n("%lld page", "%lld pages", count)
                    )
                    .font(.chrome(12.5, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(width: 380)
                .padding(16)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    section("CONTENT")
                    FileSegments(
                        items: PrintLayout.Content.allCases.filter { $0 != .zone || options.zone != nil }.map {
                            ($0, $0.title)
                        }, selection: $options.content)
                    section("PAGE")
                    HStack {
                        Picker("", selection: $options.paper) {
                            ForEach(PrintLayout.Paper.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 100)
                        FileSegments(items: [(false, "▯"), (true, "▭")], selection: $options.landscape).frame(
                            width: 140
                        )
                        .accessibilityLabel("Orientation")
                    }
                    section("SCALE")
                    FileSegments(
                        items: [(true, Loc.t("Fit page")), (false, Loc.t("Actual size"))], selection: $options.fitPage)
                    Toggle("Tile across pages", isOn: $options.tile).disabled(options.fitPage)
                    Toggle("Background colour", isOn: $options.background)
                    Toggle("Notes as appendix", isOn: $options.notesAppendix)
                    Toggle("Header: title · date", isOn: $options.header)
                    Text("Print Branch… and Print Zone… (⌘K, or right-click a zone) print only that part.")
                        .font(.chrome(13)).foregroundStyle(.secondary)
                    Spacer()
                }
                .toggleStyle(.switch)
                .font(.chrome(14))
                .padding(20)
                .frame(width: 300)
            }
            Divider()
            HStack {
                LabeledMenu("PDF") {
                    Button("Save as PDF…") { controller.runPrint(options, savePDF: true) }
                }
                .frame(width: 90)
                Spacer()
                Button("Cancel") { controller.closePrint() }.buttonStyle(FileButtonStyle()).keyboardShortcut(
                    .cancelAction)
                Button("Print") { controller.runPrint(options) }.buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 700, height: 640)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .task(id: options) { render() }
    }

    func section(_ t: String) -> some View {
        Text(t).font(.chrome(12.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    func render() {
        let (data, n) = controller.printPDF(options)
        count = n
        guard let doc = PDFDocument(data: data) else { return }
        pages = (0..<min(doc.pageCount, 16)).compactMap {
            doc.page(at: $0)?.thumbnail(of: CGSize(width: 200, height: 200), for: .mediaBox)
        }
    }
}

// MARK: Merge (Tools › Merge…, artboard 50)

struct MergeSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let m = controller.mergeState {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Merge documents").font(.chrome(18, weight: .semibold))
                    Spacer()
                    Text("Tools › Merge…").font(.chrome(12, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(18)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    FileSegments(
                        items: [(false, Loc.t("As canvases")), (true, Loc.t("Into this canvas"))],
                        selection: Binding(
                            get: { m.intoThisCanvas }, set: { controller.mergeState?.intoThisCanvas = $0 }))
                    Text(Loc.f("DOCUMENTS · %lld", m.sources.count)).font(.chrome(13, weight: .semibold))
                        .foregroundStyle(
                            .secondary)
                    ForEach(m.sources) { s in
                        HStack(spacing: 12) {
                            Text(s.kind).font(.chrome(10, weight: .bold, design: .monospaced))
                                .foregroundStyle(s.kind == "XM" ? Color.red : s.kind == "MD" ? .teal : fileAccent)
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor))
                                )
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.chrome(15))
                                Text(s.detail).font(.chrome(13)).foregroundStyle(.secondary)
                                if let p = s.progress {
                                    ProgressView(value: p).progressViewStyle(.linear).controlSize(.small)
                                        .accessibilityLabel(Loc.f("Reading %@", s.name))
                                }
                            }
                            Spacer()
                            Button {
                                controller.removeMergeSource(s.name)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Loc.f("Remove %@", s.name))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
                    }
                    Button("+ Add…") { controller.onChooseMergeFiles?() }.buttonStyle(FileButtonStyle())
                    Toggle(
                        "Generate a Map of Content",
                        isOn: Binding(get: { m.mapOfContent }, set: { controller.mergeState?.mapOfContent = $0 })
                    )
                    .toggleStyle(.switch)
                    .disabled(m.intoThisCanvas)
                    Text(
                        m.intoThisCanvas
                            ? Loc.t("Each document’s central topic becomes a branch of this canvas’s central topic.")
                            : "Each root becomes a branch on a new index canvas, with topic links to the merged canvases. Styles keep their source theme. .xmind, OPML and Markdown are accepted too."
                    )
                    .font(.chrome(13.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                Spacer(minLength: 20)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { controller.closeMerge() }.buttonStyle(FileButtonStyle()).keyboardShortcut(
                        .cancelAction)
                    Button("Merge · one undo") { controller.applyMerge() }.buttonStyle(FileButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(m.sources.isEmpty || m.reading)
                }
                .padding(16)
            }
            .frame(width: 520)
            .frame(minHeight: 560)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        }
    }
}

// MARK: Encrypt (File › Set Password…, artboard 50)

struct PasswordSheetView: View {
    var controller: CanvasController
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var remember = true

    var body: some View {
        if controller.passwordSheet {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(controller.documentEncrypted ? Loc.t("Change password") : Loc.t("Encrypt document")).font(
                        .chrome(18, weight: .semibold))
                    Spacer()
                    Text("File › Set Password…").font(.chrome(12, design: .monospaced)).foregroundStyle(
                        .secondary)
                }
                .padding(18)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Password").font(.chrome(14, weight: .medium))
                    SecureField("", text: $password).textFieldStyle(.roundedBorder).accessibilityLabel("Password")
                    Text("Confirm").font(.chrome(14, weight: .medium)).padding(.top, 6)
                    SecureField("", text: $confirm).textFieldStyle(.roundedBorder).accessibilityLabel(
                        "Confirm password")
                    Text("Hint (optional, stored unencrypted)").font(.chrome(14, weight: .medium)).padding(
                        .top, 6)
                    TextField("", text: $hint).textFieldStyle(.roundedBorder).accessibilityLabel("Hint")
                    Toggle("Remember in Keychain", isOn: $remember).toggleStyle(.switch).padding(.vertical, 4)
                    HStack(alignment: .top, spacing: 8) {
                        Text("!").font(.chrome(14, weight: .bold)).foregroundStyle(.orange)
                        Text(
                            "A forgotten password cannot be recovered. Recovery snapshots of this document are encrypted with the same key."
                        )
                        .font(.chrome(13.5)).foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    if !confirm.isEmpty && confirm != password {
                        Text("The passwords don’t match.").font(.chrome(13)).foregroundStyle(.red)
                    }
                }
                .padding(20)
                Divider()
                HStack {
                    if controller.documentEncrypted {
                        Button("Remove Password") {
                            controller.passwordSheet = false
                            controller.onRemovePassword?()
                        }
                        .buttonStyle(FileButtonStyle())
                    }
                    Spacer()
                    Button("Cancel") { controller.passwordSheet = false }.buttonStyle(FileButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Encrypt") {
                        controller.passwordSheet = false
                        controller.onSetPassword?(password, hint.isEmpty ? nil : hint, remember)
                        password = ""
                        confirm = ""
                    }
                    .buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.count < 4 || password != confirm)
                }
                .padding(16)
            }
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        }
    }
}

// MARK: Import report (artboard 33)

struct ImportReportView: View {
    var controller: CanvasController

    var body: some View {
        if let r = controller.importReport {
            HStack(alignment: .top, spacing: 20) {
                card(r)
                if r.format == "Xmind" {
                    XmindSwitcherCard(
                        report: Loc.f(
                            "Import report: %@, %@", Loc.n("%lld topic", "%lld topics", r.topics),
                            Loc.n("%lld item not converted", "%lld items not converted", r.notConverted))
                    )
                }
            }
        }
    }

    func card(_ r: ImportReport) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 16) {
                Text(Loc.f("IMPORT REPORT · %@", r.source)).font(.chrome(14, weight: .semibold)).foregroundStyle(
                    .secondary)
                HStack(spacing: 10) {
                    tile(
                        "\(r.canvases)",
                        r.format == "Xmind"
                            ? Loc.t("sheets → canvases") : r.canvases == 1 ? Loc.t("canvas") : Loc.t("canvases"),
                        ok: true)
                    tile("\(r.topics + r.markers + r.notes)", "topics, markers, notes", ok: true)
                    tile("\(r.notConverted)", "not converted", ok: r.notConverted == 0)
                }
                if r.lines.isEmpty {
                    Text("Everything converted.").font(.chrome(14.5)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(r.lines, id: \.self) { Text("· " + $0).font(.chrome(14.5)) }
                    }
                }
                Text(
                    "Also imports MindNode, Word (.docx), TextBundle, OPML, Markdown, Mermaid, PlantUML subset, draw.io, FreeMind and MindManager (best effort), and indented text."
                )
                .font(.chrome(13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") { controller.closeImportReport() }.buttonStyle(FileButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Import report")
        }
    }

    func tile(_ n: String, _ label: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(n).font(.chrome(28, weight: .bold)).foregroundStyle(
                ok ? Color(red: 0.1, green: 0.45, blue: 0.3) : Color(red: 0.6, green: 0.4, blue: 0))
            Text(label).font(.chrome(13.5))
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(ok ? Color.green.opacity(0.1) : Color.orange.opacity(0.12)))
    }
}

// MARK: Recovery snapshots

struct SnapshotsSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let list = controller.snapshots {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recovery snapshots").font(.chrome(18, weight: .semibold))
                    Spacer()
                    Text("File › Revert To").font(.chrome(12, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(18)
                Divider()
                if list.isEmpty {
                    Text("No snapshots yet. OpenNexus keeps one every five minutes while you edit, and when you close.")
                        .foregroundStyle(.secondary).padding(20)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(list) { s in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.date.formatted(date: .abbreviated, time: .standard)).font(
                                            .chrome(14.5))
                                        Text(
                                            s.encrypted
                                                ? Loc.n("%lld topic · encrypted", "%lld topics · encrypted", s.topics)
                                                : Loc.n("%lld topic", "%lld topics", s.topics)
                                        ).font(
                                            .chrome(12.5)
                                        ).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Restore") {
                                        controller.snapshots = nil
                                        controller.onRestoreSnapshot?(s)
                                    }
                                    .buttonStyle(FileButtonStyle())
                                }
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                    .accessibilityLabel(Loc.t("Snapshots"))
                    .frame(maxHeight: 380)
                }
                HStack {
                    Text("Restore is one undo. Older versions: File › Revert To › Browse All Versions.").font(
                        .chrome(12.5)
                    ).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { controller.snapshots = nil }.buttonStyle(FileButtonStyle()).keyboardShortcut(
                        .cancelAction)
                }
                .padding(16)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        }
    }
}
