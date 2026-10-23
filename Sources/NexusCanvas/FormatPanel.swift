import AppKit
import NexusCore
import NexusKeys
import NexusLayout
import NexusTheme
import SwiftUI

/// The Format panel (⌘I): Style (selection), Map (whole canvas) and Data tabs.
/// Every control writes through the controller, so each change is one undo step.
public struct FormatPanel: View {
    var controller: CanvasController
    @AppStorage("format.tab") private var tab = "style"

    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        let _ = controller.store.revision
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(
                    [("style", Loc.t("Style")), ("map", Loc.t("Map")), ("data", Loc.t("Data"))]
                        + (controller.canvas.type == .threatModel ? [("stride", "STRIDE")] : []), id: \.0
                ) { id, title in
                    Button {
                        tab = id
                    } label: {
                        VStack(spacing: 6) {
                            Text(title)
                                .font(.chrome(14, weight: tab == id ? .semibold : .regular))
                                .foregroundStyle(tab == id ? .primary : .secondary)
                            Rectangle().fill(tab == id ? Color.accentColor : .clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == id ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case "map": MapTab(controller: controller)
                    case "data": DataTab(controller: controller)
                    case "stride" where controller.canvas.type == .threatModel: StrideTab(controller: controller)
                    default:
                        if let ref = controller.selectedElement, !(ref.isCallout) {
                            ElementStyleTab(controller: controller, ref: ref)
                        } else {
                            StyleTab(controller: controller)
                        }
                    }
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(Loc.t("Format options"))
        }
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Format panel")
    }
}

// MARK: - Style tab (FMT-1)

struct StyleTab: View {
    var controller: CanvasController

    var style: TopicStyle { controller.selectionStyle }
    var override: TopicStyle { controller.selectionOverride }
    var node: Node? { controller.canvas.nodes[controller.selection.primary] }
    var branch: RGBA {
        controller.scene.nodes[controller.selection.primary]?.branchColor ?? controller.theme.ring
    }

    func set(_ name: String, _ body: @escaping (inout TopicStyle) -> Void) {
        controller.updateSelectionStyle(name, body)
    }

    func key(_ id: CommandID) -> String { controller.bindings(for: id).first?.glyphs ?? "" }

    var body: some View {
        quickStyles
        Divider()
        actions
        Divider()
        structure
        Divider()
        shapes
        Divider()
        fill
        Divider()
        border
        Divider()
        text
        Divider()
        numbering
        Divider()
        size
        Divider()
        branchLine
        Divider()
        spacing
    }

    var quickStyles: some View {
        PanelSection(
            Loc.t("Quick style"), key: "quick",
            accessory: {
                Text("⌃⌥1–8").font(.chrome(11, design: .monospaced)).foregroundStyle(.secondary)
            }
        ) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(controller.styleEnvironment.quickStyles) { q in
                    Button {
                        controller.applyQuickStyle(q.id)
                    } label: {
                        HStack(spacing: 8) {
                            QuickGlyph(quick: q, theme: controller.theme)
                            Text(q.name).font(.chrome(13)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    node?.quickStyle == q.id ? Color.accentColor : Color(nsColor: .separatorColor))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick style")
            Text("Xmind’s four (Very Important, Important, Cross Out, Default) plus four for technical work.")
                .font(.chrome(11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }

    @State private var quickName = ""
    @State private var askingQuickName = false

    var actions: some View {
        PanelSection(Loc.t("Style actions"), key: "actions") {
            VStack(alignment: .leading, spacing: 2) {
                actionRow(Loc.t("Copy style"), key(.copyStyle)) { controller.copyStyle() }
                actionRow(Loc.t("Paste style"), key(.pasteStyle)) { controller.pasteStyle() }
                actionRow(Loc.t("Reset style"), key(.resetStyle)) { controller.resetStyle() }
                Menu {
                    updateStyleItems
                } label: {
                    Text("Update style").font(.chrome(13)).accessibilityHidden(true)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Update style")
                .padding(.vertical, 4)
                actionRow(Loc.t("Save as Quick Style…"), "") { askingQuickName = true }
                actionRow(Loc.t("Select topics with this style"), "") { controller.selectTopicsWithSameStyle() }
            }
            .alert("Save as Quick Style", isPresented: $askingQuickName) {
                TextField("Name", text: $quickName)
                Button("Save") {
                    if !quickName.isEmpty { controller.saveAsQuickStyle(named: quickName) }
                    quickName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder var updateStyleItems: some View {
        let depth = controller.canvas.depth(of: controller.selection.primary)
        Button("Apply to siblings") { controller.updateStyle(.siblings) }
        Button(Loc.f("Apply to all level-%lld topics", depth + 1)) { controller.updateStyle(.sameLevel) }
        Button("Apply to all subtopics of this branch") { controller.updateStyle(.subtopics) }
        Divider()
        Button("Save as Quick Style…") { askingQuickName = true }
        Button("Save into this theme") { controller.updateStyle(.sameLevel) }
    }

    func actionRow(_ title: String, _ keys: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.chrome(13))
                Spacer()
                Text(keys).font(.chrome(11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The picker's choices: the nine structures in ⌥⌘1…9 order, each named from the
    /// structure it applies, then the extras (D249), and the current one first when it's
    /// another direction.
    static func structureOptions(current: LayoutStructure) -> [(LayoutStructure, String)] {
        let offered = CanvasController.structureCycle + CanvasController.structureExtras
        let all = offered.contains(current) ? offered : [current] + offered
        return all.map { ($0, CanvasController.structureName($0)) }
    }

    var structure: some View {
        let current = node?.structure ?? controller.canvas.layout.structure
        let shortcut = CanvasController.structureCycle.firstIndex(of: current)
        return PanelSection(Loc.t("Structure · this branch"), key: "structure") {
            HStack {
                Picker(
                    Loc.t("Structure"),
                    selection: Binding(get: { current }, set: { controller.setStructure($0) })
                ) {
                    ForEach(Self.structureOptions(current: current), id: \.0) { s, name in Text(name).tag(s) }
                }
                .labelsHidden()
                if let shortcut { Keycap(text: key(.structure(shortcut + 1))) }
            }
        }
    }

    var shapes: some View {
        PanelSection(
            Loc.t("Shape"), key: "shape",
            accessory: {
                Text("\(ShapeLibrary.all.count)").font(.chrome(11)).foregroundStyle(.secondary)
            }
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(ShapeLibrary.all) { sh in
                    Tile(selected: (style.shape ?? "rounded") == sh.id, height: 30) {
                        set(Loc.t("Shape")) { $0.shape = sh.id }
                    } content: {
                        PathIcon(d: sh.icon, lineWidth: 1.3).padding(4)
                    }
                    .help(sh.name)
                    .accessibilityLabel(sh.name)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shape")
        }
    }

    var palette: [RGBA] {
        let p = controller.styleEnvironment.palette
        return Array(p.prefix(4)) + [controller.theme.ink, .white]
    }

    var fill: some View {
        PanelSection(Loc.t("Fill"), key: "fill") {
            Segments(
                options: [
                    ("none", Loc.t("None")), ("solid", Loc.t("Solid")), ("tint", Loc.t("Tint")),
                    ("gradient", Loc.t("Gradient")),
                ],
                selection: style.fill ?? "solid"
            ) { v in set(Loc.t("Fill")) { $0.fill = v } }
            HStack(spacing: 7) {
                ForEach(palette, id: \.self) { c in
                    Swatch(color: c, selected: override.fillColor == c.hex) {
                        set(Loc.t("Fill Colour")) {
                            $0.fillColor = c.hex
                            if $0.fill == nil || $0.fill == "none" { $0.fill = "solid" }
                        }
                    }
                }
                ColorPicker(
                    "",
                    selection: hexBinding(override.fillColor, fallback: branch) { hex in
                        set(Loc.t("Fill Colour")) { $0.fillColor = hex }
                    }
                )
                .labelsHidden()
                .accessibilityLabel("Custom colour")
                .frame(width: 34)
                Spacer(minLength: 0)
            }
            LabeledMenu(Loc.t("Branch colour")) {
                Button("Follow branch colour") { set(Loc.t("Fill Colour")) { $0.fillColor = "branch" } }
                Button("Branch tint") { set(Loc.t("Fill Colour")) { $0.fillColor = "branch@0.16" } }
                Button("Theme default") { set(Loc.t("Fill Colour")) { $0.fillColor = nil } }
            }
            .fixedSize()
        }
    }

    var border: some View {
        PanelSection(Loc.t("Border"), key: "border") {
            HStack {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.border ?? "none" }, set: { v in set(Loc.t("Border")) { $0.border = v } })
                ) {
                    ForEach(NodeAppearance.BorderPattern.allCases, id: \.rawValue) { b in
                        Text(b.rawValue.capitalized).tag(b.rawValue)
                    }
                }
                .labelsHidden()
                Picker(
                    "",
                    selection: Binding(
                        get: { style.borderWidth ?? 0 }, set: { v in set(Loc.t("Border Width")) { $0.borderWidth = v } }
                    )
                ) {
                    ForEach([0, 0.5, 1, 1.5, 2, 2.5, 3, 4, 6] as [Double], id: \.self) { w in
                        Text(CanvasPanelFormat.points(w)).tag(w)
                    }
                }
                .labelsHidden()
                .frame(width: 80)
                ColorPicker(
                    "",
                    selection: hexBinding(override.borderColor, fallback: branch) { hex in
                        set(Loc.t("Border Colour")) { $0.borderColor = hex }
                    }
                )
                .labelsHidden()
                .accessibilityLabel("Custom colour")
                .frame(width: 34)
            }
            Segments(
                options: [
                    ("solid", "——"), ("dashed", "- - -"), ("dotted", "· · ·"), ("hand", Loc.t("≈ hand")),
                    ("double", Loc.t("═ double")),
                ],
                selection: style.border
            ) { v in
                set(Loc.t("Border")) {
                    $0.border = v
                    if ($0.borderWidth ?? 0) == 0 { $0.borderWidth = 2 }
                }
            }
            PanelRow(label: Loc.t("Corner radius")) {
                PointField(value: style.cornerRadius) { v in set(Loc.t("Corner Radius")) { $0.cornerRadius = v } }
            }
            PanelRow(label: Loc.t("Shadow")) {
                Segments(
                    options: [("none", Loc.t("None")), ("soft", Loc.t("Soft")), ("hard", Loc.t("Hard"))],
                    selection: style.shadow ?? "none"
                ) {
                    v in set(Loc.t("Shadow")) { $0.shadow = v }
                }
                .frame(maxWidth: 170)
            }
        }
    }

    static let fonts: [(String, String)] = [
        ("system", Loc.t("SF Pro")), ("serif", Loc.t("New York")), ("mono", Loc.t("SF Mono")),
        ("rounded", Loc.t("SF Pro Rounded")),
        ("hand", Loc.t("Handwriting")),
    ]

    var text: some View {
        PanelSection(Loc.t("Text · applies to selected characters while editing"), key: "text") {
            HStack {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.font ?? "system" }, set: { v in set(Loc.t("Font")) { $0.font = v } })
                ) {
                    ForEach(Self.fonts, id: \.0) { Text($0.1).tag($0.0) }
                    Divider()
                    ForEach(NSFontManager.shared.availableFontFamilies.prefix(40), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Picker(
                    "",
                    selection: Binding(
                        get: { style.fontSize ?? 0 },
                        set: { v in set(Loc.t("Font Size")) { $0.fontSize = v == 0 ? nil : v } })
                ) {
                    Text("Auto").tag(0.0)
                    ForEach([12, 13, 14, 15, 16, 18, 20, 24, 28, 32] as [Double], id: \.self) {
                        Text(Loc.f("%lld pt", Int($0))).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 84)
            }
            HStack {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.fontWeight ?? "medium" },
                        set: { v in set(Loc.t("Font Weight")) { $0.fontWeight = v } })
                ) {
                    ForEach(["regular", "medium", "semibold", "bold", "heavy"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                .labelsHidden()
                Toggle(
                    "Auto contrast",
                    isOn: Binding(
                        get: { style.autoContrast ?? true },
                        set: { v in set(Loc.t("Auto Contrast")) { $0.autoContrast = v } })
                )
                .toggleStyle(.checkbox)
                .font(.chrome(13))
            }
            HStack(spacing: 0) {
                textToggle("B", .bold, style.fontWeight == "bold" || style.fontWeight == "heavy") {
                    set(Loc.t("Bold")) { $0.fontWeight = ($0.fontWeight == "bold") ? "medium" : "bold" }
                }
                textToggle("I", .regular, style.italic == true, italic: true) {
                    set(Loc.t("Italic")) { $0.italic = !(style.italic ?? false) }
                }
                textToggle("U", .regular, style.underline == true, underline: true) {
                    set(Loc.t("Underline")) { $0.underline = !(style.underline ?? false) }
                }
                textToggle("S", .regular, style.strikethrough == true, strike: true) {
                    set(Loc.t("Strikethrough")) { $0.strikethrough = !(style.strikethrough ?? false) }
                }
                textToggle("</>", .regular, style.code == true) {
                    set(Loc.t("Code")) { $0.code = !(style.code ?? false) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            PanelRow(label: Loc.t("Case")) {
                Segments(
                    options: [("none", Loc.t("Aa")), ("upper", "AA"), ("lower", "aa"), ("title", Loc.t("Title"))],
                    selection: style.textCase ?? "none"
                ) {
                    v in set(Loc.t("Case")) { $0.textCase = v }
                }
                .frame(maxWidth: 190)
            }
            PanelRow(label: Loc.t("Align")) {
                Segments(
                    options: [("leading", "⟸"), ("center", "≡"), ("trailing", "⟹")], selection: style.align ?? "center"
                ) {
                    v in set(Loc.t("Align")) { $0.align = v }
                }
                .frame(maxWidth: 130)
            }
            PanelRow(label: Loc.t("Line spacing")) {
                Picker(
                    "",
                    selection: Binding(
                        get: { style.lineSpacing ?? 0 },
                        set: { v in set(Loc.t("Line Spacing")) { $0.lineSpacing = v == 0 ? nil : v } })
                ) {
                    Text("Auto").tag(0.0)
                    ForEach([1.0, 1.15, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%.2g", $0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 84)
            }
        }
    }

    func textToggle(
        _ label: String, _ weight: Font.Weight, _ on: Bool, italic: Bool = false, underline: Bool = false,
        strike: Bool = false, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.chrome(13, weight: weight))
                .italic(italic)
                .underline(underline)
                .strikethrough(strike)
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(on ? Color.accentColor : .primary)
                .background(on ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    static let numberFormats: [(String, String)] = [
        ("none", Loc.t("None")), ("decimal", "1 2 3"), ("tiered", "1.1 1.2"), ("roman", Loc.t("I II")),
        ("upper", "A B C"),
        ("lower", "a b c"), ("circled", "① ②"), ("cjk", "一 二"),
    ]

    /// Numbering on the primary topic numbers its children; "Apply to siblings" numbers
    /// the topic and its siblings instead (stored on the parent).
    var numberingTarget: NodeID {
        let id = controller.selection.primary
        let siblings = numberingSiblings
        return siblings ? (controller.canvas.parent(of: id) ?? id) : id
    }

    @AppStorage("format.numbering.siblings") private var numberingSiblings = true

    var numbering: some View {
        let target = numberingTarget
        let current = controller.canvas.nodes[target]?.style?.numbering
        return PanelSection(Loc.t("Numbering"), key: "numbering") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.numberFormats, id: \.0) { id, label in
                    Tile(selected: (current?.format ?? "none") == id, height: 30) {
                        controller.select(target)
                        controller.updateSelectionStyle(Loc.t("Numbering")) {
                            var n = $0.numbering ?? NumberingStyle()
                            n.format = id
                            if id == "tiered" { n.tiered = true }
                            $0.numbering = id == "none" ? nil : n
                        }
                    } content: {
                        Text(label).font(.chrome(12, design: .monospaced))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Numbering")
            PanelToggle(label: "Tiered (2.1, 2.2…)", isOn: current?.tiered ?? false) { v in
                controller.select(target)
                controller.updateSelectionStyle(Loc.t("Numbering")) {
                    var n = $0.numbering ?? NumberingStyle(format: "decimal")
                    n.tiered = v
                    $0.numbering = n
                }
            }
            PanelToggle(label: Loc.t("Apply to siblings"), isOn: numberingSiblings) { numberingSiblings = $0 }
            PanelToggle(label: Loc.t("Restart from this topic"), isOn: current?.restart ?? false) { v in
                controller.select(target)
                controller.updateSelectionStyle(Loc.t("Numbering")) {
                    var n = $0.numbering ?? NumberingStyle(format: "decimal")
                    n.restart = v
                    $0.numbering = n
                }
            }
        }
    }

    var size: some View {
        PanelSection(Loc.t("Size"), key: "size") {
            PanelRow(label: Loc.t("Width")) {
                PointField(value: style.width) { v in set(Loc.t("Width")) { $0.width = v } }
                Button("Fit") { set(Loc.t("Width")) { $0.width = nil } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            PanelRow(label: Loc.t("Image position")) {
                Segments(
                    options: [
                        ("top", Loc.t("Top")), ("left", Loc.t("Left")), ("right", Loc.t("Right")),
                        ("bottom", Loc.t("Bottom")),
                    ],
                    selection: style.imagePosition ?? "top"
                ) {
                    v in set(Loc.t("Image Position")) { $0.imagePosition = v }
                }
                .frame(maxWidth: 190)
            }
        }
    }

    static let lineShapes: [(String, String, String)] = [
        ("curved", Loc.t("Curved"), "M2 16 C 22 16, 22 2, 42 2"), ("straight", Loc.t("Straight"), "M2 16 L 42 2"),
        ("elbow", Loc.t("Elbow"), "M2 16 H 22 V 2 H 42"),
        ("rounded", Loc.t("Rounded"), "M2 16 H 16 Q 22 16 22 10 V 8 Q 22 2 28 2 H 42"),
        ("tapered", Loc.t("Tapered"), "M2 16 C 22 16, 22 2, 42 2"),
        ("zigzag", Loc.t("Zigzag"), "M2 16 L 12 6 L 22 14 L 32 4 L 42 2"),
    ]

    var line: LineStyle { override.line ?? LineStyle() }

    func setLine(_ name: String, _ body: @escaping (inout LineStyle) -> Void) {
        set(name) {
            var l = $0.line ?? LineStyle()
            body(&l)
            $0.line = l.isEmpty ? nil : l
        }
    }

    var branchLine: some View {
        let shape = line.taper == true ? "tapered" : (line.shape ?? controller.theme.lineShape)
        return PanelSection(Loc.t("Branch line"), key: "line") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Self.lineShapes, id: \.0) { id, name, d in
                    Tile(selected: shape == id, height: 52) {
                        setLine(Loc.t("Branch Line")) {
                            if id == "tapered" {
                                $0.taper = true
                                $0.shape = "curved"
                            } else {
                                $0.taper = nil
                                $0.shape = id
                            }
                        }
                    } content: {
                        VStack(spacing: 2) {
                            PathIcon(d: d, lineWidth: id == "tapered" ? 3 : 1.6).frame(height: 22)
                            Text(name).font(.chrome(11))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Branch line")
            HStack {
                Toggle(
                    isOn: Binding(
                        get: { (line.color ?? "branch") == "branch" },
                        set: { v in setLine(Loc.t("Line Colour")) { $0.color = v ? nil : controller.theme.ink2.hex } })
                ) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(branch.color).frame(width: 12, height: 12)
                        Text("Follow branch").font(.chrome(13))
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { line.width ?? 0 },
                        set: { v in setLine(Loc.t("Line Width")) { $0.width = v == 0 ? nil : v } })
                ) {
                    Text("Auto").tag(0.0)
                    ForEach([1, 1.5, 2, 3, 4, 6] as [Double], id: \.self) { Text(CanvasPanelFormat.points($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 84)
            }
            PanelRow(label: Loc.t("End cap")) {
                Segments(
                    options: [
                        ("none", Loc.t("None")), ("arrow", Loc.t("Arrow")), ("dot", Loc.t("Dot")),
                        ("bar", Loc.t("Bar")),
                    ],
                    selection: line.endCap ?? "none"
                ) {
                    v in setLine(Loc.t("End Cap")) { $0.endCap = v }
                }
                .frame(maxWidth: 190)
            }
            PanelToggle(label: Loc.t("Taper thick → thin"), isOn: line.taper ?? false) { v in
                setLine(Loc.t("Taper")) { $0.taper = v }
            }
            PanelToggle(label: Loc.t("Children’s lines inherit"), isOn: line.inherit ?? true) { v in
                setLine(Loc.t("Inherit")) { $0.inherit = v }
            }
        }
    }

    var spacing: some View {
        PanelSection(Loc.t("Spacing · this branch"), key: "spacing") {
            PanelRow(label: Loc.t("Sibling gap")) {
                Slider(
                    value: Binding(
                        get: { style.siblingGap ?? 20 },
                        set: { v in set(Loc.t("Sibling Gap")) { $0.siblingGap = v.rounded() } }), in: 0...80
                )
                .frame(width: 150)
                .accessibilityLabel(Loc.t("Sibling gap"))
            }
            PanelRow(label: Loc.t("Level gap")) {
                Slider(
                    value: Binding(
                        get: { style.levelGap ?? 40 },
                        set: { v in set(Loc.t("Level Gap")) { $0.levelGap = v.rounded() } }),
                    in: 8...160
                )
                .frame(width: 150)
                .accessibilityLabel(Loc.t("Level gap"))
            }
            Divider().padding(.vertical, 4)
            Text("UPDATE STYLE").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                let depth = controller.canvas.depth(of: controller.selection.primary)
                actionRow(Loc.t("Apply to siblings"), "") { controller.updateStyle(.siblings) }
                actionRow(Loc.f("Apply to all level-%lld topics", depth + 1), "") { controller.updateStyle(.sameLevel) }
                actionRow(Loc.t("Apply to all subtopics of this branch"), "") { controller.updateStyle(.subtopics) }
                actionRow(Loc.t("Save as Quick Style…"), "") { askingQuickName = true }
                actionRow(Loc.t("Save into this theme"), "") { controller.updateStyle(.sameLevel) }
            }
        }
    }
}

/// A quick style's chip (FMT-1).
struct QuickGlyph: View {
    let quick: QuickStyle
    let theme: Theme

    var body: some View {
        let env = StyleEnvironment(theme: theme, canvasStyle: CanvasStyle())
        let fill = StyleResolver.resolveColor(quick.style.fillColor, branch: theme.ring, env: env) ?? .white
        let fg = StyleResolver.resolveColor(quick.style.textColor, branch: theme.ring, env: env) ?? theme.ink
        let border = StyleResolver.resolveColor(quick.style.borderColor, branch: theme.ring, env: env)
        Text(quick.glyph)
            .font(.chrome(11, weight: .bold))
            .strikethrough(quick.style.strikethrough == true)
            .foregroundStyle(fg.color)
            .frame(width: 26, height: 22)
            .background(fill.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        border?.color ?? Color(nsColor: .separatorColor),
                        style: StrokeStyle(
                            lineWidth: border == nil ? 0.5 : 1.5,
                            dash: quick.style.border == "dashed" ? [3, 2] : [])))
    }
}
